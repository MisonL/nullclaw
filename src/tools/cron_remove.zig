const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;
const loadScheduler = @import("cron_add.zig").loadScheduler;

/// CronRemove tool — removes a scheduled cron job by its ID.
pub const CronRemoveTool = struct {
    const vtable = Tool.VTable{
        .execute = &vtableExecute,
        .name = &vtableName,
        .description = &vtableDesc,
        .parameters_json = &vtableParams,
    };

    pub fn tool(self: *CronRemoveTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn vtableExecute(ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult {
        const self: *CronRemoveTool = @ptrCast(@alignCast(ptr));
        return self.execute(allocator, args);
    }

    fn vtableName(_: *anyopaque) []const u8 {
        return "cron_remove";
    }

    fn vtableDesc(_: *anyopaque) []const u8 {
        return "Remove a scheduled cron job by its ID.";
    }

    fn vtableParams(_: *anyopaque) []const u8 {
        return 
        \\{"type":"object","properties":{"job_id":{"type":"string","description":"ID of the cron job to remove"}},"required":["job_id"]}
        ;
    }

    fn execute(_: *CronRemoveTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const job_id = root.getString(args, "job_id") orelse
            return ToolResult.fail("Missing required parameter: job_id");

        if (job_id.len == 0)
            return ToolResult.fail("Missing required parameter: job_id");

        var scheduler = loadScheduler(allocator) catch {
            return ToolResult.fail("Failed to load scheduler state");
        };
        defer scheduler.deinit();

        if (scheduler.removeJob(job_id)) {
            cron.saveJobs(&scheduler) catch {};
            const msg = try std.fmt.allocPrint(allocator, "Removed cron job {s}", .{job_id});
            return ToolResult{ .success = true, .output = msg };
        }

        const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{job_id});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "cron_remove_requires_job_id" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try tool_iface.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_id") != null);
}

test "cron_remove_not_found" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"nonexistent-999\"}");
    defer parsed.deinit();
    const result = try tool_iface.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
}

test "cron_remove_success" {
    // First, create a job via the scheduler directly
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();
    const job = try scheduler.addJob("*/5 * * * *", "echo test");
    const job_id = try std.testing.allocator.dupe(u8, job.id);
    defer std.testing.allocator.free(job_id);
    cron.saveJobs(&scheduler) catch {};

    // Now remove it via the tool
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"job_id\": \"{s}\"}}", .{job_id});
    defer std.testing.allocator.free(args);
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();
    const result = try tool_iface.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Removed") != null);
}

test "cron_remove tool name" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    try std.testing.expectEqualStrings("cron_remove", tool_iface.name());
}

test "cron_remove schema has job_id" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const schema = tool_iface.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "job_id") != null);
}

test "cron_remove empty job_id" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"\"}");
    defer parsed.deinit();
    const result = try tool_iface.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_id") != null);
}
