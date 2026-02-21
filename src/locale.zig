const std = @import("std");
const builtin = @import("builtin");

pub const UiLanguage = enum {
    en,
    zh_cn,
};

pub fn detect_ui_language() UiLanguage {
    if (get_env_var("NULLCLAW_LANG")) |lang_override| {
        defer std.heap.page_allocator.free(lang_override);
        if (parse_ui_language(lang_override)) |lang| {
            if (lang == .zh_cn and !can_render_zh(lang_override)) return .en;
            return lang;
        }
    }

    const locale_envs = [_][:0]const u8{ "LC_ALL", "LC_MESSAGES", "LANGUAGE", "LANG" };
    for (locale_envs) |name| {
        if (get_env_var(name)) |value| {
            defer std.heap.page_allocator.free(value);
            if (parse_ui_language(value)) |lang| {
                if (lang == .zh_cn and !can_render_zh(value)) return .en;
                return lang;
            }
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

fn can_render_zh(locale_value: []const u8) bool {
    return can_render_zh_for_locale(locale_value, builtin.os.tag == .windows);
}

fn can_render_zh_for_locale(locale_value: []const u8, is_windows: bool) bool {
    if (contains_ci(locale_value, "utf-8") or
        contains_ci(locale_value, "utf8") or
        contains_ci(locale_value, "65001"))
    {
        return true;
    }

    if (contains_ci(locale_value, "gbk") or
        contains_ci(locale_value, "gb2312") or
        contains_ci(locale_value, "gb18030") or
        contains_ci(locale_value, "cp936") or
        contains_ci(locale_value, ".936"))
    {
        return false;
    }

    // On Windows, unknown locale encodings are often ACP/legacy codepages.
    // Chinese UTF-8 literals will mojibake there, so prefer safe English fallback.
    if (is_windows) return false;
    return true;
}

fn starts_with_ci(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    for (prefix, 0..) |char, idx| {
        if (std.ascii.toLower(value[idx]) != std.ascii.toLower(char)) return false;
    }
    return true;
}

fn contains_ci(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(ch)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
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

test "can_render_zh_for_locale recognizes utf8 locales" {
    try std.testing.expect(can_render_zh_for_locale("zh_CN.UTF-8", true));
    try std.testing.expect(can_render_zh_for_locale("zh_CN.utf8", false));
}

test "can_render_zh_for_locale rejects gbk locales" {
    try std.testing.expect(!can_render_zh_for_locale("zh_CN.GBK", true));
    try std.testing.expect(!can_render_zh_for_locale("zh_CN.gb18030", false));
}

test "can_render_zh_for_locale defaults by platform when encoding unknown" {
    try std.testing.expect(!can_render_zh_for_locale("zh_CN", true));
    try std.testing.expect(can_render_zh_for_locale("zh_CN", false));
}
