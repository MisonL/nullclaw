//! SubagentManager — background task execution via isolated agent instances.
//!
//! Spawns subagents in separate OS threads with restricted tool sets
//! (no message, spawn, delegate — to prevent infinite loops).
//! Task results are routed via the event bus as system InboundMessages.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bus_mod = @import("bus.zig");
const config_mod = @import("config.zig");
const providers = @import("providers/root.zig");

const log = std.log.scoped(.subagent);

const SUBAGENT_REGISTRY_MAX_BYTES: usize = 4 * 1024 * 1024;
const RESTART_RECOVERY_ERROR: []const u8 = "interrupted by restart";

// ── Task types ──────────────────────────────────────────────────

pub const TaskStatus = enum {
    running,
    completed,
    failed,
};

pub const TaskState = struct {
    status: TaskStatus,
    label: []const u8,
    origin_channel: []const u8,
    origin_chat_id: []const u8,
    result: ?[]const u8 = null,
    error_msg: ?[]const u8 = null,
    started_at: i64,
    completed_at: ?i64 = null,
    thread: ?std.Thread = null,
};

pub const SubagentConfig = struct {
    max_iterations: u32 = 15,
    max_concurrent: u32 = 4,
};

const JsonTaskState = struct {
    id: u64,
    status: []const u8,
    label: []const u8,
    origin_channel: ?[]const u8 = null,
    origin_chat_id: ?[]const u8 = null,
    result: ?[]const u8 = null,
    error_msg: ?[]const u8 = null,
    started_at: i64,
    completed_at: ?i64 = null,
};

const JsonRegistry = struct {
    next_id: u64,
    tasks: []const JsonTaskState,
};

// ── ThreadContext — passed to each spawned thread ────────────────

const ThreadContext = struct {
    manager: *SubagentManager,
    task_id: u64,
    task: []const u8,
    label: []const u8,
    origin_channel: []const u8,
    origin_chat_id: []const u8,
};

// ── SubagentManager ─────────────────────────────────────────────

pub const SubagentManager = struct {
    allocator: Allocator,
    tasks: std.AutoHashMapUnmanaged(u64, *TaskState),
    next_id: u64,
    mutex: std.Thread.Mutex,
    config: SubagentConfig,
    bus: ?*bus_mod.Bus,

    // Context needed for creating providers in subagent threads
    api_key: ?[]const u8,
    default_provider: []const u8,
    default_model: ?[]const u8,
    workspace_dir: []const u8,
    agents: []const config_mod.NamedAgentConfig,
    http_enabled: bool,

    pub fn init(
        allocator: Allocator,
        cfg: *const config_mod.Config,
        bus: ?*bus_mod.Bus,
        subagent_config: SubagentConfig,
    ) SubagentManager {
        var manager: SubagentManager = .{
            .allocator = allocator,
            .tasks = .{},
            .next_id = 1,
            .mutex = .{},
            .config = subagent_config,
            .bus = bus,
            .api_key = cfg.defaultProviderKey(),
            .default_provider = cfg.default_provider,
            .default_model = cfg.default_model,
            .workspace_dir = cfg.workspace_dir,
            .agents = cfg.agents,
            .http_enabled = cfg.http_request.enabled,
        };
        manager.loadRegistry() catch |err| {
            log.warn("subagent: failed to load registry: {}", .{err});
        };
        return manager;
    }

    fn taskStatusString(status: TaskStatus) []const u8 {
        return switch (status) {
            .running => "running",
            .completed => "completed",
            .failed => "failed",
        };
    }

    fn parseTaskStatus(raw: []const u8) TaskStatus {
        if (std.ascii.eqlIgnoreCase(raw, "running")) return .running;
        if (std.ascii.eqlIgnoreCase(raw, "completed")) return .completed;
        return .failed;
    }

    fn subagentStateDirPath(self: *const SubagentManager) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.workspace_dir, "state" });
    }

    fn subagentRegistryPath(self: *const SubagentManager) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.workspace_dir, "state", "subagents.json" });
    }

    fn ensureStateDir(self: *const SubagentManager) !void {
        const state_dir = try self.subagentStateDirPath();
        defer self.allocator.free(state_dir);
        std.fs.cwd().makePath(state_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    fn freeTaskState(self: *SubagentManager, state: *TaskState, join_thread: bool) void {
        if (join_thread and state.thread != null) {
            const thread = state.thread.?;
            thread.join();
        }
        if (state.result) |r| self.allocator.free(r);
        if (state.error_msg) |e| self.allocator.free(e);
        self.allocator.free(state.label);
        self.allocator.free(state.origin_channel);
        self.allocator.free(state.origin_chat_id);
        self.allocator.destroy(state);
    }

    fn clearTasksLocked(self: *SubagentManager, join_threads: bool) void {
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            self.freeTaskState(entry.value_ptr.*, join_threads);
        }
        self.tasks.clearRetainingCapacity();
    }

    fn saveRegistryLocked(self: *SubagentManager) !void {
        var task_list: std.ArrayListUnmanaged(JsonTaskState) = .empty;
        defer task_list.deinit(self.allocator);

        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const task_id = entry.key_ptr.*;
            const state = entry.value_ptr.*;
            try task_list.append(self.allocator, .{
                .id = task_id,
                .status = taskStatusString(state.status),
                .label = state.label,
                .origin_channel = state.origin_channel,
                .origin_chat_id = state.origin_chat_id,
                .result = state.result,
                .error_msg = state.error_msg,
                .started_at = state.started_at,
                .completed_at = state.completed_at,
            });
        }

        const Ctx = struct {
            fn lessThan(_: void, a: JsonTaskState, b: JsonTaskState) bool {
                return a.id < b.id;
            }
        };
        std.mem.sort(JsonTaskState, task_list.items, {}, Ctx.lessThan);

        const payload = JsonRegistry{
            .next_id = self.next_id,
            .tasks = task_list.items,
        };
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer self.allocator.free(aw.writer.buffer);
        try std.json.Stringify.value(payload, .{}, &aw.writer);
        const json = aw.writer.buffer[0..aw.writer.end];

        try self.ensureStateDir();
        const registry_path = try self.subagentRegistryPath();
        defer self.allocator.free(registry_path);

        try std.fs.cwd().writeFile(.{
            .sub_path = registry_path,
            .data = json,
        });
    }

    pub fn saveRegistry(self: *SubagentManager) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.saveRegistryLocked();
    }

    pub fn loadRegistry(self: *SubagentManager) !void {
        const registry_path = try self.subagentRegistryPath();
        defer self.allocator.free(registry_path);

        const raw = std.fs.cwd().readFileAlloc(self.allocator, registry_path, SUBAGENT_REGISTRY_MAX_BYTES) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(raw);

        const parsed = try std.json.parseFromSlice(JsonRegistry, self.allocator, raw, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.getRunningCountLocked() > 0) {
            return error.SubagentsRunning;
        }

        self.clearTasksLocked(false);

        var max_task_id: u64 = 0;
        var recovered_running = false;
        const now = std.time.milliTimestamp();

        for (parsed.value.tasks) |task_json| {
            const state = try self.allocator.create(TaskState);
            errdefer self.allocator.destroy(state);

            const stored_status = parseTaskStatus(task_json.status);
            const recovered_status: TaskStatus = if (stored_status == .running) blk: {
                recovered_running = true;
                break :blk .failed;
            } else stored_status;

            const label = try self.allocator.dupe(u8, task_json.label);
            errdefer self.allocator.free(label);

            const origin_channel = try self.allocator.dupe(u8, task_json.origin_channel orelse "system");
            errdefer self.allocator.free(origin_channel);

            const origin_chat_id = try self.allocator.dupe(u8, task_json.origin_chat_id orelse "agent");
            errdefer self.allocator.free(origin_chat_id);

            const result = if (task_json.result) |r| try self.allocator.dupe(u8, r) else null;
            errdefer if (result) |r| self.allocator.free(r);

            const error_msg = if (stored_status == .running)
                try self.allocator.dupe(u8, RESTART_RECOVERY_ERROR)
            else if (task_json.error_msg) |e|
                try self.allocator.dupe(u8, e)
            else
                null;
            errdefer if (error_msg) |e| self.allocator.free(e);

            const completed_at = if (stored_status == .running) now else task_json.completed_at;

            state.* = .{
                .status = recovered_status,
                .label = label,
                .origin_channel = origin_channel,
                .origin_chat_id = origin_chat_id,
                .result = result,
                .error_msg = error_msg,
                .started_at = task_json.started_at,
                .completed_at = completed_at,
                .thread = null,
            };

            try self.tasks.put(self.allocator, task_json.id, state);
            if (task_json.id > max_task_id) max_task_id = task_json.id;
        }

        const next_from_tasks = max_task_id + 1;
        self.next_id = @max(parsed.value.next_id, next_from_tasks);
        if (self.next_id == 0) self.next_id = 1;

        if (recovered_running) {
            self.saveRegistryLocked() catch |err| {
                log.warn("subagent: failed to persist recovered registry: {}", .{err});
            };
        }
    }

    pub fn deinit(self: *SubagentManager) void {
        while (true) {
            var task_state: ?*TaskState = null;
            self.mutex.lock();
            var it = self.tasks.iterator();
            if (it.next()) |entry| {
                const task_id = entry.key_ptr.*;
                task_state = entry.value_ptr.*;
                _ = self.tasks.remove(task_id);
            }
            self.mutex.unlock();

            if (task_state) |state| {
                self.freeTaskState(state, true);
            } else break;
        }
        self.tasks.deinit(self.allocator);
    }

    /// Spawn a background subagent. Returns task_id immediately.
    pub fn spawn(
        self: *SubagentManager,
        task: []const u8,
        label: []const u8,
        origin_channel: []const u8,
        origin_chat_id: []const u8,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.getRunningCountLocked() >= self.config.max_concurrent)
            return error.TooManyConcurrentSubagents;

        const task_id = self.next_id;
        self.next_id += 1;

        const state = try self.allocator.create(TaskState);
        errdefer self.allocator.destroy(state);

        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const owned_origin_channel = try self.allocator.dupe(u8, origin_channel);
        errdefer self.allocator.free(owned_origin_channel);
        const owned_origin_chat_id = try self.allocator.dupe(u8, origin_chat_id);
        errdefer self.allocator.free(owned_origin_chat_id);

        state.* = .{
            .status = .running,
            .label = owned_label,
            .origin_channel = owned_origin_channel,
            .origin_chat_id = owned_origin_chat_id,
            .started_at = std.time.milliTimestamp(),
        };

        try self.tasks.put(self.allocator, task_id, state);
        errdefer {
            _ = self.tasks.remove(task_id);
            self.freeTaskState(state, false);
        }

        // Build thread context
        const ctx = try self.allocator.create(ThreadContext);
        errdefer self.allocator.destroy(ctx);
        const ctx_task = try self.allocator.dupe(u8, task);
        errdefer self.allocator.free(ctx_task);
        const ctx_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(ctx_label);
        const ctx_origin_channel = try self.allocator.dupe(u8, origin_channel);
        errdefer self.allocator.free(ctx_origin_channel);
        const ctx_origin_chat_id = try self.allocator.dupe(u8, origin_chat_id);
        errdefer self.allocator.free(ctx_origin_chat_id);
        ctx.* = .{
            .manager = self,
            .task_id = task_id,
            .task = ctx_task,
            .label = ctx_label,
            .origin_channel = ctx_origin_channel,
            .origin_chat_id = ctx_origin_chat_id,
        };

        state.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, subagentThreadFn, .{ctx});
        self.saveRegistryLocked() catch |err| {
            log.warn("subagent: failed to persist task registry after spawn: {}", .{err});
        };

        return task_id;
    }

    pub fn getTaskStatus(self: *SubagentManager, task_id: u64) ?TaskStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.get(task_id)) |state| {
            return state.status;
        }
        return null;
    }

    pub fn getTaskResult(self: *SubagentManager, task_id: u64) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.get(task_id)) |state| {
            return state.result;
        }
        return null;
    }

    pub fn getRunningCount(self: *SubagentManager) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.getRunningCountLocked();
    }

    fn getRunningCountLocked(self: *SubagentManager) u32 {
        var count: u32 = 0;
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.status == .running) count += 1;
        }
        return count;
    }

    /// Mark a task as completed or failed. Thread-safe.
    fn completeTask(self: *SubagentManager, task_id: u64, result: ?[]const u8, err_msg: ?[]const u8) void {
        // Dupe result/error into manager's allocator (source may be arena-backed)
        const owned_result = if (result) |r| self.allocator.dupe(u8, r) catch null else null;
        const owned_err = if (err_msg) |e| self.allocator.dupe(u8, e) catch null else null;

        var found = false;
        var label: []const u8 = "subagent";
        var origin_channel: []const u8 = "system";
        var origin_chat_id: []const u8 = "agent";
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.tasks.get(task_id)) |state| {
                found = true;
                state.status = if (owned_err != null) .failed else .completed;
                if (state.result) |r| self.allocator.free(r);
                if (state.error_msg) |e| self.allocator.free(e);
                state.result = owned_result;
                state.error_msg = owned_err;
                state.completed_at = std.time.milliTimestamp();
                label = state.label;
                origin_channel = state.origin_channel;
                origin_chat_id = state.origin_chat_id;
                self.saveRegistryLocked() catch |err| {
                    log.warn("subagent: failed to persist task registry after completion: {}", .{err});
                };
            }
        }

        if (!found) {
            if (owned_result) |r| self.allocator.free(r);
            if (owned_err) |e| self.allocator.free(e);
            return;
        }

        // Route result via bus (outside lock)
        if (self.bus) |b| {
            const content = if (owned_result) |r|
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' completed]\n{s}", .{ label, r }) catch return
            else if (owned_err) |e|
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' failed]\n{s}", .{ label, e }) catch return
            else
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' finished]", .{label}) catch return;

            const session_key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ origin_channel, origin_chat_id }) catch {
                self.allocator.free(content);
                return;
            };
            defer self.allocator.free(session_key);

            const msg = bus_mod.makeInbound(
                self.allocator,
                origin_channel,
                "subagent",
                origin_chat_id,
                content,
                session_key,
            ) catch {
                self.allocator.free(content);
                return;
            };
            self.allocator.free(content);

            b.publishInbound(msg) catch |err| {
                log.err("subagent: failed to publish result to bus: {}", .{err});
            };
        }
    }
};

// ── Thread function ─────────────────────────────────────────────

fn subagentThreadFn(ctx: *ThreadContext) void {
    defer {
        ctx.manager.allocator.free(ctx.task);
        ctx.manager.allocator.free(ctx.label);
        ctx.manager.allocator.free(ctx.origin_channel);
        ctx.manager.allocator.free(ctx.origin_chat_id);
        ctx.manager.allocator.destroy(ctx);
    }

    // Use the legacy complete path — simple, works with any provider,
    // no need to replicate the full ProviderHolder pattern.
    // Build a config-like struct for providers.completeWithSystem().
    const system_prompt = "You are a background subagent. Complete the assigned task concisely and accurately. You have no access to interactive tools — focus on reasoning and analysis.";

    var cfg_arena = std.heap.ArenaAllocator.init(ctx.manager.allocator);
    defer cfg_arena.deinit();

    // Build a config-like struct that providers.completeWithSystem() accepts
    const cfg = .{
        .api_key = ctx.manager.api_key,
        .default_provider = ctx.manager.default_provider,
        .default_model = ctx.manager.default_model,
        .temperature = @as(f64, 0.7),
        .max_tokens = @as(?u64, null),
    };

    const result = providers.completeWithSystem(
        cfg_arena.allocator(),
        &cfg,
        system_prompt,
        ctx.task,
    ) catch |err| {
        ctx.manager.completeTask(ctx.task_id, null, @errorName(err));
        return;
    };

    ctx.manager.completeTask(ctx.task_id, result, null);
}

// ── Tests ───────────────────────────────────────────────────────

const TestConfig = struct {
    tmp_dir: std.testing.TmpDir,
    workspace_dir: []u8,
    cfg: config_mod.Config,

    fn init() !TestConfig {
        var tmp_dir = std.testing.tmpDir(.{});
        const workspace_dir = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
        return .{
            .tmp_dir = tmp_dir,
            .workspace_dir = workspace_dir,
            .cfg = .{
                .workspace_dir = workspace_dir,
                .config_path = "unused",
                .allocator = std.testing.allocator,
            },
        };
    }

    fn deinit(self: *TestConfig) void {
        std.testing.allocator.free(self.workspace_dir);
        self.tmp_dir.cleanup();
    }
};

test "SubagentManager init and deinit" {
    var tc = try TestConfig.init();
    defer tc.deinit();
    var mgr = SubagentManager.init(std.testing.allocator, &tc.cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expectEqual(@as(u64, 1), mgr.next_id);
    try std.testing.expect(mgr.bus == null);
}

test "SubagentConfig defaults" {
    const sc = SubagentConfig{};
    try std.testing.expectEqual(@as(u32, 15), sc.max_iterations);
    try std.testing.expectEqual(@as(u32, 4), sc.max_concurrent);
}

test "TaskStatus enum values" {
    try std.testing.expect(@intFromEnum(TaskStatus.running) != @intFromEnum(TaskStatus.completed));
    try std.testing.expect(@intFromEnum(TaskStatus.completed) != @intFromEnum(TaskStatus.failed));
}

test "TaskState initial defaults" {
    const state = TaskState{
        .status = .running,
        .label = "test",
        .origin_channel = "system",
        .origin_chat_id = "agent",
        .started_at = 0,
    };
    try std.testing.expect(state.result == null);
    try std.testing.expect(state.error_msg == null);
    try std.testing.expect(state.completed_at == null);
    try std.testing.expect(state.thread == null);
}

test "SubagentManager getRunningCount empty" {
    var tc = try TestConfig.init();
    defer tc.deinit();
    var mgr = SubagentManager.init(std.testing.allocator, &tc.cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
}

test "SubagentManager getTaskStatus unknown id" {
    var tc = try TestConfig.init();
    defer tc.deinit();
    var mgr = SubagentManager.init(std.testing.allocator, &tc.cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expect(mgr.getTaskStatus(999) == null);
}

test "SubagentManager getTaskResult unknown id" {
    var tc = try TestConfig.init();
    defer tc.deinit();
    var mgr = SubagentManager.init(std.testing.allocator, &tc.cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expect(mgr.getTaskResult(999) == null);
}

test "SubagentManager completeTask updates state" {
    var tc = try TestConfig.init();
    defer tc.deinit();
    var mgr = SubagentManager.init(std.testing.allocator, &tc.cfg, null, .{});
    defer mgr.deinit();

    // Manually insert a task state to test completeTask
    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "test-task"),
        .origin_channel = try std.testing.allocator.dupe(u8, "system"),
        .origin_chat_id = try std.testing.allocator.dupe(u8, "agent"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.completeTask(1, "done!", null);

    try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(1).?);
    try std.testing.expectEqualStrings("done!", mgr.getTaskResult(1).?);
}

test "SubagentManager completeTask with error" {
    var tc = try TestConfig.init();
    defer tc.deinit();
    var mgr = SubagentManager.init(std.testing.allocator, &tc.cfg, null, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "fail-task"),
        .origin_channel = try std.testing.allocator.dupe(u8, "system"),
        .origin_chat_id = try std.testing.allocator.dupe(u8, "agent"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.completeTask(1, null, "timeout");

    try std.testing.expectEqual(TaskStatus.failed, mgr.getTaskStatus(1).?);
    try std.testing.expect(mgr.getTaskResult(1) == null);
}

test "SubagentManager completeTask routes via bus" {
    var tc = try TestConfig.init();
    defer tc.deinit();
    var bus = bus_mod.Bus.init();
    defer bus.close();

    var mgr = SubagentManager.init(std.testing.allocator, &tc.cfg, &bus, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "bus-task"),
        .origin_channel = try std.testing.allocator.dupe(u8, "telegram"),
        .origin_chat_id = try std.testing.allocator.dupe(u8, "chat-42"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.completeTask(1, "result text", null);

    // Check bus received the message — verify depth increased
    try std.testing.expect(bus.inboundDepth() > 0);

    // Drain the bus to avoid memory leak
    bus.close();
    if (bus.consumeInbound()) |msg| {
        try std.testing.expectEqualStrings("telegram", msg.channel);
        try std.testing.expectEqualStrings("chat-42", msg.chat_id);
        try std.testing.expectEqualStrings("telegram:chat-42", msg.session_key);
        msg.deinit(std.testing.allocator);
    }
}

test "SubagentManager save/load registry roundtrip" {
    var tc = try TestConfig.init();
    defer tc.deinit();

    var mgr = SubagentManager.init(std.testing.allocator, &tc.cfg, null, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .completed,
        .label = try std.testing.allocator.dupe(u8, "persisted-task"),
        .origin_channel = try std.testing.allocator.dupe(u8, "system"),
        .origin_chat_id = try std.testing.allocator.dupe(u8, "agent"),
        .result = try std.testing.allocator.dupe(u8, "done"),
        .started_at = std.time.milliTimestamp(),
        .completed_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 7, state);
    mgr.next_id = 9;
    try mgr.saveRegistry();

    var mgr2 = SubagentManager.init(std.testing.allocator, &tc.cfg, null, .{});
    defer mgr2.deinit();
    try std.testing.expectEqual(@as(?TaskStatus, .completed), mgr2.getTaskStatus(7));
    try std.testing.expectEqualStrings("done", mgr2.getTaskResult(7).?);
    try std.testing.expectEqual(@as(u64, 9), mgr2.next_id);
}

test "SubagentManager loadRegistry converts running tasks to failed" {
    var tc = try TestConfig.init();
    defer tc.deinit();

    const state_dir = try std.fs.path.join(std.testing.allocator, &.{ tc.workspace_dir, "state" });
    defer std.testing.allocator.free(state_dir);
    try std.fs.cwd().makePath(state_dir);

    const registry_path = try std.fs.path.join(std.testing.allocator, &.{ tc.workspace_dir, "state", "subagents.json" });
    defer std.testing.allocator.free(registry_path);
    const registry_json =
        \\{
        \\  "next_id": 3,
        \\  "tasks": [
        \\    {
        \\      "id": 2,
        \\      "status": "running",
        \\      "label": "stuck-task",
        \\      "origin_channel": "telegram",
        \\      "origin_chat_id": "chat77",
        \\      "started_at": 1700000000000,
        \\      "completed_at": null
        \\    }
        \\  ]
        \\}
    ;
    try std.fs.cwd().writeFile(.{
        .sub_path = registry_path,
        .data = registry_json,
    });

    var mgr = SubagentManager.init(std.testing.allocator, &tc.cfg, null, .{});
    defer mgr.deinit();

    mgr.mutex.lock();
    defer mgr.mutex.unlock();
    const loaded = mgr.tasks.get(2).?;
    try std.testing.expectEqual(TaskStatus.failed, loaded.status);
    try std.testing.expectEqualStrings(RESTART_RECOVERY_ERROR, loaded.error_msg.?);
    try std.testing.expect(loaded.completed_at != null);
    try std.testing.expectEqualStrings("telegram", loaded.origin_channel);
    try std.testing.expectEqualStrings("chat77", loaded.origin_chat_id);
    try std.testing.expectEqual(@as(u64, 3), mgr.next_id);
}
