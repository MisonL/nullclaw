const std = @import("std");
const builtin = @import("builtin");
const tools_mod = @import("../tools/root.zig");
const Tool = tools_mod.Tool;
const skills_mod = @import("../skills.zig");
const config_types = @import("../config_types.zig");

// ═══════════════════════════════════════════════════════════════════════════
// System Prompt Builder
// ═══════════════════════════════════════════════════════════════════════════

/// Maximum characters to include from a single workspace identity file.
const BOOTSTRAP_MAX_CHARS: usize = 20_000;

/// Context passed to prompt sections during construction.
pub const PromptContext = struct {
    workspace_dir: []const u8,
    model_name: []const u8,
    tools: []const Tool,
    skills_prompt_limits: config_types.SkillsPromptLimits = .{},
};

/// Build the full system prompt from workspace identity files, tools, and runtime context.
pub fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    ctx: PromptContext,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Identity section — inject workspace MD files
    try buildIdentitySection(allocator, w, ctx.workspace_dir);

    // Tools section
    try buildToolsSection(w, ctx.tools);

    // Safety section
    try w.writeAll("## Safety\n\n");
    try w.writeAll("- Do not exfiltrate private data.\n");
    try w.writeAll("- Do not run destructive commands without asking.\n");
    try w.writeAll("- Do not bypass oversight or approval mechanisms.\n");
    try w.writeAll("- Prefer `trash` over `rm`.\n");
    try w.writeAll("- When in doubt, ask before acting externally.\n\n");

    // Skills section
    try appendSkillsSection(allocator, w, ctx.workspace_dir, ctx.skills_prompt_limits);

    // Workspace section
    try std.fmt.format(w, "## Workspace\n\nWorking directory: `{s}`\n\n", .{ctx.workspace_dir});

    // DateTime section
    try appendDateTimeSection(w);

    // Runtime section
    const runtime_label = try runtimeOsLabel(allocator);
    defer allocator.free(runtime_label);
    try std.fmt.format(w, "## Runtime\n\nOS: {s} | Model: {s}\n\n", .{
        runtime_label,
        ctx.model_name,
    });

    return try buf.toOwnedSlice(allocator);
}

fn runtimeOsLabel(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "MSYSTEM")) |msystem| {
            defer allocator.free(msystem);
            return std.fmt.allocPrint(allocator, "windows (git-bash:{s})", .{msystem});
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => {},
            error.OutOfMemory => return err,
            else => {},
        }
    }
    return allocator.dupe(u8, @tagName(builtin.os.tag));
}

fn buildIdentitySection(
    allocator: std.mem.Allocator,
    w: anytype,
    workspace_dir: []const u8,
) !void {
    try w.writeAll("## Project Context\n\n");
    try w.writeAll("The following workspace files define your identity, behavior, and context.\n\n");

    const identity_files = [_][]const u8{
        "AGENTS.md",
        "SOUL.md",
        "TOOLS.md",
        "IDENTITY.md",
        "USER.md",
        "HEARTBEAT.md",
        "BOOTSTRAP.md",
        "MEMORY.md",
    };

    for (identity_files) |filename| {
        try injectWorkspaceFile(allocator, w, workspace_dir, filename);
    }
}

fn buildToolsSection(w: anytype, tools: []const Tool) !void {
    try w.writeAll("## Tools\n\n");
    for (tools) |t| {
        try std.fmt.format(w, "- **{s}**: {s}\n  Parameters: `{s}`\n", .{
            t.name(),
            t.description(),
            t.parametersJson(),
        });
    }
    try w.writeAll("\n");
}

/// Append available skills with progressive loading.
/// - always=true skills: full instruction text in the prompt
/// - always=false skills: XML summary only (agent must use read_file to load)
/// - unavailable skills: marked with available="false" and missing deps
fn appendSkillsSection(
    allocator: std.mem.Allocator,
    w: anytype,
    workspace_dir: []const u8,
    limits: config_types.SkillsPromptLimits,
) !void {
    const SkillSource = enum { workspace, community, other };

    const max_skills_in_prompt: usize = if (limits.max_skills_in_prompt == 0)
        std.math.maxInt(usize)
    else
        @intCast(limits.max_skills_in_prompt);
    const max_skills_prompt_chars: usize = if (limits.max_skills_prompt_chars == 0)
        std.math.maxInt(usize)
    else
        @intCast(limits.max_skills_prompt_chars);
    const max_skill_file_bytes: usize = if (limits.max_skill_file_bytes == 0)
        std.math.maxInt(usize)
    else
        @intCast(limits.max_skill_file_bytes);
    const max_candidates_per_root: usize = if (limits.max_candidates_per_root == 0)
        std.math.maxInt(usize)
    else
        @intCast(limits.max_candidates_per_root);
    const max_skills_loaded_per_source: usize = if (limits.max_skills_loaded_per_source == 0)
        std.math.maxInt(usize)
    else
        @intCast(limits.max_skills_loaded_per_source);

    const normalizePathChar = struct {
        fn run(c: u8) u8 {
            const slash = if (c == '\\') '/' else c;
            return if (builtin.os.tag == .windows) std.ascii.toLower(slash) else slash;
        }
    }.run;

    const trimPathSeps = struct {
        fn run(path: []const u8) []const u8 {
            return std.mem.trimRight(u8, path, "/\\");
        }
    }.run;

    const pathHasPrefix = struct {
        fn run(path_in: []const u8, prefix_in: []const u8, normalize: fn (u8) u8) bool {
            const path = trimPathSeps(path_in);
            const prefix = trimPathSeps(prefix_in);
            if (prefix.len == 0) return false;
            if (path.len < prefix.len) return false;
            for (prefix, 0..) |pc, i| {
                if (normalize(path[i]) != normalize(pc)) return false;
            }
            if (path.len == prefix.len) return true;
            return normalize(path[prefix.len]) == '/';
        }
    }.run;

    const detectSource = struct {
        fn run(skill: *const skills_mod.Skill, workspace: []const u8, community: ?[]const u8, normalize: fn (u8) u8) SkillSource {
            if (pathHasPrefix(skill.path, workspace, normalize)) return .workspace;
            if (community) |base| {
                if (pathHasPrefix(skill.path, base, normalize)) return .community;
            }
            return .other;
        }
    }.run;

    const writeWithinBudget = struct {
        fn run(writer: anytype, text: []const u8, used_chars: *usize, max_chars: usize, truncated_chars: *bool) !bool {
            if (text.len == 0) return true;
            if (used_chars.* >= max_chars or text.len > (max_chars - used_chars.*)) {
                truncated_chars.* = true;
                return false;
            }
            try writer.writeAll(text);
            used_chars.* += text.len;
            return true;
        }
    }.run;

    const sourceCounter = struct {
        fn get(source: SkillSource, workspace_count: *usize, community_count: *usize, other_count: *usize) *usize {
            return switch (source) {
                .workspace => workspace_count,
                .community => community_count,
                .other => other_count,
            };
        }
    }.get;

    // Two-source loading: workspace skills + ~/.nullclaw/skills/
    const home_dir: ?[]u8 = if (std.process.getEnvVarOwned(allocator, "HOME")) |h|
        h
    else |_| if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |h|
        h
    else |_|
        null;
    defer if (home_dir) |h| allocator.free(h);
    const community_base = if (home_dir) |h|
        std.fs.path.join(allocator, &.{ h, ".nullclaw", "skills" }) catch null
    else
        null;
    defer if (community_base) |cb| allocator.free(cb);

    // listSkillsMerged already calls checkRequirements on each skill.
    // The fallback listSkills path needs explicit checkRequirements calls.
    var used_merged = false;
    const skill_list = if (community_base) |cb| blk: {
        const merged = skills_mod.listSkillsMerged(allocator, cb, workspace_dir) catch
            break :blk skills_mod.listSkills(allocator, workspace_dir) catch return;
        used_merged = true;
        break :blk merged;
    } else skills_mod.listSkills(allocator, workspace_dir) catch return;
    defer skills_mod.freeSkills(allocator, skill_list);

    // checkRequirements only needed for the non-merged path
    if (!used_merged) {
        for (skill_list) |*skill| {
            skills_mod.checkRequirements(allocator, skill);
        }
    }

    if (skill_list.len == 0) return;

    std.mem.sort(skills_mod.Skill, @constCast(skill_list), {}, struct {
        fn lessThan(_: void, a: skills_mod.Skill, b: skills_mod.Skill) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    var candidates: std.ArrayListUnmanaged(*skills_mod.Skill) = .empty;
    defer candidates.deinit(allocator);
    var workspace_candidates: usize = 0;
    var community_candidates: usize = 0;
    var other_candidates: usize = 0;
    var truncated_candidates = false;

    for (skill_list) |*skill| {
        const source = detectSource(skill, workspace_dir, community_base, normalizePathChar);
        const source_candidate_count = sourceCounter(source, &workspace_candidates, &community_candidates, &other_candidates);
        if (source_candidate_count.* >= max_candidates_per_root) {
            truncated_candidates = true;
            continue;
        }
        source_candidate_count.* += 1;
        try candidates.append(allocator, skill);
    }

    if (candidates.items.len == 0) return;

    var used_chars: usize = 0;
    var used_skills: usize = 0;
    var workspace_loaded: usize = 0;
    var community_loaded: usize = 0;
    var other_loaded: usize = 0;

    var has_always = false;
    var has_summary = false;
    var truncated_by_count = false;
    var truncated_by_chars = false;
    var truncated_by_file_size = false;
    var truncated_by_source_limit = false;

    const renderSkill = struct {
        fn run(
            allocator_i: std.mem.Allocator,
            writer: anytype,
            skill: *const skills_mod.Skill,
            source: SkillSource,
            used_chars_i: *usize,
            used_skills_i: *usize,
            max_skills_i: usize,
            max_chars_i: usize,
            max_file_bytes_i: usize,
            max_per_source_i: usize,
            workspace_loaded_i: *usize,
            community_loaded_i: *usize,
            other_loaded_i: *usize,
            has_always_i: *bool,
            has_summary_i: *bool,
            truncated_count_i: *bool,
            truncated_chars_i: *bool,
            truncated_file_i: *bool,
            truncated_source_i: *bool,
        ) !void {
            if (used_skills_i.* >= max_skills_i) {
                truncated_count_i.* = true;
                return;
            }

            const loaded_counter = sourceCounter(source, workspace_loaded_i, community_loaded_i, other_loaded_i);
            if (loaded_counter.* >= max_per_source_i) {
                truncated_source_i.* = true;
                return;
            }

            var entry_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer entry_buf.deinit(allocator_i);
            const entry_w = entry_buf.writer(allocator_i);

            if (skill.always and skill.available) {
                if (!has_always_i.*) {
                    if (!try writeWithinBudget(writer, "## Skills\n\n", used_chars_i, max_chars_i, truncated_chars_i)) return;
                    has_always_i.* = true;
                }
                try std.fmt.format(entry_w, "### Skill: {s}\n\n", .{skill.name});
                if (skill.description.len > 0) {
                    try std.fmt.format(entry_w, "{s}\n\n", .{skill.description});
                }
                if (skill.instructions.len > 0) {
                    const instructions = if (skill.instructions.len > max_file_bytes_i)
                        skill.instructions[0..max_file_bytes_i]
                    else
                        skill.instructions;
                    try entry_w.writeAll(instructions);
                    try entry_w.writeAll("\n");
                    if (skill.instructions.len > max_file_bytes_i) {
                        try std.fmt.format(entry_w, "\n[skill instructions truncated at {d} bytes]\n", .{max_file_bytes_i});
                        truncated_file_i.* = true;
                    }
                    try entry_w.writeAll("\n");
                }
            } else {
                if (!has_summary_i.*) {
                    if (!try writeWithinBudget(writer, "## Available Skills\n\n", used_chars_i, max_chars_i, truncated_chars_i)) return;
                    if (!try writeWithinBudget(writer, "Use the read_file tool to load full skill instructions when needed.\n\n", used_chars_i, max_chars_i, truncated_chars_i)) return;
                    if (!try writeWithinBudget(writer, "<available_skills>\n", used_chars_i, max_chars_i, truncated_chars_i)) return;
                    has_summary_i.* = true;
                }
                if (!skill.available) {
                    try std.fmt.format(
                        entry_w,
                        "  <skill name=\"{s}\" description=\"{s}\" available=\"false\" missing=\"{s}\"/>\n",
                        .{ skill.name, skill.description, skill.missing_deps },
                    );
                } else {
                    const skill_path = if (skill.path.len > 0) skill.path else "";
                    const skill_md_path = try std.fs.path.join(allocator_i, &.{ skill_path, "SKILL.md" });
                    defer allocator_i.free(skill_md_path);
                    try std.fmt.format(
                        entry_w,
                        "  <skill name=\"{s}\" description=\"{s}\" path=\"{s}\"/>\n",
                        .{ skill.name, skill.description, skill_md_path },
                    );
                }
            }

            if (!try writeWithinBudget(writer, entry_buf.items, used_chars_i, max_chars_i, truncated_chars_i)) {
                return;
            }
            loaded_counter.* += 1;
            used_skills_i.* += 1;
        }
    }.run;

    for (candidates.items) |skill| {
        if (!(skill.always and skill.available)) continue;
        const source = detectSource(skill, workspace_dir, community_base, normalizePathChar);
        try renderSkill(
            allocator,
            w,
            skill,
            source,
            &used_chars,
            &used_skills,
            max_skills_in_prompt,
            max_skills_prompt_chars,
            max_skill_file_bytes,
            max_skills_loaded_per_source,
            &workspace_loaded,
            &community_loaded,
            &other_loaded,
            &has_always,
            &has_summary,
            &truncated_by_count,
            &truncated_by_chars,
            &truncated_by_file_size,
            &truncated_by_source_limit,
        );
        if (truncated_by_count or truncated_by_chars) break;
    }

    if (!truncated_by_count and !truncated_by_chars) {
        for (candidates.items) |skill| {
            if (skill.always and skill.available) continue;
            const source = detectSource(skill, workspace_dir, community_base, normalizePathChar);
            try renderSkill(
                allocator,
                w,
                skill,
                source,
                &used_chars,
                &used_skills,
                max_skills_in_prompt,
                max_skills_prompt_chars,
                max_skill_file_bytes,
                max_skills_loaded_per_source,
                &workspace_loaded,
                &community_loaded,
                &other_loaded,
                &has_always,
                &has_summary,
                &truncated_by_count,
                &truncated_by_chars,
                &truncated_by_file_size,
                &truncated_by_source_limit,
            );
            if (truncated_by_count or truncated_by_chars) break;
        }
    }

    if (has_summary) {
        _ = try writeWithinBudget(w, "</available_skills>\n\n", &used_chars, max_skills_prompt_chars, &truncated_by_chars);
    }

    if (truncated_by_count or truncated_by_chars or truncated_by_file_size or truncated_candidates or truncated_by_source_limit) {
        var note_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer note_buf.deinit(allocator);
        const note_w = note_buf.writer(allocator);
        try note_w.writeAll("[skills prompt truncated:");
        if (truncated_by_count) try note_w.writeAll(" max_skills_in_prompt");
        if (truncated_by_chars) try note_w.writeAll(" max_skills_prompt_chars");
        if (truncated_by_file_size) try note_w.writeAll(" max_skill_file_bytes");
        if (truncated_candidates) try note_w.writeAll(" max_candidates_per_root");
        if (truncated_by_source_limit) try note_w.writeAll(" max_skills_loaded_per_source");
        try note_w.writeAll("]\n\n");
        _ = try writeWithinBudget(w, note_buf.items, &used_chars, max_skills_prompt_chars, &truncated_by_chars);
    }
}

/// Append a human-readable UTC date/time section derived from the system clock.
fn appendDateTimeSection(w: anytype) !void {
    const timestamp = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const year = year_day.year;
    const month = @intFromEnum(month_day.month);
    const day = month_day.day_index + 1;
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();

    try std.fmt.format(w, "## Current Date & Time\n\n{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC\n\n", .{
        year, month, day, hour, minute,
    });
}

/// Read a workspace file and append it to the prompt, truncating if too large.
fn injectWorkspaceFile(
    allocator: std.mem.Allocator,
    w: anytype,
    workspace_dir: []const u8,
    filename: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ workspace_dir, filename });
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch {
        try std.fmt.format(w, "### {s}\n\n[File not found: {s}]\n\n", .{ filename, filename });
        return;
    };
    defer file.close();

    // Read up to BOOTSTRAP_MAX_CHARS + some margin
    const content = file.readToEndAlloc(allocator, BOOTSTRAP_MAX_CHARS + 1024) catch {
        try std.fmt.format(w, "### {s}\n\n[Could not read: {s}]\n\n", .{ filename, filename });
        return;
    };
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return;

    try std.fmt.format(w, "### {s}\n\n", .{filename});

    if (trimmed.len > BOOTSTRAP_MAX_CHARS) {
        try w.writeAll(trimmed[0..BOOTSTRAP_MAX_CHARS]);
        try std.fmt.format(w, "\n\n[... truncated at {d} chars -- use `read` for full file]\n\n", .{BOOTSTRAP_MAX_CHARS});
    } else {
        try w.writeAll(trimmed);
        try w.writeAll("\n\n");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "buildSystemPrompt includes core sections" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const workspace_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_dir);

    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = workspace_dir,
        .model_name = "test-model",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Project Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Safety") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Current Date & Time") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "test-model") != null);
}

test "buildSystemPrompt includes workspace dir" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/my/workspace",
        .model_name = "claude",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "/my/workspace") != null);
}

test "buildSystemPrompt runtime section reflects host os" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = "/tmp",
        .model_name = "test-model",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, @tagName(builtin.os.tag)) != null);
}

test "appendDateTimeSection outputs UTC timestamp" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try appendDateTimeSection(w);

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "## Current Date & Time") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "UTC") != null);
    // Verify the year is plausible (2025+)
    try std.testing.expect(std.mem.indexOf(u8, output, "202") != null);
}

test "appendSkillsSection with no skills produces nothing" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const workspace_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_dir);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, workspace_dir, .{});

    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "appendSkillsSection renders summary XML for always=false skill" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const base = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const skills_dir = try std.fs.path.join(allocator, &.{ base, "skills" });
    defer allocator.free(skills_dir);
    const skill_dir = try std.fs.path.join(allocator, &.{ skills_dir, "greeter" });
    defer allocator.free(skill_dir);
    const skill_json_path = try std.fs.path.join(allocator, &.{ skill_dir, "skill.json" });
    defer allocator.free(skill_json_path);

    // Setup
    std.fs.makeDirAbsolute(skills_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // always defaults to false — should render as summary XML
    {
        const f = try std.fs.createFileAbsolute(skill_json_path, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"greeter\", \"version\": \"1.0.0\", \"description\": \"Greets the user\", \"author\": \"dev\"}");
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base, .{});

    const output = buf.items;
    // Summary skills should appear as self-closing XML tags
    try std.testing.expect(std.mem.indexOf(u8, output, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name=\"greeter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "description=\"Greets the user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SKILL.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "read_file") != null);
    // Full instructions should NOT be in the output
    try std.testing.expect(std.mem.indexOf(u8, output, "## Skills") == null);
}

test "appendSkillsSection renders full instructions for always=true skill" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const base = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const skills_dir = try std.fs.path.join(allocator, &.{ base, "skills" });
    defer allocator.free(skills_dir);
    const skill_dir = try std.fs.path.join(allocator, &.{ skills_dir, "commit" });
    defer allocator.free(skill_dir);
    const skill_json_path = try std.fs.path.join(allocator, &.{ skill_dir, "skill.json" });
    defer allocator.free(skill_json_path);
    const skill_md_path = try std.fs.path.join(allocator, &.{ skill_dir, "SKILL.md" });
    defer allocator.free(skill_md_path);

    std.fs.makeDirAbsolute(skills_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // always=true skill with instructions
    {
        const f = try std.fs.createFileAbsolute(skill_json_path, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"commit\", \"description\": \"Git commit helper\", \"always\": true}");
    }
    {
        const f = try std.fs.createFileAbsolute(skill_md_path, .{});
        defer f.close();
        try f.writeAll("Always stage before committing.");
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base, .{});

    const output = buf.items;
    // Full instructions should be in the output
    try std.testing.expect(std.mem.indexOf(u8, output, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "### Skill: commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Always stage before committing.") != null);
    // Should NOT appear in summary XML
    try std.testing.expect(std.mem.indexOf(u8, output, "<available_skills>") == null);
}

test "appendSkillsSection renders mixed always=true and always=false" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const base = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const skills_dir = try std.fs.path.join(allocator, &.{ base, "skills" });
    defer allocator.free(skills_dir);
    const full_skill_dir = try std.fs.path.join(allocator, &.{ skills_dir, "full-skill" });
    defer allocator.free(full_skill_dir);
    const lazy_skill_dir = try std.fs.path.join(allocator, &.{ skills_dir, "lazy-skill" });
    defer allocator.free(lazy_skill_dir);
    const full_skill_json = try std.fs.path.join(allocator, &.{ full_skill_dir, "skill.json" });
    defer allocator.free(full_skill_json);
    const full_skill_md = try std.fs.path.join(allocator, &.{ full_skill_dir, "SKILL.md" });
    defer allocator.free(full_skill_md);
    const lazy_skill_json = try std.fs.path.join(allocator, &.{ lazy_skill_dir, "skill.json" });
    defer allocator.free(lazy_skill_json);

    std.fs.makeDirAbsolute(skills_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(full_skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(lazy_skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // always=true skill
    {
        const f = try std.fs.createFileAbsolute(full_skill_json, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"full-skill\", \"description\": \"Full loader\", \"always\": true}");
    }
    {
        const f = try std.fs.createFileAbsolute(full_skill_md, .{});
        defer f.close();
        try f.writeAll("Full instructions here.");
    }

    // always=false skill (default)
    {
        const f = try std.fs.createFileAbsolute(lazy_skill_json, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"lazy-skill\", \"description\": \"Lazy loader\"}");
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base, .{});

    const output = buf.items;
    // Full skill should be in ## Skills section
    try std.testing.expect(std.mem.indexOf(u8, output, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "### Skill: full-skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Full instructions here.") != null);
    // Lazy skill should be in <available_skills> XML
    try std.testing.expect(std.mem.indexOf(u8, output, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name=\"lazy-skill\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SKILL.md") != null);
}

test "appendSkillsSection renders unavailable skill with missing deps" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const base = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const skills_dir = try std.fs.path.join(allocator, &.{ base, "skills" });
    defer allocator.free(skills_dir);
    const skill_dir = try std.fs.path.join(allocator, &.{ skills_dir, "docker-deploy" });
    defer allocator.free(skill_dir);
    const skill_json_path = try std.fs.path.join(allocator, &.{ skill_dir, "skill.json" });
    defer allocator.free(skill_json_path);

    std.fs.makeDirAbsolute(skills_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Skill requiring nonexistent binary and env
    {
        const f = try std.fs.createFileAbsolute(skill_json_path, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"docker-deploy\", \"description\": \"Deploy with docker\", \"requires_bins\": [\"nullclaw_fake_docker_xyz\"], \"requires_env\": [\"NULLCLAW_FAKE_TOKEN_XYZ\"]}");
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base, .{});

    const output = buf.items;
    // Should render as unavailable in XML
    try std.testing.expect(std.mem.indexOf(u8, output, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name=\"docker-deploy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "available=\"false\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "missing=") != null);
    // Should NOT be in the full Skills section
    try std.testing.expect(std.mem.indexOf(u8, output, "## Skills") == null);
}

test "appendSkillsSection unavailable always=true skill renders in XML not full" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const base = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const skills_dir = try std.fs.path.join(allocator, &.{ base, "skills" });
    defer allocator.free(skills_dir);
    const skill_dir = try std.fs.path.join(allocator, &.{ skills_dir, "broken-always" });
    defer allocator.free(skill_dir);
    const skill_json_path = try std.fs.path.join(allocator, &.{ skill_dir, "skill.json" });
    defer allocator.free(skill_json_path);
    const skill_md_path = try std.fs.path.join(allocator, &.{ skill_dir, "SKILL.md" });
    defer allocator.free(skill_md_path);

    std.fs.makeDirAbsolute(skills_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // always=true but requires nonexistent binary → should be unavailable
    {
        const f = try std.fs.createFileAbsolute(skill_json_path, .{});
        defer f.close();
        try f.writeAll("{\"name\": \"broken-always\", \"description\": \"Broken always skill\", \"always\": true, \"requires_bins\": [\"nullclaw_nonexistent_xyz_aaa\"]}");
    }
    {
        const f = try std.fs.createFileAbsolute(skill_md_path, .{});
        defer f.close();
        try f.writeAll("These instructions should NOT appear in prompt.");
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base, .{});

    const output = buf.items;
    // Even though always=true, since unavailable it should render as XML summary
    try std.testing.expect(std.mem.indexOf(u8, output, "available=\"false\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name=\"broken-always\"") != null);
    // Full instructions should NOT be in the prompt
    try std.testing.expect(std.mem.indexOf(u8, output, "These instructions should NOT appear in prompt.") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "### Skill: broken-always") == null);
}

test "appendSkillsSection enforces max_skills_in_prompt with truncation note" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const base = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const skills_dir = try std.fs.path.join(allocator, &.{ base, "skills" });
    defer allocator.free(skills_dir);
    const skill_a = try std.fs.path.join(allocator, &.{ skills_dir, "a-skill" });
    defer allocator.free(skill_a);
    const skill_b = try std.fs.path.join(allocator, &.{ skills_dir, "b-skill" });
    defer allocator.free(skill_b);
    const skill_a_json = try std.fs.path.join(allocator, &.{ skill_a, "skill.json" });
    defer allocator.free(skill_a_json);
    const skill_b_json = try std.fs.path.join(allocator, &.{ skill_b, "skill.json" });
    defer allocator.free(skill_b_json);

    std.fs.makeDirAbsolute(skills_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skill_a) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skill_b) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    {
        const f = try std.fs.createFileAbsolute(skill_a_json, .{});
        defer f.close();
        try f.writeAll("{\"name\":\"a-skill\",\"description\":\"A\"}");
    }
    {
        const f = try std.fs.createFileAbsolute(skill_b_json, .{});
        defer f.close();
        try f.writeAll("{\"name\":\"b-skill\",\"description\":\"B\"}");
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base, .{
        .max_skills_in_prompt = 1,
    });

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "name=\"a-skill\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name=\"b-skill\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "max_skills_in_prompt") != null);
}

test "appendSkillsSection enforces max_skills_prompt_chars with truncation note" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const base = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const skills_dir = try std.fs.path.join(allocator, &.{ base, "skills" });
    defer allocator.free(skills_dir);
    const skill_a = try std.fs.path.join(allocator, &.{ skills_dir, "alpha" });
    defer allocator.free(skill_a);
    const skill_b = try std.fs.path.join(allocator, &.{ skills_dir, "beta" });
    defer allocator.free(skill_b);
    const skill_a_json = try std.fs.path.join(allocator, &.{ skill_a, "skill.json" });
    defer allocator.free(skill_a_json);
    const skill_b_json = try std.fs.path.join(allocator, &.{ skill_b, "skill.json" });
    defer allocator.free(skill_b_json);

    std.fs.makeDirAbsolute(skills_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skill_a) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skill_b) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    {
        const f = try std.fs.createFileAbsolute(skill_a_json, .{});
        defer f.close();
        try f.writeAll("{\"name\":\"alpha\",\"description\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}");
    }
    {
        const f = try std.fs.createFileAbsolute(skill_b_json, .{});
        defer f.close();
        try f.writeAll("{\"name\":\"beta\",\"description\":\"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\"}");
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base, .{
        .max_skills_prompt_chars = 220,
    });

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "max_skills_prompt_chars") != null);
}

test "appendSkillsSection truncates oversized always skill file content" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const base = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const skills_dir = try std.fs.path.join(allocator, &.{ base, "skills" });
    defer allocator.free(skills_dir);
    const skill_dir = try std.fs.path.join(allocator, &.{ skills_dir, "large-skill" });
    defer allocator.free(skill_dir);
    const skill_json = try std.fs.path.join(allocator, &.{ skill_dir, "skill.json" });
    defer allocator.free(skill_json);
    const skill_md = try std.fs.path.join(allocator, &.{ skill_dir, "SKILL.md" });
    defer allocator.free(skill_md);

    std.fs.makeDirAbsolute(skills_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(skill_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    {
        const f = try std.fs.createFileAbsolute(skill_json, .{});
        defer f.close();
        try f.writeAll("{\"name\":\"large-skill\",\"description\":\"Large\",\"always\":true}");
    }
    {
        const f = try std.fs.createFileAbsolute(skill_md, .{});
        defer f.close();
        try f.writeAll("0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz");
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try appendSkillsSection(allocator, w, base, .{
        .max_skill_file_bytes = 16,
    });

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "0123456789abcdef") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "qrstuvwxyz") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "max_skill_file_bytes") != null);
}

test "buildSystemPrompt datetime appears before runtime" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const workspace_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_dir);

    const prompt = try buildSystemPrompt(allocator, .{
        .workspace_dir = workspace_dir,
        .model_name = "test-model",
        .tools = &.{},
    });
    defer allocator.free(prompt);

    const dt_pos = std.mem.indexOf(u8, prompt, "## Current Date & Time") orelse return error.SectionNotFound;
    const rt_pos = std.mem.indexOf(u8, prompt, "## Runtime") orelse return error.SectionNotFound;
    try std.testing.expect(dt_pos < rt_pos);
}
