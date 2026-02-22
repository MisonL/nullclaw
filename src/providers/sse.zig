const std = @import("std");
const root = @import("root.zig");

/// Result of parsing a single SSE line.
pub const SseLineResult = union(enum) {
    /// Text delta content (owned, caller frees).
    delta: []const u8,
    /// Stream is complete ([DONE] sentinel).
    done: void,
    /// Line should be skipped (empty, comment, or no content).
    skip: void,
};

fn parseSseDataPayload(allocator: std.mem.Allocator, data: []const u8) !SseLineResult {
    if (std.mem.eql(u8, data, "[DONE]")) return .done;
    if (try extractDeltaContent(allocator, data)) |content| {
        return .{ .delta = content };
    }
    if (try extractResponsesTextDelta(allocator, data)) |content| {
        return .{ .delta = content };
    }
    if (isResponsesDoneEvent(data)) return .done;
    return .skip;
}

/// Parse a single SSE line in OpenAI streaming format.
///
/// Handles:
/// - `data: [DONE]` → `.done`
/// - `data: {JSON}` → extracts `choices[0].delta.content` → `.delta`
/// - Empty lines, comments (`:`) → `.skip`
pub fn parseSseLine(allocator: std.mem.Allocator, line: []const u8) !SseLineResult {
    const trimmed = std.mem.trimRight(u8, line, "\r");

    if (trimmed.len == 0) return .skip;
    if (trimmed[0] == ':') return .skip;

    const prefix = "data:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return .skip;

    const data = std.mem.trimLeft(u8, trimmed[prefix.len..], " \t");

    return parseSseDataPayload(allocator, data);
}

/// Extract `choices[0].delta.content` from an SSE JSON payload.
/// Returns owned slice or null if no content found.
pub fn extractDeltaContent(allocator: std.mem.Allocator, json_str: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const choices = obj.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;

    const first = choices.array.items[0];
    if (first != .object) return null;

    const delta = first.object.get("delta") orelse return null;
    if (delta != .object) return null;

    const content = delta.object.get("content") orelse return null;
    if (content != .string) return null;
    if (content.string.len == 0) return null;

    return try allocator.dupe(u8, content.string);
}

fn extractResponsesTextDelta(allocator: std.mem.Allocator, json_str: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    const event_type = if (obj.get("type")) |tv|
        if (tv == .string) tv.string else ""
    else
        "";

    if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
        const delta = obj.get("delta") orelse return null;
        if (delta == .string and delta.string.len > 0) {
            return try allocator.dupe(u8, delta.string);
        }
        return null;
    }

    if (std.mem.eql(u8, event_type, "response.output_text.done")) {
        const text = obj.get("text") orelse return null;
        if (text == .string and text.string.len > 0) {
            return try allocator.dupe(u8, text.string);
        }
        return null;
    }

    return null;
}

fn isResponsesDoneEvent(json_str: []const u8) bool {
    const allocator = std.heap.page_allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return false;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };

    const event_type = if (obj.get("type")) |tv|
        if (tv == .string) tv.string else ""
    else
        "";

    return std.mem.eql(u8, event_type, "response.completed") or
        std.mem.eql(u8, event_type, "response.done");
}

fn fallbackNonSseContent(allocator: std.mem.Allocator, raw_response: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw_response, " \t\r\n");
    if (trimmed.len == 0) return null;
    return root.extractContent(allocator, trimmed) catch null;
}

const NormalizedSseEvent = union(enum) {
    text_delta: []const u8,
    tool_call_delta: ToolCallDelta,
    stream_done: void,
    skip: void,
};

const ToolCallDelta = struct {
    id: ?[]const u8 = null,
    index: ?usize = null,
    order: usize = 0,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

const PartialToolCall = struct {
    seen: bool = false,
    index_hint: ?usize = null,
    order_hint: ?usize = null,
    id: std.ArrayListUnmanaged(u8) = .empty,
    name: std.ArrayListUnmanaged(u8) = .empty,
    arguments: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *PartialToolCall, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.arguments.deinit(allocator);
    }
};

fn appendIfNewSegment(
    allocator: std.mem.Allocator,
    target: *std.ArrayListUnmanaged(u8),
    segment: []const u8,
) !void {
    if (segment.len == 0) return;
    if (target.items.len == 0) {
        try target.appendSlice(allocator, segment);
        return;
    }

    if (std.mem.eql(u8, target.items, segment)) return;
    if (std.mem.endsWith(u8, target.items, segment)) return;
    if (std.mem.startsWith(u8, segment, target.items)) {
        try target.appendSlice(allocator, segment[target.items.len..]);
        return;
    }

    const max_overlap = @min(target.items.len, segment.len);
    var overlap = max_overlap;
    while (overlap > 0) : (overlap -= 1) {
        if (std.mem.eql(u8, target.items[target.items.len - overlap ..], segment[0..overlap])) {
            try target.appendSlice(allocator, segment[overlap..]);
            return;
        }
    }

    try target.appendSlice(allocator, segment);
}

fn findPartialById(partials: []PartialToolCall, id: []const u8) ?usize {
    for (partials, 0..) |partial, idx| {
        if (partial.id.items.len == 0) continue;
        if (std.mem.eql(u8, partial.id.items, id)) return idx;
    }
    return null;
}

fn findPartialByIndex(partials: []PartialToolCall, index: usize) ?usize {
    for (partials, 0..) |partial, idx| {
        if (partial.index_hint) |hint| {
            if (hint == index) return idx;
        }
    }
    return null;
}

fn findPartialByOrder(partials: []PartialToolCall, order: usize) ?usize {
    for (partials, 0..) |partial, idx| {
        if (partial.order_hint) |hint| {
            if (hint == order) return idx;
        }
    }
    return null;
}

fn resolvePartialToolCall(
    allocator: std.mem.Allocator,
    partials: *std.ArrayListUnmanaged(PartialToolCall),
    delta: ToolCallDelta,
) !*PartialToolCall {
    if (delta.id) |id| {
        if (findPartialById(partials.items, id)) |idx| {
            return &partials.items[idx];
        }
    }
    if (delta.index) |index| {
        if (findPartialByIndex(partials.items, index)) |idx| {
            return &partials.items[idx];
        }
    }
    if (findPartialByOrder(partials.items, delta.order)) |idx| {
        return &partials.items[idx];
    }

    try partials.append(allocator, .{ .order_hint = delta.order });
    return &partials.items[partials.items.len - 1];
}

fn applyToolCallDelta(
    allocator: std.mem.Allocator,
    partials: *std.ArrayListUnmanaged(PartialToolCall),
    delta: ToolCallDelta,
) !void {
    const partial = try resolvePartialToolCall(allocator, partials, delta);
    partial.seen = true;
    partial.order_hint = delta.order;

    if (delta.index) |idx| {
        partial.index_hint = idx;
    }
    if (delta.id) |id| {
        try appendIfNewSegment(allocator, &partial.id, id);
    }
    if (delta.name) |name| {
        try appendIfNewSegment(allocator, &partial.name, name);
    }
    if (delta.arguments) |args| {
        try appendIfNewSegment(allocator, &partial.arguments, args);
    }
}

fn parseOptionalIndex(val: ?std.json.Value) ?usize {
    const idx_val = val orelse return null;
    if (idx_val != .integer or idx_val.integer < 0) return null;
    return @intCast(idx_val.integer);
}

fn valueAsNonEmptyString(val: ?std.json.Value) ?[]const u8 {
    const v = val orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

fn normalizeChatCompletionsPayload(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    accumulated: *std.ArrayListUnmanaged(u8),
    tool_partials: *std.ArrayListUnmanaged(PartialToolCall),
    callback: root.StreamCallback,
    ctx: *anyopaque,
    saw_text_or_tool: *bool,
) !bool {
    const choices_val = obj.get("choices") orelse return false;
    const choices = switch (choices_val) {
        .array => |arr| arr,
        else => return false,
    };
    if (choices.items.len == 0) return true;

    const first_val = choices.items[0];
    const first_obj = switch (first_val) {
        .object => |o| o,
        else => return true,
    };

    const delta_val = first_obj.get("delta") orelse return true;
    const delta_obj = switch (delta_val) {
        .object => |o| o,
        else => return true,
    };

    if (valueAsNonEmptyString(delta_obj.get("content"))) |content| {
        try accumulated.appendSlice(allocator, content);
        callback(ctx, root.StreamChunk.textDelta(content));
        saw_text_or_tool.* = true;
    }

    const tool_calls_val = delta_obj.get("tool_calls") orelse return true;
    const tool_calls = switch (tool_calls_val) {
        .array => |arr| arr,
        else => return true,
    };

    for (tool_calls.items, 0..) |tc_val, order| {
        const tc_obj = switch (tc_val) {
            .object => |o| o,
            else => continue,
        };

        const func_val = tc_obj.get("function");
        const func_obj = if (func_val) |fv| switch (fv) {
            .object => |o| o,
            else => null,
        } else null;

        const delta: ToolCallDelta = .{
            .id = valueAsNonEmptyString(tc_obj.get("id")),
            .index = parseOptionalIndex(tc_obj.get("index")),
            .order = order,
            .name = if (func_obj) |fo| valueAsNonEmptyString(fo.get("name")) else null,
            .arguments = if (func_obj) |fo| valueAsNonEmptyString(fo.get("arguments")) else null,
        };
        try applyToolCallDelta(allocator, tool_partials, delta);
        saw_text_or_tool.* = true;
    }

    return true;
}

fn normalizeResponsesOutputItemToolCall(
    allocator: std.mem.Allocator,
    item_obj: std.json.ObjectMap,
    output_index: ?usize,
    fallback_order: usize,
    tool_partials: *std.ArrayListUnmanaged(PartialToolCall),
) !bool {
    const item_type = valueAsNonEmptyString(item_obj.get("type")) orelse return false;
    const is_tool_call = std.mem.eql(u8, item_type, "function_call") or
        std.mem.eql(u8, item_type, "tool_call");
    if (!is_tool_call) return false;

    const id_primary = valueAsNonEmptyString(item_obj.get("call_id"));
    const id_fallback = valueAsNonEmptyString(item_obj.get("id"));
    const id = id_primary orelse id_fallback;

    const delta: ToolCallDelta = .{
        .id = id,
        .index = output_index,
        .order = output_index orelse fallback_order,
        .name = valueAsNonEmptyString(item_obj.get("name")),
        .arguments = valueAsNonEmptyString(item_obj.get("arguments")),
    };
    try applyToolCallDelta(allocator, tool_partials, delta);
    return true;
}

fn normalizeResponsesPayload(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    accumulated: *std.ArrayListUnmanaged(u8),
    tool_partials: *std.ArrayListUnmanaged(PartialToolCall),
    callback: root.StreamCallback,
    ctx: *anyopaque,
    next_tool_order: *usize,
    saw_text_or_tool: *bool,
) !bool {
    const event_type = valueAsNonEmptyString(obj.get("type")) orelse return false;

    if (std.mem.eql(u8, event_type, "response.completed") or std.mem.eql(u8, event_type, "response.done")) {
        return true;
    }

    if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
        if (valueAsNonEmptyString(obj.get("delta"))) |delta| {
            try accumulated.appendSlice(allocator, delta);
            callback(ctx, root.StreamChunk.textDelta(delta));
            saw_text_or_tool.* = true;
        }
        return false;
    }

    if (std.mem.eql(u8, event_type, "response.output_text.done")) {
        if (valueAsNonEmptyString(obj.get("text"))) |text| {
            try accumulated.appendSlice(allocator, text);
            callback(ctx, root.StreamChunk.textDelta(text));
            saw_text_or_tool.* = true;
        }
        return false;
    }

    if (std.mem.eql(u8, event_type, "response.output_item.added") or
        std.mem.eql(u8, event_type, "response.output_item.done"))
    {
        const item_val = obj.get("item") orelse return false;
        const item_obj = switch (item_val) {
            .object => |o| o,
            else => return false,
        };
        const output_index = parseOptionalIndex(obj.get("output_index"));
        const order = output_index orelse next_tool_order.*;
        if (try normalizeResponsesOutputItemToolCall(
            allocator,
            item_obj,
            output_index,
            order,
            tool_partials,
        )) {
            next_tool_order.* += 1;
            saw_text_or_tool.* = true;
        }
        return false;
    }

    if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta") or
        std.mem.eql(u8, event_type, "response.function_call_arguments.done"))
    {
        const output_index = parseOptionalIndex(obj.get("output_index"));
        const order = output_index orelse next_tool_order.*;
        const delta: ToolCallDelta = .{
            .id = valueAsNonEmptyString(obj.get("call_id")) orelse valueAsNonEmptyString(obj.get("item_id")),
            .index = output_index,
            .order = order,
            .name = valueAsNonEmptyString(obj.get("name")),
            .arguments = valueAsNonEmptyString(obj.get("delta")) orelse valueAsNonEmptyString(obj.get("arguments")),
        };
        if (delta.arguments != null or delta.name != null or delta.id != null or delta.index != null) {
            try applyToolCallDelta(allocator, tool_partials, delta);
            next_tool_order.* += 1;
            saw_text_or_tool.* = true;
        }
        return false;
    }

    return false;
}

fn normalizeAndApplyOpenAiEventData(
    allocator: std.mem.Allocator,
    event_data: []const u8,
    accumulated: *std.ArrayListUnmanaged(u8),
    tool_partials: *std.ArrayListUnmanaged(PartialToolCall),
    callback: root.StreamCallback,
    ctx: *anyopaque,
    next_tool_order: *usize,
    saw_text_or_tool: *bool,
) !struct { handled: bool, done: bool } {
    if (std.mem.eql(u8, event_data, "[DONE]")) {
        _ = try applyNormalizedEvent(allocator, .stream_done, accumulated, tool_partials, callback, ctx);
        return .{ .handled = true, .done = true };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, event_data, .{}) catch return .{ .handled = false, .done = false };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return .{ .handled = false, .done = false },
    };

    var handled_any = false;
    const handled_chat = try normalizeChatCompletionsPayload(
        allocator,
        obj,
        accumulated,
        tool_partials,
        callback,
        ctx,
        saw_text_or_tool,
    );
    if (handled_chat) handled_any = true;

    const done_from_responses = try normalizeResponsesPayload(
        allocator,
        obj,
        accumulated,
        tool_partials,
        callback,
        ctx,
        next_tool_order,
        saw_text_or_tool,
    );
    if (valueAsNonEmptyString(obj.get("type")) != null) handled_any = true;
    if (done_from_responses) return .{ .handled = true, .done = true };

    return .{ .handled = handled_any, .done = false };
}

fn applyNormalizedEvent(
    allocator: std.mem.Allocator,
    event: NormalizedSseEvent,
    accumulated: *std.ArrayListUnmanaged(u8),
    tool_partials: *std.ArrayListUnmanaged(PartialToolCall),
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !bool {
    switch (event) {
        .text_delta => |text| {
            try accumulated.appendSlice(allocator, text);
            callback(ctx, root.StreamChunk.textDelta(text));
            return false;
        },
        .tool_call_delta => |delta| {
            try applyToolCallDelta(allocator, tool_partials, delta);
            return false;
        },
        .stream_done => return true,
        .skip => return false,
    }
}

fn finalizeOpenAiToolCalls(
    allocator: std.mem.Allocator,
    partials: []PartialToolCall,
) ![]root.ToolCall {
    std.mem.sort(PartialToolCall, partials, {}, struct {
        fn lessThan(_: void, a: PartialToolCall, b: PartialToolCall) bool {
            const a_order = a.order_hint orelse std.math.maxInt(usize);
            const b_order = b.order_hint orelse std.math.maxInt(usize);
            return a_order < b_order;
        }
    }.lessThan);
    var calls: std.ArrayListUnmanaged(root.ToolCall) = .empty;
    errdefer {
        for (calls.items) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
            allocator.free(tc.arguments);
        }
        calls.deinit(allocator);
    }

    for (partials, 0..) |partial, i| {
        if (!partial.seen) continue;
        if (partial.name.items.len == 0) continue;

        const id = if (partial.id.items.len > 0)
            try allocator.dupe(u8, partial.id.items)
        else
            try std.fmt.allocPrint(allocator, "call_{d}", .{i});
        errdefer allocator.free(id);

        const name = try allocator.dupe(u8, partial.name.items);
        errdefer allocator.free(name);

        const arguments = if (partial.arguments.items.len > 0)
            try allocator.dupe(u8, partial.arguments.items)
        else
            try allocator.dupe(u8, "{}");
        errdefer allocator.free(arguments);

        try calls.append(allocator, .{
            .id = id,
            .name = name,
            .arguments = arguments,
        });
    }

    return try calls.toOwnedSlice(allocator);
}

fn emitOpenAiSseEventData(
    allocator: std.mem.Allocator,
    event_data: *std.ArrayListUnmanaged(u8),
    accumulated: *std.ArrayListUnmanaged(u8),
    tool_partials: *std.ArrayListUnmanaged(PartialToolCall),
    callback: root.StreamCallback,
    ctx: *anyopaque,
    next_tool_order: *usize,
) !struct { handled: bool, done: bool, saw_text_or_tool: bool } {
    if (event_data.items.len == 0) return .{ .handled = false, .done = false, .saw_text_or_tool = false };
    defer event_data.clearRetainingCapacity();

    var saw_text_or_tool = false;
    const norm = try normalizeAndApplyOpenAiEventData(
        allocator,
        event_data.items,
        accumulated,
        tool_partials,
        callback,
        ctx,
        next_tool_order,
        &saw_text_or_tool,
    );
    return .{
        .handled = norm.handled,
        .done = norm.done,
        .saw_text_or_tool = saw_text_or_tool,
    };
}

fn hasToolCallSignal(partials: []const PartialToolCall) bool {
    for (partials) |partial| {
        if (!partial.seen) continue;
        if (partial.id.items.len > 0) return true;
        if (partial.name.items.len > 0) return true;
        if (partial.arguments.items.len > 0) return true;
    }
    return false;
}

/// Run curl in SSE streaming mode and parse output line by line.
///
/// Spawns `curl -s --no-buffer` and reads stdout incrementally.
/// For each SSE delta, calls `callback(ctx, chunk)`.
/// Returns accumulated result after stream completes.
pub fn curlStream(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    auth_header: ?[]const u8,
    extra_headers: []const []const u8,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    // Build argv on stack.
    var argv_buf: [40][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-s";
    argc += 1;
    argv_buf[argc] = "--no-buffer";
    argc += 1;
    argv_buf[argc] = "-X";
    argc += 1;
    argv_buf[argc] = "POST";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Content-Type: application/json";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Accept: text/event-stream";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Cache-Control: no-cache";
    argc += 1;

    if (auth_header) |auth| {
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = auth;
        argc += 1;
    }

    for (extra_headers) |hdr| {
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = hdr;
        argc += 1;
    }

    argv_buf[argc] = "--data-binary";
    argc += 1;
    argv_buf[argc] = "@-";
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    if (child.stdin) |*stdin_file| {
        stdin_file.writeAll(body) catch {
            stdin_file.close();
            child.stdin = null;
            return error.CurlFailed;
        };
        stdin_file.close();
        child.stdin = null;
    }

    // Read stdout line by line, parse SSE events
    var accumulated: std.ArrayListUnmanaged(u8) = .empty;
    defer accumulated.deinit(allocator);

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);
    var event_data: std.ArrayListUnmanaged(u8) = .empty;
    defer event_data.deinit(allocator);
    var tool_partials: std.ArrayListUnmanaged(PartialToolCall) = .empty;
    defer {
        for (tool_partials.items) |*partial| partial.deinit(allocator);
        tool_partials.deinit(allocator);
    }
    var raw_response: std.ArrayListUnmanaged(u8) = .empty;
    defer raw_response.deinit(allocator);
    var saw_done_event = false;
    var saw_sse_data_line = false;
    var saw_handled_event = false;
    var saw_text_or_tool = false;
    var next_tool_order: usize = 0;

    const file = child.stdout.?;
    var read_buf: [4096]u8 = undefined;

    outer: while (true) {
        const n = file.read(&read_buf) catch break;
        if (n == 0) break;
        try raw_response.appendSlice(allocator, read_buf[0..n]);

        for (read_buf[0..n]) |byte| {
            if (byte == '\n') {
                const line = std.mem.trimRight(u8, line_buf.items, "\r");
                line_buf.clearRetainingCapacity();

                if (line.len == 0) {
                    const emitted = try emitOpenAiSseEventData(
                        allocator,
                        &event_data,
                        &accumulated,
                        &tool_partials,
                        callback,
                        ctx,
                        &next_tool_order,
                    );
                    saw_handled_event = saw_handled_event or emitted.handled;
                    saw_text_or_tool = saw_text_or_tool or emitted.saw_text_or_tool;
                    if (emitted.done) {
                        saw_done_event = true;
                        break :outer;
                    }
                    continue;
                }

                if (line[0] == ':') continue;

                const data_prefix = "data:";
                if (!std.mem.startsWith(u8, line, data_prefix)) continue;
                const data = std.mem.trimLeft(u8, line[data_prefix.len..], " \t");
                if (data.len == 0) continue;
                saw_sse_data_line = true;
                if (event_data.items.len > 0) try event_data.append(allocator, '\n');
                try event_data.appendSlice(allocator, data);
            } else {
                try line_buf.append(allocator, byte);
            }
        }
    }

    // Handle a trailing line without a final '\n'
    if (line_buf.items.len > 0) {
        const line = std.mem.trimRight(u8, line_buf.items, "\r");
        if (line.len > 0 and line[0] != ':') {
            const data_prefix = "data:";
            if (std.mem.startsWith(u8, line, data_prefix)) {
                const data = std.mem.trimLeft(u8, line[data_prefix.len..], " \t");
                if (data.len > 0) {
                    saw_sse_data_line = true;
                    if (event_data.items.len > 0) try event_data.append(allocator, '\n');
                    try event_data.appendSlice(allocator, data);
                }
            }
        }
        line_buf.clearRetainingCapacity();
    }

    // Flush final pending event payload.
    const final_emitted = try emitOpenAiSseEventData(
        allocator,
        &event_data,
        &accumulated,
        &tool_partials,
        callback,
        ctx,
        &next_tool_order,
    );
    saw_handled_event = saw_handled_event or final_emitted.handled;
    saw_text_or_tool = saw_text_or_tool or final_emitted.saw_text_or_tool;
    saw_done_event = saw_done_event or final_emitted.done;

    // Some OpenAI-compatible endpoints ignore stream=true and return one-shot JSON.
    // In that case, recover content only when the stream was clearly not parseable.
    if (!saw_done_event and accumulated.items.len == 0 and !hasToolCallSignal(tool_partials.items)) {
        const can_fallback = raw_response.items.len > 0 and (!saw_sse_data_line or !saw_handled_event);
        if (fallbackNonSseContent(allocator, raw_response.items)) |fallback_text| {
            defer allocator.free(fallback_text);
            if (can_fallback and fallback_text.len > 0) {
                try accumulated.appendSlice(allocator, fallback_text);
                callback(ctx, root.StreamChunk.textDelta(fallback_text));
                saw_text_or_tool = true;
            }
        }
    }

    // Drain remaining stdout to prevent deadlock on wait()
    while (true) {
        const n = file.read(&read_buf) catch break;
        if (n == 0) break;
    }

    const term = child.wait() catch return error.CurlWaitError;
    switch (term) {
        .Exited => |code| if (code != 0) return error.CurlFailed,
        else => return error.CurlFailed,
    }

    const tool_calls = try finalizeOpenAiToolCalls(allocator, tool_partials.items);
    errdefer {
        for (tool_calls) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
            allocator.free(tc.arguments);
        }
        allocator.free(tool_calls);
    }

    if (!saw_done_event and accumulated.items.len == 0 and tool_calls.len == 0 and !saw_text_or_tool) {
        return error.NoResponseContent;
    }

    // Send final chunk only on successful completion.
    callback(ctx, root.StreamChunk.finalChunk());

    const content = if (accumulated.items.len > 0)
        try allocator.dupe(u8, accumulated.items)
    else
        null;

    return .{
        .content = content,
        .tool_calls = tool_calls,
        .usage = .{ .completion_tokens = @intCast((accumulated.items.len + 3) / 4) },
        .model = "",
    };
}

// ════════════════════════════════════════════════════════════════════════════
// Anthropic SSE Parsing
// ════════════════════════════════════════════════════════════════════════════

/// Result of parsing a single Anthropic SSE line.
pub const AnthropicSseResult = union(enum) {
    /// Remember this event type (caller tracks state).
    event: []const u8,
    /// Text delta content (owned, caller frees).
    delta: []const u8,
    /// Output token count from message_delta usage.
    usage: u32,
    /// Stream is complete (message_stop).
    done: void,
    /// Line should be skipped (empty, comment, or uninteresting event).
    skip: void,
};

fn parseAnthropicDataPayload(
    allocator: std.mem.Allocator,
    data: []const u8,
    current_event: []const u8,
) !AnthropicSseResult {
    if (std.mem.eql(u8, current_event, "message_stop")) return .done;

    if (std.mem.eql(u8, current_event, "content_block_delta")) {
        const text = try extractAnthropicDelta(allocator, data) orelse return .skip;
        return .{ .delta = text };
    }

    if (std.mem.eql(u8, current_event, "message_delta")) {
        const tokens = try extractAnthropicUsage(data) orelse return .skip;
        return .{ .usage = tokens };
    }

    return .skip;
}

fn emitAnthropicSseEventData(
    allocator: std.mem.Allocator,
    event_data: *std.ArrayListUnmanaged(u8),
    current_event: []const u8,
    accumulated: *std.ArrayListUnmanaged(u8),
    callback: root.StreamCallback,
    ctx: *anyopaque,
    output_tokens: *u32,
) !bool {
    if (event_data.items.len == 0) return false;
    defer event_data.clearRetainingCapacity();

    const result = parseAnthropicDataPayload(allocator, event_data.items, current_event) catch .skip;
    switch (result) {
        .delta => |text| {
            defer allocator.free(text);
            try accumulated.appendSlice(allocator, text);
            callback(ctx, root.StreamChunk.textDelta(text));
            return false;
        },
        .usage => |tokens| {
            output_tokens.* = tokens;
            return false;
        },
        .done => return true,
        .event, .skip => return false,
    }
}

/// Parse a single SSE line in Anthropic streaming format.
///
/// Anthropic SSE is stateful: `event:` lines set the context for subsequent `data:` lines.
/// The caller must track `current_event` across calls.
///
/// - `event: X` → `.event` (caller remembers X)
/// - `data: {JSON}` + current_event=="content_block_delta" → extracts `delta.text` → `.delta`
/// - `data: {JSON}` + current_event=="message_delta" → extracts `usage.output_tokens` → `.usage`
/// - `data: {JSON}` + current_event=="message_stop" → `.done`
/// - Everything else → `.skip`
pub fn parseAnthropicSseLine(allocator: std.mem.Allocator, line: []const u8, current_event: []const u8) !AnthropicSseResult {
    const trimmed = std.mem.trimRight(u8, line, "\r");

    if (trimmed.len == 0) return .skip;
    if (trimmed[0] == ':') return .skip;

    // Handle "event: TYPE" lines
    const event_prefix = "event:";
    if (std.mem.startsWith(u8, trimmed, event_prefix)) {
        return .{ .event = std.mem.trimLeft(u8, trimmed[event_prefix.len..], " \t") };
    }

    // Handle "data: {JSON}" lines
    const data_prefix = "data:";
    if (!std.mem.startsWith(u8, trimmed, data_prefix)) return .skip;

    const data = std.mem.trimLeft(u8, trimmed[data_prefix.len..], " \t");
    return parseAnthropicDataPayload(allocator, data, current_event);
}

/// Extract `delta.text` from an Anthropic content_block_delta JSON payload.
/// Returns owned slice or null if not a text_delta.
pub fn extractAnthropicDelta(allocator: std.mem.Allocator, json_str: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const delta = obj.get("delta") orelse return null;
    if (delta != .object) return null;

    const dtype = delta.object.get("type") orelse return null;
    if (dtype != .string or !std.mem.eql(u8, dtype.string, "text_delta")) return null;

    const text = delta.object.get("text") orelse return null;
    if (text != .string) return null;
    if (text.string.len == 0) return null;

    return try allocator.dupe(u8, text.string);
}

/// Extract `usage.output_tokens` from an Anthropic message_delta JSON payload.
/// Returns token count or null if not present.
pub fn extractAnthropicUsage(json_str: []const u8) !?u32 {
    // Use a stack buffer for parsing to avoid needing an allocator
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const usage = obj.get("usage") orelse return null;
    if (usage != .object) return null;

    const output_tokens = usage.object.get("output_tokens") orelse return null;
    if (output_tokens != .integer) return null;

    return @intCast(output_tokens.integer);
}

/// Run curl in SSE streaming mode for Anthropic and parse output line by line.
///
/// Similar to `curlStream()` but uses stateful Anthropic SSE parsing.
/// `headers` is a slice of pre-formatted header strings (e.g. "x-api-key: sk-...").
pub fn curlStreamAnthropic(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    // Build argv on stack.
    var argv_buf: [40][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-s";
    argc += 1;
    argv_buf[argc] = "--no-buffer";
    argc += 1;
    argv_buf[argc] = "-X";
    argc += 1;
    argv_buf[argc] = "POST";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Content-Type: application/json";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Accept: text/event-stream";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Cache-Control: no-cache";
    argc += 1;

    for (headers) |hdr| {
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = hdr;
        argc += 1;
    }

    argv_buf[argc] = "--data-binary";
    argc += 1;
    argv_buf[argc] = "@-";
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    if (child.stdin) |*stdin_file| {
        stdin_file.writeAll(body) catch {
            stdin_file.close();
            child.stdin = null;
            return error.CurlFailed;
        };
        stdin_file.close();
        child.stdin = null;
    }

    // Read stdout line by line, parse Anthropic SSE events
    var accumulated: std.ArrayListUnmanaged(u8) = .empty;
    defer accumulated.deinit(allocator);

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);
    var event_data: std.ArrayListUnmanaged(u8) = .empty;
    defer event_data.deinit(allocator);
    var raw_response: std.ArrayListUnmanaged(u8) = .empty;
    defer raw_response.deinit(allocator);

    var current_event: []const u8 = "";
    var output_tokens: u32 = 0;

    const file = child.stdout.?;
    var read_buf: [4096]u8 = undefined;

    outer: while (true) {
        const n = file.read(&read_buf) catch break;
        if (n == 0) break;
        try raw_response.appendSlice(allocator, read_buf[0..n]);

        for (read_buf[0..n]) |byte| {
            if (byte == '\n') {
                const line = std.mem.trimRight(u8, line_buf.items, "\r");
                line_buf.clearRetainingCapacity();

                if (line.len == 0) {
                    if (try emitAnthropicSseEventData(
                        allocator,
                        &event_data,
                        current_event,
                        &accumulated,
                        callback,
                        ctx,
                        &output_tokens,
                    )) {
                        break :outer;
                    }
                    continue;
                }

                if (line[0] == ':') continue;

                const event_prefix = "event:";
                if (std.mem.startsWith(u8, line, event_prefix)) {
                    if (current_event.len > 0) allocator.free(@constCast(current_event));
                    const ev = std.mem.trimLeft(u8, line[event_prefix.len..], " \t");
                    current_event = allocator.dupe(u8, ev) catch "";
                    continue;
                }

                const data_prefix = "data:";
                if (!std.mem.startsWith(u8, line, data_prefix)) continue;
                const data = std.mem.trimLeft(u8, line[data_prefix.len..], " \t");
                if (data.len == 0) continue;
                if (event_data.items.len > 0) try event_data.append(allocator, '\n');
                try event_data.appendSlice(allocator, data);
            } else {
                try line_buf.append(allocator, byte);
            }
        }
    }

    // Handle a trailing line without a final '\n'
    if (line_buf.items.len > 0) {
        const line = std.mem.trimRight(u8, line_buf.items, "\r");
        if (line.len > 0 and line[0] != ':') {
            const event_prefix = "event:";
            if (std.mem.startsWith(u8, line, event_prefix)) {
                if (current_event.len > 0) allocator.free(@constCast(current_event));
                const ev = std.mem.trimLeft(u8, line[event_prefix.len..], " \t");
                current_event = allocator.dupe(u8, ev) catch "";
            } else {
                const data_prefix = "data:";
                if (std.mem.startsWith(u8, line, data_prefix)) {
                    const data = std.mem.trimLeft(u8, line[data_prefix.len..], " \t");
                    if (data.len > 0) {
                        if (event_data.items.len > 0) try event_data.append(allocator, '\n');
                        try event_data.appendSlice(allocator, data);
                    }
                }
            }
        }
        line_buf.clearRetainingCapacity();
    }

    // Flush final pending event payload.
    _ = try emitAnthropicSseEventData(
        allocator,
        &event_data,
        current_event,
        &accumulated,
        callback,
        ctx,
        &output_tokens,
    );

    // Some endpoints may return one-shot JSON even when asked for stream mode.
    if (accumulated.items.len == 0) {
        if (fallbackNonSseContent(allocator, raw_response.items)) |fallback_text| {
            defer allocator.free(fallback_text);
            if (fallback_text.len > 0) {
                try accumulated.appendSlice(allocator, fallback_text);
                callback(ctx, root.StreamChunk.textDelta(fallback_text));
            }
        }
    }

    // Free owned event string
    if (current_event.len > 0) allocator.free(@constCast(current_event));

    // Send final chunk
    callback(ctx, root.StreamChunk.finalChunk());

    // Drain remaining stdout to prevent deadlock on wait()
    while (true) {
        const n = file.read(&read_buf) catch break;
        if (n == 0) break;
    }

    const term = child.wait() catch return error.CurlWaitError;
    switch (term) {
        .Exited => |code| if (code != 0) return error.CurlFailed,
        else => return error.CurlFailed,
    }

    const content = if (accumulated.items.len > 0)
        try allocator.dupe(u8, accumulated.items)
    else
        null;

    // Use actual output_tokens if reported, otherwise estimate
    const completion_tokens = if (output_tokens > 0)
        output_tokens
    else
        @as(u32, @intCast((accumulated.items.len + 3) / 4));

    return .{
        .content = content,
        .usage = .{ .completion_tokens = completion_tokens },
        .model = "",
    };
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "parseSseLine valid delta" {
    const allocator = std.testing.allocator;
    const result = try parseSseLine(allocator, "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}");
    switch (result) {
        .delta => |text| {
            defer allocator.free(text);
            try std.testing.expectEqualStrings("Hello", text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseSseLine supports data prefix without trailing space" {
    const allocator = std.testing.allocator;
    const result = try parseSseLine(allocator, "data:{\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}");
    switch (result) {
        .delta => |text| {
            defer allocator.free(text);
            try std.testing.expectEqualStrings("Hello", text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseSseLine DONE sentinel" {
    const result = try parseSseLine(std.testing.allocator, "data: [DONE]");
    try std.testing.expect(result == .done);
}

test "parseSseLine DONE sentinel without trailing space" {
    const result = try parseSseLine(std.testing.allocator, "data:[DONE]");
    try std.testing.expect(result == .done);
}

test "parseSseLine empty line" {
    const result = try parseSseLine(std.testing.allocator, "");
    try std.testing.expect(result == .skip);
}

test "parseSseLine comment" {
    const result = try parseSseLine(std.testing.allocator, ":keep-alive");
    try std.testing.expect(result == .skip);
}

test "parseSseLine delta without content" {
    const result = try parseSseLine(std.testing.allocator, "data: {\"choices\":[{\"delta\":{}}]}");
    try std.testing.expect(result == .skip);
}

test "parseSseLine empty choices" {
    const result = try parseSseLine(std.testing.allocator, "data: {\"choices\":[]}");
    try std.testing.expect(result == .skip);
}

test "parseSseLine responses text delta" {
    const allocator = std.testing.allocator;
    const line = "data:{\"type\":\"response.output_text.delta\",\"delta\":\"你好\"}";
    const result = try parseSseLine(allocator, line);
    switch (result) {
        .delta => |text| {
            defer allocator.free(text);
            try std.testing.expectEqualStrings("你好", text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseSseLine responses done event" {
    const line = "data:{\"type\":\"response.completed\"}";
    const result = try parseSseLine(std.testing.allocator, line);
    try std.testing.expect(result == .done);
}

test "parseSseLine invalid JSON" {
    try std.testing.expectError(error.InvalidSseJson, parseSseLine(std.testing.allocator, "data: not-json{{{"));
}

test "emitOpenAiSseEventData handles aggregated multiline payload" {
    const Ctx = struct {
        allocator: std.mem.Allocator,
        text: std.ArrayListUnmanaged(u8) = .empty,

        fn onChunk(ctx_ptr: *anyopaque, chunk: root.StreamChunk) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            if (chunk.is_final or chunk.delta.len == 0) return;
            self.text.appendSlice(self.allocator, chunk.delta) catch unreachable;
        }
    };

    const allocator = std.testing.allocator;
    var event_data: std.ArrayListUnmanaged(u8) = .empty;
    defer event_data.deinit(allocator);
    try event_data.appendSlice(allocator, "{\"choices\":[");
    try event_data.append(allocator, '\n');
    try event_data.appendSlice(allocator, "{\"delta\":{\"content\":\"Hello\"}}]}");

    var accumulated: std.ArrayListUnmanaged(u8) = .empty;
    defer accumulated.deinit(allocator);
    var tool_partials: std.ArrayListUnmanaged(PartialToolCall) = .empty;
    defer {
        for (tool_partials.items) |*partial| partial.deinit(allocator);
        tool_partials.deinit(allocator);
    }
    var ctx = Ctx{ .allocator = allocator };
    defer ctx.text.deinit(allocator);
    var next_tool_order: usize = 0;

    const status = try emitOpenAiSseEventData(
        allocator,
        &event_data,
        &accumulated,
        &tool_partials,
        Ctx.onChunk,
        @ptrCast(&ctx),
        &next_tool_order,
    );
    try std.testing.expect(!status.done);
    try std.testing.expect(status.handled);
    try std.testing.expect(status.saw_text_or_tool);
    try std.testing.expectEqualStrings("Hello", accumulated.items);
    try std.testing.expectEqualStrings("Hello", ctx.text.items);
    try std.testing.expectEqual(@as(usize, 0), event_data.items.len);
}

test "emitOpenAiSseEventData accumulates native tool call fragments" {
    const Ctx = struct {
        allocator: std.mem.Allocator,
        text: std.ArrayListUnmanaged(u8) = .empty,

        fn onChunk(ctx_ptr: *anyopaque, chunk: root.StreamChunk) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            if (chunk.is_final or chunk.delta.len == 0) return;
            self.text.appendSlice(self.allocator, chunk.delta) catch unreachable;
        }
    };

    const allocator = std.testing.allocator;
    var event_data: std.ArrayListUnmanaged(u8) = .empty;
    defer event_data.deinit(allocator);
    var accumulated: std.ArrayListUnmanaged(u8) = .empty;
    defer accumulated.deinit(allocator);
    var tool_partials: std.ArrayListUnmanaged(PartialToolCall) = .empty;
    defer {
        for (tool_partials.items) |*partial| partial.deinit(allocator);
        tool_partials.deinit(allocator);
    }
    var ctx = Ctx{ .allocator = allocator };
    defer ctx.text.deinit(allocator);
    var next_tool_order: usize = 0;

    try event_data.appendSlice(
        allocator,
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"file_write\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\",\\\"content\\\":\\\"hel\"}}]}}]}",
    );
    const status1 = try emitOpenAiSseEventData(
        allocator,
        &event_data,
        &accumulated,
        &tool_partials,
        Ctx.onChunk,
        @ptrCast(&ctx),
        &next_tool_order,
    );
    try std.testing.expect(!status1.done);
    try std.testing.expect(status1.handled);
    try std.testing.expect(status1.saw_text_or_tool);

    try event_data.appendSlice(
        allocator,
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"lo\\\"}\"}}]}}]}",
    );
    const status2 = try emitOpenAiSseEventData(
        allocator,
        &event_data,
        &accumulated,
        &tool_partials,
        Ctx.onChunk,
        @ptrCast(&ctx),
        &next_tool_order,
    );
    try std.testing.expect(!status2.done);
    try std.testing.expect(status2.handled);
    try std.testing.expect(status2.saw_text_or_tool);

    const calls = try finalizeOpenAiToolCalls(allocator, tool_partials.items);
    defer {
        for (calls) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
            allocator.free(tc.arguments);
        }
        allocator.free(calls);
    }

    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("call_1", calls[0].id);
    try std.testing.expectEqualStrings("file_write", calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, calls[0].arguments, "path") != null);
    try std.testing.expect(std.mem.indexOf(u8, calls[0].arguments, "content") != null);
    try std.testing.expect(calls[0].arguments.len > 20);
    try std.testing.expectEqual(@as(usize, 0), accumulated.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.text.items.len);
}

test "emitOpenAiSseEventData parses responses tool_call events" {
    const allocator = std.testing.allocator;
    var event_data: std.ArrayListUnmanaged(u8) = .empty;
    defer event_data.deinit(allocator);
    var accumulated: std.ArrayListUnmanaged(u8) = .empty;
    defer accumulated.deinit(allocator);
    var tool_partials: std.ArrayListUnmanaged(PartialToolCall) = .empty;
    defer {
        for (tool_partials.items) |*partial| partial.deinit(allocator);
        tool_partials.deinit(allocator);
    }
    var next_tool_order: usize = 0;
    var dummy_ctx: u8 = 0;

    try event_data.appendSlice(
        allocator,
        "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_42\",\"name\":\"file_write\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\",\\\"content\\\":\\\"hel\"}}",
    );
    const status1 = try emitOpenAiSseEventData(
        allocator,
        &event_data,
        &accumulated,
        &tool_partials,
        struct {
            fn onChunk(_: *anyopaque, _: root.StreamChunk) void {}
        }.onChunk,
        @ptrCast(&dummy_ctx),
        &next_tool_order,
    );
    try std.testing.expect(!status1.done);
    try std.testing.expect(status1.handled);
    try std.testing.expect(status1.saw_text_or_tool);

    try event_data.appendSlice(
        allocator,
        "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_42\",\"arguments\":\"lo\\\"}\"}}",
    );
    const status2 = try emitOpenAiSseEventData(
        allocator,
        &event_data,
        &accumulated,
        &tool_partials,
        struct {
            fn onChunk(_: *anyopaque, _: root.StreamChunk) void {}
        }.onChunk,
        @ptrCast(&dummy_ctx),
        &next_tool_order,
    );
    try std.testing.expect(!status2.done);
    try std.testing.expect(status2.handled);
    try std.testing.expect(status2.saw_text_or_tool);

    const calls = try finalizeOpenAiToolCalls(allocator, tool_partials.items);
    defer {
        for (calls) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
            allocator.free(tc.arguments);
        }
        allocator.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("call_42", calls[0].id);
    try std.testing.expectEqualStrings("file_write", calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, calls[0].arguments, "path") != null);
    try std.testing.expect(std.mem.indexOf(u8, calls[0].arguments, "content") != null);
    try std.testing.expect(calls[0].arguments.len > 20);
}

test "emitOpenAiSseEventData tool_call id fallback without index" {
    const allocator = std.testing.allocator;
    var event_data: std.ArrayListUnmanaged(u8) = .empty;
    defer event_data.deinit(allocator);
    var accumulated: std.ArrayListUnmanaged(u8) = .empty;
    defer accumulated.deinit(allocator);
    var tool_partials: std.ArrayListUnmanaged(PartialToolCall) = .empty;
    defer {
        for (tool_partials.items) |*partial| partial.deinit(allocator);
        tool_partials.deinit(allocator);
    }
    var next_tool_order: usize = 0;
    var dummy_ctx: u8 = 0;

    try event_data.appendSlice(
        allocator,
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_custom\",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"ec\"}}]}}]}",
    );
    _ = try emitOpenAiSseEventData(
        allocator,
        &event_data,
        &accumulated,
        &tool_partials,
        struct {
            fn onChunk(_: *anyopaque, _: root.StreamChunk) void {}
        }.onChunk,
        @ptrCast(&dummy_ctx),
        &next_tool_order,
    );

    try event_data.appendSlice(
        allocator,
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_custom\",\"function\":{\"arguments\":\"ho\\\"}\"}}]}}]}",
    );
    _ = try emitOpenAiSseEventData(
        allocator,
        &event_data,
        &accumulated,
        &tool_partials,
        struct {
            fn onChunk(_: *anyopaque, _: root.StreamChunk) void {}
        }.onChunk,
        @ptrCast(&dummy_ctx),
        &next_tool_order,
    );

    const calls = try finalizeOpenAiToolCalls(allocator, tool_partials.items);
    defer {
        for (calls) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
            allocator.free(tc.arguments);
        }
        allocator.free(calls);
    }
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("call_custom", calls[0].id);
    try std.testing.expectEqualStrings("shell", calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, calls[0].arguments, "echo") != null);
}

test "emitOpenAiSseEventData done event" {
    const allocator = std.testing.allocator;
    var event_data: std.ArrayListUnmanaged(u8) = .empty;
    defer event_data.deinit(allocator);
    var accumulated: std.ArrayListUnmanaged(u8) = .empty;
    defer accumulated.deinit(allocator);
    var tool_partials: std.ArrayListUnmanaged(PartialToolCall) = .empty;
    defer {
        for (tool_partials.items) |*partial| partial.deinit(allocator);
        tool_partials.deinit(allocator);
    }
    var next_tool_order: usize = 0;
    var dummy_ctx: u8 = 0;
    try event_data.appendSlice(allocator, "{\"type\":\"response.done\"}");
    const status = try emitOpenAiSseEventData(
        allocator,
        &event_data,
        &accumulated,
        &tool_partials,
        struct {
            fn onChunk(_: *anyopaque, _: root.StreamChunk) void {}
        }.onChunk,
        @ptrCast(&dummy_ctx),
        &next_tool_order,
    );
    try std.testing.expect(status.done);
    try std.testing.expect(status.handled);
}

test "extractDeltaContent with content" {
    const allocator = std.testing.allocator;
    const result = (try extractDeltaContent(allocator, "{\"choices\":[{\"delta\":{\"content\":\"world\"}}]}")).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("world", result);
}

test "extractDeltaContent without content" {
    const result = try extractDeltaContent(std.testing.allocator, "{\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}");
    try std.testing.expect(result == null);
}

test "extractDeltaContent empty content" {
    const result = try extractDeltaContent(std.testing.allocator, "{\"choices\":[{\"delta\":{\"content\":\"\"}}]}");
    try std.testing.expect(result == null);
}

test "fallbackNonSseContent extracts text from one-shot OpenAI JSON" {
    const allocator = std.testing.allocator;
    const raw = "{\"choices\":[{\"message\":{\"content\":\"hello fallback\"}}]}";
    const content = fallbackNonSseContent(allocator, raw).?;
    defer allocator.free(content);
    try std.testing.expectEqualStrings("hello fallback", content);
}

test "fallbackNonSseContent returns null for SSE payload" {
    const raw =
        \\data: {"choices":[{"delta":{"content":"a"}}]}
        \\data: [DONE]
    ;
    try std.testing.expect(fallbackNonSseContent(std.testing.allocator, raw) == null);
}

test "StreamChunk textDelta token estimate" {
    const chunk = root.StreamChunk.textDelta("12345678");
    try std.testing.expect(chunk.token_count == 2);
    try std.testing.expect(!chunk.is_final);
    try std.testing.expectEqualStrings("12345678", chunk.delta);
}

test "StreamChunk finalChunk" {
    const chunk = root.StreamChunk.finalChunk();
    try std.testing.expect(chunk.is_final);
    try std.testing.expectEqualStrings("", chunk.delta);
    try std.testing.expect(chunk.token_count == 0);
}

// ── Anthropic SSE Tests ─────────────────────────────────────────

test "parseAnthropicSseLine event line returns event" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "event: content_block_delta", "");
    switch (result) {
        .event => |ev| try std.testing.expectEqualStrings("content_block_delta", ev),
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine event line supports no trailing space" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "event:content_block_delta", "");
    switch (result) {
        .event => |ev| try std.testing.expectEqualStrings("content_block_delta", ev),
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine data with content_block_delta returns delta" {
    const allocator = std.testing.allocator;
    const json = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}";
    const result = try parseAnthropicSseLine(allocator, json, "content_block_delta");
    switch (result) {
        .delta => |text| {
            defer allocator.free(text);
            try std.testing.expectEqualStrings("Hello", text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine data with message_delta returns usage" {
    const json = "data: {\"type\":\"message_delta\",\"delta\":{},\"usage\":{\"output_tokens\":42}}";
    const result = try parseAnthropicSseLine(std.testing.allocator, json, "message_delta");
    switch (result) {
        .usage => |tokens| try std.testing.expect(tokens == 42),
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine data with message_stop returns done" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "data: {\"type\":\"message_stop\"}", "message_stop");
    try std.testing.expect(result == .done);
}

test "emitAnthropicSseEventData handles aggregated multiline payload" {
    const Ctx = struct {
        allocator: std.mem.Allocator,
        text: std.ArrayListUnmanaged(u8) = .empty,

        fn onChunk(ctx_ptr: *anyopaque, chunk: root.StreamChunk) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            if (chunk.is_final or chunk.delta.len == 0) return;
            self.text.appendSlice(self.allocator, chunk.delta) catch unreachable;
        }
    };

    const allocator = std.testing.allocator;
    var event_data: std.ArrayListUnmanaged(u8) = .empty;
    defer event_data.deinit(allocator);
    try event_data.appendSlice(allocator, "{\"type\":\"content_block_delta\",");
    try event_data.append(allocator, '\n');
    try event_data.appendSlice(allocator, "\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}");

    var accumulated: std.ArrayListUnmanaged(u8) = .empty;
    defer accumulated.deinit(allocator);
    var output_tokens: u32 = 0;
    var ctx = Ctx{ .allocator = allocator };
    defer ctx.text.deinit(allocator);

    const done = try emitAnthropicSseEventData(
        allocator,
        &event_data,
        "content_block_delta",
        &accumulated,
        Ctx.onChunk,
        @ptrCast(&ctx),
        &output_tokens,
    );
    try std.testing.expect(!done);
    try std.testing.expectEqualStrings("Hi", accumulated.items);
    try std.testing.expectEqualStrings("Hi", ctx.text.items);
    try std.testing.expect(output_tokens == 0);
    try std.testing.expectEqual(@as(usize, 0), event_data.items.len);
}

test "parseAnthropicSseLine empty line returns skip" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "", "");
    try std.testing.expect(result == .skip);
}

test "parseAnthropicSseLine comment returns skip" {
    const result = try parseAnthropicSseLine(std.testing.allocator, ":keep-alive", "");
    try std.testing.expect(result == .skip);
}

test "parseAnthropicSseLine data with unknown event returns skip" {
    const json = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_123\"}}";
    const result = try parseAnthropicSseLine(std.testing.allocator, json, "message_start");
    try std.testing.expect(result == .skip);
}

test "extractAnthropicDelta correct JSON returns text" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}";
    const result = (try extractAnthropicDelta(allocator, json)).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("world", result);
}

test "extractAnthropicDelta without text returns null" {
    const json = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}";
    const result = try extractAnthropicDelta(std.testing.allocator, json);
    try std.testing.expect(result == null);
}

test "extractAnthropicUsage correct JSON returns token count" {
    const json = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":57}}";
    const result = (try extractAnthropicUsage(json)).?;
    try std.testing.expect(result == 57);
}
