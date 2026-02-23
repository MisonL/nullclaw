const std = @import("std");
const builtin = @import("builtin");
const config_types = @import("config_types.zig");
const hooks_mod = @import("hooks.zig");
const tools_mod = @import("tools/root.zig");

const Tool = tools_mod.Tool;
const ToolResult = tools_mod.ToolResult;
const JsonObjectMap = tools_mod.JsonObjectMap;

pub const PluginSlot = enum {
    prompt_patch,
    tool_exec,
    hook_observer,
};

const PluginToolDef = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,

    fn deinit(self: *const PluginToolDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.parameters_json);
    }
};

const ParsedManifest = struct {
    name: []const u8,
    version: []const u8,
    entry: []const u8,
    has_prompt_patch: bool = false,
    has_tool_exec: bool = false,
    has_hook_observer: bool = false,
    prompt_patch: ?[]const u8 = null,
    tools: []PluginToolDef = &.{},

    fn deinit(self: *ParsedManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.entry);
        if (self.prompt_patch) |p| allocator.free(p);
        if (self.tools.len > 0) {
            for (self.tools) |*t| t.deinit(allocator);
            allocator.free(self.tools);
        }
    }
};

pub const PluginTool = struct {
    full_name: []const u8,
    description_text: []const u8,
    parameters_schema: []const u8,
    module_path: []const u8,
    workspace_dir: []const u8,
    exec_timeout_ms: u64,
    allow_network: bool,
    allow_workspace_write: bool,

    const vtable = Tool.VTable{
        .execute = &vtableExecute,
        .name = &vtableName,
        .description = &vtableDescription,
        .parameters_json = &vtableParametersJson,
    };

    pub fn tool(self: *PluginTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn vtableExecute(ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult {
        const self: *PluginTool = @ptrCast(@alignCast(ptr));
        return self.execute(allocator, args);
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *PluginTool = @ptrCast(@alignCast(ptr));
        return self.full_name;
    }

    fn vtableDescription(ptr: *anyopaque) []const u8 {
        const self: *PluginTool = @ptrCast(@alignCast(ptr));
        return self.description_text;
    }

    fn vtableParametersJson(ptr: *anyopaque) []const u8 {
        const self: *PluginTool = @ptrCast(@alignCast(ptr));
        return self.parameters_schema;
    }

    fn execute(self: *PluginTool, allocator: std.mem.Allocator, _: JsonObjectMap) !ToolResult {
        if (self.allow_network) {
            const msg = try allocator.dupe(u8, "plugin network access is not supported by current runtime");
            return .{ .success = false, .output = "", .error_msg = msg };
        }

        if (builtin.is_test) {
            const msg = try std.fmt.allocPrint(allocator, "plugin tool executed: {s}", .{self.full_name});
            return .{ .success = true, .output = msg };
        }

        var argv = try buildWasmtimeArgv(
            allocator,
            self.module_path,
            self.workspace_dir,
            self.allow_workspace_write,
            null,
        );
        defer argv.deinit(allocator);

        var child = std.process.Child.init(argv.args.items, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "plugin spawn failed: {s}", .{@errorName(err)});
            return .{ .success = false, .output = "", .error_msg = msg };
        };

        const wait_result = waitForChildWithTimeout(allocator, &child, self.exec_timeout_ms) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "plugin wait failed: {s}", .{@errorName(err)});
            return .{ .success = false, .output = "", .error_msg = msg };
        };

        const max_bytes = std.math.maxInt(usize);
        const stdout = child.stdout.?.readToEndAlloc(allocator, max_bytes) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "plugin stdout read failed: {s}", .{@errorName(err)});
            return .{ .success = false, .output = "", .error_msg = msg };
        };
        errdefer allocator.free(stdout);
        const stderr = child.stderr.?.readToEndAlloc(allocator, max_bytes) catch "";
        defer if (stderr.len > 0) allocator.free(stderr);

        const term = wait_result.term;

        if (wait_result.timed_out) {
            allocator.free(stdout);
            const msg = try std.fmt.allocPrint(allocator, "plugin execution timed out after {d}ms", .{self.exec_timeout_ms});
            return .{ .success = false, .output = "", .error_msg = msg };
        }

        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    if (stdout.len == 0) {
                        allocator.free(stdout);
                        const msg = try allocator.dupe(u8, "plugin completed with empty output");
                        return .{ .success = true, .output = msg };
                    }
                    return .{ .success = true, .output = stdout };
                }
                allocator.free(stdout);
                const detail = if (stderr.len > 0) stderr else "plugin execution failed";
                const msg = try std.fmt.allocPrint(allocator, "plugin exited with code {d}: {s}", .{ code, detail });
                return .{ .success = false, .output = "", .error_msg = msg };
            },
            else => {
                allocator.free(stdout);
                const msg = try allocator.dupe(u8, "plugin terminated unexpectedly");
                return .{ .success = false, .output = "", .error_msg = msg };
            },
        }
    }
};

fn emitPluginError(hook_bus: ?*hooks_mod.HookBus, name: []const u8, message: []const u8) void {
    if (hook_bus) |bus| {
        var evt: hooks_mod.HookEvent = .{
            .plugin_error = .{
                .name = name,
                .message = message,
            },
        };
        bus.emit(&evt);
    }
}

fn emitPluginLoaded(hook_bus: ?*hooks_mod.HookBus, name: []const u8, version: []const u8) void {
    if (hook_bus) |bus| {
        var evt: hooks_mod.HookEvent = .{
            .plugin_loaded = .{
                .name = name,
                .version = version,
            },
        };
        bus.emit(&evt);
    }
}

fn sanitizeToken(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |c, i| {
        const lower = std.ascii.toLower(c);
        out[i] = if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) lower else '_';
    }
    return out;
}

fn resolveDirPath(allocator: std.mem.Allocator, workspace_dir: []const u8, dir_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(dir_path)) return allocator.dupe(u8, dir_path);
    return std.fs.path.join(allocator, &.{ workspace_dir, dir_path });
}

fn manifestExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn collectManifestPaths(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    cfg: config_types.PluginsConfig,
) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }

    for (cfg.dirs) |dir_cfg| {
        const root_dir = resolveDirPath(allocator, workspace_dir, dir_cfg) catch continue;
        defer allocator.free(root_dir);

        const direct_manifest = std.fs.path.join(allocator, &.{ root_dir, "plugin.json" }) catch continue;
        defer allocator.free(direct_manifest);
        if (std.fs.path.isAbsolute(direct_manifest) and manifestExists(direct_manifest)) {
            try list.append(allocator, try allocator.dupe(u8, direct_manifest));
            continue;
        }

        var dir = std.fs.openDirAbsolute(root_dir, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            const nested_manifest = std.fs.path.join(allocator, &.{ root_dir, entry.name, "plugin.json" }) catch continue;
            defer allocator.free(nested_manifest);
            if (manifestExists(nested_manifest)) {
                try list.append(allocator, try allocator.dupe(u8, nested_manifest));
            }
        }
    }

    return try list.toOwnedSlice(allocator);
}

fn parseManifest(allocator: std.mem.Allocator, manifest_path: []const u8) !ParsedManifest {
    const content = try std.fs.openFileAbsolute(manifest_path, .{});
    defer content.close();
    const bytes = try content.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPluginManifest;

    const obj = parsed.value.object;
    const name_v = obj.get("name") orelse return error.InvalidPluginManifest;
    const version_v = obj.get("version") orelse return error.InvalidPluginManifest;
    const entry_v = obj.get("entry") orelse return error.InvalidPluginManifest;
    if (name_v != .string or version_v != .string or entry_v != .string) return error.InvalidPluginManifest;

    var out = ParsedManifest{
        .name = try allocator.dupe(u8, name_v.string),
        .version = try allocator.dupe(u8, version_v.string),
        .entry = try allocator.dupe(u8, entry_v.string),
    };
    errdefer out.deinit(allocator);

    if (obj.get("slots")) |slots_v| {
        if (slots_v == .array) {
            for (slots_v.array.items) |item| {
                if (item != .string) continue;
                if (std.mem.eql(u8, item.string, "prompt_patch")) out.has_prompt_patch = true;
                if (std.mem.eql(u8, item.string, "tool_exec")) out.has_tool_exec = true;
                if (std.mem.eql(u8, item.string, "hook_observer")) out.has_hook_observer = true;
            }
        }
    }
    if (!(out.has_prompt_patch or out.has_tool_exec or out.has_hook_observer)) {
        return error.InvalidPluginManifest;
    }

    if (out.has_prompt_patch) {
        if (obj.get("prompt_patch")) |pp| {
            if (pp == .string) out.prompt_patch = try allocator.dupe(u8, pp.string);
        }
    }

    if (out.has_tool_exec) {
        if (obj.get("tools")) |tools_v| {
            if (tools_v == .array) {
                var defs: std.ArrayListUnmanaged(PluginToolDef) = .empty;
                errdefer {
                    for (defs.items) |*d| d.deinit(allocator);
                    defs.deinit(allocator);
                }
                for (tools_v.array.items) |item| {
                    if (item != .object) continue;
                    const tn = item.object.get("name") orelse continue;
                    if (tn != .string) continue;
                    const td = item.object.get("description") orelse std.json.Value{ .string = "Execute plugin tool" };
                    const ps = item.object.get("parameters_json") orelse std.json.Value{ .string = "{\"type\":\"object\",\"properties\":{}}" };
                    if (td != .string or ps != .string) continue;
                    try defs.append(allocator, .{
                        .name = try allocator.dupe(u8, tn.string),
                        .description = try allocator.dupe(u8, td.string),
                        .parameters_json = try allocator.dupe(u8, ps.string),
                    });
                }
                out.tools = try defs.toOwnedSlice(allocator);
            }
        }

        if (out.tools.len == 0) {
            out.tools = try allocator.alloc(PluginToolDef, 1);
            out.tools[0] = .{
                .name = try allocator.dupe(u8, "run"),
                .description = try allocator.dupe(u8, "Execute plugin entrypoint"),
                .parameters_json = try allocator.dupe(u8, "{\"type\":\"object\",\"properties\":{}}"),
            };
        }
    }

    return out;
}

fn pluginModulePath(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    entry: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(entry)) return allocator.dupe(u8, entry);
    const parent = std.fs.path.dirname(manifest_path) orelse ".";
    return std.fs.path.join(allocator, &.{ parent, entry });
}

fn fileSize(path: []const u8) !u64 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.size;
}

const WasmtimeArgv = struct {
    args: std.ArrayListUnmanaged([]const u8) = .empty,
    owned: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *WasmtimeArgv, allocator: std.mem.Allocator) void {
        for (self.owned.items) |item| allocator.free(item);
        self.owned.deinit(allocator);
        self.args.deinit(allocator);
    }
};

fn buildWasmtimeArgv(
    allocator: std.mem.Allocator,
    module_path: []const u8,
    workspace_dir: []const u8,
    allow_workspace_write: bool,
    event_name: ?[]const u8,
) !WasmtimeArgv {
    var out = WasmtimeArgv{};
    errdefer out.deinit(allocator);

    try out.args.appendSlice(allocator, &.{ "wasmtime", "run" });
    if (allow_workspace_write) {
        const dir_flag = try std.fmt.allocPrint(allocator, "--dir={s}", .{workspace_dir});
        try out.owned.append(allocator, dir_flag);
        try out.args.append(allocator, dir_flag);
    }
    try out.args.append(allocator, module_path);
    if (event_name) |evt| {
        try out.args.appendSlice(allocator, &.{ "--", evt });
    }

    return out;
}

const WaitThreadCtx = struct {
    child: *std.process.Child,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wait_err: ?anyerror = null,
    term: ?std.process.Child.Term = null,

    fn run(ctx: *WaitThreadCtx) void {
        ctx.term = ctx.child.wait() catch |err| {
            ctx.wait_err = err;
            ctx.done.store(true, .release);
            return;
        };
        ctx.done.store(true, .release);
    }
};

const WaitWithTimeoutResult = struct {
    term: std.process.Child.Term,
    timed_out: bool,
};

fn waitForChildWithTimeout(
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    timeout_ms: u64,
) !WaitWithTimeoutResult {
    _ = allocator;
    var ctx = WaitThreadCtx{ .child = child };
    const waiter = try std.Thread.spawn(.{ .stack_size = 128 * 1024 }, WaitThreadCtx.run, .{&ctx});

    var timed_out = false;
    if (timeout_ms > 0) {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (!ctx.done.load(.acquire)) {
            if (std.time.milliTimestamp() >= deadline) {
                timed_out = true;
                _ = child.kill() catch {};
                break;
            }
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }

    waiter.join();

    if (ctx.wait_err) |err| return err;
    if (ctx.term == null) return error.PluginWaitNoTerm;
    return .{
        .term = ctx.term.?,
        .timed_out = timed_out,
    };
}

fn toolNameExists(list: *std.ArrayList(Tool), name: []const u8) bool {
    for (list.items) |t| {
        if (std.mem.eql(u8, t.name(), name)) return true;
    }
    return false;
}

pub fn appendPluginTools(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    cfg: config_types.PluginsConfig,
    tool_list: *std.ArrayList(Tool),
    hook_bus: ?*hooks_mod.HookBus,
) !void {
    if (!cfg.enabled or cfg.dirs.len == 0) return;

    const manifests = try collectManifestPaths(allocator, workspace_dir, cfg);
    defer {
        for (manifests) |p| allocator.free(p);
        allocator.free(manifests);
    }

    var loaded_plugins: u32 = 0;
    for (manifests) |manifest_path| {
        if (loaded_plugins >= cfg.max_loaded) break;

        var manifest = parseManifest(allocator, manifest_path) catch |err| {
            emitPluginError(hook_bus, "unknown", @errorName(err));
            continue;
        };
        defer manifest.deinit(allocator);

        const module_path = pluginModulePath(allocator, manifest_path, manifest.entry) catch |err| {
            emitPluginError(hook_bus, manifest.name, @errorName(err));
            continue;
        };
        defer allocator.free(module_path);

        const module_size = fileSize(module_path) catch |err| {
            emitPluginError(hook_bus, manifest.name, @errorName(err));
            continue;
        };
        if (module_size > cfg.max_wasm_bytes) {
            emitPluginError(hook_bus, manifest.name, "plugin wasm exceeds max_wasm_bytes");
            continue;
        }

        if (manifest.has_tool_exec and manifest.tools.len > 0) {
            const safe_plugin_name = try sanitizeToken(allocator, manifest.name);
            defer allocator.free(safe_plugin_name);
            for (manifest.tools) |tool_def| {
                const safe_tool_name = try sanitizeToken(allocator, tool_def.name);
                defer allocator.free(safe_tool_name);
                const prefixed_name = try std.fmt.allocPrint(allocator, "plugin_{s}_{s}", .{ safe_plugin_name, safe_tool_name });
                if (toolNameExists(tool_list, prefixed_name)) {
                    allocator.free(prefixed_name);
                    emitPluginError(hook_bus, manifest.name, "tool name conflict");
                    continue;
                }

                const pt = try allocator.create(PluginTool);
                pt.* = .{
                    .full_name = prefixed_name,
                    .description_text = try allocator.dupe(u8, tool_def.description),
                    .parameters_schema = try allocator.dupe(u8, tool_def.parameters_json),
                    .module_path = try allocator.dupe(u8, module_path),
                    .workspace_dir = workspace_dir,
                    .exec_timeout_ms = cfg.exec_timeout_ms,
                    .allow_network = cfg.allow_network,
                    .allow_workspace_write = cfg.allow_workspace_write,
                };
                try tool_list.append(allocator, pt.tool());
            }
        }

        loaded_plugins += 1;
        emitPluginLoaded(hook_bus, manifest.name, manifest.version);
    }
}

pub fn collectPromptPatch(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    cfg: config_types.PluginsConfig,
) !?[]u8 {
    if (!cfg.enabled or cfg.dirs.len == 0) return null;

    const manifests = try collectManifestPaths(allocator, workspace_dir, cfg);
    defer {
        for (manifests) |p| allocator.free(p);
        allocator.free(manifests);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var loaded_plugins: u32 = 0;

    for (manifests) |manifest_path| {
        if (loaded_plugins >= cfg.max_loaded) break;
        var manifest = parseManifest(allocator, manifest_path) catch continue;
        defer manifest.deinit(allocator);

        if (manifest.has_prompt_patch and manifest.prompt_patch != null) {
            try std.fmt.format(buf.writer(allocator), "### Plugin: {s} ({s})\n{s}\n\n", .{
                manifest.name,
                manifest.version,
                manifest.prompt_patch.?,
            });
        }
        loaded_plugins += 1;
    }

    if (buf.items.len == 0) return null;
    return try buf.toOwnedSlice(allocator);
}

const HookObserverTask = struct {
    workspace_dir: []u8,
    cfg: config_types.PluginsConfig,
    event_name: []u8,

    fn run(ctx: *HookObserverTask) void {
        const allocator = std.heap.c_allocator;
        defer {
            allocator.free(ctx.workspace_dir);
            allocator.free(ctx.event_name);
            allocator.destroy(ctx);
        }

        const manifests = collectManifestPaths(allocator, ctx.workspace_dir, ctx.cfg) catch return;
        defer {
            for (manifests) |p| allocator.free(p);
            allocator.free(manifests);
        }

        var loaded_plugins: u32 = 0;
        for (manifests) |manifest_path| {
            if (loaded_plugins >= ctx.cfg.max_loaded) break;
            loaded_plugins += 1;

            var manifest = parseManifest(allocator, manifest_path) catch continue;
            defer manifest.deinit(allocator);
            if (!manifest.has_hook_observer) continue;
            if (ctx.cfg.allow_network) continue;

            const module_path = pluginModulePath(allocator, manifest_path, manifest.entry) catch continue;
            defer allocator.free(module_path);
            const module_size = fileSize(module_path) catch continue;
            if (module_size > ctx.cfg.max_wasm_bytes) continue;
            if (builtin.is_test) continue;

            var argv = buildWasmtimeArgv(
                allocator,
                module_path,
                ctx.workspace_dir,
                ctx.cfg.allow_workspace_write,
                ctx.event_name,
            ) catch continue;
            defer argv.deinit(allocator);

            var child = std.process.Child.init(argv.args.items, allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;
            child.spawn() catch continue;

            _ = waitForChildWithTimeout(allocator, &child, ctx.cfg.exec_timeout_ms) catch {
                _ = child.kill() catch {};
                continue;
            };

            const stdout_out = child.stdout.?.readToEndAlloc(allocator, 128 * 1024) catch "";
            defer if (stdout_out.len > 0) allocator.free(stdout_out);
            const stderr_out = child.stderr.?.readToEndAlloc(allocator, 128 * 1024) catch "";
            defer if (stderr_out.len > 0) allocator.free(stderr_out);
        }
    }
};

fn hookEventName(event: *const hooks_mod.HookEvent) []const u8 {
    return switch (event.*) {
        .gateway_startup => "gateway_startup",
        .agent_bootstrap => "agent_bootstrap",
        .message_received => "message_received",
        .stream_fallback => "stream_fallback",
        .model_fallback => "model_fallback",
        .tool_loop_warning => "tool_loop_warning",
        .tool_loop_breaker => "tool_loop_breaker",
        .turn_complete => "turn_complete",
        .plugin_loaded => "plugin_loaded",
        .plugin_error => "plugin_error",
        .mcp_request => "mcp_request",
        .daemon_feedback_tick => "daemon_feedback_tick",
    };
}

pub fn notifyHookObserversAsync(
    workspace_dir: []const u8,
    cfg: config_types.PluginsConfig,
    event: *const hooks_mod.HookEvent,
) void {
    if (!cfg.enabled or cfg.dirs.len == 0) return;
    if (builtin.is_test) return;

    const allocator = std.heap.c_allocator;
    const task = allocator.create(HookObserverTask) catch return;
    task.workspace_dir = allocator.dupe(u8, workspace_dir) catch {
        allocator.destroy(task);
        return;
    };
    task.event_name = allocator.dupe(u8, hookEventName(event)) catch {
        allocator.free(task.workspace_dir);
        allocator.destroy(task);
        return;
    };
    task.cfg = cfg;

    const thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, HookObserverTask.run, .{task}) catch {
        allocator.free(task.workspace_dir);
        allocator.free(task.event_name);
        allocator.destroy(task);
        return;
    };
    thread.detach();
}

test "collectPromptPatch returns null when plugins disabled" {
    const patch = try collectPromptPatch(std.testing.allocator, ".", .{ .enabled = false });
    try std.testing.expect(patch == null);
}

test "sanitizeToken keeps alnum and replaces separators" {
    const out = try sanitizeToken(std.testing.allocator, "My-Plugin.v1");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("my_plugin_v1", out);
}

test "notifyHookObserversAsync no-op when disabled" {
    var evt: hooks_mod.HookEvent = .{ .turn_complete = .{ .response_len = 1, .used_tools = false } };
    notifyHookObserversAsync(".", .{ .enabled = false }, &evt);
}

test "buildWasmtimeArgv adds workspace dir only when write allowed" {
    var with_write = try buildWasmtimeArgv(
        std.testing.allocator,
        "/tmp/plugin.wasm",
        "/tmp/workspace",
        true,
        null,
    );
    defer with_write.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), with_write.args.items.len);
    try std.testing.expect(std.mem.eql(u8, with_write.args.items[2], "--dir=/tmp/workspace"));

    var without_write = try buildWasmtimeArgv(
        std.testing.allocator,
        "/tmp/plugin.wasm",
        "/tmp/workspace",
        false,
        null,
    );
    defer without_write.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), without_write.args.items.len);
    try std.testing.expect(std.mem.eql(u8, without_write.args.items[2], "/tmp/plugin.wasm"));
}

test "plugin tool rejects allow_network policy" {
    var tool = PluginTool{
        .full_name = "plugin_test_tool",
        .description_text = "desc",
        .parameters_schema = "{}",
        .module_path = "/tmp/plugin.wasm",
        .workspace_dir = "/tmp/workspace",
        .exec_timeout_ms = 100,
        .allow_network = true,
        .allow_workspace_write = false,
    };
    var args = std.json.ObjectMap.init(std.testing.allocator);
    defer args.deinit();

    const result = try tool.execute(std.testing.allocator, args);
    defer if (result.error_msg) |msg| std.testing.allocator.free(msg);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}
