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

fn apply_extended_fields(
    scheduler: *CronScheduler,
    job: *cron.CronJob,
    job_type: cron.JobType,
    session_target: cron.SessionTarget,
    prompt: ?[]const u8,
    name: ?[]const u8,
    model: ?[]const u8,
    delivery: cron.DeliveryConfig,
) !void {
    const allocator = scheduler.allocator;
    job.job_type = job_type;
    job.session_target = session_target;
    job.created_at_s = std.time.timestamp();

    if (prompt) |p| {
        if (job.prompt) |old| allocator.free(old);
        job.prompt = try allocator.dupe(u8, p);
    }
    if (name) |n| {
        if (job.name) |old| allocator.free(old);
        job.name = try allocator.dupe(u8, n);
    }
    if (model) |m| {
        if (job.model) |old| allocator.free(old);
        job.model = try allocator.dupe(u8, m);
    }

    job.delivery.mode = delivery.mode;
    if (job.delivery.channel) |old| allocator.free(old);
    job.delivery.channel = if (delivery.channel) |ch| try allocator.dupe(u8, ch) else null;
    if (job.delivery.to) |old| allocator.free(old);
    job.delivery.to = if (delivery.to) |to| try allocator.dupe(u8, to) else null;
    job.delivery.best_effort = delivery.best_effort;
}

/// Schedule tool — lets the agent manage recurring and one-shot scheduled tasks.
/// Delegates to the CronScheduler from the cron module for persistent job management.
pub const ScheduleTool = struct {
    const vtable = Tool.VTable{
        .execute = &vtableExecute,
        .name = &vtableName,
        .description = &vtableDesc,
        .parameters_json = &vtableParams,
    };

    pub fn tool(self: *ScheduleTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn vtableExecute(ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult {
        const self: *ScheduleTool = @ptrCast(@alignCast(ptr));
        return self.execute(allocator, args);
    }

    fn vtableName(_: *anyopaque) []const u8 {
        return "schedule";
    }

    fn vtableDesc(_: *anyopaque) []const u8 {
        return "Manage scheduled tasks. Actions: create/add/once/update/list/get/cancel/remove/pause/resume. Supports agent fields and delivery.";
    }

    fn vtableParams(_: *anyopaque) []const u8 {
        return 
        \\{"type":"object","properties":{"action":{"type":"string","enum":["create","add","once","update","list","get","cancel","remove","pause","resume"],"description":"Action to perform"},"id":{"type":"string","description":"Task ID for get/update/cancel/remove/pause/resume"},"job_id":{"type":"string","description":"Alias for id in id-based actions"},"expression":{"type":"string","description":"Cron expression for recurring tasks"},"delay":{"type":"string","description":"Delay for one-shot tasks (e.g. '30m', '2h')"},"command":{"type":"string","description":"Command for shell jobs; optional fallback text for agent jobs"},"prompt":{"type":"string","description":"Prompt for agent jobs"},"name":{"type":"string","description":"Optional job name"},"job_type":{"type":"string","enum":["shell","agent"]},"session_target":{"type":"string","enum":["isolated","main"]},"model":{"type":"string","description":"Model override for agent jobs"},"enabled":{"type":"boolean","description":"Enable or disable a job (update)"},"delete_after_run":{"type":"boolean","description":"Delete after execution (update)"},"delivery":{"type":"object","properties":{"mode":{"type":"string","enum":["none","always","on_error","on_success"]},"channel":{"type":"string","description":"Empty string clears channel on update"},"to":{"type":"string","description":"Empty string clears target chat on update"},"best_effort":{"type":"boolean"}}}},"required":["action"]}
        ;
    }

    fn execute(_: *ScheduleTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action' parameter");

        if (std.mem.eql(u8, action, "list")) {
            var scheduler = loadScheduler(allocator) catch {
                return ToolResult.ok("No scheduled jobs.");
            };
            defer scheduler.deinit();

            const jobs = scheduler.listJobs();
            if (jobs.len == 0) {
                return ToolResult.ok("No scheduled jobs.");
            }

            // Format job list
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            const w = buf.writer(allocator);
            try w.print("Scheduled jobs ({d}):\n", .{jobs.len});
            for (jobs) |job| {
                const flags: []const u8 = blk: {
                    if (job.paused and job.one_shot) break :blk " [paused, one-shot]";
                    if (job.paused) break :blk " [paused]";
                    if (job.one_shot) break :blk " [one-shot]";
                    break :blk "";
                };
                const status = job.last_status orelse "pending";
                try w.print("- {s} | {s} | type={s} target={s} | status={s}{s} | cmd: {s}\n", .{
                    job.id,
                    job.expression,
                    job.job_type.asStr(),
                    job.session_target.asStr(),
                    status,
                    flags,
                    job.command,
                });
            }
            return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
        }

        if (std.mem.eql(u8, action, "get")) {
            const id = root.getString(args, "id") orelse root.getString(args, "job_id") orelse
                return ToolResult.fail("Missing 'id' parameter for get action");

            var scheduler = loadScheduler(allocator) catch {
                const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{id});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            defer scheduler.deinit();

            if (scheduler.getJob(id)) |job| {
                const flags: []const u8 = blk: {
                    if (job.paused and job.one_shot) break :blk " [paused, one-shot]";
                    if (job.paused) break :blk " [paused]";
                    if (job.one_shot) break :blk " [one-shot]";
                    break :blk "";
                };
                const status = job.last_status orelse "pending";
                const msg = try std.fmt.allocPrint(allocator, "Job {s} | {s} | type={s} target={s} | next={d} | status={s}{s}\n  cmd: {s}\n  prompt: {s}\n  model: {s}\n  delivery: mode={s} channel={s} to={s} best_effort={s}", .{
                    job.id,
                    job.expression,
                    job.job_type.asStr(),
                    job.session_target.asStr(),
                    job.next_run_secs,
                    status,
                    flags,
                    job.command,
                    job.prompt orelse "<none>",
                    job.model orelse "<none>",
                    job.delivery.mode.asStr(),
                    job.delivery.channel orelse "<none>",
                    job.delivery.to orelse "<none>",
                    if (job.delivery.best_effort) "true" else "false",
                });
                return ToolResult{ .success = true, .output = msg };
            }
            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{id});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        if (std.mem.eql(u8, action, "create") or std.mem.eql(u8, action, "add")) {
            const expression = root.getString(args, "expression") orelse
                return ToolResult.fail("Missing 'expression' parameter for cron job");
            const prompt = root.getString(args, "prompt");
            const name = root.getString(args, "name");
            const model = root.getString(args, "model");
            const command_input = root.getString(args, "command");

            const job_type = if (root.getString(args, "job_type")) |raw|
                parse_job_type(raw) orelse return ToolResult.fail("Invalid 'job_type'. Use 'shell' or 'agent'")
            else
                cron.JobType.shell;

            const session_target = if (root.getString(args, "session_target")) |raw|
                parse_session_target(raw) orelse return ToolResult.fail("Invalid 'session_target'. Use 'isolated' or 'main'")
            else
                cron.SessionTarget.isolated;

            const command = blk: {
                if (command_input) |cmd| break :blk cmd;
                if (job_type == .agent) {
                    if (prompt) |p| break :blk p;
                }
                return ToolResult.fail("Missing 'command' parameter");
            };

            var delivery = cron.DeliveryConfig{};
            if (root.getValue(args, "delivery")) |delivery_val| {
                if (delivery_val != .object) return ToolResult.fail("'delivery' must be an object");

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

            var scheduler = loadScheduler(allocator) catch {
                return ToolResult.fail("Failed to load scheduler state");
            };
            defer scheduler.deinit();

            const job = scheduler.addJob(expression, command) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create job: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            apply_extended_fields(&scheduler, job, job_type, session_target, prompt, name, model, delivery) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to apply extended fields: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            cron.saveJobs(&scheduler) catch {};

            const msg = try std.fmt.allocPrint(allocator, "Created job {s} | {s} | type={s} target={s} | cmd: {s}", .{
                job.id,
                job.expression,
                job.job_type.asStr(),
                job.session_target.asStr(),
                job.command,
            });
            return ToolResult{ .success = true, .output = msg };
        }

        if (std.mem.eql(u8, action, "once")) {
            const delay = root.getString(args, "delay") orelse
                return ToolResult.fail("Missing 'delay' parameter for one-shot task");
            const prompt = root.getString(args, "prompt");
            const name = root.getString(args, "name");
            const model = root.getString(args, "model");
            const command_input = root.getString(args, "command");

            const job_type = if (root.getString(args, "job_type")) |raw|
                parse_job_type(raw) orelse return ToolResult.fail("Invalid 'job_type'. Use 'shell' or 'agent'")
            else
                cron.JobType.shell;

            const session_target = if (root.getString(args, "session_target")) |raw|
                parse_session_target(raw) orelse return ToolResult.fail("Invalid 'session_target'. Use 'isolated' or 'main'")
            else
                cron.SessionTarget.isolated;

            const command = blk: {
                if (command_input) |cmd| break :blk cmd;
                if (job_type == .agent) {
                    if (prompt) |p| break :blk p;
                }
                return ToolResult.fail("Missing 'command' parameter");
            };

            var delivery = cron.DeliveryConfig{};
            if (root.getValue(args, "delivery")) |delivery_val| {
                if (delivery_val != .object) return ToolResult.fail("'delivery' must be an object");

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

            var scheduler = loadScheduler(allocator) catch {
                return ToolResult.fail("Failed to load scheduler state");
            };
            defer scheduler.deinit();

            const job = scheduler.addOnce(delay, command) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create one-shot task: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            apply_extended_fields(&scheduler, job, job_type, session_target, prompt, name, model, delivery) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to apply extended fields: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            cron.saveJobs(&scheduler) catch {};

            const msg = try std.fmt.allocPrint(allocator, "Created one-shot task {s} | type={s} target={s} | runs at {d} | cmd: {s}", .{
                job.id,
                job.job_type.asStr(),
                job.session_target.asStr(),
                job.next_run_secs,
                job.command,
            });
            return ToolResult{ .success = true, .output = msg };
        }

        if (std.mem.eql(u8, action, "update")) {
            const id = root.getString(args, "id") orelse root.getString(args, "job_id") orelse
                return ToolResult.fail("Missing 'id' (or 'job_id') parameter for update action");

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

            if (expression == null and command == null and prompt == null and name == null and model == null and enabled == null and delete_after_run == null and job_type == null and session_target == null and delivery_patch == null)
                return ToolResult.fail("Nothing to update — provide one or more fields");

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
            const updated = scheduler.updateJob(id, patch) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to update job: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            if (!updated) {
                const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{id});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            }

            cron.saveJobs(&scheduler) catch {};

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            const w = buf.writer(allocator);
            try w.print("Updated job {s}", .{id});
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

        if (std.mem.eql(u8, action, "cancel") or std.mem.eql(u8, action, "remove")) {
            const id = root.getString(args, "id") orelse root.getString(args, "job_id") orelse
                return ToolResult.fail("Missing 'id' parameter for cancel action");

            var scheduler = loadScheduler(allocator) catch {
                return ToolResult.fail("Failed to load scheduler state");
            };
            defer scheduler.deinit();

            if (scheduler.removeJob(id)) {
                cron.saveJobs(&scheduler) catch {};
                const msg = try std.fmt.allocPrint(allocator, "Cancelled job {s}", .{id});
                return ToolResult{ .success = true, .output = msg };
            }
            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{id});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        if (std.mem.eql(u8, action, "pause") or std.mem.eql(u8, action, "resume")) {
            const id = root.getString(args, "id") orelse root.getString(args, "job_id") orelse
                return ToolResult.fail("Missing 'id' parameter");

            var scheduler = loadScheduler(allocator) catch {
                return ToolResult.fail("Failed to load scheduler state");
            };
            defer scheduler.deinit();

            const is_pause = std.mem.eql(u8, action, "pause");
            const found = if (is_pause) scheduler.pauseJob(id) else scheduler.resumeJob(id);

            if (found) {
                cron.saveJobs(&scheduler) catch {};
                const verb: []const u8 = if (is_pause) "Paused" else "Resumed";
                const msg = try std.fmt.allocPrint(allocator, "{s} job {s}", .{ verb, id });
                return ToolResult{ .success = true, .output = msg };
            }
            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{id});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        const msg = try std.fmt.allocPrint(allocator, "Unknown action '{s}'", .{action});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "schedule tool name" {
    var st = ScheduleTool{};
    const t = st.tool();
    try std.testing.expectEqualStrings("schedule", t.name());
}

test "schedule schema has action" {
    var st = ScheduleTool{};
    const t = st.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "action") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"update\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "job_type") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "session_target") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "delivery") != null);
}

test "schedule list returns success" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"list\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    // Either "No scheduled jobs." or a formatted job list
    try std.testing.expect(result.output.len > 0);
}

test "schedule unknown action" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"explode\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unknown action") != null);
}

test "schedule create with expression" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"create\", \"expression\": \"*/5 * * * *\", \"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    // Succeeds if HOME/.nullclaw is writable, otherwise may fail gracefully
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Created job") != null);
    }
}

test "schedule create rejects invalid job_type" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"create\", \"expression\": \"*/5 * * * *\", \"command\": \"echo hello\", \"job_type\": \"bad\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_type") != null);
}

test "schedule create rejects invalid delivery mode" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"create\", \"expression\": \"*/5 * * * *\", \"command\": \"echo hello\", \"delivery\": {\"mode\": \"broken\"}}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "delivery.mode") != null);
}

test "schedule create supports agent fields" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs(
        \\{
        \\  "action": "create",
        \\  "expression": "*/30 * * * *",
        \\  "job_type": "agent",
        \\  "session_target": "main",
        \\  "prompt": "Summarize today",
        \\  "name": "agent-via-schedule",
        \\  "model": "qwen3-max",
        \\  "delivery": { "mode": "always", "channel": "telegram", "to": "chat99", "best_effort": false }
        \\}
    );
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "type=agent") != null);
    }
}

// ── Additional schedule tests ───────────────────────────────────

test "schedule missing action" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "action") != null);
}

test "schedule get missing id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"get\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "id") != null);
}

test "schedule get nonexistent job" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"get\", \"id\": \"nonexistent-123\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
}

test "schedule get accepts job_id alias" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"get\", \"job_id\": \"alias-nonexistent-123\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Missing 'id'") == null);
}

test "schedule cancel requires id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"cancel\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "schedule cancel nonexistent job returns not found" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"cancel\", \"id\": \"job-nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    // Job doesn't exist in the real scheduler, so cancel returns not-found or success if previously created
    if (!result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
    }
}

test "schedule cancel accepts job_id alias" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"cancel\", \"job_id\": \"alias-job-nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    if (!result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Missing 'id'") == null);
    }
}

test "schedule remove nonexistent job returns not found" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"remove\", \"id\": \"job-nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    if (!result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
    }
}

test "schedule pause nonexistent job returns not found" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"pause\", \"id\": \"job-nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    if (!result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
    }
}

test "schedule resume nonexistent job returns not found" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"resume\", \"id\": \"job-nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    if (!result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
    }
}

test "schedule pause accepts job_id alias" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"pause\", \"job_id\": \"alias-pause-nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    if (!result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Missing 'id'") == null);
    }
}

test "schedule once creates one-shot task" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"once\", \"delay\": \"30m\", \"command\": \"echo later\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "one-shot") != null);
    }
}

test "schedule add creates recurring job" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"add\", \"expression\": \"0 * * * *\", \"command\": \"echo hourly\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Created job") != null);
    }
}

test "schedule create missing command" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"create\", \"expression\": \"* * * * *\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "command") != null);
}

test "schedule create missing expression" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"create\", \"command\": \"echo hi\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "expression") != null);
}

test "schedule update requires id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"update\", \"enabled\": true}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "id") != null);
}

test "schedule update requires at least one field" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"update\", \"id\": \"job-1\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Nothing to update") != null);
}

test "schedule update rejects invalid job_type" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"update\", \"id\": \"job-1\", \"job_type\": \"bad\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_type") != null);
}

test "schedule update rejects invalid delivery mode" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"update\", \"id\": \"job-1\", \"delivery\": {\"mode\": \"broken\"}}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "delivery.mode") != null);
}

test "schedule once missing delay" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"once\", \"command\": \"echo hi\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "delay") != null);
}

test "schedule pause requires id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"pause\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "schedule resume requires id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"resume\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}
