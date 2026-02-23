const std = @import("std");
const builtin = @import("builtin");
const json_util = @import("json_util.zig");
const websocket = @import("websocket.zig");
const tools_mod = @import("tools/root.zig");

pub const ToolResult = tools_mod.ToolResult;
const MAX_WS_MESSAGE_BYTES: usize = 4 * 1024 * 1024;
const MAX_WS_RESPONSE_SCAN: usize = 512;
const MAX_DOM_READ_BYTES: usize = 8192;

pub const CdpConfig = struct {
    enabled: bool = false,
    endpoint: []const u8 = "http://127.0.0.1:9222",
    connect_timeout_ms: u64 = 3000,
    action_timeout_ms: u64 = 10_000,
    allow_remote: bool = false,
};

fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "::1");
}

fn endpointHost(endpoint: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, endpoint, "http://") and !std.mem.startsWith(u8, endpoint, "https://")) return null;
    const scheme_end = std.mem.indexOf(u8, endpoint, "://") orelse return null;
    const rest = endpoint[scheme_end + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash];
    const colon = std.mem.indexOfScalar(u8, host_port, ':') orelse host_port.len;
    return host_port[0..colon];
}

fn endpointTrimmed(endpoint: []const u8) []const u8 {
    return std.mem.trimRight(u8, endpoint, "/");
}

fn endpointJoin(allocator: std.mem.Allocator, endpoint: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ endpointTrimmed(endpoint), suffix });
}

fn fetchHttpBody(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const req: std.http.Client.FetchOptions = .{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
        .extra_headers = &.{},
    };
    const result = try client.fetch(req);
    const status_code = @intFromEnum(result.status);
    if (status_code < 200 or status_code >= 300) return error.CdpHttpRequestFailed;
    return allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
}

pub fn validateConfig(cfg: CdpConfig) !void {
    if (!cfg.enabled) return error.CdpDisabled;
    if (cfg.endpoint.len == 0) return error.InvalidCdpEndpoint;
    if (!std.mem.startsWith(u8, cfg.endpoint, "http://") and !std.mem.startsWith(u8, cfg.endpoint, "https://")) {
        return error.InvalidCdpEndpoint;
    }
    if (!cfg.allow_remote) {
        const host = endpointHost(cfg.endpoint) orelse return error.InvalidCdpEndpoint;
        if (!isLoopbackHost(host)) return error.CdpRemoteNotAllowed;
    }
}

pub fn probe(allocator: std.mem.Allocator, cfg: CdpConfig) !void {
    try validateConfig(cfg);
    const url = try endpointJoin(allocator, cfg.endpoint, "/json/version");
    defer allocator.free(url);
    const body = try fetchHttpBody(allocator, url);
    defer allocator.free(body);
}

fn openTabViaHttp(allocator: std.mem.Allocator, cfg: CdpConfig, target_url: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/json/new?{s}", .{ endpointTrimmed(cfg.endpoint), target_url });
    defer allocator.free(url);
    const body = try fetchHttpBody(allocator, url);
    defer allocator.free(body);
}

const WsEndpoint = struct {
    secure: bool,
    host: []const u8,
    port: u16,
    path_and_query: []const u8,
};

fn parseWsUrl(url: []const u8) !WsEndpoint {
    const secure: bool = if (std.mem.startsWith(u8, url, "ws://"))
        false
    else if (std.mem.startsWith(u8, url, "wss://"))
        true
    else
        return error.InvalidCdpWsUrl;

    const rest = if (secure) url["wss://".len..] else url["ws://".len..];
    if (rest.len == 0) return error.InvalidCdpWsUrl;

    const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash_idx];
    const path_and_query = if (slash_idx < rest.len) rest[slash_idx..] else "/";
    if (host_port.len == 0) return error.InvalidCdpWsUrl;

    var host: []const u8 = host_port;
    var port: u16 = if (secure) 443 else 80;
    if (host_port[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return error.InvalidCdpWsUrl;
        if (close <= 1) return error.InvalidCdpWsUrl;
        host = host_port[1..close];
        if (close + 1 < host_port.len) {
            if (host_port[close + 1] != ':') return error.InvalidCdpWsUrl;
            port = std.fmt.parseInt(u16, host_port[close + 2 ..], 10) catch return error.InvalidCdpWsUrl;
        }
    } else if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon| {
        host = host_port[0..colon];
        if (host.len == 0) return error.InvalidCdpWsUrl;
        port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return error.InvalidCdpWsUrl;
    }

    return .{
        .secure = secure,
        .host = host,
        .port = port,
        .path_and_query = path_and_query,
    };
}

fn headerValueCaseInsensitive(headers: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn clampPollTimeoutMs(timeout_ms: u64) i32 {
    if (timeout_ms == 0) return -1;
    if (timeout_ms > @as(u64, @intCast(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intCast(timeout_ms);
}

fn waitStreamReadable(stream: std.net.Stream, timeout_ms: u64) !void {
    var pfd = [_]std.posix.pollfd{
        .{
            .fd = stream.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL,
            .revents = 0,
        },
    };
    const n = try std.posix.poll(&pfd, clampPollTimeoutMs(timeout_ms));
    if (n == 0) return error.CdpResponseTimeout;
    const revents = pfd[0].revents;
    if ((revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0 and (revents & std.posix.POLL.IN) == 0) {
        return error.ConnectionClosed;
    }
}

fn validateWsTargetPolicy(cfg: CdpConfig, ws_url: []const u8) !void {
    if (cfg.allow_remote) return;
    const target = try parseWsUrl(ws_url);
    if (!isLoopbackHost(target.host)) return error.CdpRemoteNotAllowed;
}

const CdpWsClient = struct {
    allocator: std.mem.Allocator,
    read_timeout_ms: u64,
    transport: union(enum) {
        plain: std.net.Stream,
        tls: websocket.WsClient,
    },

    fn connect(allocator: std.mem.Allocator, ws_url: []const u8, connect_timeout_ms: u64) !CdpWsClient {
        const target = try parseWsUrl(ws_url);
        if (target.secure) {
            const tls_ws = try websocket.WsClient.connect(
                allocator,
                target.host,
                target.port,
                target.path_and_query,
                &.{},
            );
            return .{
                .allocator = allocator,
                .read_timeout_ms = connect_timeout_ms,
                .transport = .{ .tls = tls_ws },
            };
        }

        const addr_list = try std.net.getAddressList(allocator, target.host, target.port);
        defer addr_list.deinit();
        if (addr_list.addrs.len == 0) return error.DnsResolutionFailed;

        const stream = try std.net.tcpConnectToAddress(addr_list.addrs[0]);
        errdefer stream.close();

        var key_raw: [16]u8 = undefined;
        std.crypto.random.bytes(&key_raw);
        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &key_raw);

        var request_buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&request_buf);
        const w = fbs.writer();
        try w.print("GET {s} HTTP/1.1\r\n", .{target.path_and_query});
        if ((target.port == 80 and !target.secure) or (target.port == 443 and target.secure)) {
            try w.print("Host: {s}\r\n", .{target.host});
        } else {
            try w.print("Host: {s}:{d}\r\n", .{ target.host, target.port });
        }
        try w.writeAll("Upgrade: websocket\r\n");
        try w.writeAll("Connection: Upgrade\r\n");
        try w.print("Sec-WebSocket-Key: {s}\r\n", .{key_b64});
        try w.writeAll("Sec-WebSocket-Version: 13\r\n");
        try w.writeAll("\r\n");
        try stream.writeAll(fbs.getWritten());

        var response_buf: [4096]u8 = undefined;
        var response_len: usize = 0;
        while (response_len < response_buf.len) {
            try waitStreamReadable(stream, connect_timeout_ms);
            const n = try stream.read(response_buf[response_len..]);
            if (n == 0) return error.WsHandshakeFailed;
            response_len += n;
            if (std.mem.indexOf(u8, response_buf[0..response_len], "\r\n\r\n") != null) break;
        }

        const response = response_buf[0..response_len];
        if (!std.mem.startsWith(u8, response, "HTTP/1.1 101") and !std.mem.startsWith(u8, response, "HTTP/1.0 101")) {
            return error.WsHandshakeFailed;
        }

        const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.WsHandshakeFailed;
        const headers = response[0..header_end];
        const accept = headerValueCaseInsensitive(headers, "Sec-WebSocket-Accept") orelse return error.WsHandshakeFailed;
        const expected = websocket.WsClient.computeAcceptKey(&key_b64);
        if (!std.mem.eql(u8, accept, &expected)) return error.WsHandshakeFailed;

        return .{
            .allocator = allocator,
            .read_timeout_ms = connect_timeout_ms,
            .transport = .{ .plain = stream },
        };
    }

    fn deinit(self: *CdpWsClient) void {
        switch (self.transport) {
            .plain => |*stream| {
                self.sendFrame(.close, &.{}) catch {};
                stream.close();
            },
            .tls => |*ws| {
                ws.writeClose();
                ws.deinit();
            },
        }
    }

    fn currentStream(self: *CdpWsClient) std.net.Stream {
        return switch (self.transport) {
            .plain => |stream| stream,
            .tls => |ws| ws.stream,
        };
    }

    fn waitReadable(self: *CdpWsClient) !void {
        try waitStreamReadable(self.currentStream(), self.read_timeout_ms);
    }

    fn readExact(self: *CdpWsClient, buf: []u8) !void {
        switch (self.transport) {
            .plain => |*stream| {
                var off: usize = 0;
                while (off < buf.len) {
                    try self.waitReadable();
                    const n = try stream.read(buf[off..]);
                    if (n == 0) return error.ConnectionClosed;
                    off += n;
                }
            },
            .tls => return error.UnsupportedOperation,
        }
    }

    fn sendFrame(self: *CdpWsClient, opcode: websocket.Opcode, payload: []const u8) !void {
        switch (self.transport) {
            .plain => |*stream| {
                var mask: [4]u8 = undefined;
                std.crypto.random.bytes(&mask);
                const frame_buf = try self.allocator.alloc(u8, payload.len + 14);
                defer self.allocator.free(frame_buf);
                const n = try websocket.buildFrame(frame_buf, opcode, payload, mask);
                try stream.writeAll(frame_buf[0..n]);
            },
            .tls => return error.UnsupportedOperation,
        }
    }

    fn writeText(self: *CdpWsClient, text: []const u8) !void {
        switch (self.transport) {
            .plain => try self.sendFrame(.text, text),
            .tls => |*ws| try ws.writeText(text),
        }
    }

    fn readFrame(self: *CdpWsClient) !?websocket.Frame {
        switch (self.transport) {
            .plain => {},
            .tls => return error.UnsupportedOperation,
        }
        var header_buf: [14]u8 = undefined;
        try self.readExact(header_buf[0..2]);

        var hlen: usize = 2;
        const len_marker = header_buf[1] & 0x7F;
        if (len_marker == 126) {
            try self.readExact(header_buf[2..4]);
            hlen = 4;
        } else if (len_marker == 127) {
            try self.readExact(header_buf[2..10]);
            hlen = 10;
        }

        const masked = (header_buf[1] & 0x80) != 0;
        if (masked) {
            try self.readExact(header_buf[hlen .. hlen + 4]);
            hlen += 4;
        }

        const parsed = try websocket.parseFrameHeader(header_buf[0..hlen]);
        if (parsed.payload_len > MAX_WS_MESSAGE_BYTES) return error.FrameTooLarge;

        const plen: usize = @intCast(parsed.payload_len);
        const payload = if (plen > 0) blk: {
            const p = try self.allocator.alloc(u8, plen);
            errdefer self.allocator.free(p);
            try self.readExact(p);
            break :blk p;
        } else @constCast(&[_]u8{});

        if (parsed.masked and plen > 0) {
            const mask_start = parsed.header_bytes - 4;
            const mask: [4]u8 = .{
                header_buf[mask_start + 0],
                header_buf[mask_start + 1],
                header_buf[mask_start + 2],
                header_buf[mask_start + 3],
            };
            websocket.applyMask(payload, mask);
        }

        switch (parsed.opcode) {
            .ping => {
                self.sendFrame(.pong, payload) catch {};
                if (plen > 0) self.allocator.free(payload);
                return websocket.Frame{ .opcode = .ping, .fin = true, .payload = @constCast(&[_]u8{}) };
            },
            .close => {
                if (plen > 0) self.allocator.free(payload);
                return null;
            },
            else => return websocket.Frame{ .opcode = parsed.opcode, .fin = parsed.fin, .payload = payload },
        }
    }

    fn readTextMessagePlain(self: *CdpWsClient) !?[]u8 {
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        errdefer msg.deinit(self.allocator);

        while (true) {
            const maybe_frame = try self.readFrame();
            if (maybe_frame == null) {
                msg.deinit(self.allocator);
                return null;
            }

            const frame = maybe_frame.?;
            defer if (frame.payload.len > 0) self.allocator.free(frame.payload);

            switch (frame.opcode) {
                .text, .continuation => {
                    try msg.appendSlice(self.allocator, frame.payload);
                    if (msg.items.len > MAX_WS_MESSAGE_BYTES) return error.MessageTooLarge;
                    if (frame.fin) {
                        const owned = try msg.toOwnedSlice(self.allocator);
                        return @as(?[]u8, owned);
                    }
                },
                .binary, .pong, .ping => continue,
                else => continue,
            }
        }
    }

    fn readTextMessage(self: *CdpWsClient) !?[]u8 {
        return switch (self.transport) {
            .plain => try self.readTextMessagePlain(),
            .tls => |*ws| blk: {
                try self.waitReadable();
                break :blk try ws.readTextMessage();
            },
        };
    }
};

fn parseJsonId(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |i| if (i >= 0) @as(u64, @intCast(i)) else null,
        .float => |f| if (f >= 0) @as(u64, @intFromFloat(f)) else null,
        else => null,
    };
}

fn responseMatchesRequestId(allocator: std.mem.Allocator, message: []const u8, request_id: u64) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const id_val = parsed.value.object.get("id") orelse return false;
    return parseJsonId(id_val) == request_id;
}

fn cdpErrorString(obj: std.json.ObjectMap) ?[]const u8 {
    const err_val = obj.get("error") orelse return null;
    if (err_val != .object) return null;
    const msg_val = err_val.object.get("message") orelse return null;
    if (msg_val != .string) return null;
    return msg_val.string;
}

fn cdpResultObject(obj: std.json.ObjectMap) ?std.json.ObjectMap {
    const result_val = obj.get("result") orelse return null;
    if (result_val != .object) return null;
    return result_val.object;
}

fn executeCdpCommand(
    allocator: std.mem.Allocator,
    ws: *CdpWsClient,
    request_id: *u64,
    method: []const u8,
    params_json: ?[]const u8,
) ![]u8 {
    const id = request_id.*;
    request_id.* += 1;

    var req: std.ArrayListUnmanaged(u8) = .empty;
    defer req.deinit(allocator);
    try req.appendSlice(allocator, "{\"id\":");
    var id_buf: [32]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
    try req.appendSlice(allocator, id_str);
    try req.appendSlice(allocator, ",\"method\":");
    try json_util.appendJsonString(&req, allocator, method);
    if (params_json) |p| {
        try req.appendSlice(allocator, ",\"params\":");
        try req.appendSlice(allocator, p);
    }
    try req.append(allocator, '}');

    try ws.writeText(req.items);

    const started_ms = std.time.milliTimestamp();
    var seen: usize = 0;
    while (seen < MAX_WS_RESPONSE_SCAN) : (seen += 1) {
        if (ws.read_timeout_ms > 0 and std.time.milliTimestamp() - started_ms >= @as(i64, @intCast(ws.read_timeout_ms))) {
            return error.CdpResponseTimeout;
        }
        const msg_opt = try ws.readTextMessage();
        if (msg_opt == null) return error.CdpConnectionClosed;
        const msg = msg_opt.?;
        if (!responseMatchesRequestId(allocator, msg, id)) {
            allocator.free(msg);
            continue;
        }
        return msg;
    }
    return error.CdpResponseTimeout;
}

fn extractPageWsUrlFromList(allocator: std.mem.Allocator, list_json: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, list_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;

    var first_any: ?[]const u8 = null;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const ws_val = item.object.get("webSocketDebuggerUrl") orelse continue;
        if (ws_val != .string) continue;
        if (first_any == null) first_any = ws_val.string;

        const type_val = item.object.get("type");
        if (type_val != null and type_val.? == .string and std.mem.eql(u8, type_val.?.string, "page")) {
            return try allocator.dupe(u8, ws_val.string);
        }
    }
    if (first_any) |u| return try allocator.dupe(u8, u);
    return null;
}

fn extractWsUrlFromVersion(allocator: std.mem.Allocator, version_json: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, version_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const ws = parsed.value.object.get("webSocketDebuggerUrl") orelse return null;
    if (ws != .string) return null;
    return try allocator.dupe(u8, ws.string);
}

fn resolveWsUrl(allocator: std.mem.Allocator, cfg: CdpConfig) ![]u8 {
    const list_url = try endpointJoin(allocator, cfg.endpoint, "/json/list");
    defer allocator.free(list_url);
    const list_body = fetchHttpBody(allocator, list_url) catch null;
    defer if (list_body) |b| allocator.free(b);
    if (list_body) |b| {
        if (try extractPageWsUrlFromList(allocator, b)) |u| return u;
    }

    const version_url = try endpointJoin(allocator, cfg.endpoint, "/json/version");
    defer allocator.free(version_url);
    const version_body = try fetchHttpBody(allocator, version_url);
    defer allocator.free(version_body);
    if (try extractWsUrlFromVersion(allocator, version_body)) |u| return u;
    return error.CdpTargetNotFound;
}

fn evaluateExpression(
    allocator: std.mem.Allocator,
    ws: *CdpWsClient,
    request_id: *u64,
    expression: []const u8,
) ![]u8 {
    var params: std.ArrayListUnmanaged(u8) = .empty;
    defer params.deinit(allocator);
    try params.appendSlice(allocator, "{\"expression\":");
    try json_util.appendJsonString(&params, allocator, expression);
    try params.appendSlice(allocator, ",\"returnByValue\":true,\"awaitPromise\":true}");

    const response = try executeCdpCommand(allocator, ws, request_id, "Runtime.evaluate", params.items);
    defer allocator.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return error.InvalidCdpResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCdpResponse;
    if (cdpErrorString(parsed.value.object) != null) return error.CdpCommandFailed;

    const result_obj = cdpResultObject(parsed.value.object) orelse return error.InvalidCdpResponse;
    if (result_obj.get("exceptionDetails") != null) return error.CdpScriptException;

    const eval_val = result_obj.get("result") orelse return error.InvalidCdpResponse;
    if (eval_val != .object) return error.InvalidCdpResponse;
    const value = eval_val.object.get("value") orelse return error.InvalidCdpResponse;

    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .null => allocator.dupe(u8, ""),
        .array, .object => std.json.Stringify.valueAlloc(allocator, value, .{}),
        else => error.InvalidCdpResponse,
    };
}

fn performClick(allocator: std.mem.Allocator, ws: *CdpWsClient, request_id: *u64, args: tools_mod.JsonObjectMap) !ToolResult {
    const selector = tools_mod.getString(args, "selector") orelse {
        return .{ .success = false, .output = "", .error_msg = "Missing 'selector' parameter for click action" };
    };
    const selector_json = try std.json.Stringify.valueAlloc(allocator, .{ .string = selector }, .{});
    defer allocator.free(selector_json);
    const script = try std.fmt.allocPrint(
        allocator,
        "(function(){{const el=document.querySelector({s});if(!el)return 'selector_not_found';el.click();return 'ok';}})()",
        .{selector_json},
    );
    defer allocator.free(script);

    const result = evaluateExpression(allocator, ws, request_id, script) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "CDP click failed: {s}", .{@errorName(err)});
        return .{ .success = false, .output = "", .error_msg = msg };
    };
    defer allocator.free(result);
    if (std.mem.eql(u8, result, "ok")) {
        const msg = try std.fmt.allocPrint(allocator, "Clicked element {s}", .{selector});
        return .{ .success = true, .output = msg };
    }
    if (std.mem.eql(u8, result, "selector_not_found")) {
        return .{ .success = false, .output = "", .error_msg = "CDP click selector not found" };
    }
    const msg = try std.fmt.allocPrint(allocator, "CDP click returned unexpected result: {s}", .{result});
    return .{ .success = false, .output = "", .error_msg = msg };
}

fn performType(allocator: std.mem.Allocator, ws: *CdpWsClient, request_id: *u64, args: tools_mod.JsonObjectMap) !ToolResult {
    const selector = tools_mod.getString(args, "selector") orelse {
        return .{ .success = false, .output = "", .error_msg = "Missing 'selector' parameter for type action" };
    };
    const text = tools_mod.getString(args, "text") orelse {
        return .{ .success = false, .output = "", .error_msg = "Missing 'text' parameter for type action" };
    };
    const selector_json = try std.json.Stringify.valueAlloc(allocator, .{ .string = selector }, .{});
    defer allocator.free(selector_json);
    const text_json = try std.json.Stringify.valueAlloc(allocator, .{ .string = text }, .{});
    defer allocator.free(text_json);
    const script = try std.fmt.allocPrint(
        allocator,
        "(function(){{const el=document.querySelector({s});if(!el)return 'selector_not_found';if(typeof el.focus==='function')el.focus();if(!('value' in el))return 'not_typable';el.value={s};el.dispatchEvent(new Event('input',{{bubbles:true}}));el.dispatchEvent(new Event('change',{{bubbles:true}}));return 'ok';}})()",
        .{ selector_json, text_json },
    );
    defer allocator.free(script);

    const result = evaluateExpression(allocator, ws, request_id, script) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "CDP type failed: {s}", .{@errorName(err)});
        return .{ .success = false, .output = "", .error_msg = msg };
    };
    defer allocator.free(result);

    if (std.mem.eql(u8, result, "ok")) {
        const msg = try std.fmt.allocPrint(allocator, "Typed text into element {s}", .{selector});
        return .{ .success = true, .output = msg };
    }
    if (std.mem.eql(u8, result, "selector_not_found")) {
        return .{ .success = false, .output = "", .error_msg = "CDP type selector not found" };
    }
    if (std.mem.eql(u8, result, "not_typable")) {
        return .{ .success = false, .output = "", .error_msg = "CDP type target is not an input/textarea element" };
    }
    const msg = try std.fmt.allocPrint(allocator, "CDP type returned unexpected result: {s}", .{result});
    return .{ .success = false, .output = "", .error_msg = msg };
}

fn performScroll(allocator: std.mem.Allocator, ws: *CdpWsClient, request_id: *u64, args: tools_mod.JsonObjectMap) !ToolResult {
    const maybe_selector = tools_mod.getString(args, "selector");
    const script = if (maybe_selector) |selector| blk: {
        const selector_json = try std.json.Stringify.valueAlloc(allocator, .{ .string = selector }, .{});
        defer allocator.free(selector_json);
        break :blk try std.fmt.allocPrint(
            allocator,
            "(function(){{const el=document.querySelector({s});if(!el)return 'selector_not_found';el.scrollIntoView({{behavior:'instant',block:'center'}});return 'ok';}})()",
            .{selector_json},
        );
    } else blk: {
        const x = tools_mod.getInt(args, "x") orelse 0;
        const y = tools_mod.getInt(args, "y") orelse 600;
        break :blk try std.fmt.allocPrint(
            allocator,
            "(function(){{window.scrollBy({d},{d});return 'ok';}})()",
            .{ x, y },
        );
    };
    defer allocator.free(script);

    const result = evaluateExpression(allocator, ws, request_id, script) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "CDP scroll failed: {s}", .{@errorName(err)});
        return .{ .success = false, .output = "", .error_msg = msg };
    };
    defer allocator.free(result);
    if (std.mem.eql(u8, result, "ok")) {
        return .{ .success = true, .output = "Scrolled page via CDP" };
    }
    if (std.mem.eql(u8, result, "selector_not_found")) {
        return .{ .success = false, .output = "", .error_msg = "CDP scroll selector not found" };
    }
    const msg = try std.fmt.allocPrint(allocator, "CDP scroll returned unexpected result: {s}", .{result});
    return .{ .success = false, .output = "", .error_msg = msg };
}

fn performRead(allocator: std.mem.Allocator, ws: *CdpWsClient, request_id: *u64) !ToolResult {
    const script =
        "(function(){const body=document.body;if(!body)return '';const t=body.innerText||body.textContent||'';return String(t).trim();})()";
    const content = evaluateExpression(allocator, ws, request_id, script) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "CDP read failed: {s}", .{@errorName(err)});
        return .{ .success = false, .output = "", .error_msg = msg };
    };
    defer allocator.free(content);

    if (content.len == 0) {
        const msg = try allocator.dupe(u8, "Page returned empty response");
        return .{ .success = true, .output = msg };
    }

    const truncated = content.len > MAX_DOM_READ_BYTES;
    const body_len = if (truncated) MAX_DOM_READ_BYTES else content.len;
    const suffix: []const u8 = if (truncated) "\n\n[Content truncated to 8 KB]" else "";
    const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ content[0..body_len], suffix });
    return .{ .success = true, .output = output };
}

fn performScreenshot(
    allocator: std.mem.Allocator,
    ws: *CdpWsClient,
    request_id: *u64,
    workspace_dir: []const u8,
    args: tools_mod.JsonObjectMap,
) !ToolResult {
    _ = executeCdpCommand(allocator, ws, request_id, "Page.enable", "{}") catch null;

    const response = executeCdpCommand(allocator, ws, request_id, "Page.captureScreenshot", "{\"format\":\"png\"}") catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "CDP screenshot failed: {s}", .{@errorName(err)});
        return .{ .success = false, .output = "", .error_msg = msg };
    };
    defer allocator.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        return .{ .success = false, .output = "", .error_msg = "CDP screenshot returned invalid JSON" };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .success = false, .output = "", .error_msg = "CDP screenshot response is not an object" };
    }
    if (cdpErrorString(parsed.value.object)) |msg| {
        const err = try std.fmt.allocPrint(allocator, "CDP screenshot error: {s}", .{msg});
        return .{ .success = false, .output = "", .error_msg = err };
    }

    const result_obj = cdpResultObject(parsed.value.object) orelse {
        return .{ .success = false, .output = "", .error_msg = "CDP screenshot missing result object" };
    };
    const data_val = result_obj.get("data") orelse {
        return .{ .success = false, .output = "", .error_msg = "CDP screenshot missing image data" };
    };
    if (data_val != .string) {
        return .{ .success = false, .output = "", .error_msg = "CDP screenshot image data is not a string" };
    }

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_val.string) catch {
        return .{ .success = false, .output = "", .error_msg = "CDP screenshot data is not valid base64" };
    };
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, data_val.string) catch {
        return .{ .success = false, .output = "", .error_msg = "CDP screenshot base64 decode failed" };
    };

    const filename = tools_mod.getString(args, "filename") orelse "browser-cdp.png";
    const full = try std.fs.path.join(allocator, &.{ workspace_dir, filename });
    defer allocator.free(full);
    const file = std.fs.cwd().createFile(full, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "CDP screenshot path create failed: {s}", .{@errorName(err)});
        return .{ .success = false, .output = "", .error_msg = msg };
    };
    defer file.close();
    try file.writeAll(decoded);

    const msg = try std.fmt.allocPrint(allocator, "[IMAGE:{s}]", .{full});
    return .{ .success = true, .output = msg };
}

pub fn performAction(
    allocator: std.mem.Allocator,
    cfg: CdpConfig,
    workspace_dir: []const u8,
    action: []const u8,
    args: tools_mod.JsonObjectMap,
) !ToolResult {
    try validateConfig(cfg);

    if (builtin.is_test) {
        if (std.mem.eql(u8, action, "screenshot")) {
            const filename = tools_mod.getString(args, "filename") orelse "browser-cdp.png";
            const full = try std.fs.path.join(allocator, &.{ workspace_dir, filename });
            defer allocator.free(full);
            const msg = try std.fmt.allocPrint(allocator, "[IMAGE:{s}]", .{full});
            return .{ .success = true, .output = msg };
        }
        const msg = try std.fmt.allocPrint(allocator, "CDP action '{s}' executed (test)", .{action});
        return .{ .success = true, .output = msg };
    }

    // Lightweight mode: verify endpoint reachability and provide deterministic response.
    probe(allocator, cfg) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "CDP endpoint unavailable: {s}", .{@errorName(err)});
        return .{ .success = false, .output = "", .error_msg = msg };
    };

    if (std.mem.eql(u8, action, "open")) {
        const url = tools_mod.getString(args, "url") orelse {
            return .{ .success = false, .output = "", .error_msg = "Missing 'url' parameter for open action" };
        };
        if (!std.mem.startsWith(u8, url, "https://")) {
            return .{ .success = false, .output = "", .error_msg = "Only https:// URLs are supported for security" };
        }
        openTabViaHttp(allocator, cfg, url) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "CDP open failed: {s}", .{@errorName(err)});
            return .{ .success = false, .output = "", .error_msg = msg };
        };
        const msg = try std.fmt.allocPrint(allocator, "Opened {s} via CDP", .{url});
        return .{ .success = true, .output = msg };
    }

    const ws_url = resolveWsUrl(allocator, cfg) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "CDP target discovery failed: {s}", .{@errorName(err)});
        return .{ .success = false, .output = "", .error_msg = msg };
    };
    defer allocator.free(ws_url);

    validateWsTargetPolicy(cfg, ws_url) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "CDP target policy violation: {s}", .{@errorName(err)});
        return .{ .success = false, .output = "", .error_msg = msg };
    };

    var ws = CdpWsClient.connect(allocator, ws_url, cfg.connect_timeout_ms) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "CDP websocket connection failed: {s}", .{@errorName(err)});
        return .{ .success = false, .output = "", .error_msg = msg };
    };
    defer ws.deinit();
    ws.read_timeout_ms = cfg.action_timeout_ms;

    var request_id: u64 = 1;
    if (std.mem.eql(u8, action, "click")) {
        return performClick(allocator, &ws, &request_id, args);
    }
    if (std.mem.eql(u8, action, "type")) {
        return performType(allocator, &ws, &request_id, args);
    }
    if (std.mem.eql(u8, action, "scroll")) {
        return performScroll(allocator, &ws, &request_id, args);
    }
    if (std.mem.eql(u8, action, "read")) {
        return performRead(allocator, &ws, &request_id);
    }
    if (std.mem.eql(u8, action, "screenshot")) {
        return performScreenshot(allocator, &ws, &request_id, workspace_dir, args);
    }

    return .{
        .success = false,
        .output = "",
        .error_msg = "Unsupported CDP browser action",
    };
}

test "validateConfig rejects remote endpoint by default" {
    const cfg: CdpConfig = .{
        .enabled = true,
        .endpoint = "http://10.0.0.2:9222",
        .allow_remote = false,
    };
    try std.testing.expectError(error.CdpRemoteNotAllowed, validateConfig(cfg));
}

test "validateConfig accepts loopback endpoint" {
    const cfg: CdpConfig = .{
        .enabled = true,
        .endpoint = "http://127.0.0.1:9222",
    };
    try validateConfig(cfg);
}

test "parseWsUrl handles ws target with explicit port" {
    const ws = try parseWsUrl("ws://127.0.0.1:9222/devtools/page/abc?q=1");
    try std.testing.expect(!ws.secure);
    try std.testing.expectEqualStrings("127.0.0.1", ws.host);
    try std.testing.expectEqual(@as(u16, 9222), ws.port);
    try std.testing.expectEqualStrings("/devtools/page/abc?q=1", ws.path_and_query);
}

test "parseWsUrl defaults path and port" {
    const ws = try parseWsUrl("ws://localhost");
    try std.testing.expectEqualStrings("localhost", ws.host);
    try std.testing.expectEqual(@as(u16, 80), ws.port);
    try std.testing.expectEqualStrings("/", ws.path_and_query);
}

test "parseWsUrl handles wss target" {
    const ws = try parseWsUrl("wss://127.0.0.1/devtools/browser/abc");
    try std.testing.expect(ws.secure);
    try std.testing.expectEqualStrings("127.0.0.1", ws.host);
    try std.testing.expectEqual(@as(u16, 443), ws.port);
    try std.testing.expectEqualStrings("/devtools/browser/abc", ws.path_and_query);
}

test "extractPageWsUrlFromList prefers page target" {
    const allocator = std.testing.allocator;
    const sample =
        \\[
        \\  {"type":"service_worker","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/sw/1"},
        \\  {"type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/2"}
        \\]
    ;
    const ws_opt = try extractPageWsUrlFromList(allocator, sample);
    const ws = ws_opt orelse return error.TestExpectedEqual;
    defer allocator.free(ws);
    try std.testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/page/2", ws);
}

test "responseMatchesRequestId matches valid response id" {
    const allocator = std.testing.allocator;
    const msg = "{\"id\":7,\"result\":{\"ok\":true}}";
    try std.testing.expect(responseMatchesRequestId(allocator, msg, 7));
    try std.testing.expect(!responseMatchesRequestId(allocator, msg, 8));
}

test "responseMatchesRequestId ignores event message without id" {
    const allocator = std.testing.allocator;
    const msg = "{\"method\":\"Runtime.executionContextCreated\",\"params\":{}}";
    try std.testing.expect(!responseMatchesRequestId(allocator, msg, 1));
}

test "validateWsTargetPolicy rejects remote ws when allow_remote is false" {
    const cfg: CdpConfig = .{
        .enabled = true,
        .endpoint = "http://127.0.0.1:9222",
        .allow_remote = false,
    };
    try std.testing.expectError(
        error.CdpRemoteNotAllowed,
        validateWsTargetPolicy(cfg, "ws://10.10.10.10:9222/devtools/page/1"),
    );
}

test "validateWsTargetPolicy allows remote ws when allow_remote is true" {
    const cfg: CdpConfig = .{
        .enabled = true,
        .endpoint = "http://127.0.0.1:9222",
        .allow_remote = true,
    };
    try validateWsTargetPolicy(cfg, "ws://10.10.10.10:9222/devtools/page/1");
}
