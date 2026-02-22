const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;
const loadScheduler = @import("cron_add.zig").loadScheduler;

fn parse_job_type(raw: []const u8) ?cron.JobType {
    if (std.ascii.eqlIgnoreCase(raw, "shell")) return .shell;
    if (std.ascii.eqlIgnoreCase(raw, "agent")) return .agent;
    return null;
}

fn parse_session_target(raw: []const u8) ?cron.SessionTarget {
    if (std.ascii.eqlIgnoreCase(raw, "isolated")) return .isolated;
    if (std.ascii.eqlIgnoreCase(raw, "main")) return .main;
    return null;
}

fn parse_delivery_mode(raw: []const u8) ?cron.DeliveryMode {
    if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(raw, "always")) return .always;
    if (std.ascii.eqlIgnoreCase(raw, "on_error")) return .on_error;
    if (std.ascii.eqlIgnoreCase(raw, "on_success")) return .on_success;
    return null;
}

/// CronUpdate tool — update a cron job's expression, command, or enabled state.
pub const CronUpdateTool = struct {
    const vtable = Tool.VTable{
        .execute = &vtableExecute,
        .name = &vtableName,
        .description = &vtableDesc,
        .parameters_json = &vtableParams,
    };

    pub fn tool(self: *CronUpdateTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn vtableExecute(ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult {
        const self: *CronUpdateTool = @ptrCast(@alignCast(ptr));
        return self.execute(allocator, args);
    }

    fn vtableName(_: *anyopaque) []const u8 {
        return "cron_update";
    }

    fn vtableDesc(_: *anyopaque) []const u8 {
        return "Update a cron job: expression, command, agent fields, model, and delivery settings.";
    }

    fn vtableParams(_: *anyopaque) []const u8 {
        return 
        \\{"type":"object","properties":{"job_id":{"type":"string","description":"ID of the cron job to update"},"expression":{"type":"string","description":"New cron expression"},"command":{"type":"string","description":"New command to execute"},"prompt":{"type":"string","description":"New prompt for agent jobs"},"name":{"type":"string","description":"Job display name"},"job_type":{"type":"string","enum":["shell","agent"]},"session_target":{"type":"string","enum":["isolated","main"]},"model":{"type":"string","description":"Model override for agent jobs"},"enabled":{"type":"boolean","description":"Enable or disable the job"},"delete_after_run":{"type":"boolean","description":"Delete job after first run"},"delivery":{"type":"object","properties":{"mode":{"type":"string","enum":["none","always","on_error","on_success"]},"channel":{"type":"string","description":"Empty string clears channel"},"to":{"type":"string","description":"Empty string clears target chat"},"best_effort":{"type":"boolean"}}}},"required":["job_id"]}
        ;
    }

    fn execute(_: *CronUpdateTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const job_id = root.getString(args, "job_id") orelse
            return ToolResult.fail("Missing 'job_id' parameter");

        const expression = root.getString(args, "expression");
        const command = root.getString(args, "command");
        const prompt = root.getString(args, "prompt");
        const name = root.getString(args, "name");
        const model = root.getString(args, "model");
        const enabled = root.getBool(args, "enabled");
        const delete_after_run = root.getBool(args, "delete_after_run");
        const job_type = if (root.getString(args, "job_type")) |raw|
            parse_job_type(raw) orelse return ToolResult.fail("Invalid 'job_type'. Use 'shell' or 'agent'")
        else
            null;
        const session_target = if (root.getString(args, "session_target")) |raw|
            parse_session_target(raw) orelse return ToolResult.fail("Invalid 'session_target'. Use 'isolated' or 'main'")
        else
            null;

        var delivery_patch: ?cron.DeliveryPatch = null;
        if (root.getValue(args, "delivery")) |delivery_val| {
            if (delivery_val != .object) return ToolResult.fail("'delivery' must be an object");

            var patch = cron.DeliveryPatch{};
            var it = delivery_val.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                if (std.mem.eql(u8, key, "mode")) {
                    const raw_mode = switch (val) {
                        .string => |s| s,
                        else => return ToolResult.fail("'delivery.mode' must be a string"),
                    };
                    patch.mode = parse_delivery_mode(raw_mode) orelse
                        return ToolResult.fail("Invalid 'delivery.mode'");
                } else if (std.mem.eql(u8, key, "channel")) {
                    const raw_channel = switch (val) {
                        .string => |s| s,
                        else => return ToolResult.fail("'delivery.channel' must be a string"),
                    };
                    if (raw_channel.len == 0) {
                        patch.clear_channel = true;
                    } else {
                        patch.channel = raw_channel;
                    }
                } else if (std.mem.eql(u8, key, "to")) {
                    const raw_to = switch (val) {
                        .string => |s| s,
                        else => return ToolResult.fail("'delivery.to' must be a string"),
                    };
                    if (raw_to.len == 0) {
                        patch.clear_to = true;
                    } else {
                        patch.to = raw_to;
                    }
                } else if (std.mem.eql(u8, key, "best_effort")) {
                    patch.best_effort = switch (val) {
                        .bool => |b| b,
                        else => return ToolResult.fail("'delivery.best_effort' must be a boolean"),
                    };
                }
            }
            delivery_patch = patch;
        }

        // Validate that at least one field is being updated
        if (expression == null and command == null and prompt == null and name == null and job_type == null and session_target == null and model == null and enabled == null and delete_after_run == null and delivery_patch == null)
            return ToolResult.fail("Nothing to update — provide one or more fields");

        // Validate expression if provided
        if (expression) |expr| {
            _ = cron.normalizeExpression(expr) catch
                return ToolResult.fail("Invalid cron expression");
        }

        var scheduler = loadScheduler(allocator) catch {
            return ToolResult.fail("Failed to load scheduler state");
        };
        defer scheduler.deinit();

        const patch = cron.CronJobPatch{
            .expression = expression,
            .command = command,
            .prompt = prompt,
            .name = name,
            .job_type = job_type,
            .session_target = session_target,
            .delivery = delivery_patch,
            .enabled = enabled,
            .model = model,
            .delete_after_run = delete_after_run,
        };

        const updated = scheduler.updateJob(job_id, patch) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to update job: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        if (!updated) {
            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{job_id});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        cron.saveJobs(&scheduler) catch {};

        // Build summary of what changed
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        try w.print("Updated job {s}", .{job_id});
        if (expression) |expr| try w.print(" | expression={s}", .{expr});
        if (command) |cmd| try w.print(" | command={s}", .{cmd});
        if (prompt) |p| try w.print(" | prompt={s}", .{p});
        if (name) |n| try w.print(" | name={s}", .{n});
        if (job_type) |jt| try w.print(" | job_type={s}", .{jt.asStr()});
        if (session_target) |target| try w.print(" | session_target={s}", .{target.asStr()});
        if (model) |m| try w.print(" | model={s}", .{m});
        if (enabled) |ena| try w.print(" | enabled={s}", .{if (ena) "true" else "false"});
        if (delete_after_run) |d| try w.print(" | delete_after_run={s}", .{if (d) "true" else "false"});
        if (delivery_patch) |dp| {
            if (dp.mode) |mode| try w.print(" | delivery.mode={s}", .{mode.asStr()});
            if (dp.channel) |channel| try w.print(" | delivery.channel={s}", .{channel});
            if (dp.clear_channel) try w.print(" | delivery.channel=<cleared>", .{});
            if (dp.to) |to| try w.print(" | delivery.to={s}", .{to});
            if (dp.clear_to) try w.print(" | delivery.to=<cleared>", .{});
            if (dp.best_effort) |be| try w.print(" | delivery.best_effort={s}", .{if (be) "true" else "false"});
        }

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "cron_update tool name" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    try std.testing.expectEqualStrings("cron_update", t.name());
}

test "cron_update schema has job_id" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "job_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "job_type") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "session_target") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "delivery") != null);
}

test "cron_update_requires_job_id" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_id") != null);
}

test "cron_update_requires_something" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"job-1\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Nothing to update") != null);
}

test "cron_update_expression" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    // First create a job via CronScheduler so there's something to update
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();
    const job = try scheduler.addJob("*/5 * * * *", "echo test");
    cron.saveJobs(&scheduler) catch {};

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"job_id\": \"{s}\", \"expression\": \"*/10 * * * *\"}}", .{job.id});
    defer std.testing.allocator.free(args);
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Updated job") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "expression") != null);
    }
}

test "cron_update_disable" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();
    const job = try scheduler.addJob("*/5 * * * *", "echo test");
    cron.saveJobs(&scheduler) catch {};

    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"job_id\": \"{s}\", \"enabled\": false}}", .{job.id});
    defer std.testing.allocator.free(args);
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Updated job") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "enabled=false") != null);
    }
}

test "cron_update_not_found" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"nonexistent-999\", \"command\": \"echo new\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
}

test "cron_update_invalid_expression" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"job-1\", \"expression\": \"bad\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid cron expression") != null);
}

test "cron_update_invalid_job_type" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"job-1\", \"job_type\": \"bad\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_type") != null);
}

test "cron_update_invalid_delivery_mode" {
    var ct = CronUpdateTool{};
    const t = ct.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"job-1\", \"delivery\": {\"mode\": \"broken\"}}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "delivery.mode") != null);
}
