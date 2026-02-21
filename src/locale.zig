const std = @import("std");

pub const UiLanguage = enum {
    en,
    zh_cn,
};

pub fn detect_ui_language() UiLanguage {
    if (get_env_var("NULLCLAW_LANG")) |lang_override| {
        defer std.heap.page_allocator.free(lang_override);
        if (parse_ui_language(lang_override)) |lang| return lang;
    }

    const locale_envs = [_][:0]const u8{ "LC_ALL", "LC_MESSAGES", "LANGUAGE", "LANG" };
    for (locale_envs) |name| {
        if (get_env_var(name)) |value| {
            defer std.heap.page_allocator.free(value);
            if (parse_ui_language(value)) |lang| return lang;
        }
    }
    return .en;
}

fn get_env_var(name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(std.heap.page_allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        error.OutOfMemory => null,
        else => null,
    };
}

fn parse_ui_language(raw: []const u8) ?UiLanguage {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (starts_with_ci(trimmed, "zh")) return .zh_cn;
    if (starts_with_ci(trimmed, "en")) return .en;
    return null;
}

fn starts_with_ci(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    for (prefix, 0..) |char, idx| {
        if (std.ascii.toLower(value[idx]) != std.ascii.toLower(char)) return false;
    }
    return true;
}

test "parse_ui_language supports zh variants" {
    try std.testing.expectEqual(UiLanguage.zh_cn, parse_ui_language("zh"));
    try std.testing.expectEqual(UiLanguage.zh_cn, parse_ui_language("zh_CN.UTF-8"));
    try std.testing.expectEqual(UiLanguage.zh_cn, parse_ui_language("ZH-hans"));
}

test "parse_ui_language supports en variants" {
    try std.testing.expectEqual(UiLanguage.en, parse_ui_language("en"));
    try std.testing.expectEqual(UiLanguage.en, parse_ui_language("en_US.UTF-8"));
}

test "parse_ui_language returns null for unsupported language" {
    try std.testing.expect(parse_ui_language("fr_FR.UTF-8") == null);
    try std.testing.expect(parse_ui_language("") == null);
}
