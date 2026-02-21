const std = @import("std");
const builtin = @import("builtin");
const Sandbox = @import("sandbox.zig").Sandbox;

/// Landlock sandbox backend for Linux kernel 5.13+ LSM.
/// Restricts filesystem access using the Landlock kernel interface.
/// On non-Linux platforms, returns error.UnsupportedPlatform.
pub const LandlockSandbox = struct {
    workspace_dir: []const u8,

    pub const sandbox_vtable = Sandbox.VTable{
        .wrapCommand = wrapCommand,
        .isAvailable = isAvailable,
        .name = getName,
        .description = getDescription,
    };

    pub fn sandbox(self: *LandlockSandbox) Sandbox {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &sandbox_vtable,
        };
    }

    fn wrapCommand(_: *anyopaque, _: []const []const u8, _: [][]const u8) anyerror![]const []const u8 {
        // This backend is currently a placeholder until full ruleset application
        // is implemented before child process spawn.
        return error.NotImplemented;
    }

    fn isAvailable(_: *anyopaque) bool {
        // Returning false avoids a false security signal when users enable sandboxing.
        return false;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "landlock";
    }

    fn getDescription(_: *anyopaque) []const u8 {
        _ = builtin;
        return "Landlock backend placeholder (not implemented yet)";
    }
};

pub fn createLandlockSandbox(workspace_dir: []const u8) LandlockSandbox {
    return .{ .workspace_dir = workspace_dir };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "landlock sandbox name" {
    var ll = createLandlockSandbox("/tmp/workspace");
    const sb = ll.sandbox();
    try std.testing.expectEqualStrings("landlock", sb.name());
}

test "landlock sandbox availability matches platform" {
    var ll = createLandlockSandbox("/tmp/workspace");
    const sb = ll.sandbox();
    try std.testing.expect(!sb.isAvailable());
}

test "landlock sandbox wrap command returns not implemented" {
    var ll = createLandlockSandbox("/tmp/workspace");
    const sb = ll.sandbox();
    const argv = [_][]const u8{ "echo", "test" };
    var buf: [16][]const u8 = undefined;
    const result = sb.wrapCommand(&argv, &buf);
    try std.testing.expectError(error.NotImplemented, result);
}
