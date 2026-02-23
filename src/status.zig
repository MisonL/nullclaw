const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").Config;
const locale = @import("locale.zig");

const version = "0.1.1";

fn enabled_disabled(v: bool, zh: bool) []const u8 {
    if (zh) return if (v) "已启用" else "已禁用";
    return if (v) "enabled" else "disabled";
}

fn on_off(v: bool, zh: bool) []const u8 {
    if (zh) return if (v) "开" else "关";
    return if (v) "on" else "off";
}

fn yes_no(v: bool, zh: bool) []const u8 {
    if (zh) return if (v) "是" else "否";
    return if (v) "yes" else "no";
}

fn configured(v: bool, zh: bool) []const u8 {
    if (zh) return if (v) "已配置" else "未配置";
    return if (v) "configured" else "not configured";
}

fn readEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        error.OutOfMemory => null,
        else => null,
    };
}

fn hostOsLabel() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "windows",
        .macos => "macos",
        .linux => "linux",
        else => @tagName(builtin.os.tag),
    };
}

const DaemonFeedbackSnapshot = struct {
    found: bool = false,
    turn_complete: u64 = 0,
    model_fallback: u64 = 0,
    tool_loop_warning: u64 = 0,
    tool_loop_breaker: u64 = 0,
    turn_complete_recent_5m: u64 = 0,
    model_fallback_recent_5m: u64 = 0,
    tool_loop_warning_recent_5m: u64 = 0,
    tool_loop_breaker_recent_5m: u64 = 0,
    last_critical_event_unix: i64 = 0,
};

fn loadDaemonFeedback(allocator: std.mem.Allocator, cfg: *const Config) DaemonFeedbackSnapshot {
    const cfg_dir = std.fs.path.dirname(cfg.config_path) orelse return .{};
    const state_path = std.fs.path.join(allocator, &.{ cfg_dir, "daemon_state.json" }) catch return .{};
    defer allocator.free(state_path);

    const content = std.fs.openFileAbsolute(state_path, .{}) catch return .{};
    defer content.close();

    const bytes = content.readToEndAlloc(allocator, 1024 * 256) catch return .{};
    defer allocator.free(bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const feedback_val = parsed.value.object.get("feedback") orelse return .{};
    if (feedback_val != .object) return .{};

    var snap = DaemonFeedbackSnapshot{ .found = true };
    if (feedback_val.object.get("turn_complete")) |v| {
        if (v == .integer) snap.turn_complete = @intCast(v.integer);
    }
    if (feedback_val.object.get("model_fallback")) |v| {
        if (v == .integer) snap.model_fallback = @intCast(v.integer);
    }
    if (feedback_val.object.get("tool_loop_warning")) |v| {
        if (v == .integer) snap.tool_loop_warning = @intCast(v.integer);
    }
    if (feedback_val.object.get("tool_loop_breaker")) |v| {
        if (v == .integer) snap.tool_loop_breaker = @intCast(v.integer);
    }
    if (feedback_val.object.get("recent_5m")) |recent_val| {
        if (recent_val == .object) {
            if (recent_val.object.get("turn_complete")) |v| {
                if (v == .integer) snap.turn_complete_recent_5m = @intCast(v.integer);
            }
            if (recent_val.object.get("model_fallback")) |v| {
                if (v == .integer) snap.model_fallback_recent_5m = @intCast(v.integer);
            }
            if (recent_val.object.get("tool_loop_warning")) |v| {
                if (v == .integer) snap.tool_loop_warning_recent_5m = @intCast(v.integer);
            }
            if (recent_val.object.get("tool_loop_breaker")) |v| {
                if (v == .integer) snap.tool_loop_breaker_recent_5m = @intCast(v.integer);
            }
        }
    }
    if (feedback_val.object.get("last_critical_event_unix")) |v| {
        if (v == .integer) snap.last_critical_event_unix = @intCast(v.integer);
    }
    return snap;
}

fn detectShellLabel(allocator: std.mem.Allocator, zh: bool) ![]u8 {
    if (readEnvOwned(allocator, "MSYSTEM")) |msystem| {
        defer allocator.free(msystem);
        return std.fmt.allocPrint(allocator, "Git Bash ({s})", .{msystem});
    }

    if (builtin.os.tag == .windows) {
        if (readEnvOwned(allocator, "WT_SESSION")) |wt| {
            defer allocator.free(wt);
            return allocator.dupe(u8, "Windows Terminal");
        }
    }

    if (readEnvOwned(allocator, "TERM_PROGRAM")) |term_program| {
        defer allocator.free(term_program);
        return std.fmt.allocPrint(allocator, "{s}", .{term_program});
    }

    if (readEnvOwned(allocator, "SHELL")) |shell| {
        defer allocator.free(shell);
        return std.fmt.allocPrint(allocator, "{s}", .{shell});
    }

    if (readEnvOwned(allocator, "ComSpec")) |comspec| {
        defer allocator.free(comspec);
        return std.fmt.allocPrint(allocator, "{s}", .{comspec});
    }

    return allocator.dupe(u8, if (zh) "未知" else "unknown");
}

pub fn run(allocator: std.mem.Allocator) !void {
    const zh = locale.detect_ui_language() == .zh_cn;
    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    const w = &bw.interface;
    const shell_label = try detectShellLabel(allocator, zh);
    defer allocator.free(shell_label);
    const host_os = hostOsLabel();

    var cfg = Config.load(allocator) catch {
        try w.writeAll(if (zh) "nullclaw 状态（未找到配置，请先运行 `nullclaw onboard`）\n" else "nullclaw Status (no config found -- run `nullclaw onboard` first)\n");
        if (zh) {
            try w.print("\n版本: {s}\n", .{version});
        } else {
            try w.print("\nVersion: {s}\n", .{version});
        }
        try w.flush();
        return;
    };
    defer cfg.deinit();

    try w.writeAll(if (zh) "nullclaw 状态\n\n" else "nullclaw Status\n\n");
    if (zh) {
        try w.print("版本:        {s}\n", .{version});
        try w.print("工作目录:    {s}\n", .{cfg.workspace_dir});
        try w.print("配置文件:    {s}\n", .{cfg.config_path});
    } else {
        try w.print("Version:     {s}\n", .{version});
        try w.print("Workspace:   {s}\n", .{cfg.workspace_dir});
        try w.print("Config:      {s}\n", .{cfg.config_path});
    }
    try w.print("\n", .{});
    if (zh) {
        try w.print("提供商:      {s}\n", .{cfg.default_provider});
        try w.print("模型:        {s}\n", .{cfg.default_model orelse "(default)"});
        try w.print("温度:        {d:.1}\n", .{cfg.temperature});
    } else {
        try w.print("Provider:    {s}\n", .{cfg.default_provider});
        try w.print("Model:       {s}\n", .{cfg.default_model orelse "(default)"});
        try w.print("Temperature: {d:.1}\n", .{cfg.temperature});
    }
    try w.print("\n", .{});
    if (zh) {
        try w.print("记忆:        {s} (自动保存: {s})\n", .{
            cfg.memory_backend,
            on_off(cfg.memory_auto_save, zh),
        });
        try w.print("心跳:        {s}\n", .{
            enabled_disabled(cfg.heartbeat_enabled, zh),
        });
        try w.print("安全:        workspace_only={s}, 每小时最多操作={d}\n", .{
            yes_no(cfg.workspace_only, zh),
            cfg.max_actions_per_hour,
        });
    } else {
        try w.print("Memory:      {s} (auto-save: {s})\n", .{
            cfg.memory_backend,
            on_off(cfg.memory_auto_save, zh),
        });
        try w.print("Heartbeat:   {s}\n", .{
            enabled_disabled(cfg.heartbeat_enabled, zh),
        });
        try w.print("Security:    workspace_only={s}, max_actions/hr={d}\n", .{
            yes_no(cfg.workspace_only, zh),
            cfg.max_actions_per_hour,
        });
    }
    try w.print("\n", .{});

    // Diagnostics
    if (zh) {
        try w.print("诊断:          {s}\n", .{cfg.diagnostics.backend});
    } else {
        try w.print("Diagnostics:   {s}\n", .{cfg.diagnostics.backend});
    }

    // Runtime
    if (zh) {
        try w.print("运行时:      {s}\n", .{cfg.runtime.kind});
        try w.print("主机系统:    {s}\n", .{host_os});
        try w.print("终端壳:      {s}\n", .{shell_label});
    } else {
        try w.print("Runtime:     {s}\n", .{cfg.runtime.kind});
        try w.print("Host OS:     {s}\n", .{host_os});
        try w.print("Shell:       {s}\n", .{shell_label});
    }

    // Gateway
    if (zh) {
        try w.print("网关:        {s}:{d}\n", .{ cfg.gateway_host, cfg.gateway_port });
    } else {
        try w.print("Gateway:     {s}:{d}\n", .{ cfg.gateway_host, cfg.gateway_port });
    }

    // Scheduler
    if (zh) {
        try w.print("调度器:      {s} (max_tasks={d}, max_concurrent={d})\n", .{
            enabled_disabled(cfg.scheduler.enabled, zh),
            cfg.scheduler.max_tasks,
            cfg.scheduler.max_concurrent,
        });
    } else {
        try w.print("Scheduler:   {s} (max_tasks={d}, max_concurrent={d})\n", .{
            enabled_disabled(cfg.scheduler.enabled, zh),
            cfg.scheduler.max_tasks,
            cfg.scheduler.max_concurrent,
        });
    }

    // Cost tracking
    if (zh) {
        try w.print("成本:        {s}\n", .{if (cfg.cost.enabled) "追踪已启用" else "已禁用"});
    } else {
        try w.print("Cost:        {s}\n", .{if (cfg.cost.enabled) "tracking enabled" else "disabled"});
    }

    // Hardware
    if (zh) {
        try w.print("硬件:        {s}\n", .{enabled_disabled(cfg.hardware.enabled, zh)});
    } else {
        try w.print("Hardware:    {s}\n", .{enabled_disabled(cfg.hardware.enabled, zh)});
    }

    // Peripherals
    if (zh) {
        try w.print("外设:        {s}（{d} 块板卡）\n", .{
            enabled_disabled(cfg.peripherals.enabled, zh),
            cfg.peripherals.boards.len,
        });
    } else {
        try w.print("Peripherals: {s} ({d} boards)\n", .{
            enabled_disabled(cfg.peripherals.enabled, zh),
            cfg.peripherals.boards.len,
        });
    }

    // Sandbox
    if (zh) {
        try w.print("沙箱:        {s}\n", .{enabled_disabled(cfg.security.sandbox.enabled orelse false, zh)});
    } else {
        try w.print("Sandbox:     {s}\n", .{enabled_disabled(cfg.security.sandbox.enabled orelse false, zh)});
    }

    // Audit
    if (zh) {
        try w.print("审计:        {s}\n", .{enabled_disabled(cfg.security.audit.enabled, zh)});
    } else {
        try w.print("Audit:       {s}\n", .{enabled_disabled(cfg.security.audit.enabled, zh)});
    }

    const daemon_feedback = loadDaemonFeedback(allocator, &cfg);
    if (daemon_feedback.found) {
        if (zh) {
            try w.print(
                "守护反馈(累计): turn_complete={d}, model_fallback={d}, tool_loop_warning={d}, tool_loop_breaker={d}\n",
                .{
                    daemon_feedback.turn_complete,
                    daemon_feedback.model_fallback,
                    daemon_feedback.tool_loop_warning,
                    daemon_feedback.tool_loop_breaker,
                },
            );
            try w.print(
                "守护反馈(近5分钟): turn_complete={d}, model_fallback={d}, tool_loop_warning={d}, tool_loop_breaker={d}\n",
                .{
                    daemon_feedback.turn_complete_recent_5m,
                    daemon_feedback.model_fallback_recent_5m,
                    daemon_feedback.tool_loop_warning_recent_5m,
                    daemon_feedback.tool_loop_breaker_recent_5m,
                },
            );
            if (daemon_feedback.last_critical_event_unix > 0) {
                try w.print("最近关键事件(Unix): {d}\n", .{daemon_feedback.last_critical_event_unix});
            }
        } else {
            try w.print(
                "Daemon feedback (total): turn_complete={d}, model_fallback={d}, tool_loop_warning={d}, tool_loop_breaker={d}\n",
                .{
                    daemon_feedback.turn_complete,
                    daemon_feedback.model_fallback,
                    daemon_feedback.tool_loop_warning,
                    daemon_feedback.tool_loop_breaker,
                },
            );
            try w.print(
                "Daemon feedback (last 5m): turn_complete={d}, model_fallback={d}, tool_loop_warning={d}, tool_loop_breaker={d}\n",
                .{
                    daemon_feedback.turn_complete_recent_5m,
                    daemon_feedback.model_fallback_recent_5m,
                    daemon_feedback.tool_loop_warning_recent_5m,
                    daemon_feedback.tool_loop_breaker_recent_5m,
                },
            );
            if (daemon_feedback.last_critical_event_unix > 0) {
                try w.print("Last critical event (unix): {d}\n", .{daemon_feedback.last_critical_event_unix});
            }
        }
    }

    try w.print("\n", .{});

    // Channels
    if (zh) {
        try w.writeAll("频道:\n");
        try w.writeAll("  CLI:       始终启用\n");
    } else {
        try w.writeAll("Channels:\n");
        try w.writeAll("  CLI:       always\n");
    }
    try w.print("  Telegram:  {s}\n", .{configured(cfg.channels.telegram != null, zh)});
    try w.print("  Discord:   {s}\n", .{configured(cfg.channels.discord != null, zh)});
    try w.print("  Slack:     {s}\n", .{configured(cfg.channels.slack != null, zh)});
    try w.print("  Webhook:   {s}\n", .{configured(cfg.channels.webhook != null, zh)});
    try w.print("  Matrix:    {s}\n", .{configured(cfg.channels.matrix != null, zh)});
    try w.print("  IRC:       {s}\n", .{configured(cfg.channels.irc != null, zh)});

    try w.flush();
}
