const std = @import("std");
const dispatcher = @import("dispatcher.zig");
const ParsedToolCall = dispatcher.ParsedToolCall;

pub const LoopThresholds = struct {
    signature_window: usize = 30,
    warn_repeat_streak: u32 = 3,
    warn_abab_streak: u32 = 2,
    warn_no_progress_streak: u32 = 3,
    critical_repeat_streak: u32 = 6,
    critical_abab_streak: u32 = 3,
    critical_no_progress_streak: u32 = 6,
};

pub const ToolLoopState = enum {
    normal,
    warning,
    critical,
};

pub const ToolLoopDetector = struct {
    allocator: std.mem.Allocator,
    thresholds: LoopThresholds,

    signature_history: std.ArrayListUnmanaged(u64) = .empty,
    repeated_signature_streak: u32 = 0,
    abab_streak: u32 = 0,
    no_progress_streak: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, thresholds: LoopThresholds) ToolLoopDetector {
        return .{
            .allocator = allocator,
            .thresholds = thresholds,
        };
    }

    pub fn deinit(self: *ToolLoopDetector) void {
        self.signature_history.deinit(self.allocator);
    }

    pub fn reset(self: *ToolLoopDetector) void {
        self.signature_history.clearRetainingCapacity();
        self.repeated_signature_streak = 0;
        self.abab_streak = 0;
        self.no_progress_streak = 0;
    }

    pub fn hashParsedToolCalls(calls: []const ParsedToolCall) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (calls) |call| {
            hasher.update(call.name);
            hasher.update(&[_]u8{0x1f});
            hasher.update(call.arguments_json);
            hasher.update(&[_]u8{0x1e});
            if (call.tool_call_id) |id| hasher.update(id);
            hasher.update(&[_]u8{0x1d});
        }
        return hasher.final();
    }

    fn isAbabToolPattern(signatures: []const u64) bool {
        if (signatures.len < 4) return false;
        const a = signatures[signatures.len - 4];
        const b = signatures[signatures.len - 3];
        const c = signatures[signatures.len - 2];
        const d = signatures[signatures.len - 1];
        return a == c and b == d and a != b;
    }

    pub fn recordTurn(self: *ToolLoopDetector, calls: []const ParsedToolCall, has_progress: bool) !ToolLoopState {
        if (calls.len == 0) {
            self.reset();
            return .normal;
        }

        const signature = hashParsedToolCalls(calls);
        try self.signature_history.append(self.allocator, signature);

        if (self.signature_history.items.len > self.thresholds.signature_window) {
            const tail = self.signature_history.items[1..];
            std.mem.copyForwards(u64, self.signature_history.items[0..tail.len], tail);
            self.signature_history.items.len -= 1;
        }

        const history_len = self.signature_history.items.len;
        if (history_len >= 2 and
            self.signature_history.items[history_len - 1] == self.signature_history.items[history_len - 2])
        {
            self.repeated_signature_streak += 1;
        } else {
            self.repeated_signature_streak = 1;
        }

        if (isAbabToolPattern(self.signature_history.items)) {
            self.abab_streak += 1;
        } else {
            self.abab_streak = 0;
        }

        if (!has_progress) {
            self.no_progress_streak += 1;
        } else {
            self.no_progress_streak = 0;
        }

        const loop_critical = self.repeated_signature_streak >= self.thresholds.critical_repeat_streak or
            self.abab_streak >= self.thresholds.critical_abab_streak or
            self.no_progress_streak >= self.thresholds.critical_no_progress_streak;

        const loop_warning = self.repeated_signature_streak >= self.thresholds.warn_repeat_streak or
            self.abab_streak >= self.thresholds.warn_abab_streak or
            self.no_progress_streak >= self.thresholds.warn_no_progress_streak;

        if (loop_critical) {
            return .critical;
        } else if (loop_warning) {
            return .warning;
        }
        return .normal;
    }
};

test "hashParsedToolCalls stable for same input" {
    const calls_a = [_]ParsedToolCall{
        .{ .name = "shell", .arguments_json = "{\"command\":\"ls\"}", .tool_call_id = "tc1" },
        .{ .name = "file_read", .arguments_json = "{\"path\":\"a.txt\"}", .tool_call_id = "tc2" },
    };
    const calls_b = [_]ParsedToolCall{
        .{ .name = "shell", .arguments_json = "{\"command\":\"ls\"}", .tool_call_id = "tc1" },
        .{ .name = "file_read", .arguments_json = "{\"path\":\"a.txt\"}", .tool_call_id = "tc2" },
    };
    const calls_c = [_]ParsedToolCall{
        .{ .name = "shell", .arguments_json = "{\"command\":\"pwd\"}", .tool_call_id = "tc1" },
        .{ .name = "file_read", .arguments_json = "{\"path\":\"a.txt\"}", .tool_call_id = "tc2" },
    };

    const h1 = ToolLoopDetector.hashParsedToolCalls(&calls_a);
    const h2 = ToolLoopDetector.hashParsedToolCalls(&calls_b);
    const h3 = ToolLoopDetector.hashParsedToolCalls(&calls_c);

    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}

test "isAbabToolPattern detects alternating signature loop" {
    const sigs_true = [_]u64{ 11, 22, 11, 22 };
    const sigs_false_same = [_]u64{ 11, 11, 11, 11 };
    const sigs_false_short = [_]u64{ 11, 22, 11 };
    const sigs_false_diff = [_]u64{ 11, 22, 33, 22 };

    try std.testing.expect(ToolLoopDetector.isAbabToolPattern(&sigs_true));
    try std.testing.expect(!ToolLoopDetector.isAbabToolPattern(&sigs_false_same));
    try std.testing.expect(!ToolLoopDetector.isAbabToolPattern(&sigs_false_short));
    try std.testing.expect(!ToolLoopDetector.isAbabToolPattern(&sigs_false_diff));
}

test "recordTurn enters warning and critical on repeated loops" {
    var detector = ToolLoopDetector.init(std.testing.allocator, .{
        .warn_repeat_streak = 2,
        .critical_repeat_streak = 3,
        .warn_abab_streak = 99,
        .critical_abab_streak = 99,
        .warn_no_progress_streak = 99,
        .critical_no_progress_streak = 99,
    });
    defer detector.deinit();

    const calls = [_]ParsedToolCall{
        .{ .name = "shell", .arguments_json = "{\"command\":\"ls\"}" },
    };

    try std.testing.expectEqual(ToolLoopState.normal, try detector.recordTurn(&calls, false));
    try std.testing.expectEqual(ToolLoopState.warning, try detector.recordTurn(&calls, false));
    try std.testing.expectEqual(ToolLoopState.critical, try detector.recordTurn(&calls, false));
}

test "recordTurn clears state when no tool calls provided" {
    var detector = ToolLoopDetector.init(std.testing.allocator, .{
        .warn_repeat_streak = 2,
        .critical_repeat_streak = 4,
    });
    defer detector.deinit();

    const calls = [_]ParsedToolCall{
        .{ .name = "shell", .arguments_json = "{\"command\":\"ls\"}" },
    };

    _ = try detector.recordTurn(&calls, false);
    _ = try detector.recordTurn(&calls, false);
    try std.testing.expect(detector.repeated_signature_streak >= 2);
    try std.testing.expect(detector.signature_history.items.len > 0);

    try std.testing.expectEqual(ToolLoopState.normal, try detector.recordTurn(&.{}, true));
    try std.testing.expectEqual(@as(u32, 0), detector.repeated_signature_streak);
    try std.testing.expectEqual(@as(u32, 0), detector.abab_streak);
    try std.testing.expectEqual(@as(u32, 0), detector.no_progress_streak);
    try std.testing.expectEqual(@as(usize, 0), detector.signature_history.items.len);
}
