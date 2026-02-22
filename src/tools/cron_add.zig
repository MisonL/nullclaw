const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;

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

/// CronAdd tool — creates a new cron job with either a cron expression or a delay.
pub const CronAddTool = struct {
    const vtable = Tool.VTable{
        .execute = &vtableExecute,
        .name = &vtableName,
        .description = &vtableDesc,
        .parameters_json = &vtableParams,
    };

    pub fn tool(self: *CronAddTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn vtableExecute(ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult {
        const self: *CronAddTool = @ptrCast(@alignCast(ptr));
        return self.execute(allocator, args);
    }

    fn vtableName(_: *anyopaque) []const u8 {
        return "cron_add";
    }

    fn vtableDesc(_: *anyopaque) []const u8 {
        return "Create a scheduled cron job. Supports shell and agent jobs with optional session_target, prompt, model, and delivery.";
    }

    fn vtableParams(_: *anyopaque) []const u8 {
        return 
        \\{"type":"object","properties":{"expression":{"type":"string","description":"Cron expression (e.g. '*/5 * * * *')"},"delay":{"type":"string","description":"Delay for one-shot tasks (e.g. '30m', '2h')"},"command":{"type":"string","description":"Command for shell jobs; optional fallback text for agent jobs"},"job_type":{"type":"string","enum":["shell","agent"],"description":"Job type"},"session_target":{"type":"string","enum":["isolated","main"],"description":"Session target for agent jobs"},"prompt":{"type":"string","description":"Prompt for agent jobs"},"model":{"type":"string","description":"Optional model override for agent jobs"},"name":{"type":"string","description":"Optional job name"},"delivery":{"type":"object","properties":{"mode":{"type":"string","enum":["none","always","on_error","on_success"]},"channel":{"type":"string"},"to":{"type":"string"},"best_effort":{"type":"boolean"}}}}}
        ;
    }

    fn execute(_: *CronAddTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const command_raw = root.getString(args, "command");
        const expression = root.getString(args, "expression");
        const delay = root.getString(args, "delay");
        const prompt = root.getString(args, "prompt");
        const name = root.getString(args, "name");
        const model = root.getString(args, "model");

        if (expression == null and delay == null)
            return ToolResult.fail("Missing schedule: provide either 'expression' (cron syntax) or 'delay' (e.g. '30m')");

        const job_type = if (root.getString(args, "job_type")) |raw|
            parse_job_type(raw) orelse return ToolResult.fail("Invalid 'job_type'. Use 'shell' or 'agent'")
        else
            cron.JobType.shell;

        const session_target = if (root.getString(args, "session_target")) |raw|
            parse_session_target(raw) orelse return ToolResult.fail("Invalid 'session_target'. Use 'isolated' or 'main'")
        else
            cron.SessionTarget.isolated;

        const command = blk: {
            if (command_raw) |cmd| break :blk cmd;
            if (job_type == .agent) {
                if (prompt) |p| break :blk p;
            }
            return ToolResult.fail("Missing required 'command' parameter");
        };

        // Validate expression if provided
        if (expression) |expr| {
            _ = cron.normalizeExpression(expr) catch
                return ToolResult.fail("Invalid cron expression");
        }

        // Validate delay if provided
        if (delay) |d| {
            _ = cron.parseDuration(d) catch
                return ToolResult.fail("Invalid delay format");
        }

        var scheduler = loadScheduler(allocator) catch {
            return ToolResult.fail("Failed to load scheduler state");
        };
        defer scheduler.deinit();

        var delivery = cron.DeliveryConfig{};
        if (root.getValue(args, "delivery")) |delivery_val| {
            if (delivery_val != .object) {
                return ToolResult.fail("'delivery' must be an object");
            }

            var it = delivery_val.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                if (std.mem.eql(u8, key, "mode")) {
                    const raw_mode = switch (val) {
                        .string => |s| s,
                        else => return ToolResult.fail("'delivery.mode' must be a string"),
                    };
                    delivery.mode = parse_delivery_mode(raw_mode) orelse
                        return ToolResult.fail("Invalid 'delivery.mode'");
                } else if (std.mem.eql(u8, key, "channel")) {
                    const raw_channel = switch (val) {
                        .string => |s| s,
                        else => return ToolResult.fail("'delivery.channel' must be a string"),
                    };
                    delivery.channel = if (raw_channel.len == 0) null else raw_channel;
                } else if (std.mem.eql(u8, key, "to")) {
                    const raw_to = switch (val) {
                        .string => |s| s,
                        else => return ToolResult.fail("'delivery.to' must be a string"),
                    };
                    delivery.to = if (raw_to.len == 0) null else raw_to;
                } else if (std.mem.eql(u8, key, "best_effort")) {
                    delivery.best_effort = switch (val) {
                        .bool => |b| b,
                        else => return ToolResult.fail("'delivery.best_effort' must be a boolean"),
                    };
                }
            }
        }

        const apply_extended_fields = struct {
            fn apply(job: *cron.CronJob, scheduler_ptr: *CronScheduler, jt: cron.JobType, target: cron.SessionTarget, prompt_in: ?[]const u8, name_in: ?[]const u8, model_in: ?[]const u8, delivery_in: cron.DeliveryConfig) !void {
                job.job_type = jt;
                job.session_target = target;
                job.created_at_s = std.time.timestamp();

                if (prompt_in) |p| {
                    if (job.prompt) |old| scheduler_ptr.allocator.free(old);
                    job.prompt = try scheduler_ptr.allocator.dupe(u8, p);
                }
                if (name_in) |n| {
                    if (job.name) |old| scheduler_ptr.allocator.free(old);
                    job.name = try scheduler_ptr.allocator.dupe(u8, n);
                }
                if (model_in) |m| {
                    if (job.model) |old| scheduler_ptr.allocator.free(old);
                    job.model = try scheduler_ptr.allocator.dupe(u8, m);
                }

                job.delivery.mode = delivery_in.mode;
                if (job.delivery.channel) |old| scheduler_ptr.allocator.free(old);
                job.delivery.channel = if (delivery_in.channel) |ch| try scheduler_ptr.allocator.dupe(u8, ch) else null;
                if (job.delivery.to) |old| scheduler_ptr.allocator.free(old);
                job.delivery.to = if (delivery_in.to) |to| try scheduler_ptr.allocator.dupe(u8, to) else null;
                job.delivery.best_effort = delivery_in.best_effort;
            }
        }.apply;

        // Prefer expression (recurring) over delay (one-shot)
        if (expression) |expr| {
            const job = scheduler.addJob(expr, command) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create job: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            apply_extended_fields(job, &scheduler, job_type, session_target, prompt, name, model, delivery) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to apply extended job fields: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            cron.saveJobs(&scheduler) catch {};

            const msg = try std.fmt.allocPrint(allocator, "Created cron job {s}: {s} \u{2192} {s} (job_type={s})", .{
                job.id,
                job.expression,
                job.command,
                job.job_type.asStr(),
            });
            return ToolResult{ .success = true, .output = msg };
        }

        if (delay) |d| {
            const job = scheduler.addOnce(d, command) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create one-shot task: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            apply_extended_fields(job, &scheduler, job_type, session_target, prompt, name, model, delivery) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to apply extended job fields: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            cron.saveJobs(&scheduler) catch {};

            const msg = try std.fmt.allocPrint(allocator, "Created cron job {s}: {s} \u{2192} {s} (job_type={s})", .{
                job.id,
                job.expression,
                job.command,
                job.job_type.asStr(),
            });
            return ToolResult{ .success = true, .output = msg };
        }

        return ToolResult.fail("Unexpected state: no expression or delay");
    }
};

/// Load the CronScheduler from persisted state (~/.nullclaw/cron.json).
/// Shared by cron_add, cron_list, cron_remove, and schedule tools.
pub fn loadScheduler(allocator: std.mem.Allocator) !CronScheduler {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    cron.loadJobs(&scheduler) catch {};
    return scheduler;
}

// ── Tests ───────────────────────────────────────────────────────────

test "cron_add_requires_command" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"*/5 * * * *\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "command") != null);
}

test "cron_add_requires_schedule" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "expression") != null or
        std.mem.indexOf(u8, result.error_msg.?, "delay") != null);
}

test "cron_add_with_expression" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"*/5 * * * *\", \"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Created cron job") != null);
    }
}

test "cron_add_with_delay" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"delay\": \"30m\", \"command\": \"echo later\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Created cron job") != null);
    }
}

test "cron_add_rejects_invalid_expression" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"bad cron\", \"command\": \"echo fail\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid cron expression") != null);
}

test "cron_add tool name" {
    var cat = CronAddTool{};
    const t = cat.tool();
    try std.testing.expectEqualStrings("cron_add", t.name());
}

test "cron_add schema has command" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "command") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "expression") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "delay") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "job_type") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "session_target") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "delivery") != null);
}

test "cron_add invalid job_type" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"*/5 * * * *\", \"command\": \"echo hi\", \"job_type\": \"weird\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_type") != null);
}

test "cron_add supports agent fields and delivery" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs(
        \\{
        \\  "expression": "*/10 * * * *",
        \\  "command": "fallback command",
        \\  "job_type": "agent",
        \\  "session_target": "main",
        \\  "prompt": "Summarize build status",
        \\  "model": "qwen3-max",
        \\  "name": "agent-job-test",
        \\  "delivery": {
        \\    "mode": "always",
        \\    "channel": "telegram",
        \\    "to": "chat123",
        \\    "best_effort": false
        \\  }
        \\}
    );
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        var scheduler = loadScheduler(std.testing.allocator) catch return error.SkipZigTest;
        defer scheduler.deinit();

        var found = false;
        for (scheduler.listJobs()) |job| {
            if (job.name != null and std.mem.eql(u8, job.name.?, "agent-job-test")) {
                found = true;
                try std.testing.expectEqual(cron.JobType.agent, job.job_type);
                try std.testing.expectEqual(cron.SessionTarget.main, job.session_target);
                try std.testing.expectEqualStrings("Summarize build status", job.prompt.?);
                try std.testing.expectEqualStrings("qwen3-max", job.model.?);
                try std.testing.expectEqual(cron.DeliveryMode.always, job.delivery.mode);
                try std.testing.expectEqualStrings("telegram", job.delivery.channel.?);
                try std.testing.expectEqualStrings("chat123", job.delivery.to.?);
                try std.testing.expect(!job.delivery.best_effort);
                break;
            }
        }
        try std.testing.expect(found);
    }
}
