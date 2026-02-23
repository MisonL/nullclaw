const std = @import("std");
const builtin = @import("builtin");
const yc = @import("nullclaw");

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;
    std.fs.File.stderr().writeAll("panic: ") catch {};
    std.fs.File.stderr().writeAll(msg) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
    std.process.exit(1);
}

const log = std.log.scoped(.main);

const Command = enum {
    agent,
    gateway,
    daemon,
    service,
    status,
    onboard,
    doctor,
    cron,
    channel,
    skills,
    hardware,
    migrate,
    models,
    mcp,
    help,
};

fn is_zh_ui() bool {
    return yc.locale.detect_ui_language() == .zh_cn;
}

fn print_no_config_and_exit() noreturn {
    if (is_zh_ui()) {
        std.debug.print("未找到配置，请先运行 `nullclaw onboard`\n", .{});
    } else {
        std.debug.print("No config found -- run `nullclaw onboard` first\n", .{});
    }
    std.process.exit(1);
}

fn enabled_disabled_word(v: bool, zh: bool) []const u8 {
    if (zh) return if (v) "已启用" else "已禁用";
    return if (v) "enabled" else "disabled";
}

fn configured_word(v: bool, zh: bool) []const u8 {
    if (zh) return if (v) "已配置" else "未配置";
    return if (v) "configured" else "not configured";
}

fn print_invalid_port_and_exit(port_arg: []const u8) noreturn {
    if (is_zh_ui()) {
        std.debug.print("无效端口: {s}\n", .{port_arg});
    } else {
        std.debug.print("Invalid port: {s}\n", .{port_arg});
    }
    std.process.exit(1);
}

fn parseCommand(arg: []const u8) ?Command {
    const command_map = std.StaticStringMap(Command).initComptime(.{
        .{ "agent", .agent },
        .{ "gateway", .gateway },
        .{ "daemon", .daemon },
        .{ "service", .service },
        .{ "status", .status },
        .{ "onboard", .onboard },
        .{ "doctor", .doctor },
        .{ "cron", .cron },
        .{ "channel", .channel },
        .{ "skills", .skills },
        .{ "hardware", .hardware },
        .{ "migrate", .migrate },
        .{ "models", .models },
        .{ "mcp", .mcp },
        .{ "help", .help },
        .{ "--help", .help },
        .{ "-h", .help },
    });
    return command_map.get(arg);
}

fn force_windows_console_utf8() void {
    if (builtin.os.tag != .windows) return;
    const windows = std.os.windows;
    _ = windows.kernel32.SetConsoleOutputCP(65001);
}

pub fn main() !void {
    force_windows_console_utf8();

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = parseCommand(args[1]) orelse {
        if (is_zh_ui()) {
            std.debug.print("未知命令: {s}\n\n", .{args[1]});
        } else {
            std.debug.print("Unknown command: {s}\n\n", .{args[1]});
        }
        printUsage();
        std.process.exit(1);
    };

    const sub_args = args[2..];

    switch (cmd) {
        .status => try yc.status.run(allocator),
        .agent => try yc.agent.run(allocator, sub_args),
        .onboard => try runOnboard(allocator, sub_args),
        .doctor => try yc.doctor.run(allocator),
        .help => printUsage(),
        .gateway => try runGateway(allocator, sub_args),
        .daemon => try runDaemon(allocator, sub_args),
        .service => try runService(allocator, sub_args),
        .cron => try runCron(allocator, sub_args),
        .channel => try runChannel(allocator, sub_args),
        .skills => try runSkills(allocator, sub_args),
        .hardware => try runHardware(allocator, sub_args),
        .migrate => try runMigrate(allocator, sub_args),
        .models => try runModels(allocator, sub_args),
        .mcp => try runMcp(allocator, sub_args),
    }
}

// ── Gateway ──────────────────────────────────────────────────────

fn runGateway(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    var cfg = yc.config.Config.load(allocator) catch {
        print_no_config_and_exit();
    };
    defer cfg.deinit();

    // Config values are the baseline; CLI flags override them.
    var port: u16 = cfg.gateway.port;
    var host: []const u8 = cfg.gateway.host;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        if ((std.mem.eql(u8, sub_args[i], "--port") or std.mem.eql(u8, sub_args[i], "-p")) and i + 1 < sub_args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, sub_args[i], 10) catch {
                print_invalid_port_and_exit(sub_args[i]);
            };
        } else if (std.mem.eql(u8, sub_args[i], "--host") and i + 1 < sub_args.len) {
            i += 1;
            host = sub_args[i];
        }
    }

    try yc.gateway.run(allocator, host, port);
}

// ── Daemon ───────────────────────────────────────────────────────

fn runDaemon(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    var cfg = yc.config.Config.load(allocator) catch {
        print_no_config_and_exit();
    };
    defer cfg.deinit();

    // Config values are the baseline; CLI flags override them.
    var port: u16 = cfg.gateway.port;
    var host: []const u8 = cfg.gateway.host;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        if ((std.mem.eql(u8, sub_args[i], "--port") or std.mem.eql(u8, sub_args[i], "-p")) and i + 1 < sub_args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, sub_args[i], 10) catch {
                print_invalid_port_and_exit(sub_args[i]);
            };
        } else if (std.mem.eql(u8, sub_args[i], "--host") and i + 1 < sub_args.len) {
            i += 1;
            host = sub_args[i];
        }
    }

    try yc.daemon.run(allocator, &cfg, host, port);
}

// ── MCP Server ───────────────────────────────────────────────────

fn runMcp(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    const zh = is_zh_ui();
    if (sub_args.len < 1 or !std.mem.eql(u8, sub_args[0], "serve")) {
        if (zh) {
            std.debug.print("用法: nullclaw mcp serve\n", .{});
        } else {
            std.debug.print("Usage: nullclaw mcp serve\n", .{});
        }
        std.process.exit(1);
    }

    var cfg = yc.config.Config.load(allocator) catch {
        print_no_config_and_exit();
    };
    defer cfg.deinit();

    yc.mcp_server.serve(allocator, &cfg, null) catch |err| {
        if (err == error.McpServerDisabled) {
            if (zh) {
                std.debug.print("MCP server 已禁用，请在配置中设置 `mcp.enabled=true`。\n", .{});
            } else {
                std.debug.print("MCP server is disabled. Set `mcp.enabled=true` in config.\n", .{});
            }
            std.process.exit(1);
        }
        return err;
    };
}

// ── Service ──────────────────────────────────────────────────────

fn runService(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    const zh = is_zh_ui();
    if (sub_args.len < 1) {
        if (zh) {
            std.debug.print("用法: nullclaw service <install|start|stop|status|uninstall>\n", .{});
        } else {
            std.debug.print("Usage: nullclaw service <install|start|stop|status|uninstall>\n", .{});
        }
        std.process.exit(1);
    }

    const subcmd = sub_args[0];
    const service_cmd: yc.service.ServiceCommand = blk: {
        const map = .{
            .{ "install", yc.service.ServiceCommand.install },
            .{ "start", yc.service.ServiceCommand.start },
            .{ "stop", yc.service.ServiceCommand.stop },
            .{ "status", yc.service.ServiceCommand.status },
            .{ "uninstall", yc.service.ServiceCommand.uninstall },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, subcmd, entry[0])) break :blk entry[1];
        }
        if (zh) {
            std.debug.print("未知 service 子命令: {s}\n", .{subcmd});
            std.debug.print("用法: nullclaw service <install|start|stop|status|uninstall>\n", .{});
        } else {
            std.debug.print("Unknown service command: {s}\n", .{subcmd});
            std.debug.print("Usage: nullclaw service <install|start|stop|status|uninstall>\n", .{});
        }
        std.process.exit(1);
    };

    var cfg = yc.config.Config.load(allocator) catch {
        print_no_config_and_exit();
    };
    defer cfg.deinit();

    yc.service.handleCommand(allocator, service_cmd, cfg.config_path) catch |err| {
        if (err == error.UnsupportedPlatform) {
            if (zh) {
                std.debug.print("当前平台不支持 service 命令。\n", .{});
            } else {
                std.debug.print("Service command is not supported on this platform.\n", .{});
            }
        } else {
            if (zh) {
                std.debug.print("服务命令失败: {s}\n", .{@errorName(err)});
            } else {
                std.debug.print("Service command failed: {s}\n", .{@errorName(err)});
            }
        }
        std.process.exit(1);
    };
}

// ── Cron ─────────────────────────────────────────────────────────

fn runCron(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    const zh = is_zh_ui();
    if (sub_args.len < 1) {
        if (zh) {
            std.debug.print(
                \\用法: nullclaw cron <command> [args]
                \\
                \\命令:
                \\  list                          列出全部定时任务
                \\  add <expression> <command>    添加周期任务
                \\  once <delay> <command>        添加一次性延迟任务
                \\  remove <id>                   删除定时任务
                \\  pause <id>                    暂停定时任务
                \\  resume <id>                   恢复已暂停任务
                \\  run <id>                      立即执行指定任务
                \\  update <id> [options]         更新任务配置
                \\  runs <id>                     查看任务执行历史
                \\
            , .{});
        } else {
            std.debug.print(
                \\Usage: nullclaw cron <command> [args]
                \\
                \\Commands:
                \\  list                          List all scheduled tasks
                \\  add <expression> <command>    Add a recurring cron job
                \\  once <delay> <command>        Add a one-shot delayed task
                \\  remove <id>                   Remove a scheduled task
                \\  pause <id>                    Pause a scheduled task
                \\  resume <id>                   Resume a paused task
                \\  run <id>                      Run a scheduled task immediately
                \\  update <id> [options]         Update a cron job
                \\  runs <id>                     List recent run history for a job
                \\
            , .{});
        }
        std.process.exit(1);
    }

    const subcmd = sub_args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        try yc.cron.cliListJobs(allocator);
    } else if (std.mem.eql(u8, subcmd, "add")) {
        if (sub_args.len < 3) {
            if (zh) std.debug.print("用法: nullclaw cron add <expression> <command>\n", .{}) else std.debug.print("Usage: nullclaw cron add <expression> <command>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliAddJob(allocator, sub_args[1], sub_args[2]);
    } else if (std.mem.eql(u8, subcmd, "once")) {
        if (sub_args.len < 3) {
            if (zh) std.debug.print("用法: nullclaw cron once <delay> <command>\n", .{}) else std.debug.print("Usage: nullclaw cron once <delay> <command>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliAddOnce(allocator, sub_args[1], sub_args[2]);
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        if (sub_args.len < 2) {
            if (zh) std.debug.print("用法: nullclaw cron remove <id>\n", .{}) else std.debug.print("Usage: nullclaw cron remove <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliRemoveJob(allocator, sub_args[1]);
    } else if (std.mem.eql(u8, subcmd, "pause")) {
        if (sub_args.len < 2) {
            if (zh) std.debug.print("用法: nullclaw cron pause <id>\n", .{}) else std.debug.print("Usage: nullclaw cron pause <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliPauseJob(allocator, sub_args[1]);
    } else if (std.mem.eql(u8, subcmd, "resume")) {
        if (sub_args.len < 2) {
            if (zh) std.debug.print("用法: nullclaw cron resume <id>\n", .{}) else std.debug.print("Usage: nullclaw cron resume <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliResumeJob(allocator, sub_args[1]);
    } else if (std.mem.eql(u8, subcmd, "run")) {
        if (sub_args.len < 2) {
            if (zh) std.debug.print("用法: nullclaw cron run <id>\n", .{}) else std.debug.print("Usage: nullclaw cron run <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliRunJob(allocator, sub_args[1]);
    } else if (std.mem.eql(u8, subcmd, "update")) {
        if (sub_args.len < 2) {
            if (zh) std.debug.print("用法: nullclaw cron update <id> [--expression <expr>] [--command <cmd>] [--enable] [--disable]\n", .{}) else std.debug.print("Usage: nullclaw cron update <id> [--expression <expr>] [--command <cmd>] [--enable] [--disable]\n", .{});
            std.process.exit(1);
        }
        const id = sub_args[1];
        var expression: ?[]const u8 = null;
        var command: ?[]const u8 = null;
        var enabled: ?bool = null;
        var i: usize = 2;
        while (i < sub_args.len) : (i += 1) {
            if (std.mem.eql(u8, sub_args[i], "--expression") and i + 1 < sub_args.len) {
                i += 1;
                expression = sub_args[i];
            } else if (std.mem.eql(u8, sub_args[i], "--command") and i + 1 < sub_args.len) {
                i += 1;
                command = sub_args[i];
            } else if (std.mem.eql(u8, sub_args[i], "--enable")) {
                enabled = true;
            } else if (std.mem.eql(u8, sub_args[i], "--disable")) {
                enabled = false;
            }
        }
        try yc.cron.cliUpdateJob(allocator, id, expression, command, enabled);
    } else if (std.mem.eql(u8, subcmd, "runs")) {
        if (sub_args.len < 2) {
            if (zh) std.debug.print("用法: nullclaw cron runs <id>\n", .{}) else std.debug.print("Usage: nullclaw cron runs <id>\n", .{});
            std.process.exit(1);
        }
        try yc.cron.cliListRuns(allocator, sub_args[1]);
    } else {
        if (zh) {
            std.debug.print("未知 cron 子命令: {s}\n", .{subcmd});
        } else {
            std.debug.print("Unknown cron command: {s}\n", .{subcmd});
        }
        std.process.exit(1);
    }
}

// ── Channel ──────────────────────────────────────────────────────

fn runChannel(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    const zh = is_zh_ui();
    if (sub_args.len < 1) {
        if (zh) {
            std.debug.print(
                \\用法: nullclaw channel <command> [args]
                \\
                \\命令:
                \\  list                          列出已配置频道
                \\  start                         启动已配置频道
                \\  doctor                        运行频道健康检查
                \\  add <type> <config_json>      添加频道
                \\  remove <name>                 删除频道
                \\
            , .{});
        } else {
            std.debug.print(
                \\Usage: nullclaw channel <command> [args]
                \\
                \\Commands:
                \\  list                          List configured channels
                \\  start                         Start all configured channels
                \\  doctor                        Run health checks
                \\  add <type> <config_json>      Add a channel
                \\  remove <name>                 Remove a channel
                \\
            , .{});
        }
        std.process.exit(1);
    }

    const subcmd = sub_args[0];

    var cfg = yc.config.Config.load(allocator) catch {
        print_no_config_and_exit();
    };
    defer cfg.deinit();

    if (std.mem.eql(u8, subcmd, "list")) {
        if (zh) {
            std.debug.print("已配置频道:\n", .{});
        } else {
            std.debug.print("Configured channels:\n", .{});
        }
        std.debug.print("  CLI:       {s}\n", .{enabled_disabled_word(cfg.channels.cli, zh)});
        std.debug.print("  Telegram:  {s}\n", .{configured_word(cfg.channels.telegram != null, zh)});
        std.debug.print("  Discord:   {s}\n", .{configured_word(cfg.channels.discord != null, zh)});
        std.debug.print("  Slack:     {s}\n", .{configured_word(cfg.channels.slack != null, zh)});
        std.debug.print("  Webhook:   {s}\n", .{configured_word(cfg.channels.webhook != null, zh)});
        std.debug.print("  iMessage:  {s}\n", .{configured_word(cfg.channels.imessage != null, zh)});
        std.debug.print("  Matrix:    {s}\n", .{configured_word(cfg.channels.matrix != null, zh)});
        std.debug.print("  WhatsApp:  {s}\n", .{configured_word(cfg.channels.whatsapp != null, zh)});
        std.debug.print("  IRC:       {s}\n", .{configured_word(cfg.channels.irc != null, zh)});
        std.debug.print("  Lark:      {s}\n", .{configured_word(cfg.channels.lark != null, zh)});
        std.debug.print("  DingTalk:  {s}\n", .{configured_word(cfg.channels.dingtalk != null, zh)});
    } else if (std.mem.eql(u8, subcmd, "start")) {
        try runChannelStart(allocator, sub_args[1..]);
    } else if (std.mem.eql(u8, subcmd, "doctor")) {
        if (zh) {
            std.debug.print("频道健康:\n", .{});
            std.debug.print("  CLI:      正常\n", .{});
            if (cfg.channels.telegram != null) std.debug.print("  Telegram: 已配置（可用 `channel start` 验证）\n", .{});
            if (cfg.channels.discord != null) std.debug.print("  Discord:  已配置（可用 `channel start` 验证）\n", .{});
            if (cfg.channels.slack != null) std.debug.print("  Slack:    已配置（可用 `channel start` 验证）\n", .{});
        } else {
            std.debug.print("Channel health:\n", .{});
            std.debug.print("  CLI:      ok\n", .{});
            if (cfg.channels.telegram != null) std.debug.print("  Telegram: configured (use `channel start` to verify)\n", .{});
            if (cfg.channels.discord != null) std.debug.print("  Discord:  configured (use `channel start` to verify)\n", .{});
            if (cfg.channels.slack != null) std.debug.print("  Slack:    configured (use `channel start` to verify)\n", .{});
        }
    } else if (std.mem.eql(u8, subcmd, "add")) {
        if (sub_args.len < 2) {
            if (zh) {
                std.debug.print("用法: nullclaw channel add <type>\n", .{});
                std.debug.print("类型: telegram, discord, slack, webhook, matrix, whatsapp, irc, lark, dingtalk\n", .{});
            } else {
                std.debug.print("Usage: nullclaw channel add <type>\n", .{});
                std.debug.print("Types: telegram, discord, slack, webhook, matrix, whatsapp, irc, lark, dingtalk\n", .{});
            }
            std.process.exit(1);
        }
        if (zh) {
            std.debug.print("如需添加 '{s}' 频道，请编辑配置文件:\n  {s}\n", .{ sub_args[1], cfg.config_path });
            std.debug.print("在 \"channels\" 下新增 \"{s}\" 对象并填写必填字段。\n", .{sub_args[1]});
        } else {
            std.debug.print("To add a '{s}' channel, edit your config file:\n  {s}\n", .{ sub_args[1], cfg.config_path });
            std.debug.print("Add a \"{s}\" object under \"channels\" with the required fields.\n", .{sub_args[1]});
        }
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        if (sub_args.len < 2) {
            if (zh) {
                std.debug.print("用法: nullclaw channel remove <name>\n", .{});
            } else {
                std.debug.print("Usage: nullclaw channel remove <name>\n", .{});
            }
            std.process.exit(1);
        }
        if (zh) {
            std.debug.print("如需移除 '{s}' 频道，请编辑配置文件:\n  {s}\n", .{ sub_args[1], cfg.config_path });
            std.debug.print("删除 \"channels\" 下的 \"{s}\" 对象，或将其设置为 null。\n", .{sub_args[1]});
        } else {
            std.debug.print("To remove the '{s}' channel, edit your config file:\n  {s}\n", .{ sub_args[1], cfg.config_path });
            std.debug.print("Remove or set the \"{s}\" object to null under \"channels\".\n", .{sub_args[1]});
        }
    } else {
        if (zh) {
            std.debug.print("未知 channel 子命令: {s}\n", .{subcmd});
        } else {
            std.debug.print("Unknown channel command: {s}\n", .{subcmd});
        }
        std.process.exit(1);
    }
}

// ── Skills ───────────────────────────────────────────────────────

fn runSkills(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    const zh = is_zh_ui();
    if (sub_args.len < 1) {
        if (zh) {
            std.debug.print(
                \\用法: nullclaw skills <command> [args]
                \\
                \\命令:
                \\  list                          列出已安装技能
                \\  install <source>              从 GitHub URL 或路径安装
                \\  remove <name>                 删除技能
                \\  info <name>                   查看技能详情
                \\
            , .{});
        } else {
            std.debug.print(
                \\Usage: nullclaw skills <command> [args]
                \\
                \\Commands:
                \\  list                          List installed skills
                \\  install <source>              Install from GitHub URL or path
                \\  remove <name>                 Remove a skill
                \\  info <name>                   Show skill details
                \\
            , .{});
        }
        std.process.exit(1);
    }

    var cfg = yc.config.Config.load(allocator) catch {
        print_no_config_and_exit();
    };
    defer cfg.deinit();

    const subcmd = sub_args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        const skills_list = yc.skills.listSkills(allocator, cfg.workspace_dir) catch |err| {
            if (zh) {
                std.debug.print("列出技能失败: {s}\n", .{@errorName(err)});
            } else {
                std.debug.print("Failed to list skills: {s}\n", .{@errorName(err)});
            }
            std.process.exit(1);
        };
        defer yc.skills.freeSkills(allocator, skills_list);

        if (skills_list.len == 0) {
            if (zh) {
                std.debug.print("未安装任何技能。\n", .{});
            } else {
                std.debug.print("No skills installed.\n", .{});
            }
        } else {
            if (zh) {
                std.debug.print("已安装技能（{d}）:\n", .{skills_list.len});
            } else {
                std.debug.print("Installed skills ({d}):\n", .{skills_list.len});
            }
            for (skills_list) |skill| {
                std.debug.print("  {s} v{s}", .{ skill.name, skill.version });
                if (skill.description.len > 0) {
                    std.debug.print(" -- {s}", .{skill.description});
                }
                std.debug.print("\n", .{});
            }
        }
    } else if (std.mem.eql(u8, subcmd, "install")) {
        if (sub_args.len < 2) {
            if (zh) {
                std.debug.print("用法: nullclaw skills install <source>\n", .{});
            } else {
                std.debug.print("Usage: nullclaw skills install <source>\n", .{});
            }
            std.process.exit(1);
        }
        yc.skills.installSkillFromPath(allocator, sub_args[1], cfg.workspace_dir) catch |err| {
            if (zh) {
                std.debug.print("安装技能失败: {s}\n", .{@errorName(err)});
            } else {
                std.debug.print("Failed to install skill: {s}\n", .{@errorName(err)});
            }
            std.process.exit(1);
        };
        if (zh) {
            std.debug.print("技能安装来源: {s}\n", .{sub_args[1]});
        } else {
            std.debug.print("Skill installed from: {s}\n", .{sub_args[1]});
        }
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        if (sub_args.len < 2) {
            if (zh) {
                std.debug.print("用法: nullclaw skills remove <name>\n", .{});
            } else {
                std.debug.print("Usage: nullclaw skills remove <name>\n", .{});
            }
            std.process.exit(1);
        }
        yc.skills.removeSkill(allocator, sub_args[1], cfg.workspace_dir) catch |err| {
            if (zh) {
                std.debug.print("移除技能 '{s}' 失败: {s}\n", .{ sub_args[1], @errorName(err) });
            } else {
                std.debug.print("Failed to remove skill '{s}': {s}\n", .{ sub_args[1], @errorName(err) });
            }
            std.process.exit(1);
        };
        if (zh) {
            std.debug.print("已移除技能: {s}\n", .{sub_args[1]});
        } else {
            std.debug.print("Removed skill: {s}\n", .{sub_args[1]});
        }
    } else if (std.mem.eql(u8, subcmd, "info")) {
        if (sub_args.len < 2) {
            if (zh) {
                std.debug.print("用法: nullclaw skills info <name>\n", .{});
            } else {
                std.debug.print("Usage: nullclaw skills info <name>\n", .{});
            }
            std.process.exit(1);
        }
        const skill_path = std.fs.path.join(allocator, &.{ cfg.workspace_dir, "skills", sub_args[1] }) catch {
            if (zh) {
                std.debug.print("内存不足\n", .{});
            } else {
                std.debug.print("Out of memory\n", .{});
            }
            std.process.exit(1);
        };
        defer allocator.free(skill_path);

        const skill = yc.skills.loadSkill(allocator, skill_path) catch {
            if (zh) {
                std.debug.print("技能 '{s}' 不存在或无效。\n", .{sub_args[1]});
            } else {
                std.debug.print("Skill '{s}' not found or invalid.\n", .{sub_args[1]});
            }
            std.process.exit(1);
        };
        defer yc.skills.freeSkill(allocator, &skill);

        if (zh) {
            std.debug.print("技能: {s}\n", .{skill.name});
            std.debug.print("  版本:        {s}\n", .{skill.version});
        } else {
            std.debug.print("Skill: {s}\n", .{skill.name});
            std.debug.print("  Version:     {s}\n", .{skill.version});
        }
        if (skill.description.len > 0) {
            if (zh) {
                std.debug.print("  描述:        {s}\n", .{skill.description});
            } else {
                std.debug.print("  Description: {s}\n", .{skill.description});
            }
        }
        if (skill.author.len > 0) {
            if (zh) {
                std.debug.print("  作者:        {s}\n", .{skill.author});
            } else {
                std.debug.print("  Author:      {s}\n", .{skill.author});
            }
        }
        if (zh) {
            std.debug.print("  启用:        {}\n", .{skill.enabled});
        } else {
            std.debug.print("  Enabled:     {}\n", .{skill.enabled});
        }
        if (skill.instructions.len > 0) {
            if (zh) {
                std.debug.print("  指令长度:    {d} 字节\n", .{skill.instructions.len});
            } else {
                std.debug.print("  Instructions: {d} bytes\n", .{skill.instructions.len});
            }
        }
    } else {
        if (zh) {
            std.debug.print("未知 skills 子命令: {s}\n", .{subcmd});
        } else {
            std.debug.print("Unknown skills command: {s}\n", .{subcmd});
        }
        std.process.exit(1);
    }
}

// ── Hardware ─────────────────────────────────────────────────────

fn runHardware(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    const zh = is_zh_ui();
    if (sub_args.len < 1) {
        if (zh) {
            std.debug.print(
                \\用法: nullclaw hardware <command> [args]
                \\
                \\命令:
                \\  scan                          扫描已连接硬件
                \\  flash                         烧录固件到设备
                \\  monitor                       监控已连接设备
                \\
            , .{});
        } else {
            std.debug.print(
                \\Usage: nullclaw hardware <command> [args]
                \\
                \\Commands:
                \\  scan                          Scan for connected hardware
                \\  flash                         Flash firmware to a device
                \\  monitor                       Monitor connected devices
                \\
            , .{});
        }
        std.process.exit(1);
    }

    const subcmd = sub_args[0];

    if (std.mem.eql(u8, subcmd, "scan")) {
        if (zh) {
            std.debug.print("正在扫描硬件设备...\n", .{});
            std.debug.print("已知板卡注册表: {d} 条\n", .{yc.hardware.knownBoards().len});
        } else {
            std.debug.print("Scanning for hardware devices...\n", .{});
            std.debug.print("Known board registry: {d} entries\n", .{yc.hardware.knownBoards().len});
        }

        const devices = yc.hardware.discoverHardware(allocator) catch |err| {
            if (zh) {
                std.debug.print("扫描失败: {s}\n", .{@errorName(err)});
            } else {
                std.debug.print("Discovery failed: {s}\n", .{@errorName(err)});
            }
            std.process.exit(1);
        };
        defer yc.hardware.freeDiscoveredDevices(allocator, devices);

        if (devices.len == 0) {
            if (zh) {
                std.debug.print("未发现可识别设备。\n", .{});
            } else {
                std.debug.print("No recognized devices found.\n", .{});
            }
        } else {
            if (zh) {
                std.debug.print("发现 {d} 个设备:\n", .{devices.len});
            } else {
                std.debug.print("Discovered {d} device(s):\n", .{devices.len});
            }
            for (devices) |dev| {
                std.debug.print("  {s}", .{dev.name});
                if (dev.detail) |det| {
                    std.debug.print(" ({s})", .{det});
                }
                if (dev.device_path) |path| {
                    std.debug.print(" @ {s}", .{path});
                }
                std.debug.print("\n", .{});
            }
        }
    } else if (std.mem.eql(u8, subcmd, "flash")) {
        if (sub_args.len < 2) {
            if (zh) {
                std.debug.print("用法: nullclaw hardware flash <firmware_file> [--target <board>]\n", .{});
            } else {
                std.debug.print("Usage: nullclaw hardware flash <firmware_file> [--target <board>]\n", .{});
            }
            std.process.exit(1);
        }
        if (zh) {
            std.debug.print("Flash 功能尚未实现。固件文件: {s}\n", .{sub_args[1]});
        } else {
            std.debug.print("Flash not yet implemented. Firmware file: {s}\n", .{sub_args[1]});
        }
    } else if (std.mem.eql(u8, subcmd, "monitor")) {
        if (zh) {
            std.debug.print("Monitor 功能尚未实现。请先执行 `nullclaw hardware scan` 扫描设备。\n", .{});
        } else {
            std.debug.print("Monitor not yet implemented. Use `nullclaw hardware scan` to discover devices first.\n", .{});
        }
    } else {
        if (zh) {
            std.debug.print("未知 hardware 子命令: {s}\n", .{subcmd});
        } else {
            std.debug.print("Unknown hardware command: {s}\n", .{subcmd});
        }
        std.process.exit(1);
    }
}

// ── Migrate ──────────────────────────────────────────────────────

fn runMigrate(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    const zh = is_zh_ui();
    if (sub_args.len < 1) {
        if (zh) {
            std.debug.print(
                \\用法: nullclaw migrate <source> [options]
                \\
                \\来源:
                \\  openclaw                      从 OpenClaw 工作目录导入
                \\
                \\选项:
                \\  --dry-run                     仅预览，不写入
                \\  --source <path>               源工作目录路径
                \\
            , .{});
        } else {
            std.debug.print(
                \\Usage: nullclaw migrate <source> [options]
                \\
                \\Sources:
                \\  openclaw                      Import from OpenClaw workspace
                \\
                \\Options:
                \\  --dry-run                     Preview without writing
                \\  --source <path>               Source workspace path
                \\
            , .{});
        }
        std.process.exit(1);
    }

    if (std.mem.eql(u8, sub_args[0], "openclaw")) {
        var dry_run = false;
        var source_path: ?[]const u8 = null;

        var i: usize = 1;
        while (i < sub_args.len) : (i += 1) {
            if (std.mem.eql(u8, sub_args[i], "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, sub_args[i], "--source") and i + 1 < sub_args.len) {
                i += 1;
                source_path = sub_args[i];
            }
        }

        var cfg = yc.config.Config.load(allocator) catch {
            print_no_config_and_exit();
        };
        defer cfg.deinit();

        const stats = yc.migration.migrateOpenclaw(allocator, &cfg, source_path, dry_run) catch |err| {
            if (zh) {
                std.debug.print("迁移失败: {s}\n", .{@errorName(err)});
            } else {
                std.debug.print("Migration failed: {s}\n", .{@errorName(err)});
            }
            std.process.exit(1);
        };

        if (dry_run) {
            std.debug.print("[DRY RUN] ", .{});
        }
        if (zh) {
            std.debug.print("迁移完成: 导入 {d} 条, 跳过 {d} 条\n", .{ stats.imported, stats.skipped_unchanged });
        } else {
            std.debug.print("Migration complete: {d} imported, {d} skipped\n", .{ stats.imported, stats.skipped_unchanged });
        }
    } else {
        if (zh) {
            std.debug.print("未知迁移来源: {s}\n", .{sub_args[0]});
        } else {
            std.debug.print("Unknown migration source: {s}\n", .{sub_args[0]});
        }
        std.process.exit(1);
    }
}

// ── Models ───────────────────────────────────────────────────────

fn runModels(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    const zh = is_zh_ui();
    if (sub_args.len < 1) {
        if (zh) {
            std.debug.print(
                \\用法: nullclaw models <command>
                \\
                \\命令:
                \\  list                          列出可用模型
                \\  info <model>                  查看模型详情
                \\  benchmark                     运行模型延迟基准
                \\  refresh                       刷新模型目录缓存
                \\
            , .{});
        } else {
            std.debug.print(
                \\Usage: nullclaw models <command>
                \\
                \\Commands:
                \\  list                          List available models
                \\  info <model>                  Show model details
                \\  benchmark                     Run model latency benchmark
                \\  refresh                       Refresh model catalog
                \\
            , .{});
        }
        std.process.exit(1);
    }

    const subcmd = sub_args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        var cfg_opt: ?yc.config.Config = yc.config.Config.load(allocator) catch null;
        defer if (cfg_opt) |*c| c.deinit();

        if (zh) {
            std.debug.print("当前配置:\n", .{});
        } else {
            std.debug.print("Current configuration:\n", .{});
        }
        if (cfg_opt) |*c| {
            if (zh) {
                std.debug.print("  提供商: {s}\n", .{c.default_provider});
                std.debug.print("  模型:   {s}\n", .{c.default_model orelse "(未设置)"});
                std.debug.print("  温度:   {d:.1}\n\n", .{c.default_temperature});
            } else {
                std.debug.print("  Provider: {s}\n", .{c.default_provider});
                std.debug.print("  Model:    {s}\n", .{c.default_model orelse "(not set)"});
                std.debug.print("  Temp:     {d:.1}\n\n", .{c.default_temperature});
            }
        } else {
            if (zh) {
                std.debug.print("  （未找到配置，请先运行 `nullclaw onboard`）\n\n", .{});
            } else {
                std.debug.print("  (no config -- run `nullclaw onboard` first)\n\n", .{});
            }
        }

        if (zh) {
            std.debug.print("已知提供商及默认模型:\n", .{});
        } else {
            std.debug.print("Known providers and default models:\n", .{});
        }
        for (yc.onboard.known_providers) |p| {
            std.debug.print("  {s:<12} {s:<36} {s}\n", .{ p.key, p.default_model, p.label });
        }
        if (zh) {
            std.debug.print("\n可使用 `nullclaw models info <model>` 查看详情。\n", .{});
        } else {
            std.debug.print("\nUse `nullclaw models info <model>` for details.\n", .{});
        }
    } else if (std.mem.eql(u8, subcmd, "info")) {
        if (sub_args.len < 2) {
            if (zh) {
                std.debug.print("用法: nullclaw models info <model>\n", .{});
            } else {
                std.debug.print("Usage: nullclaw models info <model>\n", .{});
            }
            std.process.exit(1);
        }
        if (zh) {
            std.debug.print("模型: {s}\n", .{sub_args[1]});
            std.debug.print("  默认提供商: {s}\n", .{yc.onboard.canonicalProviderName(sub_args[1])});
            std.debug.print("  上下文: 取决于提供商\n", .{});
            std.debug.print("  定价: 请查看提供商后台\n", .{});
        } else {
            std.debug.print("Model: {s}\n", .{sub_args[1]});
            std.debug.print("  Default provider: {s}\n", .{yc.onboard.canonicalProviderName(sub_args[1])});
            std.debug.print("  Context: varies by provider\n", .{});
            std.debug.print("  Pricing: see provider dashboard\n", .{});
        }
    } else if (std.mem.eql(u8, subcmd, "benchmark")) {
        if (zh) {
            std.debug.print("正在运行模型延迟基准...\n", .{});
            std.debug.print("请先配置 provider（运行 nullclaw onboard）。\n", .{});
        } else {
            std.debug.print("Running model latency benchmark...\n", .{});
            std.debug.print("Configure a provider first (nullclaw onboard).\n", .{});
        }
    } else if (std.mem.eql(u8, subcmd, "refresh")) {
        try yc.onboard.runModelsRefresh(allocator);
    } else {
        if (zh) {
            std.debug.print("未知 models 子命令: {s}\n", .{subcmd});
        } else {
            std.debug.print("Unknown models command: {s}\n", .{subcmd});
        }
        std.process.exit(1);
    }
}

// ── Onboard ──────────────────────────────────────────────────────

fn runOnboard(allocator: std.mem.Allocator, sub_args: []const []const u8) !void {
    var interactive = false;
    var channels_only = false;
    var api_key: ?[]const u8 = null;
    var provider: ?[]const u8 = null;
    var memory_backend: ?[]const u8 = null;
    var model: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        if (std.mem.eql(u8, sub_args[i], "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, sub_args[i], "--channels-only")) {
            channels_only = true;
        } else if (std.mem.eql(u8, sub_args[i], "--api-key") and i + 1 < sub_args.len) {
            i += 1;
            api_key = sub_args[i];
        } else if (std.mem.eql(u8, sub_args[i], "--provider") and i + 1 < sub_args.len) {
            i += 1;
            provider = sub_args[i];
        } else if (std.mem.eql(u8, sub_args[i], "--memory") and i + 1 < sub_args.len) {
            i += 1;
            memory_backend = sub_args[i];
        } else if (std.mem.eql(u8, sub_args[i], "--model") and i + 1 < sub_args.len) {
            i += 1;
            model = sub_args[i];
        }
    }

    if (channels_only) {
        try yc.onboard.runChannelsOnly(allocator);
    } else if (interactive) {
        try yc.onboard.runWizard(allocator);
    } else {
        try yc.onboard.runQuickSetup(allocator, api_key, provider, memory_backend, model);
    }
}

// ── Channel Start (Telegram bot loop) ────────────────────────────

fn runChannelStart(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const zh = is_zh_ui();
    // Load config
    var config = yc.config.Config.load(allocator) catch {
        print_no_config_and_exit();
    };
    defer config.deinit();

    const telegram_config = config.channels.telegram orelse {
        if (zh) {
            std.debug.print("Telegram 未配置。请在 config.json 添加:\n", .{});
            std.debug.print("  \"channels\": {{\"telegram\": {{\"accounts\": {{\"main\": {{\"bot_token\": \"...\"}}}}}}}}\n", .{});
        } else {
            std.debug.print("Telegram not configured. Add to config.json:\n", .{});
            std.debug.print("  \"channels\": {{\"telegram\": {{\"accounts\": {{\"main\": {{\"bot_token\": \"...\"}}}}}}}}\n", .{});
        }
        std.process.exit(1);
    };

    // Determine allowed users: --user CLI args override config allow_from
    var user_list: std.ArrayList([]const u8) = .empty;
    defer user_list.deinit(allocator);
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--user") and i + 1 < args.len) {
                i += 1;
                user_list.append(allocator, args[i]) catch |err| log.err("failed to append user: {}", .{err});
            }
        }
    }
    const allowed: []const []const u8 = if (user_list.items.len > 0)
        user_list.items
    else
        telegram_config.allow_from;

    // Resolve API key with explicit ownership:
    // - config key: borrowed slice from config
    // - env key: owned allocation that we free on function exit
    var resolved_api_key_owned: ?[]u8 = null;
    defer if (resolved_api_key_owned) |k| allocator.free(k);
    const resolved_api_key: ?[]const u8 = blk: {
        if (config.defaultProviderKey()) |k| break :blk k;
        resolved_api_key_owned = yc.providers.resolveApiKey(allocator, config.default_provider, null) catch null;
        break :blk resolved_api_key_owned;
    };
    const provider_kind = yc.providers.classifyProvider(config.default_provider);
    const requires_api_key = switch (provider_kind) {
        .ollama_provider, .claude_cli_provider, .codex_cli_provider, .openai_codex_provider => false,
        else => true,
    };

    if (requires_api_key and resolved_api_key == null) {
        if (zh) {
            std.debug.print("未配置 API key。请在 ~/.nullclaw/config.json 添加:\n", .{});
            std.debug.print("  \"providers\": {{ \"{s}\": {{ \"api_key\": \"...\" }} }}\n", .{config.default_provider});
        } else {
            std.debug.print("No API key configured. Set env var or add to ~/.nullclaw/config.json:\n", .{});
            std.debug.print("  \"providers\": {{ \"{s}\": {{ \"api_key\": \"...\" }} }}\n", .{config.default_provider});
        }
        std.process.exit(1);
    }

    const model = config.default_model orelse "anthropic/claude-3.5-sonnet";
    const temperature = config.default_temperature;

    if (zh) {
        std.debug.print("nullclaw Telegram 机器人启动中...\n", .{});
        std.debug.print("  提供商: {s}\n", .{config.default_provider});
        std.debug.print("  模型: {s}\n", .{model});
        std.debug.print("  温度: {d:.1}\n", .{temperature});
    } else {
        std.debug.print("nullclaw telegram bot starting...\n", .{});
        std.debug.print("  Provider: {s}\n", .{config.default_provider});
        std.debug.print("  Model: {s}\n", .{model});
        std.debug.print("  Temperature: {d:.1}\n", .{temperature});
    }
    if (allowed.len == 0) {
        if (zh) {
            std.debug.print("  允许用户: （空，所有消息都会被拒绝）\n", .{});
        } else {
            std.debug.print("  Allowed users: (none — all messages will be denied)\n", .{});
        }
    } else if (allowed.len == 1 and std.mem.eql(u8, allowed[0], "*")) {
        if (zh) {
            std.debug.print("  允许用户: *\n", .{});
        } else {
            std.debug.print("  Allowed users: *\n", .{});
        }
    } else {
        if (zh) {
            std.debug.print("  允许用户:", .{});
        } else {
            std.debug.print("  Allowed users:", .{});
        }
        for (allowed) |u| {
            std.debug.print(" {s}", .{u});
        }
        std.debug.print("\n", .{});
    }

    var tg = yc.channels.telegram.TelegramChannel.init(allocator, telegram_config.bot_token, allowed);
    tg.proxy = telegram_config.proxy;

    // Set up transcription — key comes from providers.{audio_media.provider}
    const trans = config.audio_media;
    const whisper_ptr: ?*yc.voice.WhisperTranscriber = if (config.getProviderKey(trans.provider)) |key| blk: {
        const wt = try allocator.create(yc.voice.WhisperTranscriber);
        wt.* = .{
            .endpoint = yc.voice.resolveTranscriptionEndpoint(trans.provider, trans.base_url),
            .api_key = key,
            .model = trans.model,
            .language = trans.language,
        };
        break :blk wt;
    } else null;
    if (whisper_ptr) |wt| tg.transcriber = wt.transcriber();

    // Initialize MCP tools from config
    const mcp_tools: ?[]const yc.tools.Tool = if (config.mcp_servers.len > 0)
        yc.mcp.initMcpTools(allocator, config.mcp_servers) catch |err| blk: {
            if (zh) {
                std.debug.print("  MCP: 初始化失败: {}\n", .{err});
            } else {
                std.debug.print("  MCP: init failed: {}\n", .{err});
            }
            break :blk null;
        }
    else
        null;

    var subagent_manager = yc.subagent.SubagentManager.init(allocator, &config, null, .{
        .max_iterations = config.agent.max_tool_iterations,
        .max_concurrent = config.scheduler.max_concurrent,
    });
    defer subagent_manager.deinit();

    // Create tools (for system prompt and tool calling)
    const tools = yc.tools.allTools(allocator, config.workspace_dir, .{
        .http_enabled = config.http_request.enabled,
        .browser_enabled = config.browser.enabled,
        .browser_config = config.browser,
        .screenshot_enabled = true,
        .mcp_tools = mcp_tools,
        .agents = config.agents,
        .fallback_api_key = resolved_api_key,
        .max_model_fallback_hops = config.reliability.max_model_fallback_hops,
        .subagent_manager = &subagent_manager,
        .tools_config = config.tools,
        .security_config = config.security,
        .plugins_config = config.plugins,
    }) catch &.{};
    defer if (tools.len > 0) allocator.free(tools);

    if (mcp_tools) |mt| {
        if (zh) {
            std.debug.print("  MCP 工具: {d}\n", .{mt.len});
        } else {
            std.debug.print("  MCP tools: {d}\n", .{mt.len});
        }
    }

    // Create optional memory backend (don't fail if unavailable)
    var mem_opt: ?yc.memory.Memory = null;
    const db_path = std.fs.path.joinZ(allocator, &.{ config.workspace_dir, "memory.db" }) catch null;
    defer if (db_path) |p| allocator.free(p);
    if (db_path) |p| {
        if (yc.memory.createMemory(allocator, config.memory.backend, p)) |mem| {
            mem_opt = mem;
        } else |_| {}
    }

    // Create noop observer
    var noop_obs = yc.observability.NoopObserver{};
    const obs = noop_obs.observer();

    // Create provider vtable — concrete struct must stay alive for the loop.
    // Use a tagged union so the right type lives on the stack.
    const ProviderHolder = union(enum) {
        openrouter: yc.providers.openrouter.OpenRouterProvider,
        anthropic: yc.providers.anthropic.AnthropicProvider,
        openai: yc.providers.openai.OpenAiProvider,
        gemini: yc.providers.gemini.GeminiProvider,
        ollama: yc.providers.ollama.OllamaProvider,
        compatible: yc.providers.compatible.OpenAiCompatibleProvider,
        claude_cli: yc.providers.claude_cli.ClaudeCliProvider,
        codex_cli: yc.providers.codex_cli.CodexCliProvider,
        openai_codex: yc.providers.openai_codex.OpenAiCodexProvider,
    };

    var holder: ProviderHolder = switch (provider_kind) {
        .anthropic_provider => .{ .anthropic = yc.providers.anthropic.AnthropicProvider.init(
            allocator,
            resolved_api_key,
            if (std.mem.startsWith(u8, config.default_provider, "anthropic-custom:"))
                config.default_provider["anthropic-custom:".len..]
            else
                config.getProviderBaseUrl(config.default_provider),
        ) },
        .openai_provider => .{ .openai = yc.providers.openai.OpenAiProvider.initWithBaseUrl(
            allocator,
            resolved_api_key,
            config.getProviderBaseUrl(config.default_provider),
        ) },
        .gemini_provider => .{ .gemini = yc.providers.gemini.GeminiProvider.initWithBaseUrl(
            allocator,
            resolved_api_key,
            config.getProviderBaseUrl(config.default_provider),
        ) },
        .ollama_provider => .{ .ollama = yc.providers.ollama.OllamaProvider.init(
            allocator,
            config.getProviderBaseUrl(config.default_provider),
        ) },
        .openrouter_provider => .{ .openrouter = yc.providers.openrouter.OpenRouterProvider.initWithBaseUrl(
            allocator,
            resolved_api_key,
            config.getProviderBaseUrl(config.default_provider),
        ) },
        .compatible_provider => .{ .compatible = yc.providers.compatible.OpenAiCompatibleProvider.init(
            allocator,
            config.default_provider,
            if (std.mem.startsWith(u8, config.default_provider, "custom:"))
                config.default_provider["custom:".len..]
            else
                config.getProviderBaseUrl(config.default_provider) orelse
                    yc.providers.compatibleProviderUrl(config.default_provider) orelse "https://openrouter.ai/api/v1",
            resolved_api_key,
            .bearer,
        ) },
        .claude_cli_provider => if (yc.providers.claude_cli.ClaudeCliProvider.init(allocator, null)) |p|
            .{ .claude_cli = p }
        else |_|
            .{ .openrouter = yc.providers.openrouter.OpenRouterProvider.initWithBaseUrl(allocator, resolved_api_key, config.getProviderBaseUrl(config.default_provider)) },
        .codex_cli_provider => if (yc.providers.codex_cli.CodexCliProvider.init(allocator, null)) |p|
            .{ .codex_cli = p }
        else |_|
            .{ .openrouter = yc.providers.openrouter.OpenRouterProvider.initWithBaseUrl(allocator, resolved_api_key, config.getProviderBaseUrl(config.default_provider)) },
        .openai_codex_provider => .{ .openai_codex = yc.providers.openai_codex.OpenAiCodexProvider.init(allocator, null) },
        .unknown => .{ .openrouter = yc.providers.openrouter.OpenRouterProvider.initWithBaseUrl(
            allocator,
            resolved_api_key,
            config.getProviderBaseUrl(config.default_provider),
        ) },
    };

    const provider_i: yc.providers.Provider = switch (holder) {
        .openrouter => |*p| p.provider(),
        .anthropic => |*p| p.provider(),
        .openai => |*p| p.provider(),
        .gemini => |*p| p.provider(),
        .ollama => |*p| p.provider(),
        .compatible => |*p| p.provider(),
        .claude_cli => |*p| p.provider(),
        .codex_cli => |*p| p.provider(),
        .openai_codex => |*p| p.provider(),
    };

    if (zh) {
        std.debug.print("  工具: {d} 个已加载\n", .{tools.len});
        std.debug.print("  记忆: {s}\n", .{if (mem_opt != null) "已启用" else "已禁用"});
    } else {
        std.debug.print("  Tools: {d} loaded\n", .{tools.len});
        std.debug.print("  Memory: {s}\n", .{if (mem_opt != null) "enabled" else "disabled"});
    }

    // Register bot commands in Telegram's "/" menu
    tg.setMyCommands();

    // Skip messages accumulated while bot was offline
    tg.dropPendingUpdates();

    if (zh) {
        std.debug.print("  正在轮询消息...（Ctrl+C 停止）\n\n", .{});
    } else {
        std.debug.print("  Polling for messages... (Ctrl+C to stop)\n\n", .{});
    }

    var session_mgr = yc.session.SessionManager.init(allocator, &config, provider_i, tools, mem_opt, obs, null);
    defer session_mgr.deinit();

    var typing = yc.channels.telegram.TypingIndicator.init(&tg);
    var evict_counter: u32 = 0;

    // Bot loop: poll → full agent loop (tool calling) → reply
    while (true) {
        const messages = tg.pollUpdates(allocator) catch |err| {
            if (zh) {
                std.debug.print("轮询错误: {}\n", .{err});
            } else {
                std.debug.print("Poll error: {}\n", .{err});
            }
            std.Thread.sleep(5 * std.time.ns_per_s);
            continue;
        };

        for (messages) |msg| {
            std.debug.print("[{s}] {s}: {s}\n", .{ msg.channel, msg.id, msg.content });

            // Handle /start command (Telegram-specific greeting, not sent to LLM)
            const trimmed_content = std.mem.trim(u8, msg.content, " \t\r\n");
            if (std.mem.eql(u8, trimmed_content, "/start")) {
                var greeting_buf: [512]u8 = undefined;
                const name = msg.first_name orelse msg.id;
                const greeting = std.fmt.bufPrint(&greeting_buf, "Hello, {s}! I'm nullClaw.\n\nModel: {s}\nType /help for available commands.", .{ name, model }) catch "Hello! I'm nullClaw. Type /help for commands.";
                tg.sendMessageWithReply(msg.sender, greeting, msg.message_id) catch |err| log.err("failed to send /start reply: {}", .{err});
                continue;
            }

            // Determine reply-to: always in groups, configurable in private chats
            const use_reply_to = msg.is_group or telegram_config.reply_in_private;
            const reply_to_id: ?i64 = if (use_reply_to) msg.message_id else null;

            // Session key: "telegram:{chat_id}"
            var key_buf: [128]u8 = undefined;
            const session_key = std.fmt.bufPrint(&key_buf, "telegram:{s}", .{msg.sender}) catch msg.sender;

            // Start periodic typing indicator while LLM is thinking
            typing.start(msg.sender);

            const reply = session_mgr.processMessage(session_key, msg.content) catch |err| {
                typing.stop();
                if (zh) {
                    std.debug.print("  Agent 错误: {}\n", .{err});
                } else {
                    std.debug.print("  Agent error: {}\n", .{err});
                }
                const err_msg = if (zh)
                    switch (err) {
                        error.CurlFailed, error.CurlReadError, error.CurlWaitError => "网络错误，请稍后重试。",
                        error.MaxToolIterationsExceeded => "工具迭代次数超过上限。",
                        error.OutOfMemory => "内存不足，无法处理请求。",
                        else => "处理失败，请重试或发送 /new 开启新会话。",
                    }
                else switch (err) {
                    error.CurlFailed, error.CurlReadError, error.CurlWaitError => "Network error. Please try again.",
                    error.MaxToolIterationsExceeded => "Tool iteration limit exceeded.",
                    error.OutOfMemory => "Out of memory while processing the request.",
                    else => "An error occurred. Try again or use /new for a fresh session.",
                };
                tg.sendMessageWithReply(msg.sender, err_msg, reply_to_id) catch |send_err| log.err("failed to send error reply: {}", .{send_err});
                continue;
            };
            defer allocator.free(reply);

            typing.stop();

            std.debug.print("  -> {s}\n", .{reply});

            // Reply on telegram; handles [IMAGE:path] markers + split
            tg.sendMessageWithReply(msg.sender, reply, reply_to_id) catch |err| {
                if (zh) {
                    std.debug.print("  发送错误: {}\n", .{err});
                } else {
                    std.debug.print("  Send error: {}\n", .{err});
                }
            };
        }

        if (messages.len > 0) {
            // Free message memory
            for (messages) |msg| {
                allocator.free(msg.id);
                allocator.free(msg.sender);
                allocator.free(msg.content);
                if (msg.first_name) |fn_| allocator.free(fn_);
            }
            allocator.free(messages);
        }

        // Periodically evict sessions idle longer than the configured timeout
        evict_counter += 1;
        if (evict_counter >= 100) {
            evict_counter = 0;
            _ = session_mgr.evictIdle(config.agent.session_idle_timeout_secs);
        }
    }
}

fn printUsage() void {
    const usage_en =
        \\nullclaw -- The smallest AI assistant. Zig-powered.
        \\
        \\USAGE:
        \\  nullclaw <command> [options]
        \\
        \\COMMANDS:
        \\  onboard     Initialize workspace and configuration
        \\  agent       Start the AI agent loop
        \\  gateway     Start the gateway server (HTTP/WebSocket)
        \\  daemon      Start long-running runtime (gateway + channels + heartbeat)
        \\  service     Manage OS service lifecycle (install/start/stop/status/uninstall)
        \\  status      Show system status
        \\  doctor      Run diagnostics
        \\  cron        Manage scheduled tasks
        \\  channel     Manage channels (Telegram, Discord, Slack, ...)
        \\  skills      Manage skills
        \\  hardware    Discover and manage hardware
        \\  migrate     Migrate data from other agent runtimes
        \\  models      Manage provider model catalogs
        \\  mcp         Run MCP server (stdio)
        \\  help        Show this help
        \\
        \\OPTIONS:
        \\  onboard [--interactive] [--api-key KEY] [--provider PROV] [--memory MEM] [--model MODEL]
        \\  agent [-m MESSAGE] [-s SESSION] [--provider PROVIDER] [--model MODEL] [--temperature TEMP]
        \\  gateway [--port PORT] [--host HOST]
        \\  daemon [--port PORT] [--host HOST]
        \\  service <install|start|stop|status|uninstall>
        \\  cron <list|add|once|remove|pause|resume> [ARGS]
        \\  channel <list|start|doctor|add|remove> [ARGS]
        \\  skills <list|install|remove> [ARGS]
        \\  hardware <discover|introspect|info> [ARGS]
        \\  migrate openclaw [--dry-run] [--source PATH]
        \\  models refresh
        \\  mcp serve
        \\
    ;
    const usage_zh =
        \\nullclaw -- 最小可用 AI 助手（Zig 驱动）
        \\
        \\用法:
        \\  nullclaw <命令> [选项]
        \\
        \\命令:
        \\  onboard     初始化工作目录和配置
        \\  agent       启动 AI Agent 循环
        \\  gateway     启动网关服务 (HTTP/WebSocket)
        \\  daemon      启动常驻运行时（网关 + 频道 + 心跳）
        \\  service     管理系统服务（install/start/stop/status/uninstall）
        \\  status      查看系统状态
        \\  doctor      运行诊断
        \\  cron        管理定时任务
        \\  channel     管理频道（Telegram、Discord、Slack 等）
        \\  skills      管理技能
        \\  hardware    发现并管理硬件
        \\  migrate     从其他 Agent 运行时迁移数据
        \\  models      管理模型目录
        \\  mcp         运行 MCP 服务（stdio）
        \\  help        显示帮助
        \\
        \\选项:
        \\  onboard [--interactive] [--api-key KEY] [--provider PROV] [--memory MEM] [--model MODEL]
        \\  agent [-m MESSAGE] [-s SESSION] [--provider PROVIDER] [--model MODEL] [--temperature TEMP]
        \\  gateway [--port PORT] [--host HOST]
        \\  daemon [--port PORT] [--host HOST]
        \\  service <install|start|stop|status|uninstall>
        \\  cron <list|add|once|remove|pause|resume> [ARGS]
        \\  channel <list|start|doctor|add|remove> [ARGS]
        \\  skills <list|install|remove> [ARGS]
        \\  hardware <discover|introspect|info> [ARGS]
        \\  migrate openclaw [--dry-run] [--source PATH]
        \\  models refresh
        \\  mcp serve
        \\
    ;
    if (is_zh_ui()) {
        std.debug.print("{s}", .{usage_zh});
    } else {
        std.debug.print("{s}", .{usage_en});
    }
}

test "parse known commands" {
    try std.testing.expectEqual(.agent, parseCommand("agent").?);
    try std.testing.expectEqual(.status, parseCommand("status").?);
    try std.testing.expectEqual(.service, parseCommand("service").?);
    try std.testing.expectEqual(.migrate, parseCommand("migrate").?);
    try std.testing.expectEqual(.models, parseCommand("models").?);
    try std.testing.expectEqual(.mcp, parseCommand("mcp").?);
    try std.testing.expect(parseCommand("unknown") == null);
}
