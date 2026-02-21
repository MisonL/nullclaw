const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite3_dep = b.dependency("sqlite3", .{
        .target = target,
        .optimize = optimize,
    });
    const sqlite3 = sqlite3_dep.artifact("sqlite3");
    sqlite3.root_module.addCMacro("SQLITE_ENABLE_FTS5", "1");

    // ---------- library module (importable by consumers) ----------
    const lib_mod = b.addModule("nullclaw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.linkLibrary(sqlite3);

    // ---------- executable ----------
    const exe = b.addExecutable(.{
        .name = "nullclaw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nullclaw", .module = lib_mod },
            },
        }),
    });

    // Link SQLite on the compile step (not the module)
    exe.linkLibrary(sqlite3);
    exe.dead_strip_dylibs = true;

    if (optimize != .Debug) {
        exe.root_module.strip = true;
        exe.root_module.unwind_tables = .none;
        exe.root_module.omit_frame_pointer = true;
    }

    b.installArtifact(exe);

    // macOS: strip local symbols post-install (Zig strip only removes debug info)
    if (optimize != .Debug and builtin.os.tag == .macos) {
        const strip_cmd = b.addSystemCommand(&.{ "strip", "-x", "zig-out/bin/nullclaw" });
        strip_cmd.step.dependOn(b.getInstallStep());
        b.default_step = &strip_cmd.step;
    }

    // ---------- run step ----------
    const run_step = b.step("run", "Run nullclaw");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ---------- tests ----------
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    lib_tests.linkLibrary(sqlite3);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
