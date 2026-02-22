//! SQLite-backed persistent memory — the brain.
//!
//! Features:
//! - Core memories table with CRUD
//! - FTS5 full-text search with BM25 scoring
//! - FTS5 sync triggers (insert/update/delete)
//! - Upsert semantics (ON CONFLICT DO UPDATE)
//! - Session-scoped memory isolation via session_id
//! - Session message storage (legacy compat)
//! - KV store for settings

const std = @import("std");
const root = @import("root.zig");
const Memory = root.Memory;
const MemoryCategory = root.MemoryCategory;
const MemoryEntry = root.MemoryEntry;

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SQLITE_STATIC: c.sqlite3_destructor_type = null;

pub const SqliteMemory = struct {
    db: ?*c.sqlite3,
    allocator: std.mem.Allocator,

    const Self = @This();
    const MMR_LAMBDA: f64 = 0.72;
    const TEMPORAL_DECAY_HALF_LIFE_DAYS: f64 = 30.0;
    const MAX_RECALL_CANDIDATE_MULTIPLIER: usize = 4;
    const MIN_RECALL_CANDIDATES: usize = 24;
    const MAX_RECALL_CANDIDATES: usize = 128;
    const LN_2: f64 = 0.6931471805599453;

    pub fn init(allocator: std.mem.Allocator, db_path: [*:0]const u8) !Self {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }

        var self_ = Self{ .db = db, .allocator = allocator };
        try self_.configurePragmas();
        try self_.migrate();
        try self_.migrateSessionId();
        return self_;
    }

    pub fn deinit(self: *Self) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    fn configurePragmas(self: *Self) !void {
        const pragmas =
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA synchronous  = NORMAL;
            \\PRAGMA temp_store   = MEMORY;
            \\PRAGMA cache_size   = -2000;
        ;
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, pragmas, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| c.sqlite3_free(msg);
            return error.MigrationFailed;
        }
    }

    fn migrate(self: *Self) !void {
        const sql =
            \\-- Core memories table
            \\CREATE TABLE IF NOT EXISTS memories (
            \\  id         TEXT PRIMARY KEY,
            \\  key        TEXT NOT NULL UNIQUE,
            \\  content    TEXT NOT NULL,
            \\  category   TEXT NOT NULL DEFAULT 'core',
            \\  session_id TEXT,
            \\  created_at TEXT NOT NULL,
            \\  updated_at TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_memories_category ON memories(category);
            \\CREATE INDEX IF NOT EXISTS idx_memories_key ON memories(key);
            \\CREATE INDEX IF NOT EXISTS idx_memories_session ON memories(session_id);
            \\
            \\-- FTS5 full-text search (BM25 scoring)
            \\CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
            \\  key, content, content=memories, content_rowid=rowid
            \\);
            \\
            \\-- FTS5 triggers: keep in sync with memories table
            \\CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
            \\  INSERT INTO memories_fts(rowid, key, content)
            \\  VALUES (new.rowid, new.key, new.content);
            \\END;
            \\CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
            \\  INSERT INTO memories_fts(memories_fts, rowid, key, content)
            \\  VALUES ('delete', old.rowid, old.key, old.content);
            \\END;
            \\CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
            \\  INSERT INTO memories_fts(memories_fts, rowid, key, content)
            \\  VALUES ('delete', old.rowid, old.key, old.content);
            \\  INSERT INTO memories_fts(rowid, key, content)
            \\  VALUES (new.rowid, new.key, new.content);
            \\END;
            \\
            \\-- Legacy tables for backward compat
            \\CREATE TABLE IF NOT EXISTS messages (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  session_id TEXT NOT NULL,
            \\  role TEXT NOT NULL,
            \\  content TEXT NOT NULL,
            \\  created_at TEXT DEFAULT (datetime('now'))
            \\);
            \\CREATE TABLE IF NOT EXISTS sessions (
            \\  id TEXT PRIMARY KEY,
            \\  provider TEXT,
            \\  model TEXT,
            \\  created_at TEXT DEFAULT (datetime('now')),
            \\  updated_at TEXT DEFAULT (datetime('now'))
            \\);
            \\CREATE TABLE IF NOT EXISTS kv (
            \\  key TEXT PRIMARY KEY,
            \\  value TEXT NOT NULL
            \\);
            \\
            \\-- Embedding cache for vector search
            \\CREATE TABLE IF NOT EXISTS embedding_cache (
            \\  content_hash TEXT PRIMARY KEY,
            \\  embedding    BLOB NOT NULL,
            \\  created_at   TEXT NOT NULL DEFAULT (datetime('now'))
            \\);
            \\
            \\-- Embeddings linked to memory entries
            \\CREATE TABLE IF NOT EXISTS memory_embeddings (
            \\  memory_key  TEXT PRIMARY KEY,
            \\  embedding   BLOB NOT NULL,
            \\  updated_at  TEXT NOT NULL DEFAULT (datetime('now')),
            \\  FOREIGN KEY (memory_key) REFERENCES memories(key) ON DELETE CASCADE
            \\);
        ;
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| c.sqlite3_free(msg);
            return error.MigrationFailed;
        }
    }

    /// Migration: add session_id column to existing databases that lack it.
    /// Safe to run repeatedly — ALTER TABLE fails gracefully if column already exists.
    pub fn migrateSessionId(self: *Self) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(
            self.db,
            "ALTER TABLE memories ADD COLUMN session_id TEXT;",
            null,
            null,
            &err_msg,
        );
        if (rc != c.SQLITE_OK) {
            // "duplicate column name" is expected on databases that already have the column
            if (err_msg) |msg| c.sqlite3_free(msg);
        }
        // Ensure index exists regardless
        var err_msg2: [*c]u8 = null;
        const rc2 = c.sqlite3_exec(
            self.db,
            "CREATE INDEX IF NOT EXISTS idx_memories_session ON memories(session_id);",
            null,
            null,
            &err_msg2,
        );
        if (rc2 != c.SQLITE_OK) {
            if (err_msg2) |msg| c.sqlite3_free(msg);
        }
    }

    // ── Memory trait implementation ────────────────────────────────

    fn implName(_: *anyopaque) []const u8 {
        return "sqlite";
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const now = getNowTimestamp(self_.allocator) catch return error.StepFailed;
        defer self_.allocator.free(now);

        const id = generateId(self_.allocator) catch return error.StepFailed;
        defer self_.allocator.free(id);

        const cat_str = category.toString();

        const sql = "INSERT INTO memories (id, key, content, category, session_id, created_at, updated_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) " ++
            "ON CONFLICT(key) DO UPDATE SET " ++
            "content = excluded.content, " ++
            "category = excluded.category, " ++
            "session_id = excluded.session_id, " ++
            "updated_at = excluded.updated_at";

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self_.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, key.ptr, @intCast(key.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, content.ptr, @intCast(content.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, cat_str.ptr, @intCast(cat_str.len), SQLITE_STATIC);
        if (session_id) |sid| {
            _ = c.sqlite3_bind_text(stmt, 5, sid.ptr, @intCast(sid.len), SQLITE_STATIC);
        } else {
            _ = c.sqlite3_bind_null(stmt, 5);
        }
        _ = c.sqlite3_bind_text(stmt, 6, now.ptr, @intCast(now.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 7, now.ptr, @intCast(now.len), SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return error.StepFailed;
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        if (limit == 0) return allocator.alloc(MemoryEntry, 0);

        const trimmed = std.mem.trim(u8, query, " \t\n\r");
        if (trimmed.len == 0) return allocator.alloc(MemoryEntry, 0);

        const expanded_query = try expandQueryForSearch(allocator, trimmed);
        defer allocator.free(expanded_query);
        const effective_query = if (expanded_query.len > 0) expanded_query else trimmed;

        const candidate_limit = computeCandidateLimit(limit);

        const fts_results = try fts5Search(self_, allocator, effective_query, candidate_limit, session_id);
        if (fts_results.len > 0) {
            return try rerankRecallResults(allocator, fts_results, limit);
        }

        allocator.free(fts_results);
        const like_results = try likeSearch(self_, allocator, effective_query, candidate_limit, session_id);
        if (like_results.len == 0) return like_results;
        return try rerankRecallResults(allocator, like_results, limit);
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const sql = "SELECT id, key, content, category, created_at, session_id FROM memories WHERE key = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self_.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            return try readEntryFromRow(stmt.?, allocator);
        }
        return null;
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?MemoryCategory, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        var entries: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        if (category) |cat| {
            const cat_str = cat.toString();
            const sql = "SELECT id, key, content, category, created_at, session_id FROM memories " ++
                "WHERE category = ?1 ORDER BY updated_at DESC";
            var stmt: ?*c.sqlite3_stmt = null;
            var rc = c.sqlite3_prepare_v2(self_.db, sql, -1, &stmt, null);
            if (rc != c.SQLITE_OK) return error.PrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);

            _ = c.sqlite3_bind_text(stmt, 1, cat_str.ptr, @intCast(cat_str.len), SQLITE_STATIC);

            while (true) {
                rc = c.sqlite3_step(stmt);
                if (rc == c.SQLITE_ROW) {
                    const entry = try readEntryFromRow(stmt.?, allocator);
                    if (session_id) |sid| {
                        if (entry.session_id == null or !std.mem.eql(u8, entry.session_id.?, sid)) {
                            entry.deinit(allocator);
                            continue;
                        }
                    }
                    try entries.append(allocator, entry);
                } else break;
            }
        } else {
            const sql = "SELECT id, key, content, category, created_at, session_id FROM memories ORDER BY updated_at DESC";
            var stmt: ?*c.sqlite3_stmt = null;
            var rc = c.sqlite3_prepare_v2(self_.db, sql, -1, &stmt, null);
            if (rc != c.SQLITE_OK) return error.PrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);

            while (true) {
                rc = c.sqlite3_step(stmt);
                if (rc == c.SQLITE_ROW) {
                    const entry = try readEntryFromRow(stmt.?, allocator);
                    if (session_id) |sid| {
                        if (entry.session_id == null or !std.mem.eql(u8, entry.session_id.?, sid)) {
                            entry.deinit(allocator);
                            continue;
                        }
                    }
                    try entries.append(allocator, entry);
                } else break;
            }
        }

        return entries.toOwnedSlice(allocator);
    }

    fn implForget(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const sql = "DELETE FROM memories WHERE key = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self_.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return error.StepFailed;

        return c.sqlite3_changes(self_.db) > 0;
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const sql = "SELECT COUNT(*) FROM memories";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self_.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            const count = c.sqlite3_column_int64(stmt, 0);
            return @intCast(count);
        }
        return 0;
    }

    fn implHealthCheck(ptr: *anyopaque) bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self_.db, "SELECT 1", null, null, &err_msg);
        if (err_msg) |msg| c.sqlite3_free(msg);
        return rc == c.SQLITE_OK;
    }

    fn implDeinit(ptr: *anyopaque) void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        self_.deinit();
    }

    pub const vtable = Memory.VTable{
        .name = &implName,
        .store = &implStore,
        .recall = &implRecall,
        .get = &implGet,
        .list = &implList,
        .forget = &implForget,
        .count = &implCount,
        .healthCheck = &implHealthCheck,
        .deinit = &implDeinit,
    };

    pub fn memory(self: *Self) Memory {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    // ── Legacy helpers ─────────────────────────────────────────────

    pub fn saveMessage(self: *Self, session_id: []const u8, role_str: []const u8, content: []const u8) !void {
        const sql = "INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, role_str.ptr, @intCast(role_str.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, content.ptr, @intCast(content.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
    }

    /// A single persisted message entry (role + content).
    pub const MessageEntry = struct {
        role: []const u8,
        content: []const u8,
    };

    /// Load all messages for a session, ordered by creation time.
    /// Caller owns the returned slice and all strings within it.
    pub fn loadMessages(self: *Self, allocator: std.mem.Allocator, session_id: []const u8) ![]MessageEntry {
        const sql = "SELECT role, content FROM messages WHERE session_id = ? ORDER BY id ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), SQLITE_STATIC);

        var list: std.ArrayListUnmanaged(MessageEntry) = .empty;
        errdefer {
            for (list.items) |entry| {
                allocator.free(entry.role);
                allocator.free(entry.content);
            }
            list.deinit(allocator);
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const role_ptr = c.sqlite3_column_text(stmt, 0);
            const role_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const content_ptr = c.sqlite3_column_text(stmt, 1);
            const content_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));

            if (role_ptr == null or content_ptr == null) continue;

            try list.append(allocator, .{
                .role = try allocator.dupe(u8, role_ptr[0..role_len]),
                .content = try allocator.dupe(u8, content_ptr[0..content_len]),
            });
        }

        return list.toOwnedSlice(allocator);
    }

    /// Delete all messages for a session.
    pub fn clearMessages(self: *Self, session_id: []const u8) !void {
        const sql = "DELETE FROM messages WHERE session_id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
    }

    pub fn reindex(self: *Self) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(
            self.db,
            "INSERT INTO memories_fts(memories_fts) VALUES('rebuild');",
            null,
            null,
            &err_msg,
        );
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| c.sqlite3_free(msg);
            return error.StepFailed;
        }
    }

    // ── Internal search helpers ────────────────────────────────────

    fn fts5Search(self_: *Self, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) ![]MemoryEntry {
        // Build FTS5 query: wrap each word in quotes joined by OR
        var fts_query: std.ArrayList(u8) = .empty;
        defer fts_query.deinit(allocator);

        var iter = std.mem.tokenizeAny(u8, query, " \t\n\r");
        var first = true;
        while (iter.next()) |word| {
            if (!first) {
                try fts_query.appendSlice(allocator, " OR ");
            }
            try fts_query.append(allocator, '"');
            for (word) |ch_byte| {
                if (ch_byte == '"') {
                    try fts_query.appendSlice(allocator, "\"\"");
                } else {
                    try fts_query.append(allocator, ch_byte);
                }
            }
            try fts_query.append(allocator, '"');
            first = false;
        }

        if (fts_query.items.len == 0) return allocator.alloc(MemoryEntry, 0);

        const sql =
            "SELECT m.id, m.key, m.content, m.category, m.created_at, m.session_id, bm25(memories_fts) as score, " ++
            "CASE " ++
            "WHEN instr(m.created_at, '-') > 0 THEN CAST(strftime('%s', m.created_at) AS INTEGER) " ++
            "ELSE CAST(m.created_at AS INTEGER) END AS created_epoch " ++
            "FROM memories_fts f " ++
            "JOIN memories m ON m.rowid = f.rowid " ++
            "WHERE memories_fts MATCH ?1 " ++
            "ORDER BY score " ++
            "LIMIT ?2";

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self_.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return allocator.alloc(MemoryEntry, 0);
        defer _ = c.sqlite3_finalize(stmt);

        // Null-terminate the FTS query for sqlite
        try fts_query.append(allocator, 0);
        const fts_z = fts_query.items[0 .. fts_query.items.len - 1];
        _ = c.sqlite3_bind_text(stmt, 1, fts_z.ptr, @intCast(fts_z.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(limit));

        var entries: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        while (true) {
            rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_ROW) {
                const score_raw = c.sqlite3_column_double(stmt.?, 6);
                const created_epoch = c.sqlite3_column_int64(stmt.?, 7);
                var entry = try readEntryFromRow(stmt.?, allocator);
                // Filter by session_id if requested
                if (session_id) |sid| {
                    if (entry.session_id == null or !std.mem.eql(u8, entry.session_id.?, sid)) {
                        entry.deinit(allocator);
                        continue;
                    }
                }
                // BM25 returns lower-is-better values (often negative); convert to higher-is-better.
                entry.score = computeTemporalRelevance(-score_raw, entry, created_epoch);
                try entries.append(allocator, entry);
            } else break;
        }

        return entries.toOwnedSlice(allocator);
    }

    fn likeSearch(self_: *Self, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) ![]MemoryEntry {
        var keywords: std.ArrayList([]const u8) = .empty;
        defer keywords.deinit(allocator);

        var iter = std.mem.tokenizeAny(u8, query, " \t\n\r");
        while (iter.next()) |word| {
            try keywords.append(allocator, word);
        }

        if (keywords.items.len == 0) return allocator.alloc(MemoryEntry, 0);

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);

        try sql_buf.appendSlice(
            allocator,
            "SELECT id, key, content, category, created_at, session_id, " ++
                "CASE WHEN instr(created_at, '-') > 0 THEN CAST(strftime('%s', created_at) AS INTEGER) ELSE CAST(created_at AS INTEGER) END AS created_epoch " ++
                "FROM memories WHERE ",
        );

        for (keywords.items, 0..) |_, i| {
            if (i > 0) try sql_buf.appendSlice(allocator, " OR ");
            try sql_buf.appendSlice(allocator, "(content LIKE ?");
            try appendInt(&sql_buf, allocator, i * 2 + 1);
            try sql_buf.appendSlice(allocator, " OR key LIKE ?");
            try appendInt(&sql_buf, allocator, i * 2 + 2);
            try sql_buf.appendSlice(allocator, ")");
        }

        try sql_buf.appendSlice(allocator, " ORDER BY updated_at DESC LIMIT ?");
        try appendInt(&sql_buf, allocator, keywords.items.len * 2 + 1);
        try sql_buf.append(allocator, 0);

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self_.db, sql_buf.items.ptr, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return allocator.alloc(MemoryEntry, 0);
        defer _ = c.sqlite3_finalize(stmt);

        var like_bufs: std.ArrayList([]u8) = .empty;
        defer {
            for (like_bufs.items) |buf| allocator.free(buf);
            like_bufs.deinit(allocator);
        }

        for (keywords.items, 0..) |word, i| {
            const like = try std.fmt.allocPrint(allocator, "%{s}%", .{word});
            try like_bufs.append(allocator, like);
            _ = c.sqlite3_bind_text(stmt, @intCast(i * 2 + 1), like.ptr, @intCast(like.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, @intCast(i * 2 + 2), like.ptr, @intCast(like.len), SQLITE_STATIC);
        }
        _ = c.sqlite3_bind_int64(stmt, @intCast(keywords.items.len * 2 + 1), @intCast(limit));

        var entries: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        while (true) {
            rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_ROW) {
                const created_epoch = c.sqlite3_column_int64(stmt.?, 6);
                var entry = try readEntryFromRow(stmt.?, allocator);
                // Filter by session_id if requested
                if (session_id) |sid| {
                    if (entry.session_id == null or !std.mem.eql(u8, entry.session_id.?, sid)) {
                        entry.deinit(allocator);
                        continue;
                    }
                }
                entry.score = computeTemporalRelevance(1.0, entry, created_epoch);
                try entries.append(allocator, entry);
            } else break;
        }

        return entries.toOwnedSlice(allocator);
    }

    // ── Utility functions ──────────────────────────────────────────

    fn readEntryFromRow(stmt: *c.sqlite3_stmt, allocator: std.mem.Allocator) !MemoryEntry {
        const id = try dupeColumnText(stmt, 0, allocator);
        errdefer allocator.free(id);
        const key = try dupeColumnText(stmt, 1, allocator);
        errdefer allocator.free(key);
        const content = try dupeColumnText(stmt, 2, allocator);
        errdefer allocator.free(content);
        const cat_str = try dupeColumnText(stmt, 3, allocator);
        const timestamp = try dupeColumnText(stmt, 4, allocator);
        errdefer allocator.free(timestamp);
        const sid = try dupeColumnTextNullable(stmt, 5, allocator);
        errdefer if (sid) |s| allocator.free(s);

        const category = blk: {
            if (std.mem.eql(u8, cat_str, "core")) {
                allocator.free(cat_str);
                break :blk MemoryCategory.core;
            } else if (std.mem.eql(u8, cat_str, "daily")) {
                allocator.free(cat_str);
                break :blk MemoryCategory.daily;
            } else if (std.mem.eql(u8, cat_str, "conversation")) {
                allocator.free(cat_str);
                break :blk MemoryCategory.conversation;
            } else {
                break :blk MemoryCategory{ .custom = cat_str };
            }
        };

        return MemoryEntry{
            .id = id,
            .key = key,
            .content = content,
            .category = category,
            .timestamp = timestamp,
            .session_id = sid,
            .score = null,
        };
    }

    fn dupeColumnText(stmt: *c.sqlite3_stmt, col: c_int, allocator: std.mem.Allocator) ![]u8 {
        const raw = c.sqlite3_column_text(stmt, col);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        if (raw == null or len == 0) {
            return allocator.dupe(u8, "");
        }
        const slice: []const u8 = @as([*]const u8, @ptrCast(raw))[0..len];
        return allocator.dupe(u8, slice);
    }

    /// Like dupeColumnText but returns null when the column value is SQL NULL.
    fn dupeColumnTextNullable(stmt: *c.sqlite3_stmt, col: c_int, allocator: std.mem.Allocator) !?[]u8 {
        if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) {
            return null;
        }
        const raw = c.sqlite3_column_text(stmt, col);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        if (raw == null) {
            return null;
        }
        const slice: []const u8 = @as([*]const u8, @ptrCast(raw))[0..len];
        return try allocator.dupe(u8, slice);
    }

    fn appendInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
        var tmp: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return error.PrepareFailed;
        try buf.appendSlice(allocator, s);
    }

    fn getNowTimestamp(allocator: std.mem.Allocator) ![]u8 {
        const ts = std.time.timestamp();
        return std.fmt.allocPrint(allocator, "{d}", .{ts});
    }

    fn generateId(allocator: std.mem.Allocator) ![]u8 {
        const ts = std.time.nanoTimestamp();
        var buf: [16]u8 = undefined;
        std.crypto.random.bytes(&buf);
        const rand_hi = std.mem.readInt(u64, buf[0..8], .little);
        const rand_lo = std.mem.readInt(u64, buf[8..16], .little);
        return std.fmt.allocPrint(allocator, "{d}-{x}-{x}", .{ ts, rand_hi, rand_lo });
    }

    fn computeCandidateLimit(limit: usize) usize {
        if (limit == 0) return 0;
        const scaled = limit *| MAX_RECALL_CANDIDATE_MULTIPLIER;
        const with_min = @max(scaled, MIN_RECALL_CANDIDATES);
        return @min(with_min, MAX_RECALL_CANDIDATES);
    }

    fn computeTemporalRelevance(base_score: f64, entry: MemoryEntry, created_epoch: i64) f64 {
        const safe_base = if (std.math.isFinite(base_score) and base_score > 0.0) base_score else 0.0;
        if (safe_base <= 0.0) return 0.0;

        // Core memories are treated as evergreen and are not time-decayed.
        const decay = switch (entry.category) {
            .core => 1.0,
            else => computeTemporalDecayFactor(created_epoch),
        };
        return safe_base * decay;
    }

    fn computeTemporalDecayFactor(created_epoch: i64) f64 {
        if (created_epoch <= 0) return 1.0;

        const now_ts = std.time.timestamp();
        if (now_ts <= created_epoch) return 1.0;

        const age_seconds = now_ts - created_epoch;
        const age_days = @as(f64, @floatFromInt(age_seconds)) / 86400.0;
        const raw = @exp((-LN_2 * age_days) / TEMPORAL_DECAY_HALF_LIFE_DAYS);
        if (!std.math.isFinite(raw)) return 1.0;
        return @max(0.0, @min(1.0, raw));
    }

    fn rerankRecallResults(allocator: std.mem.Allocator, entries: []MemoryEntry, limit: usize) ![]MemoryEntry {
        errdefer {
            for (entries) |*entry| entry.deinit(allocator);
            allocator.free(entries);
        }

        if (entries.len == 0) return entries;

        const target = @min(limit, entries.len);
        if (target == 0) {
            for (entries) |*entry| entry.deinit(allocator);
            allocator.free(entries);
            return allocator.alloc(MemoryEntry, 0);
        }

        var base_scores = try allocator.alloc(f64, entries.len);
        defer allocator.free(base_scores);

        var max_base: f64 = 0.0;
        for (entries, 0..) |entry, i| {
            const raw_score = entry.score orelse 0.0;
            const safe = if (std.math.isFinite(raw_score) and raw_score > 0.0) raw_score else 0.0;
            base_scores[i] = safe;
            max_base = @max(max_base, safe);
        }

        if (max_base < std.math.floatEps(f64)) {
            for (base_scores) |*score| score.* = 1.0;
        } else {
            for (base_scores) |*score| score.* /= max_base;
        }

        var token_sets = try allocator.alloc([]u64, entries.len);
        defer {
            for (token_sets) |set| allocator.free(set);
            allocator.free(token_sets);
        }
        for (entries, 0..) |entry, i| {
            token_sets[i] = try buildEntryTokenSet(allocator, entry);
        }

        var selected_indices = try allocator.alloc(usize, target);
        defer allocator.free(selected_indices);
        var selected_mask = try allocator.alloc(bool, entries.len);
        defer allocator.free(selected_mask);
        @memset(selected_mask, false);

        var ranking_scores = try allocator.alloc(f64, entries.len);
        defer allocator.free(ranking_scores);
        @memset(ranking_scores, 0.0);

        var selected_count: usize = 0;
        while (selected_count < target) {
            var best_idx: ?usize = null;
            var best_score = -std.math.inf(f64);

            for (entries, 0..) |_, i| {
                if (selected_mask[i]) continue;

                var max_similarity: f64 = 0.0;
                for (selected_indices[0..selected_count]) |selected| {
                    max_similarity = @max(max_similarity, jaccardSimilarity(token_sets[i], token_sets[selected]));
                }

                const mmr_score = if (selected_count == 0)
                    base_scores[i]
                else
                    (MMR_LAMBDA * base_scores[i]) - ((1.0 - MMR_LAMBDA) * max_similarity);

                if (mmr_score > best_score) {
                    best_score = mmr_score;
                    best_idx = i;
                }
            }

            if (best_idx == null) break;

            const idx = best_idx.?;
            selected_indices[selected_count] = idx;
            selected_mask[idx] = true;
            ranking_scores[idx] = best_score;
            selected_count += 1;
        }

        var moved_mask = try allocator.alloc(bool, entries.len);
        defer allocator.free(moved_mask);
        @memset(moved_mask, false);

        const reranked = try allocator.alloc(MemoryEntry, selected_count);
        for (0..selected_count) |out_idx| {
            const src_idx = selected_indices[out_idx];
            moved_mask[src_idx] = true;
            var entry = entries[src_idx];
            entry.score = ranking_scores[src_idx];
            reranked[out_idx] = entry;
        }

        for (entries, 0..) |*entry, i| {
            if (!moved_mask[i]) entry.deinit(allocator);
        }
        allocator.free(entries);

        return reranked;
    }

    fn buildEntryTokenSet(allocator: std.mem.Allocator, entry: MemoryEntry) ![]u64 {
        var hashes: std.ArrayList(u64) = .empty;
        defer hashes.deinit(allocator);

        try appendTokenHashes(allocator, &hashes, entry.key);
        try appendTokenHashes(allocator, &hashes, entry.content);

        return hashes.toOwnedSlice(allocator);
    }

    fn appendTokenHashes(allocator: std.mem.Allocator, hashes: *std.ArrayList(u64), text: []const u8) !void {
        var token_buf: std.ArrayList(u8) = .empty;
        defer token_buf.deinit(allocator);

        for (text) |ch| {
            if (isTokenByte(ch)) {
                try token_buf.append(allocator, toLowerAscii(ch));
            } else {
                try flushTokenBuffer(allocator, hashes, &token_buf);
            }
        }
        try flushTokenBuffer(allocator, hashes, &token_buf);
    }

    fn flushTokenBuffer(allocator: std.mem.Allocator, hashes: *std.ArrayList(u64), token_buf: *std.ArrayList(u8)) !void {
        if (token_buf.items.len == 0) return;
        defer token_buf.clearRetainingCapacity();

        // Ignore trivial one-byte ASCII tokens ("a", "x", "1") to reduce noise.
        if (token_buf.items.len < 2 and isAsciiSlice(token_buf.items)) return;

        const token_hash = std.hash.Wyhash.hash(0, token_buf.items);
        if (!containsHash(hashes.items, token_hash)) {
            try hashes.append(allocator, token_hash);
        }
    }

    fn jaccardSimilarity(a: []const u64, b: []const u64) f64 {
        if (a.len == 0 or b.len == 0) return 0.0;

        var intersection: usize = 0;
        for (a) |lhs| {
            if (containsHash(b, lhs)) intersection += 1;
        }

        const union_count = a.len + b.len - intersection;
        if (union_count == 0) return 0.0;
        return @as(f64, @floatFromInt(intersection)) / @as(f64, @floatFromInt(union_count));
    }

    fn containsHash(values: []const u64, needle: u64) bool {
        for (values) |value| {
            if (value == needle) return true;
        }
        return false;
    }

    fn expandQueryForSearch(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
        var tokens: std.ArrayList([]u8) = .empty;
        defer {
            for (tokens.items) |token| allocator.free(token);
            tokens.deinit(allocator);
        }

        var iter = std.mem.tokenizeAny(u8, query, " \t\n\r");
        while (iter.next()) |word| {
            try appendExpandedToken(allocator, &tokens, word);
            var part_iter = std.mem.tokenizeAny(u8, word, "-_/.:");
            while (part_iter.next()) |part| {
                try appendExpandedToken(allocator, &tokens, part);
            }
        }

        if (tokens.items.len == 0) return try allocator.dupe(u8, query);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        for (tokens.items, 0..) |token, i| {
            if (i > 0) try out.append(allocator, ' ');
            try out.appendSlice(allocator, token);
        }
        return out.toOwnedSlice(allocator);
    }

    fn appendExpandedToken(allocator: std.mem.Allocator, tokens: *std.ArrayList([]u8), raw: []const u8) !void {
        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(allocator);

        for (raw) |ch| {
            if (isTokenByte(ch)) {
                try normalized.append(allocator, toLowerAscii(ch));
            }
        }

        if (normalized.items.len == 0) return;
        if (normalized.items.len < 2 and isAsciiSlice(normalized.items)) return;
        if (isStopWord(normalized.items)) return;

        for (tokens.items) |existing| {
            if (std.mem.eql(u8, existing, normalized.items)) return;
        }

        try tokens.append(allocator, try allocator.dupe(u8, normalized.items));
    }

    fn isStopWord(token: []const u8) bool {
        if (!isAsciiSlice(token)) return false;
        const stop_words = [_][]const u8{
            "a",    "an",   "the",  "and",  "or",  "to",  "of",   "for",
            "in",   "on",   "at",   "is",   "are", "was", "were", "be",
            "this", "that", "with", "from", "as",  "by",  "it",
        };
        for (stop_words) |word| {
            if (std.mem.eql(u8, token, word)) return true;
        }
        return false;
    }

    fn isTokenByte(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch >= 0x80;
    }

    fn toLowerAscii(ch: u8) u8 {
        return if (ch < 0x80) std.ascii.toLower(ch) else ch;
    }

    fn isAsciiSlice(text: []const u8) bool {
        for (text) |ch| {
            if (ch >= 0x80) return false;
        }
        return true;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "sqlite memory init with in-memory db" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    try mem.saveMessage("test-session", "user", "hello");
}

test "sqlite name" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();
    try std.testing.expectEqualStrings("sqlite", m.name());
}

test "sqlite health check" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();
    try std.testing.expect(m.healthCheck());
}

test "sqlite store and get" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("user_lang", "Prefers Zig", .core, null);

    const entry = try m.get(std.testing.allocator, "user_lang");
    try std.testing.expect(entry != null);
    defer entry.?.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("user_lang", entry.?.key);
    try std.testing.expectEqualStrings("Prefers Zig", entry.?.content);
    try std.testing.expect(entry.?.category.eql(.core));
}

test "sqlite store upsert" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("pref", "likes Zig", .core, null);
    try m.store("pref", "loves Zig", .core, null);

    const entry = try m.get(std.testing.allocator, "pref");
    try std.testing.expect(entry != null);
    defer entry.?.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("loves Zig", entry.?.content);

    const cnt = try m.count();
    try std.testing.expectEqual(@as(usize, 1), cnt);
}

test "sqlite recall keyword" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "Zig is fast and safe", .core, null);
    try m.store("b", "Python is interpreted", .core, null);
    try m.store("c", "Zig has comptime", .core, null);

    const results = try m.recall(std.testing.allocator, "Zig", 10, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.content, "Zig") != null);
    }
}

test "sqlite recall no match" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "Zig rocks", .core, null);

    const results = try m.recall(std.testing.allocator, "javascript", 10, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "sqlite recall empty query" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "data", .core, null);

    const results = try m.recall(std.testing.allocator, "", 10, null);
    defer root.freeEntries(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "sqlite recall whitespace query" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "data", .core, null);

    const results = try m.recall(std.testing.allocator, "   ", 10, null);
    defer root.freeEntries(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "sqlite forget" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("temp", "temporary data", .conversation, null);
    try std.testing.expectEqual(@as(usize, 1), try m.count());

    const removed = try m.forget("temp");
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 0), try m.count());
}

test "sqlite forget nonexistent" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    const removed = try m.forget("nope");
    try std.testing.expect(!removed);
}

test "sqlite list all" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "one", .core, null);
    try m.store("b", "two", .daily, null);
    try m.store("c", "three", .conversation, null);

    const all = try m.list(std.testing.allocator, null, null);
    defer root.freeEntries(std.testing.allocator, all);
    try std.testing.expectEqual(@as(usize, 3), all.len);
}

test "sqlite list by category" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "core1", .core, null);
    try m.store("b", "core2", .core, null);
    try m.store("c", "daily1", .daily, null);

    const core_list = try m.list(std.testing.allocator, .core, null);
    defer root.freeEntries(std.testing.allocator, core_list);
    try std.testing.expectEqual(@as(usize, 2), core_list.len);

    const daily_list = try m.list(std.testing.allocator, .daily, null);
    defer root.freeEntries(std.testing.allocator, daily_list);
    try std.testing.expectEqual(@as(usize, 1), daily_list.len);
}

test "sqlite count empty" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();
    try std.testing.expectEqual(@as(usize, 0), try m.count());
}

test "sqlite get nonexistent" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    const entry = try m.get(std.testing.allocator, "nope");
    try std.testing.expect(entry == null);
}

test "sqlite category roundtrip" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k0", "v0", .core, null);
    try m.store("k1", "v1", .daily, null);
    try m.store("k2", "v2", .conversation, null);
    try m.store("k3", "v3", .{ .custom = "project" }, null);

    const e0 = (try m.get(std.testing.allocator, "k0")).?;
    defer e0.deinit(std.testing.allocator);
    try std.testing.expect(e0.category.eql(.core));

    const e1 = (try m.get(std.testing.allocator, "k1")).?;
    defer e1.deinit(std.testing.allocator);
    try std.testing.expect(e1.category.eql(.daily));

    const e2 = (try m.get(std.testing.allocator, "k2")).?;
    defer e2.deinit(std.testing.allocator);
    try std.testing.expect(e2.category.eql(.conversation));

    const e3 = (try m.get(std.testing.allocator, "k3")).?;
    defer e3.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("project", e3.category.custom);
}

test "sqlite forget then recall no ghost results" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("ghost", "phantom memory content", .core, null);
    _ = try m.forget("ghost");

    const results = try m.recall(std.testing.allocator, "phantom memory", 10, null);
    defer root.freeEntries(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "sqlite forget and re-store same key" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("cycle", "version 1", .core, null);
    _ = try m.forget("cycle");
    try m.store("cycle", "version 2", .core, null);

    const entry = (try m.get(std.testing.allocator, "cycle")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("version 2", entry.content);
    try std.testing.expectEqual(@as(usize, 1), try m.count());
}

test "sqlite store empty content" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("empty", "", .core, null);
    const entry = (try m.get(std.testing.allocator, "empty")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", entry.content);
}

test "sqlite store empty key" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("", "content for empty key", .core, null);
    const entry = (try m.get(std.testing.allocator, "")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("content for empty key", entry.content);
}

test "sqlite recall results have scores" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("s1", "scored result test", .core, null);

    const results = try m.recall(std.testing.allocator, "scored", 10, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expect(results.len > 0);
    for (results) |entry| {
        try std.testing.expect(entry.score != null);
    }
}

test "sqlite reindex" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("r1", "reindex test alpha", .core, null);
    try m.store("r2", "reindex test beta", .core, null);

    try mem.reindex();

    const results = try m.recall(std.testing.allocator, "reindex", 10, null);
    defer root.freeEntries(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "sqlite recall with sql injection attempt" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("safe", "normal content", .core, null);

    const results = try m.recall(std.testing.allocator, "'; DROP TABLE memories; --", 10, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 1), try m.count());
}

test "sqlite schema has fts5 table" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    const sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='memories_fts'";
    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(mem.db, sql, -1, &stmt, null);
    try std.testing.expectEqual(c.SQLITE_OK, rc);
    defer _ = c.sqlite3_finalize(stmt);

    rc = c.sqlite3_step(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, rc);
    const count = c.sqlite3_column_int64(stmt, 0);
    try std.testing.expectEqual(@as(i64, 1), count);
}

test "sqlite fts5 syncs on insert" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("test_key", "unique_searchterm_xyz", .core, null);

    const sql = "SELECT COUNT(*) FROM memories_fts WHERE memories_fts MATCH '\"unique_searchterm_xyz\"'";
    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(mem.db, sql, -1, &stmt, null);
    try std.testing.expectEqual(c.SQLITE_OK, rc);
    defer _ = c.sqlite3_finalize(stmt);

    rc = c.sqlite3_step(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, rc);
    try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(stmt, 0));
}

test "sqlite fts5 syncs on delete" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("del_key", "deletable_content_abc", .core, null);
    _ = try m.forget("del_key");

    const sql = "SELECT COUNT(*) FROM memories_fts WHERE memories_fts MATCH '\"deletable_content_abc\"'";
    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(mem.db, sql, -1, &stmt, null);
    try std.testing.expectEqual(c.SQLITE_OK, rc);
    defer _ = c.sqlite3_finalize(stmt);

    rc = c.sqlite3_step(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, rc);
    try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stmt, 0));
}

test "sqlite fts5 syncs on update" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("upd_key", "original_content_111", .core, null);
    try m.store("upd_key", "updated_content_222", .core, null);

    {
        const sql = "SELECT COUNT(*) FROM memories_fts WHERE memories_fts MATCH '\"original_content_111\"'";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(mem.db, sql, -1, &stmt, null);
        try std.testing.expectEqual(c.SQLITE_OK, rc);
        defer _ = c.sqlite3_finalize(stmt);
        rc = c.sqlite3_step(stmt);
        try std.testing.expectEqual(c.SQLITE_ROW, rc);
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stmt, 0));
    }

    {
        const sql = "SELECT COUNT(*) FROM memories_fts WHERE memories_fts MATCH '\"updated_content_222\"'";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(mem.db, sql, -1, &stmt, null);
        try std.testing.expectEqual(c.SQLITE_OK, rc);
        defer _ = c.sqlite3_finalize(stmt);
        rc = c.sqlite3_step(stmt);
        try std.testing.expectEqual(c.SQLITE_ROW, rc);
        try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(stmt, 0));
    }
}

test "sqlite list custom category" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("c1", "custom1", .{ .custom = "project" }, null);
    try m.store("c2", "custom2", .{ .custom = "project" }, null);
    try m.store("c3", "other", .core, null);

    const project = try m.list(std.testing.allocator, .{ .custom = "project" }, null);
    defer root.freeEntries(std.testing.allocator, project);
    try std.testing.expectEqual(@as(usize, 2), project.len);
}

test "sqlite list empty db" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    const all = try m.list(std.testing.allocator, null, null);
    defer root.freeEntries(std.testing.allocator, all);
    try std.testing.expectEqual(@as(usize, 0), all.len);
}

test "sqlite recall matches by key not just content" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("zig_preferences", "User likes systems programming", .core, null);

    const results = try m.recall(std.testing.allocator, "zig", 10, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expect(results.len > 0);
}

test "sqlite recall respects limit" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    for (0..10) |i| {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key_{d}", .{i}) catch continue;
        var content_buf: [64]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "searchable content number {d}", .{i}) catch continue;
        try m.store(key, content, .core, null);
    }

    const results = try m.recall(std.testing.allocator, "searchable", 3, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expect(results.len <= 3);
}

test "sqlite store unicode content" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("unicode_key", "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\xe3\x81\xae\xe3\x83\x86\xe3\x82\xb9\xe3\x83\x88", .core, null);

    const entry = (try m.get(std.testing.allocator, "unicode_key")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\xe3\x81\xae\xe3\x83\x86\xe3\x82\xb9\xe3\x83\x88", entry.content);
}

test "sqlite recall unicode query" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("jp", "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\xe3\x81\xae\xe3\x83\x86\xe3\x82\xb9\xe3\x83\x88", .core, null);

    const results = try m.recall(std.testing.allocator, "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", 10, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expect(results.len > 0);
}

test "sqlite store long content" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    // Build a long string
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    for (0..1000) |_| {
        try buf.appendSlice(std.testing.allocator, "abcdefghij");
    }

    try m.store("long", buf.items, .core, null);
    const entry = (try m.get(std.testing.allocator, "long")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 10000), entry.content.len);
}

test "sqlite multiple categories count" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "one", .core, null);
    try m.store("b", "two", .daily, null);
    try m.store("c", "three", .conversation, null);
    try m.store("d", "four", .{ .custom = "project" }, null);

    try std.testing.expectEqual(@as(usize, 4), try m.count());
}

test "sqlite saveMessage stores messages" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    try mem.saveMessage("session-1", "user", "hello");
    try mem.saveMessage("session-1", "assistant", "hi there");
    try mem.saveMessage("session-2", "user", "another session");

    // Verify messages table has data
    const sql = "SELECT COUNT(*) FROM messages";
    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(mem.db, sql, -1, &stmt, null);
    try std.testing.expectEqual(c.SQLITE_OK, rc);
    defer _ = c.sqlite3_finalize(stmt);

    rc = c.sqlite3_step(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, rc);
    try std.testing.expectEqual(@as(i64, 3), c.sqlite3_column_int64(stmt, 0));
}

test "sqlite store and forget multiple keys" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k1", "v1", .core, null);
    try m.store("k2", "v2", .core, null);
    try m.store("k3", "v3", .core, null);

    try std.testing.expectEqual(@as(usize, 3), try m.count());

    _ = try m.forget("k2");
    try std.testing.expectEqual(@as(usize, 2), try m.count());

    _ = try m.forget("k1");
    _ = try m.forget("k3");
    try std.testing.expectEqual(@as(usize, 0), try m.count());
}

test "sqlite upsert changes category" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("key", "value", .core, null);
    try m.store("key", "new value", .daily, null);

    const entry = (try m.get(std.testing.allocator, "key")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new value", entry.content);
    try std.testing.expect(entry.category.eql(.daily));
}

test "sqlite recall multi-word query" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("zig-lang", "Zig is a systems programming language", .core, null);
    try m.store("rust-lang", "Rust is also a systems language", .core, null);
    try m.store("python-lang", "Python is interpreted", .core, null);

    const results = try m.recall(std.testing.allocator, "systems programming", 10, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expect(results.len >= 1);
}

test "sqlite list returns all entries" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("first", "first entry", .core, null);
    try m.store("second", "second entry", .core, null);
    try m.store("third", "third entry", .core, null);

    const all = try m.list(std.testing.allocator, null, null);
    defer root.freeEntries(std.testing.allocator, all);

    try std.testing.expectEqual(@as(usize, 3), all.len);

    // All keys should be present
    var found_first = false;
    var found_second = false;
    var found_third = false;
    for (all) |entry| {
        if (std.mem.eql(u8, entry.key, "first")) found_first = true;
        if (std.mem.eql(u8, entry.key, "second")) found_second = true;
        if (std.mem.eql(u8, entry.key, "third")) found_third = true;
    }
    try std.testing.expect(found_first);
    try std.testing.expect(found_second);
    try std.testing.expect(found_third);
}

test "sqlite get returns entry with all fields" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("test_key", "test_content", .daily, null);

    const entry = (try m.get(std.testing.allocator, "test_key")).?;
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test_key", entry.key);
    try std.testing.expectEqualStrings("test_content", entry.content);
    try std.testing.expect(entry.category.eql(.daily));
    try std.testing.expect(entry.id.len > 0);
    try std.testing.expect(entry.timestamp.len > 0);
}

test "sqlite recall with quotes in query" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("quotes", "He said \"hello\" to the world", .core, null);

    const results = try m.recall(std.testing.allocator, "hello", 10, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expect(results.len > 0);
}

test "sqlite health check after operations" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k", "v", .core, null);
    _ = try m.forget("k");

    try std.testing.expect(m.healthCheck());
}

test "sqlite kv table exists" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    const sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='kv'";
    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(mem.db, sql, -1, &stmt, null);
    try std.testing.expectEqual(c.SQLITE_OK, rc);
    defer _ = c.sqlite3_finalize(stmt);

    rc = c.sqlite3_step(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, rc);
    try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(stmt, 0));
}

// ── Session ID tests ──────────────────────────────────────────────

test "sqlite store with session_id persists" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k1", "session data", .core, "sess-abc");

    const entry = (try m.get(std.testing.allocator, "k1")).?;
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("session data", entry.content);
    try std.testing.expect(entry.session_id != null);
    try std.testing.expectEqualStrings("sess-abc", entry.session_id.?);
}

test "sqlite store without session_id gives null" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k1", "no session", .core, null);

    const entry = (try m.get(std.testing.allocator, "k1")).?;
    defer entry.deinit(std.testing.allocator);

    try std.testing.expect(entry.session_id == null);
}

test "sqlite recall with session_id filters correctly" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k1", "session A fact", .core, "sess-a");
    try m.store("k2", "session B fact", .core, "sess-b");
    try m.store("k3", "no session fact", .core, null);

    // Recall with session-a filter returns only session-a entry
    const results = try m.recall(std.testing.allocator, "fact", 10, "sess-a");
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("k1", results[0].key);
    try std.testing.expect(results[0].session_id != null);
    try std.testing.expectEqualStrings("sess-a", results[0].session_id.?);
}

test "sqlite recall with null session_id returns all" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k1", "alpha fact", .core, "sess-a");
    try m.store("k2", "beta fact", .core, "sess-b");
    try m.store("k3", "gamma fact", .core, null);

    const results = try m.recall(std.testing.allocator, "fact", 10, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
}

test "sqlite list with session_id filter" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k1", "a1", .core, "sess-a");
    try m.store("k2", "a2", .conversation, "sess-a");
    try m.store("k3", "b1", .core, "sess-b");
    try m.store("k4", "none1", .core, null);

    // List with session-a filter
    const results = try m.list(std.testing.allocator, null, "sess-a");
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |entry| {
        try std.testing.expect(entry.session_id != null);
        try std.testing.expectEqualStrings("sess-a", entry.session_id.?);
    }
}

test "sqlite list with session_id and category filter" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k1", "a1", .core, "sess-a");
    try m.store("k2", "a2", .conversation, "sess-a");
    try m.store("k3", "b1", .core, "sess-b");

    const results = try m.list(std.testing.allocator, .core, "sess-a");
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("k1", results[0].key);
}

test "sqlite cross-session recall isolation" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("secret", "session A secret data", .core, "sess-a");

    // Session B cannot see session A data
    const results_b = try m.recall(std.testing.allocator, "secret", 10, "sess-b");
    defer root.freeEntries(std.testing.allocator, results_b);
    try std.testing.expectEqual(@as(usize, 0), results_b.len);

    // Session A can see its own data
    const results_a = try m.recall(std.testing.allocator, "secret", 10, "sess-a");
    defer root.freeEntries(std.testing.allocator, results_a);
    try std.testing.expectEqual(@as(usize, 1), results_a.len);
}

test "sqlite schema has session_id column" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    // Verify session_id column exists by querying it
    const sql = "SELECT session_id FROM memories LIMIT 0";
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(mem.db, sql, -1, &stmt, null);
    try std.testing.expectEqual(c.SQLITE_OK, rc);
    _ = c.sqlite3_finalize(stmt);
}

test "sqlite schema migration is idempotent" {
    // Calling migrateSessionId twice should not fail
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    // migrateSessionId already ran during init; call it again
    try mem.migrateSessionId();

    // Store with session_id should still work
    const m = mem.memory();
    try m.store("k1", "data", .core, "sess-x");
    const entry = (try m.get(std.testing.allocator, "k1")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("sess-x", entry.session_id.?);
}

test "sqlite query expansion splits provider style tokens" {
    const expanded = try SqliteMemory.expandQueryForSearch(std.testing.allocator, "the gpt-4.1-mini / qwen3-max and");
    defer std.testing.allocator.free(expanded);

    try std.testing.expect(std.mem.indexOf(u8, expanded, "gpt") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "mini") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "qwen3") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "max") != null);
}

test "sqlite fts recall session filter is respected" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("sess_a_doc", "fts_filter_probe_token repeated", .conversation, "sess-a");
    try m.store("sess_b_doc", "fts_filter_probe_token repeated", .conversation, "sess-b");

    const results = try m.recall(std.testing.allocator, "fts_filter_probe_token", 10, "sess-a");
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("sess_a_doc", results[0].key);
}

test "sqlite temporal decay prefers fresh non-core memories" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("stale", "temporal_decay_probe content", .conversation, null);
    try m.store("fresh", "temporal_decay_probe content", .conversation, null);

    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(
        mem.db,
        "UPDATE memories SET created_at='946684800', updated_at='946684800' WHERE key='stale';",
        null,
        null,
        &err_msg,
    );
    if (err_msg) |msg| c.sqlite3_free(msg);
    try std.testing.expectEqual(c.SQLITE_OK, rc);

    const results = try m.recall(std.testing.allocator, "temporal_decay_probe", 2, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("fresh", results[0].key);
}

test "sqlite mmr rerank reduces near-duplicate recall" {
    const allocator = std.testing.allocator;

    const entries = try allocator.alloc(MemoryEntry, 3);
    entries[0] = .{
        .id = try allocator.dupe(u8, "id-a"),
        .key = try allocator.dupe(u8, "a"),
        .content = try allocator.dupe(u8, "zig memory safety ownership borrow checker"),
        .category = .conversation,
        .timestamp = try allocator.dupe(u8, "1700000000"),
        .session_id = null,
        .score = 1.0,
    };
    entries[1] = .{
        .id = try allocator.dupe(u8, "id-b"),
        .key = try allocator.dupe(u8, "b"),
        .content = try allocator.dupe(u8, "zig memory safety ownership borrow checker patterns"),
        .category = .conversation,
        .timestamp = try allocator.dupe(u8, "1700000000"),
        .session_id = null,
        .score = 0.95,
    };
    entries[2] = .{
        .id = try allocator.dupe(u8, "id-c"),
        .key = try allocator.dupe(u8, "c"),
        .content = try allocator.dupe(u8, "zig web routing http server handlers"),
        .category = .conversation,
        .timestamp = try allocator.dupe(u8, "1700000000"),
        .session_id = null,
        .score = 0.90,
    };

    const reranked = try SqliteMemory.rerankRecallResults(allocator, entries, 2);
    defer root.freeEntries(allocator, reranked);

    try std.testing.expectEqual(@as(usize, 2), reranked.len);
    try std.testing.expectEqualStrings("a", reranked[0].key);
    try std.testing.expectEqualStrings("c", reranked[1].key);
}

test "sqlite token hashing handles UTF-8 text safely" {
    const allocator = std.testing.allocator;

    const entry = MemoryEntry{
        .id = try allocator.dupe(u8, "id-utf8"),
        .key = try allocator.dupe(u8, "键-key"),
        .content = try allocator.dupe(u8, "你好，Nullclaw 🚀 mixed UTF-8 tokens"),
        .category = .conversation,
        .timestamp = try allocator.dupe(u8, "1700000000"),
        .session_id = null,
        .score = 1.0,
    };
    defer entry.deinit(allocator);

    const token_set = try SqliteMemory.buildEntryTokenSet(allocator, entry);
    defer allocator.free(token_set);

    // Non-empty result confirms tokenization/hash path completed without panic.
    try std.testing.expect(token_set.len > 0);
}
