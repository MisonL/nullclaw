const std = @import("std");

pub const HookEventKind = enum {
    gateway_startup,
    agent_bootstrap,
    message_received,
    stream_fallback,
    model_fallback,
    tool_loop_warning,
    tool_loop_breaker,
    turn_complete,
    plugin_loaded,
    plugin_error,
    mcp_request,
    daemon_feedback_tick,
};

pub const HookEvent = union(HookEventKind) {
    gateway_startup: struct {
        host: []const u8,
        port: u16,
    },
    agent_bootstrap: struct {
        model: []const u8,
        workspace_dir: []const u8,
    },
    message_received: struct {
        text: []const u8,
    },
    stream_fallback: struct {
        reason: []const u8,
    },
    model_fallback: struct {
        requested_model: []const u8,
        active_model: []const u8,
    },
    tool_loop_warning: struct {
        repeat_streak: u32,
        abab_streak: u32,
        no_progress_streak: u32,
    },
    tool_loop_breaker: struct {
        repeat_streak: u32,
        abab_streak: u32,
        no_progress_streak: u32,
    },
    turn_complete: struct {
        response_len: usize,
        used_tools: bool,
    },
    plugin_loaded: struct {
        name: []const u8,
        version: []const u8,
    },
    plugin_error: struct {
        name: []const u8,
        message: []const u8,
    },
    mcp_request: struct {
        method: []const u8,
        success: bool,
    },
    daemon_feedback_tick: struct {
        turn_complete_count: u64,
        model_fallback_count: u64,
        tool_loop_warning_count: u64,
        tool_loop_breaker_count: u64,
    },
};

pub const HookCallback = *const fn (ctx: *anyopaque, event: *const HookEvent) void;

const Subscription = struct {
    id: u32,
    kind: ?HookEventKind,
    callback: HookCallback,
    ctx: *anyopaque,
    active: bool = true,
};

pub const HookBus = struct {
    allocator: std.mem.Allocator,
    next_id: u32 = 1,
    subscriptions: std.ArrayListUnmanaged(Subscription) = .empty,

    pub fn init(allocator: std.mem.Allocator) HookBus {
        return .{
            .allocator = allocator,
            .next_id = 1,
            .subscriptions = .empty,
        };
    }

    pub fn deinit(self: *HookBus) void {
        self.subscriptions.deinit(self.allocator);
    }

    pub fn subscribe(
        self: *HookBus,
        kind: ?HookEventKind,
        callback: HookCallback,
        ctx: *anyopaque,
    ) !u32 {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        try self.subscriptions.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .callback = callback,
            .ctx = ctx,
            .active = true,
        });
        return id;
    }

    pub fn unsubscribe(self: *HookBus, id: u32) bool {
        for (self.subscriptions.items) |*sub| {
            if (sub.active and sub.id == id) {
                sub.active = false;
                return true;
            }
        }
        return false;
    }

    pub fn emit(self: *HookBus, event: *const HookEvent) void {
        const kind = std.meta.activeTag(event.*);
        for (self.subscriptions.items) |sub| {
            if (!sub.active) continue;
            if (sub.kind) |only_kind| {
                if (only_kind != kind) continue;
            }
            sub.callback(sub.ctx, event);
        }
    }
};

test "HookBus subscribe and emit all events" {
    const Ctx = struct {
        count: usize = 0,

        fn onEvent(ctx_ptr: *anyopaque, _: *const HookEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.count += 1;
        }
    };

    var bus = HookBus.init(std.testing.allocator);
    defer bus.deinit();

    var ctx = Ctx{};
    _ = try bus.subscribe(null, Ctx.onEvent, @ptrCast(&ctx));

    var evt: HookEvent = .{ .message_received = .{ .text = "hi" } };
    bus.emit(&evt);
    try std.testing.expectEqual(@as(usize, 1), ctx.count);
}

test "HookBus kind filter routes only matching events" {
    const Ctx = struct {
        count: usize = 0,

        fn onEvent(ctx_ptr: *anyopaque, _: *const HookEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.count += 1;
        }
    };

    var bus = HookBus.init(std.testing.allocator);
    defer bus.deinit();

    var ctx = Ctx{};
    _ = try bus.subscribe(.tool_loop_warning, Ctx.onEvent, @ptrCast(&ctx));

    var evt_a: HookEvent = .{ .message_received = .{ .text = "hi" } };
    bus.emit(&evt_a);
    try std.testing.expectEqual(@as(usize, 0), ctx.count);

    var evt_b: HookEvent = .{ .tool_loop_warning = .{
        .repeat_streak = 3,
        .abab_streak = 1,
        .no_progress_streak = 2,
    } };
    bus.emit(&evt_b);
    try std.testing.expectEqual(@as(usize, 1), ctx.count);
}

test "HookBus unsubscribe stops delivery" {
    const Ctx = struct {
        count: usize = 0,

        fn onEvent(ctx_ptr: *anyopaque, _: *const HookEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.count += 1;
        }
    };

    var bus = HookBus.init(std.testing.allocator);
    defer bus.deinit();

    var ctx = Ctx{};
    const sub_id = try bus.subscribe(null, Ctx.onEvent, @ptrCast(&ctx));
    try std.testing.expect(bus.unsubscribe(sub_id));
    try std.testing.expect(!bus.unsubscribe(sub_id));

    var evt: HookEvent = .{ .turn_complete = .{
        .response_len = 5,
        .used_tools = false,
    } };
    bus.emit(&evt);
    try std.testing.expectEqual(@as(usize, 0), ctx.count);
}
