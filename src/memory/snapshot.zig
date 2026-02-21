//! Memory snapshot — export/import core memories as JSON.
//!
//! Mirrors ZeroClaw's snapshot module:
//!   - export_snapshot: dumps all Memory entries to a JSON file
//!   - hydrate_from_snapshot: restores entries from JSON
//!   - should_hydrate: checks if memory is empty but snapshot exists

const std = @import("std");
const root = @import("root.zig");
const json_util = @import("../json_util.zig");
const Memory = root.Memory;
const MemoryEntry = root.MemoryEntry;
const MemoryCategory = root.MemoryCategory;

/// Default snapshot filename.
pub const SNAPSHOT_FILENAME = "MEMORY_SNAPSHOT.json";

// ── Export ─────────────────────────────────────────────────────────

/// Export all core memories to a JSON snapshot file.
/// Returns the number of entries exported.
pub fn exportSnapshot(allocator: std.mem.Allocator, mem: Memory, workspace_dir: []const u8) !usize {
    // List all core memories
    const entries = try mem.list(allocator, .core, null);
    defer root.freeEntries(allocator, entries);

    if (entries.len == 0) return 0;

    // Build JSON output
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer json_buf.deinit(allocator);

    try json_buf.appendSlice(allocator, "[\n");

    for (entries, 0..) |entry, i| {
        if (i > 0) try json_buf.appendSlice(allocator, ",\n");
        try json_buf.appendSlice(allocator, "  {");
        try json_util.appendJsonKeyValue(&json_buf, allocator, "key", entry.key);
        try json_buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&json_buf, allocator, "content", entry.content);
        try json_buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&json_buf, allocator, "category", entry.category.toString());
        try json_buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&json_buf, allocator, "timestamp", entry.timestamp);
        try json_buf.append(allocator, '}');
    }

    try json_buf.appendSlice(allocator, "\n]\n");

    // Write to file
    const snapshot_path = try std.fs.path.join(allocator, &.{ workspace_dir, SNAPSHOT_FILENAME });
    defer allocator.free(snapshot_path);

    const file = try std.fs.cwd().createFile(snapshot_path, .{});
    defer file.close();

    try file.writeAll(json_buf.items);

    return entries.len;
}

// ── Hydrate ───────────────────────────────────────────────────────

/// A parsed snapshot entry.
const SnapshotEntry = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8,
};

/// Restore memory entries from a JSON snapshot file.
/// Returns the number of entries hydrated.
pub fn hydrateFromSnapshot(allocator: std.mem.Allocator, mem: Memory, workspace_dir: []const u8) !usize {
    const snapshot_path = try std.fs.path.join(allocator, &.{ workspace_dir, SNAPSHOT_FILENAME });
    defer allocator.free(snapshot_path);

    // Read snapshot file
    const content = std.fs.cwd().readFileAlloc(allocator, snapshot_path, 10 * 1024 * 1024) catch return 0;
    defer allocator.free(content);

    if (content.len == 0) return 0;

    // Parse JSON array
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return 0;
    defer parsed.deinit();

    const array = switch (parsed.value) {
        .array => |a| a,
        else => return 0,
    };

    var hydrated: usize = 0;
    for (array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const key_val = obj.get("key") orelse continue;
        const content_val = obj.get("content") orelse continue;

        const key = switch (key_val) {
            .string => |s| s,
            else => continue,
        };
        const entry_content = switch (content_val) {
            .string => |s| s,
            else => continue,
        };

        // Determine category
        var category: MemoryCategory = .core;
        if (obj.get("category")) |cat_val| {
            const cat_str = switch (cat_val) {
                .string => |s| s,
                else => "core",
            };
            category = MemoryCategory.fromString(cat_str);
        }

        mem.store(key, entry_content, category, null) catch continue;
        hydrated += 1;
    }

    return hydrated;
}

// ── Should hydrate ────────────────────────────────────────────────

/// Check if we should auto-hydrate on startup.
/// Returns true if memory is empty but snapshot file exists.
pub fn shouldHydrate(allocator: std.mem.Allocator, mem: ?Memory, workspace_dir: []const u8) bool {
    // Check if memory is empty
    if (mem) |m| {
        const count = m.count() catch 0;
        if (count > 0) return false;
    }

    // Check if snapshot file exists
    const snapshot_path = std.fs.path.join(allocator, &.{ workspace_dir, SNAPSHOT_FILENAME }) catch return false;
    defer allocator.free(snapshot_path);

    std.fs.cwd().access(snapshot_path, .{}) catch return false;
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────

test "shouldHydrate no memory no snapshot" {
    try std.testing.expect(!shouldHydrate(std.testing.allocator, null, "/nonexistent"));
}

test "shouldHydrate with non-empty memory" {
    // Create an in-memory SQLite for test
    const sqlite = @import("sqlite.zig");
    var mem_impl = try sqlite.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    // Store something
    try mem.store("test", "data", .core, null);

    // Should not hydrate because memory is not empty
    try std.testing.expect(!shouldHydrate(std.testing.allocator, mem, "/nonexistent"));
}

test "exportSnapshot returns zero for empty memory" {
    const sqlite = @import("sqlite.zig");
    var mem_impl = try sqlite.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    const count = try exportSnapshot(std.testing.allocator, mem, "/tmp/yc_snapshot_test_nonexist");
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "SNAPSHOT_FILENAME is correct" {
    try std.testing.expectEqualStrings("MEMORY_SNAPSHOT.json", SNAPSHOT_FILENAME);
}
