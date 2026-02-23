const std = @import("std");
const Config = @import("config.zig").Config;
const providers = @import("providers/root.zig");
const session_mod = @import("session.zig");
const observability = @import("observability.zig");
const json_util = @import("json_util.zig");
const hooks_mod = @import("hooks.zig");
const tools_mod = @import("tools/root.zig");

const ServerVersion = "0.1.1";

const CoreTool = enum {
    agent_turn,
    agent_status,
    session_reset,
    session_list,
};

fn effectiveMaxConcurrentRequests(cfg: *const Config) u32 {
    if (cfg.mcp.max_concurrent_requests == 0) return 1;
    return cfg.mcp.max_concurrent_requests;
}

fn emitFrame(stdout: std.fs.File, payload: []const u8) !void {
    var header_buf: [128]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{payload.len});
    try stdout.writeAll(header);
    try stdout.writeAll(payload);
}

fn readExact(file: std.fs.File, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try file.read(buf[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}

fn parseContentLength(headers: []const u8) !usize {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "Content-Length:")) continue;
        const value = std.mem.trim(u8, line["Content-Length:".len..], " \t");
        return try std.fmt.parseInt(usize, value, 10);
    }
    return error.MissingContentLength;
}

fn readFrame(allocator: std.mem.Allocator, stdin: std.fs.File) !?[]u8 {
    var headers = std.ArrayList(u8).empty;
    defer headers.deinit(allocator);

    var byte: [1]u8 = undefined;
    while (true) {
        const n = try stdin.read(&byte);
        if (n == 0) {
            if (headers.items.len == 0) return null;
            return error.EndOfStream;
        }
        try headers.append(allocator, byte[0]);
        if (headers.items.len >= 4 and std.mem.endsWith(u8, headers.items, "\r\n\r\n")) break;
        if (headers.items.len > 32 * 1024) return error.HeadersTooLarge;
    }

    const header_no_tail = headers.items[0 .. headers.items.len - 4];
    const body_len = try parseContentLength(header_no_tail);
    const body = try allocator.alloc(u8, body_len);
    errdefer allocator.free(body);
    try readExact(stdin, body);
    return body;
}

fn jsonValueToSlice(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn writeJsonRpcResult(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    id_value: std.json.Value,
    result_json: []const u8,
) !void {
    const id_json = try jsonValueToSlice(allocator, id_value);
    defer allocator.free(id_json);

    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_json, result_json },
    );
    defer allocator.free(payload);
    try emitFrame(stdout, payload);
}

fn writeJsonRpcError(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    id_value: ?std.json.Value,
    code: i64,
    message: []const u8,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    if (id_value) |idv| {
        const id_json = try jsonValueToSlice(allocator, idv);
        defer allocator.free(id_json);
        try buf.appendSlice(allocator, id_json);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"error\":{");
    try json_util.appendJsonKey(&buf, allocator, "code");
    var code_buf: [32]u8 = undefined;
    const code_str = try std.fmt.bufPrint(&code_buf, "{d}", .{code});
    try buf.appendSlice(allocator, code_str);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "message", message);
    try buf.appendSlice(allocator, "}}");
    try emitFrame(stdout, buf.items);
}

fn emitMcpRequest(hook_bus: ?*hooks_mod.HookBus, method: []const u8, success: bool) void {
    if (hook_bus) |bus| {
        var evt: hooks_mod.HookEvent = .{
            .mcp_request = .{
                .method = method,
                .success = success,
            },
        };
        bus.emit(&evt);
    }
}

fn mcpTextResult(allocator: std.mem.Allocator, text: []const u8, is_error: bool) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"content\":[{\"type\":\"text\",\"text\":");
    try json_util.appendJsonString(&buf, allocator, text);
    try buf.appendSlice(allocator, "}],\"isError\":");
    try buf.appendSlice(allocator, if (is_error) "true" else "false");
    try buf.appendSlice(allocator, "}");

    return try buf.toOwnedSlice(allocator);
}

fn toolsListResult(allocator: std.mem.Allocator) ![]u8 {
    const payload =
        \\{"tools":[
        \\{"name":"agent_turn","description":"Run one agent turn in a session","inputSchema":{"type":"object","properties":{"session_key":{"type":"string"},"message":{"type":"string"},"model_override":{"type":"string"},"stream":{"type":"boolean"}},"required":["message"]}},
        \\{"name":"agent_status","description":"Get current agent runtime status","inputSchema":{"type":"object","properties":{}}},
        \\{"name":"session_reset","description":"Reset a session by key","inputSchema":{"type":"object","properties":{"session_key":{"type":"string"}},"required":["session_key"]}},
        \\{"name":"session_list","description":"List active sessions","inputSchema":{"type":"object","properties":{}}}
        \\]}
    ;
    return allocator.dupe(u8, payload);
}

fn initializeResult(allocator: std.mem.Allocator) ![]u8 {
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"nullclaw\",\"version\":\"{s}\"}}}}",
        .{ServerVersion},
    );
    return payload;
}

fn getToolName(method_name: []const u8) ?CoreTool {
    if (std.mem.eql(u8, method_name, "agent_turn")) return .agent_turn;
    if (std.mem.eql(u8, method_name, "agent_status")) return .agent_status;
    if (std.mem.eql(u8, method_name, "session_reset")) return .session_reset;
    if (std.mem.eql(u8, method_name, "session_list")) return .session_list;
    return null;
}

fn getObjString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn callCoreTool(
    allocator: std.mem.Allocator,
    cfg: *const Config,
    session_mgr: *session_mod.SessionManager,
    tool: CoreTool,
    arguments: ?std.json.ObjectMap,
    request_timeout_secs: u64,
) ![]u8 {
    switch (tool) {
        .agent_status => {
            const text = try std.fmt.allocPrint(
                allocator,
                "provider={s} model={s} sessions={d}",
                .{ cfg.default_provider, cfg.default_model orelse "(default)", session_mgr.sessionCount() },
            );
            defer allocator.free(text);
            return mcpTextResult(allocator, text, false);
        },
        .session_list => {
            const sessions = try session_mgr.listSessionKeys(allocator);
            defer {
                for (sessions) |s| allocator.free(s);
                allocator.free(sessions);
            }

            var text_buf: std.ArrayList(u8) = .empty;
            defer text_buf.deinit(allocator);
            if (sessions.len == 0) {
                try text_buf.appendSlice(allocator, "no active sessions");
            } else {
                for (sessions, 0..) |s, i| {
                    if (i > 0) try text_buf.append(allocator, '\n');
                    try text_buf.appendSlice(allocator, s);
                }
            }
            const text = try text_buf.toOwnedSlice(allocator);
            defer allocator.free(text);
            return mcpTextResult(allocator, text, false);
        },
        .session_reset => {
            const args = arguments orelse return mcpTextResult(allocator, "missing arguments", true);
            const session_key = getObjString(args, "session_key") orelse return mcpTextResult(allocator, "missing session_key", true);
            const removed = session_mgr.resetSession(session_key);
            const text = if (removed) "session reset" else "session not found";
            return mcpTextResult(allocator, text, false);
        },
        .agent_turn => {
            const args = arguments orelse return mcpTextResult(allocator, "missing arguments", true);
            const message = getObjString(args, "message") orelse return mcpTextResult(allocator, "missing message", true);
            const session_key = getObjString(args, "session_key") orelse "mcp:default";
            var result = session_mgr.processMessageDetailed(session_key, message, .{
                .request_timeout_secs = request_timeout_secs,
            }) catch |err| {
                if (err == error.RequestTimeoutExceeded) {
                    return mcpTextResult(allocator, "request timeout exceeded", true);
                }
                const msg = try std.fmt.allocPrint(allocator, "agent_turn failed: {s}", .{@errorName(err)});
                defer allocator.free(msg);
                return mcpTextResult(allocator, msg, true);
            };
            defer result.deinit(allocator);

            var payload: std.ArrayListUnmanaged(u8) = .empty;
            errdefer payload.deinit(allocator);
            try payload.appendSlice(allocator, "{\"content\":[{\"type\":\"text\",\"text\":");
            try json_util.appendJsonString(&payload, allocator, result.response_text);
            try payload.appendSlice(allocator, "}],\"structuredContent\":{");
            try json_util.appendJsonKeyValue(&payload, allocator, "text", result.response_text);
            try payload.appendSlice(allocator, ",");
            try json_util.appendJsonKeyValue(&payload, allocator, "model", result.active_model);
            try payload.appendSlice(allocator, ",");
            try json_util.appendJsonKey(&payload, allocator, "used_tools");
            try payload.appendSlice(allocator, "[");
            for (result.used_tools, 0..) |tool_name, i| {
                if (i > 0) try payload.appendSlice(allocator, ",");
                try json_util.appendJsonString(&payload, allocator, tool_name);
            }
            try payload.appendSlice(allocator, "]");
            try payload.appendSlice(allocator, ",");
            try json_util.appendJsonKey(&payload, allocator, "latency_ms");
            var latency_buf: [32]u8 = undefined;
            const latency_str = try std.fmt.bufPrint(&latency_buf, "{d}", .{result.latency_ms});
            try payload.appendSlice(allocator, latency_str);
            try payload.appendSlice(allocator, "},\"isError\":false}");

            return try payload.toOwnedSlice(allocator);
        },
    }
}

fn handleRequest(
    allocator: std.mem.Allocator,
    cfg: *const Config,
    session_mgr: *session_mod.SessionManager,
    stdout: std.fs.File,
    body: []const u8,
    hook_bus: ?*hooks_mod.HookBus,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        emitMcpRequest(hook_bus, "invalid_json", false);
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const obj = parsed.value.object;
    const method_v = obj.get("method") orelse return;
    if (method_v != .string) return;
    const method = method_v.string;
    const id_v = obj.get("id");

    // notifications/initialized is notification-only
    if (std.mem.eql(u8, method, "notifications/initialized")) return;

    if (id_v == null) return;
    const id = id_v.?;

    if (std.mem.eql(u8, method, "initialize")) {
        const res = try initializeResult(allocator);
        defer allocator.free(res);
        try writeJsonRpcResult(allocator, stdout, id, res);
        emitMcpRequest(hook_bus, method, true);
        return;
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        const res = try toolsListResult(allocator);
        defer allocator.free(res);
        try writeJsonRpcResult(allocator, stdout, id, res);
        emitMcpRequest(hook_bus, method, true);
        return;
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        const params_v = obj.get("params") orelse {
            try writeJsonRpcError(allocator, stdout, id, -32602, "missing params");
            emitMcpRequest(hook_bus, method, false);
            return;
        };
        if (params_v != .object) {
            try writeJsonRpcError(allocator, stdout, id, -32602, "invalid params");
            emitMcpRequest(hook_bus, method, false);
            return;
        }
        const tool_name = getObjString(params_v.object, "name") orelse {
            try writeJsonRpcError(allocator, stdout, id, -32602, "missing tool name");
            emitMcpRequest(hook_bus, method, false);
            return;
        };
        const tool = getToolName(tool_name) orelse {
            try writeJsonRpcError(allocator, stdout, id, -32601, "unknown tool");
            emitMcpRequest(hook_bus, method, false);
            return;
        };
        const args_obj = if (params_v.object.get("arguments")) |a|
            if (a == .object) a.object else null
        else
            null;

        const result = try callCoreTool(allocator, cfg, session_mgr, tool, args_obj, cfg.mcp.request_timeout_secs);
        defer allocator.free(result);
        try writeJsonRpcResult(allocator, stdout, id, result);
        emitMcpRequest(hook_bus, method, true);
        return;
    }

    try writeJsonRpcError(allocator, stdout, id, -32601, "method not found");
    emitMcpRequest(hook_bus, method, false);
}

pub fn serve(allocator: std.mem.Allocator, cfg: *const Config, hook_bus: ?*hooks_mod.HookBus) !void {
    if (!cfg.mcp.enabled) return error.McpServerDisabled;

    var owned_api_key: ?[]u8 = null;
    defer if (owned_api_key) |k| allocator.free(k);

    const api_key = if (cfg.defaultProviderKey()) |k|
        k
    else blk: {
        owned_api_key = providers.resolveApiKey(allocator, cfg.default_provider, null) catch null;
        break :blk owned_api_key;
    };

    var provider_holder = providers.ProviderHolder.fromConfig(allocator, cfg.default_provider, api_key);
    defer provider_holder.deinit();
    const provider_i = provider_holder.provider();

    var noop = observability.NoopObserver{};
    var session_mgr = session_mod.SessionManager.init(
        allocator,
        cfg,
        provider_i,
        &.{},
        null,
        noop.observer(),
        null,
    );
    defer session_mgr.deinit();

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();
    const max_concurrent_requests = effectiveMaxConcurrentRequests(cfg);
    var active_requests: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    while (true) {
        const maybe_body = readFrame(allocator, stdin) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (maybe_body == null) return;
        const body = maybe_body.?;
        defer allocator.free(body);

        const active_before = active_requests.fetchAdd(1, .acq_rel);
        if (active_before >= max_concurrent_requests) {
            _ = active_requests.fetchSub(1, .acq_rel);
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const id_value = parsed.value.object.get("id") orelse continue;
            writeJsonRpcError(allocator, stdout, id_value, -32000, "server busy: max_concurrent_requests exceeded") catch {};
            emitMcpRequest(hook_bus, "tools/call", false);
            continue;
        }
        defer _ = active_requests.fetchSub(1, .acq_rel);

        handleRequest(allocator, cfg, &session_mgr, stdout, body, hook_bus) catch {};
    }
}

test "parseContentLength extracts integer value" {
    const raw = "Content-Length: 42\r\nContent-Type: application/json\r\n";
    const len = try parseContentLength(raw);
    try std.testing.expectEqual(@as(usize, 42), len);
}

test "getToolName resolves known methods" {
    try std.testing.expect(getToolName("agent_turn").? == .agent_turn);
    try std.testing.expect(getToolName("session_list").? == .session_list);
    try std.testing.expect(getToolName("unknown") == null);
}

test "effectiveMaxConcurrentRequests floors to one" {
    var cfg = Config{
        .workspace_dir = "/tmp/mcp_effective_max",
        .config_path = "/tmp/mcp_effective_max/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.mcp.max_concurrent_requests = 0;
    try std.testing.expectEqual(@as(u32, 1), effectiveMaxConcurrentRequests(&cfg));
    cfg.mcp.max_concurrent_requests = 7;
    try std.testing.expectEqual(@as(u32, 7), effectiveMaxConcurrentRequests(&cfg));
}

const TestMcpProviderMode = enum {
    tool_then_done,
};

const TestMcpProvider = struct {
    mode: TestMcpProviderMode = .tool_then_done,
    calls: usize = 0,

    const vtable = providers.Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
    };

    fn provider(self: *TestMcpProvider) providers.Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn chatWithSystemImpl(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        return allocator.dupe(u8, "");
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *TestMcpProvider = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.calls == 1) {
            return .{
                .content = try allocator.dupe(u8, "<tool_call>{\"name\":\"mcp_test_tool\",\"arguments\":{}}</tool_call>"),
                .tool_calls = &.{},
                .usage = .{},
                .model = "",
            };
        }
        return .{
            .content = try allocator.dupe(u8, "done"),
            .tool_calls = &.{},
            .usage = .{},
            .model = "",
        };
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return false;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "mcp-test-provider";
    }

    fn deinitImpl(_: *anyopaque) void {}
};

const FastMcpTool = struct {
    const vtable = tools_mod.Tool.VTable{
        .execute = executeImpl,
        .name = nameImpl,
        .description = descriptionImpl,
        .parameters_json = parametersImpl,
    };

    fn tool(self: *FastMcpTool) tools_mod.Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(_: *anyopaque, _: std.mem.Allocator, _: tools_mod.JsonObjectMap) anyerror!tools_mod.ToolResult {
        return .{ .success = true, .output = "ok" };
    }

    fn nameImpl(_: *anyopaque) []const u8 {
        return "mcp_test_tool";
    }

    fn descriptionImpl(_: *anyopaque) []const u8 {
        return "test tool";
    }

    fn parametersImpl(_: *anyopaque) []const u8 {
        return "{\"type\":\"object\"}";
    }
};

const SlowMcpTool = struct {
    const vtable = tools_mod.Tool.VTable{
        .execute = executeImpl,
        .name = nameImpl,
        .description = descriptionImpl,
        .parameters_json = parametersImpl,
    };

    fn tool(self: *SlowMcpTool) tools_mod.Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(_: *anyopaque, _: std.mem.Allocator, _: tools_mod.JsonObjectMap) anyerror!tools_mod.ToolResult {
        std.Thread.sleep(1200 * std.time.ns_per_ms);
        return .{ .success = true, .output = "ok" };
    }

    fn nameImpl(_: *anyopaque) []const u8 {
        return "mcp_test_tool";
    }

    fn descriptionImpl(_: *anyopaque) []const u8 {
        return "slow test tool";
    }

    fn parametersImpl(_: *anyopaque) []const u8 {
        return "{\"type\":\"object\"}";
    }
};

fn parseToolArguments(allocator: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
}

test "callCoreTool agent_turn returns real used_tools and active model" {
    const allocator = std.testing.allocator;
    var provider_state = TestMcpProvider{};
    var tool_state = FastMcpTool{};
    var tools = [_]tools_mod.Tool{tool_state.tool()};

    var cfg = Config{
        .workspace_dir = "/tmp/mcp_test",
        .config_path = "/tmp/mcp_test/config.json",
        .allocator = allocator,
        .default_model = "unit-model",
    };
    var noop = observability.NoopObserver{};
    var session_mgr = session_mod.SessionManager.init(
        allocator,
        &cfg,
        provider_state.provider(),
        &tools,
        null,
        noop.observer(),
        null,
    );
    defer session_mgr.deinit();

    const parsed_args = try parseToolArguments(allocator,
        \\{"message":"please run tool","session_key":"mcp:test"}
    );
    defer parsed_args.deinit();

    const result_json = try callCoreTool(
        allocator,
        &cfg,
        &session_mgr,
        .agent_turn,
        parsed_args.value.object,
        0,
    );
    defer allocator.free(result_json);

    const parsed_result = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed_result.deinit();
    const root_obj = parsed_result.value.object;
    const structured = root_obj.get("structuredContent").?.object;
    const used_tools = structured.get("used_tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), used_tools.items.len);
    try std.testing.expectEqualStrings("mcp_test_tool", used_tools.items[0].string);
    try std.testing.expectEqualStrings("unit-model", structured.get("model").?.string);
}

test "callCoreTool agent_turn returns timeout when deadline exceeded" {
    const allocator = std.testing.allocator;
    var provider_state = TestMcpProvider{};
    var tool_state = SlowMcpTool{};
    var tools = [_]tools_mod.Tool{tool_state.tool()};

    var cfg = Config{
        .workspace_dir = "/tmp/mcp_timeout_test",
        .config_path = "/tmp/mcp_timeout_test/config.json",
        .allocator = allocator,
    };
    var noop = observability.NoopObserver{};
    var session_mgr = session_mod.SessionManager.init(
        allocator,
        &cfg,
        provider_state.provider(),
        &tools,
        null,
        noop.observer(),
        null,
    );
    defer session_mgr.deinit();

    const parsed_args = try parseToolArguments(allocator,
        \\{"message":"run slow tool","session_key":"mcp:timeout"}
    );
    defer parsed_args.deinit();

    const result_json = try callCoreTool(
        allocator,
        &cfg,
        &session_mgr,
        .agent_turn,
        parsed_args.value.object,
        1,
    );
    defer allocator.free(result_json);

    const parsed_result = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed_result.deinit();
    const root_obj = parsed_result.value.object;
    try std.testing.expect(root_obj.get("isError").?.bool);
    const text = root_obj.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings("request timeout exceeded", text);
}
