//! Agent core — main loop, tool execution, conversation management.
//!
//! Mirrors ZeroClaw's agent module: Agent struct, tool call loop,
//! system prompt construction, history management, single and interactive modes.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.agent);
const Config = @import("../config.zig").Config;
const config_types = @import("../config_types.zig");
const providers = @import("../providers/root.zig");
const Provider = providers.Provider;
const ChatMessage = providers.ChatMessage;
const ChatRequest = providers.ChatRequest;
const ChatResponse = providers.ChatResponse;
const ToolSpec = providers.ToolSpec;
const tools_mod = @import("../tools/root.zig");
const Tool = tools_mod.Tool;
const ToolResult = tools_mod.ToolResult;
const subagent_mod = @import("../subagent.zig");
const memory_mod = @import("../memory/root.zig");
const Memory = memory_mod.Memory;
const MemoryCategory = memory_mod.MemoryCategory;
const observability = @import("../observability.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const hooks_mod = @import("../hooks.zig");
const HookBus = hooks_mod.HookBus;
const HookEvent = hooks_mod.HookEvent;

pub const dispatcher = @import("dispatcher.zig");
pub const prompt = @import("prompt.zig");
pub const memory_loader = @import("memory_loader.zig");
const cli_mod = @import("../channels/cli.zig");

const ParsedToolCall = dispatcher.ParsedToolCall;
const ToolExecutionResult = dispatcher.ToolExecutionResult;

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

/// Maximum agentic tool-use iterations per user message.
const DEFAULT_MAX_TOOL_ITERATIONS: u32 = 10;

/// Maximum non-system messages before trimming.
const DEFAULT_MAX_HISTORY: u32 = 50;

/// Default: keep this many most-recent non-system messages after compaction.
const DEFAULT_COMPACTION_KEEP_RECENT: u32 = 20;

/// Default: max characters retained in stored compaction summary.
const DEFAULT_COMPACTION_MAX_SUMMARY_CHARS: u32 = 2_000;

/// Default: max characters in source transcript passed to the summarizer.
const DEFAULT_COMPACTION_MAX_SOURCE_CHARS: u32 = 12_000;

/// Default token limit for context window (used by token-based compaction trigger).
pub const DEFAULT_TOKEN_LIMIT: u64 = 128_000;

/// Minimum history length before context exhaustion recovery is attempted.
const CONTEXT_RECOVERY_MIN_HISTORY: usize = 6;

/// Number of recent messages to keep during force compression.
const CONTEXT_RECOVERY_KEEP: usize = 4;

/// Tool-loop detection thresholds.
const TOOL_LOOP_SIGNATURE_WINDOW: usize = 30;
const TOOL_LOOP_WARN_REPEAT_STREAK: u32 = 3;
const TOOL_LOOP_WARN_ABAB_STREAK: u32 = 2;
const TOOL_LOOP_WARN_NO_PROGRESS_STREAK: u32 = 3;
const TOOL_LOOP_CRITICAL_REPEAT_STREAK: u32 = 6;
const TOOL_LOOP_CRITICAL_ABAB_STREAK: u32 = 3;
const TOOL_LOOP_CRITICAL_NO_PROGRESS_STREAK: u32 = 6;

const NormalizedCliLine = struct {
    text: []const u8,
    owned: bool,
};

fn hashParsedToolCalls(calls: []const ParsedToolCall) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (calls) |call| {
        hasher.update(call.name);
        hasher.update(&[_]u8{0x1f});
        hasher.update(call.arguments_json);
        hasher.update(&[_]u8{0x1e});
        if (call.tool_call_id) |id| hasher.update(id);
        hasher.update(&[_]u8{0x1d});
    }
    return hasher.final();
}

fn isAbabToolPattern(signatures: []const u64) bool {
    if (signatures.len < 4) return false;
    const a = signatures[signatures.len - 4];
    const b = signatures[signatures.len - 3];
    const c = signatures[signatures.len - 2];
    const d = signatures[signatures.len - 1];
    return a == c and b == d and a != b;
}

// ═══════════════════════════════════════════════════════════════════════════
// Agent
// ═══════════════════════════════════════════════════════════════════════════

pub const Agent = struct {
    allocator: std.mem.Allocator,
    provider: Provider,
    reliable_provider: ?*providers.reliable.ReliableProvider = null,
    tools: []const Tool,
    tool_specs: []const ToolSpec,
    mem: ?Memory,
    observer: Observer,
    model_name: []const u8,
    model_name_owned: bool = false,
    temperature: f64,
    workspace_dir: []const u8,
    max_tool_iterations: u32,
    max_history_messages: u32,
    auto_save: bool,
    token_limit: u64 = 0,
    max_tokens: u32 = 4096,
    message_timeout_secs: u64 = 0,
    skills_prompt_limits: config_types.SkillsPromptLimits = .{},
    compaction_keep_recent: u32 = DEFAULT_COMPACTION_KEEP_RECENT,
    compaction_max_summary_chars: u32 = DEFAULT_COMPACTION_MAX_SUMMARY_CHARS,
    compaction_max_source_chars: u32 = DEFAULT_COMPACTION_MAX_SOURCE_CHARS,

    /// Optional streaming callback. When set, turn() uses streamChat() for streaming providers.
    stream_callback: ?providers.StreamCallback = null,
    /// Context pointer passed to stream_callback.
    stream_ctx: ?*anyopaque = null,

    /// Conversation history — owned, growable list.
    history: std.ArrayListUnmanaged(OwnedMessage) = .empty,

    /// Total tokens used across all turns.
    total_tokens: u64 = 0,

    /// Whether the system prompt has been injected.
    has_system_prompt: bool = false,

    /// Whether compaction was performed during the last turn.
    last_turn_compacted: bool = false,

    /// Whether context was force-compacted due to exhaustion during the current turn.
    context_was_compacted: bool = false,
    /// Optional internal lifecycle hooks (lightweight pub/sub bus).
    internal_hooks: ?*HookBus = null,

    /// An owned copy of a ChatMessage, where content is heap-allocated.
    const OwnedMessage = struct {
        role: providers.Role,
        content: []const u8,

        fn deinit(self: *const OwnedMessage, allocator: std.mem.Allocator) void {
            allocator.free(self.content);
        }

        fn toChatMessage(self: *const OwnedMessage) ChatMessage {
            return .{ .role = self.role, .content = self.content };
        }
    };

    /// Initialize agent from a loaded Config.
    pub fn fromConfig(
        allocator: std.mem.Allocator,
        cfg: *const Config,
        provider_i: Provider,
        tools: []const Tool,
        mem: ?Memory,
        observer_i: Observer,
    ) !Agent {
        // Build tool specs for function-calling APIs
        const specs = try allocator.alloc(ToolSpec, tools.len);
        for (tools, 0..) |t, i| {
            specs[i] = .{
                .name = t.name(),
                .description = t.description(),
                .parameters_json = t.parametersJson(),
            };
        }

        var provider_out = provider_i;
        var reliable_provider_ptr: ?*providers.reliable.ReliableProvider = null;

        // Wrap with ReliableProvider to enable retries + model fallback cooldown/probing.
        // This keeps provider behavior stable across CLI, channel, and gateway session flows.
        if (cfg.reliability.provider_retries > 0 or cfg.reliability.model_fallbacks.len > 0) {
            const rp = try allocator.create(providers.reliable.ReliableProvider);
            errdefer allocator.destroy(rp);

            rp.* = providers.reliable.ReliableProvider.initWithProvider(
                provider_i,
                cfg.reliability.provider_retries,
                cfg.reliability.provider_backoff_ms,
            ).withModelFallbacks(cfg.reliability.model_fallbacks);
            _ = rp.withProbePolicy(
                cfg.reliability.model_fallback_cooldown_secs * 1000,
                cfg.reliability.model_probe_interval_secs * 1000,
                cfg.reliability.probe_primary_during_cooldown,
            );
            provider_out = rp.provider();
            reliable_provider_ptr = rp;
        }

        return .{
            .allocator = allocator,
            .provider = provider_out,
            .reliable_provider = reliable_provider_ptr,
            .tools = tools,
            .tool_specs = specs,
            .mem = mem,
            .observer = observer_i,
            .model_name = cfg.default_model orelse "anthropic/claude-sonnet-4",
            .temperature = cfg.default_temperature,
            .workspace_dir = cfg.workspace_dir,
            .max_tool_iterations = cfg.agent.max_tool_iterations,
            .max_history_messages = cfg.agent.max_history_messages,
            .auto_save = cfg.memory.auto_save,
            .token_limit = cfg.agent.token_limit,
            .max_tokens = cfg.max_tokens,
            .message_timeout_secs = cfg.agent.message_timeout_secs,
            .skills_prompt_limits = cfg.agent.skills_prompt_limits,
            .compaction_keep_recent = cfg.agent.compaction_keep_recent,
            .compaction_max_summary_chars = cfg.agent.compaction_max_summary_chars,
            .compaction_max_source_chars = cfg.agent.compaction_max_source_chars,
            .history = .empty,
            .total_tokens = 0,
            .has_system_prompt = false,
            .last_turn_compacted = false,
        };
    }

    pub fn deinit(self: *Agent) void {
        if (self.reliable_provider) |rp| {
            self.allocator.destroy(rp);
            self.reliable_provider = null;
        }
        if (self.model_name_owned) self.allocator.free(self.model_name);
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.deinit(self.allocator);
        self.allocator.free(self.tool_specs);
    }

    pub fn setInternalHooks(self: *Agent, bus: ?*HookBus) void {
        self.internal_hooks = bus;
    }

    fn emitHook(self: *Agent, event: HookEvent) void {
        if (self.internal_hooks) |bus| {
            var evt = event;
            bus.emit(&evt);
        }
    }

    /// Build a compaction transcript from a slice of history messages.
    fn buildCompactionTranscript(self: *Agent, start: usize, end: usize) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        for (self.history.items[start..end]) |*msg| {
            const role_str: []const u8 = switch (msg.role) {
                .system => "SYSTEM",
                .user => "USER",
                .assistant => "ASSISTANT",
                .tool => "TOOL",
            };
            try buf.appendSlice(self.allocator, role_str);
            try buf.appendSlice(self.allocator, ": ");
            // Truncate very long messages in transcript
            const content = if (msg.content.len > 500) msg.content[0..500] else msg.content;
            try buf.appendSlice(self.allocator, content);
            try buf.append(self.allocator, '\n');

            // Safety cap
            if (buf.items.len > self.compaction_max_source_chars) break;
        }

        if (buf.items.len > self.compaction_max_source_chars) {
            buf.items.len = self.compaction_max_source_chars;
        }

        return buf.toOwnedSlice(self.allocator);
    }

    /// Estimate total tokens in conversation history using heuristic: (total_chars + 3) / 4.
    pub fn tokenEstimate(self: *const Agent) u64 {
        var total_chars: u64 = 0;
        for (self.history.items) |*msg| {
            total_chars += msg.content.len;
        }
        return (total_chars + 3) / 4;
    }

    /// Summarize a slice of history messages via the LLM provider.
    /// Returns an owned summary string. Falls back to transcript truncation on error.
    fn summarizeSlice(self: *Agent, start: usize, end: usize) ![]u8 {
        const transcript = try self.buildCompactionTranscript(start, end);
        defer self.allocator.free(transcript);

        const summarizer_system = "You are a conversation compaction engine. Summarize older chat history into concise context for future turns. Preserve: user preferences, commitments, decisions, unresolved tasks, key facts. Omit: filler, repeated chit-chat, verbose tool logs. Output plain text bullet points only.";
        const summarizer_user = try std.fmt.allocPrint(self.allocator, "Summarize the following conversation history for context preservation. Keep it short (max 12 bullet points).\n\n{s}", .{transcript});
        defer self.allocator.free(summarizer_user);

        var summary_messages: [2]ChatMessage = .{
            .{ .role = .system, .content = summarizer_system },
            .{ .role = .user, .content = summarizer_user },
        };

        const messages_slice = summary_messages[0..2];

        const summary_resp = self.provider.chat(
            self.allocator,
            .{
                .messages = messages_slice,
                .model = self.model_name,
                .temperature = 0.2,
                .tools = null,
            },
            self.model_name,
            0.2,
        ) catch {
            // Fallback: use a local truncation of the transcript
            const max_len = @min(transcript.len, self.compaction_max_summary_chars);
            return try self.allocator.dupe(u8, transcript[0..max_len]);
        };
        // Free response's heap-allocated fields after extracting what we need
        defer {
            if (summary_resp.content) |c| {
                if (c.len > 0) self.allocator.free(c);
            }
            if (summary_resp.model.len > 0) self.allocator.free(summary_resp.model);
            if (summary_resp.reasoning_content) |rc| {
                if (rc.len > 0) self.allocator.free(rc);
            }
        }

        const raw_summary = summary_resp.contentOrEmpty();
        const max_len = @min(raw_summary.len, self.compaction_max_summary_chars);
        return try self.allocator.dupe(u8, raw_summary[0..max_len]);
    }

    /// Auto-compact history when it exceeds max_history_messages or when
    /// estimated token usage exceeds 75% of the configured token limit.
    /// For large histories (>10 messages to summarize), uses multi-part strategy:
    /// splits into halves, summarizes each independently, then merges.
    /// Returns true if compaction was performed.
    pub fn autoCompactHistory(self: *Agent) !bool {
        const has_system = self.history.items.len > 0 and self.history.items[0].role == .system;
        const start: usize = if (has_system) 1 else 0;
        const non_system_count = self.history.items.len - start;

        // Trigger on message count exceeding threshold
        const count_trigger = non_system_count > self.max_history_messages;

        // Trigger on token estimate exceeding 75% of token limit
        const token_threshold = (self.token_limit * 3) / 4;
        const token_trigger = self.token_limit > 0 and self.tokenEstimate() > token_threshold;

        if (!count_trigger and !token_trigger) return false;

        const keep_recent = @min(self.compaction_keep_recent, @as(u32, @intCast(non_system_count)));
        const compact_count = non_system_count - keep_recent;
        if (compact_count == 0) return false;

        const compact_end = start + compact_count;

        // Multi-part strategy: if >10 messages to summarize, split into halves
        const summary = if (compact_count > 10) blk: {
            const mid = start + compact_count / 2;

            // Summarize first half
            const summary_a = try self.summarizeSlice(start, mid);
            defer self.allocator.free(summary_a);

            // Summarize second half
            const summary_b = try self.summarizeSlice(mid, compact_end);
            defer self.allocator.free(summary_b);

            // Merge the two summaries
            const merged = try std.fmt.allocPrint(
                self.allocator,
                "Earlier context:\n{s}\n\nMore recent context:\n{s}",
                .{ summary_a, summary_b },
            );

            // Truncate if too long
            if (merged.len > self.compaction_max_summary_chars) {
                const truncated = try self.allocator.dupe(u8, merged[0..self.compaction_max_summary_chars]);
                self.allocator.free(merged);
                break :blk truncated;
            }

            break :blk merged;
        } else try self.summarizeSlice(start, compact_end);
        defer self.allocator.free(summary);

        // Create the compaction summary message
        const summary_content = try std.fmt.allocPrint(self.allocator, "[Compaction summary]\n{s}", .{summary});

        // Free old messages being compacted
        for (self.history.items[start..compact_end]) |*msg| {
            msg.deinit(self.allocator);
        }

        // Replace compacted messages with summary
        self.history.items[start] = .{
            .role = .assistant,
            .content = summary_content,
        };

        // Shift remaining messages
        if (compact_end > start + 1) {
            const src = self.history.items[compact_end..];
            std.mem.copyForwards(OwnedMessage, self.history.items[start + 1 ..], src);
            self.history.items.len -= (compact_end - start - 1);
        }

        return true;
    }

    /// Force-compress history for context exhaustion recovery.
    /// Keeps system prompt (if any) + last CONTEXT_RECOVERY_KEEP messages.
    /// Everything in between is dropped without LLM summarization (we can't call
    /// the LLM since the context is exhausted). Returns true if compression was performed.
    pub fn forceCompressHistory(self: *Agent) bool {
        const has_system = self.history.items.len > 0 and self.history.items[0].role == .system;
        const start: usize = if (has_system) 1 else 0;
        const non_system_count = self.history.items.len - start;

        if (non_system_count <= CONTEXT_RECOVERY_KEEP) return false;

        const keep_start = self.history.items.len - CONTEXT_RECOVERY_KEEP;
        const to_remove = keep_start - start;

        // Free messages being removed
        for (self.history.items[start..keep_start]) |*msg| {
            msg.deinit(self.allocator);
        }

        // Shift remaining elements
        const src = self.history.items[keep_start..];
        std.mem.copyForwards(OwnedMessage, self.history.items[start..], src);
        self.history.items.len -= to_remove;

        return true;
    }

    /// Handle slash commands that don't require LLM.
    /// Returns an owned response string, or null if not a slash command.
    pub fn handleSlashCommand(self: *Agent, message: []const u8) !?[]const u8 {
        const trimmed = std.mem.trim(u8, message, " \t\r\n");

        if (std.mem.eql(u8, trimmed, "/new")) {
            self.clearHistory();
            return try self.allocator.dupe(u8, "Session cleared.");
        }

        if (std.mem.eql(u8, trimmed, "/help")) {
            return try self.allocator.dupe(u8,
                \\Available commands:
                \\  /new     — Clear conversation history and start fresh
                \\  /help    — Show this help message
                \\  /status  — Show current model, provider and session stats
                \\  /model <name> — Switch to a different model
                \\  exit, quit — Exit interactive mode
            );
        }

        if (std.mem.eql(u8, trimmed, "/status")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "Model: {s}\nHistory: {d} messages\nTokens used: {d}\nTools: {d} available",
                .{
                    self.model_name,
                    self.history.items.len,
                    self.total_tokens,
                    self.tools.len,
                },
            );
        }

        if (std.mem.eql(u8, trimmed, "/model") or std.mem.startsWith(u8, trimmed, "/model ")) {
            const arg = if (trimmed.len > "/model".len)
                std.mem.trim(u8, trimmed["/model".len..], " \t")
            else
                "";
            if (arg.len == 0) {
                return try std.fmt.allocPrint(self.allocator, "Current model: {s}", .{self.model_name});
            }
            if (self.model_name_owned) self.allocator.free(self.model_name);
            self.model_name = try self.allocator.dupe(u8, arg);
            self.model_name_owned = true;
            return try std.fmt.allocPrint(self.allocator, "Switched to model: {s}", .{arg});
        }

        return null;
    }

    /// Execute a single conversation turn: send messages to LLM, parse tool calls,
    /// execute tools, and loop until a final text response is produced.
    pub fn turn(self: *Agent, user_message: []const u8) ![]const u8 {
        self.context_was_compacted = false;
        const native_tools_enabled = self.provider.supportsNativeTools() and self.tool_specs.len > 0;
        self.emitHook(.{ .message_received = .{ .text = user_message } });

        // Handle slash commands before sending to LLM (saves tokens)
        if (try self.handleSlashCommand(user_message)) |response| {
            return response;
        }

        // Inject system prompt on first turn
        if (!self.has_system_prompt) {
            const system_prompt = try prompt.buildSystemPrompt(self.allocator, .{
                .workspace_dir = self.workspace_dir,
                .model_name = self.model_name,
                .tools = self.tools,
                .skills_prompt_limits = self.skills_prompt_limits,
            });
            defer self.allocator.free(system_prompt);

            const base_tool_instructions = try dispatcher.buildToolInstructions(self.allocator, self.tools);
            defer self.allocator.free(base_tool_instructions);

            // Prefer native tool-calling where available, while retaining XML fallback
            // for OpenAI-compatible gateways/models that ignore structured tools.
            const tool_instructions = if (native_tools_enabled)
                try std.fmt.allocPrint(
                    self.allocator,
                    \\
                    \\## Native Tool Calling
                    \\Use the API's native function/tool-calling interface first whenever tools are needed.
                    \\If native tool-calling is unavailable for this model/provider, fall back to the XML protocol below.
                    \\
                    \\{s}
                ,
                    .{base_tool_instructions},
                )
            else
                try self.allocator.dupe(u8, base_tool_instructions);
            defer self.allocator.free(tool_instructions);

            const full_system = try self.allocator.alloc(u8, system_prompt.len + tool_instructions.len);
            var system_transferred = false;
            errdefer if (!system_transferred) self.allocator.free(full_system);
            @memcpy(full_system[0..system_prompt.len], system_prompt);
            @memcpy(full_system[system_prompt.len..], tool_instructions);

            try self.history.append(self.allocator, .{
                .role = .system,
                .content = full_system,
            });
            system_transferred = true;
            self.has_system_prompt = true;
            self.emitHook(.{ .agent_bootstrap = .{
                .model = self.model_name,
                .workspace_dir = self.workspace_dir,
            } });
        }

        // Auto-save user message to memory (timestamp-based key to avoid overwriting)
        if (self.auto_save) {
            if (self.mem) |mem| {
                const ts = @as(u64, @intCast(std.time.timestamp()));
                const save_key = std.fmt.allocPrint(self.allocator, "autosave_user_{d}", .{ts}) catch null;
                if (save_key) |key| {
                    defer self.allocator.free(key);
                    mem.store(key, user_message, .conversation, null) catch {};
                }
            }
        }

        // Enrich message with memory context (always returns owned slice; ownership → history)
        const enriched = if (self.mem) |mem|
            try memory_loader.enrichMessage(self.allocator, mem, user_message)
        else
            try self.allocator.dupe(u8, user_message);
        var enriched_transferred = false;
        errdefer if (!enriched_transferred) self.allocator.free(enriched);

        try self.history.append(self.allocator, .{
            .role = .user,
            .content = enriched,
        });
        enriched_transferred = true;

        // Record agent event
        const start_event = ObserverEvent{ .llm_request = .{
            .provider = self.provider.getName(),
            .model = self.model_name,
            .messages_count = self.history.items.len,
        } };
        self.observer.recordEvent(&start_event);

        // Tool call loop — reuse a single arena across iterations (retains pages)
        var iter_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer iter_arena.deinit();
        var tool_signature_history: std.ArrayListUnmanaged(u64) = .empty;
        defer tool_signature_history.deinit(self.allocator);
        var repeated_signature_streak: u32 = 0;
        var abab_streak: u32 = 0;
        var no_progress_streak: u32 = 0;
        var used_tools_in_turn = false;

        var iteration: u32 = 0;
        while (iteration < self.max_tool_iterations) : (iteration += 1) {
            _ = iter_arena.reset(.retain_capacity);
            const arena = iter_arena.allocator();

            // Build messages slice for provider (arena-owned; freed at end of iteration)
            const messages = blk: {
                const m = try arena.alloc(ChatMessage, self.history.items.len);
                for (self.history.items, 0..) |*msg, i| {
                    m[i] = msg.toChatMessage();
                }
                break :blk m;
            };

            const timer_start = std.time.milliTimestamp();
            const is_streaming = self.stream_callback != null and self.provider.supportsStreaming();
            var used_stream_response = false;

            // Call provider: streaming (single-attempt) or blocking with retry
            var response: ChatResponse = undefined;
            if (is_streaming) {
                response = blk: {
                    const stream_result = self.provider.streamChat(
                        self.allocator,
                        .{
                            .messages = messages,
                            .model = self.model_name,
                            .temperature = self.temperature,
                            .max_tokens = self.max_tokens,
                            .tools = if (native_tools_enabled) self.tool_specs else null,
                            .timeout_secs = self.message_timeout_secs,
                        },
                        self.model_name,
                        self.temperature,
                        self.stream_callback.?,
                        self.stream_ctx.?,
                    ) catch |stream_err| {
                        const fail_duration: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - timer_start)));
                        const fail_event = ObserverEvent{ .llm_response = .{
                            .provider = self.provider.getName(),
                            .model = self.model_name,
                            .duration_ms = fail_duration,
                            .success = false,
                            .error_message = @errorName(stream_err),
                        } };
                        self.observer.recordEvent(&fail_event);
                        const stream_fallback_event = ObserverEvent{ .err = .{
                            .component = "agent.streaming",
                            .message = "stream_error_fallback_to_blocking",
                        } };
                        self.observer.recordEvent(&stream_fallback_event);
                        self.emitHook(.{ .stream_fallback = .{
                            .reason = "stream_error_fallback_to_blocking",
                        } });

                        const fallback_response = self.provider.chat(
                            self.allocator,
                            .{
                                .messages = messages,
                                .model = self.model_name,
                                .temperature = self.temperature,
                                .max_tokens = self.max_tokens,
                                .tools = if (native_tools_enabled) self.tool_specs else null,
                                .timeout_secs = self.message_timeout_secs,
                            },
                            self.model_name,
                            self.temperature,
                        ) catch |fallback_err| {
                            const fallback_fail_duration: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - timer_start)));
                            const fallback_fail_event = ObserverEvent{ .llm_response = .{
                                .provider = self.provider.getName(),
                                .model = self.model_name,
                                .duration_ms = fallback_fail_duration,
                                .success = false,
                                .error_message = @errorName(fallback_err),
                            } };
                            self.observer.recordEvent(&fallback_fail_event);
                            return fallback_err;
                        };

                        if (fallback_response.content) |text| {
                            if (text.len > 0 and self.stream_callback != null and self.stream_ctx != null) {
                                self.stream_callback.?(self.stream_ctx.?, providers.StreamChunk.textDelta(text));
                            }
                        }
                        break :blk fallback_response;
                    };

                    const stream_valid = (stream_result.content != null and stream_result.content.?.len > 0) or
                        stream_result.tool_calls.len > 0;
                    if (stream_valid) {
                        used_stream_response = true;
                        break :blk ChatResponse{
                            .content = stream_result.content,
                            .tool_calls = stream_result.tool_calls,
                            .usage = stream_result.usage,
                            .model = stream_result.model,
                        };
                    }

                    const stream_fallback_event = ObserverEvent{ .err = .{
                        .component = "agent.streaming",
                        .message = "stream_empty_fallback_to_blocking",
                    } };
                    self.observer.recordEvent(&stream_fallback_event);
                    self.emitHook(.{ .stream_fallback = .{
                        .reason = "stream_empty_fallback_to_blocking",
                    } });

                    const fallback_response = self.provider.chat(
                        self.allocator,
                        .{
                            .messages = messages,
                            .model = self.model_name,
                            .temperature = self.temperature,
                            .max_tokens = self.max_tokens,
                            .tools = if (native_tools_enabled) self.tool_specs else null,
                            .timeout_secs = self.message_timeout_secs,
                        },
                        self.model_name,
                        self.temperature,
                    ) catch |fallback_err| {
                        const fail_duration: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - timer_start)));
                        const fail_event = ObserverEvent{ .llm_response = .{
                            .provider = self.provider.getName(),
                            .model = self.model_name,
                            .duration_ms = fail_duration,
                            .success = false,
                            .error_message = @errorName(fallback_err),
                        } };
                        self.observer.recordEvent(&fail_event);
                        return fallback_err;
                    };

                    if (fallback_response.content) |text| {
                        if (text.len > 0 and self.stream_callback != null and self.stream_ctx != null) {
                            self.stream_callback.?(self.stream_ctx.?, providers.StreamChunk.textDelta(text));
                        }
                    }
                    break :blk fallback_response;
                };
            } else {
                response = self.provider.chat(
                    self.allocator,
                    .{
                        .messages = messages,
                        .model = self.model_name,
                        .temperature = self.temperature,
                        .max_tokens = self.max_tokens,
                        .tools = if (native_tools_enabled) self.tool_specs else null,
                        .timeout_secs = self.message_timeout_secs,
                    },
                    self.model_name,
                    self.temperature,
                ) catch |err| retry_blk: {
                    // Record the failed attempt
                    const fail_duration: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - timer_start)));
                    const fail_event = ObserverEvent{ .llm_response = .{
                        .provider = self.provider.getName(),
                        .model = self.model_name,
                        .duration_ms = fail_duration,
                        .success = false,
                        .error_message = @errorName(err),
                    } };
                    self.observer.recordEvent(&fail_event);

                    // Context exhaustion: compact immediately before first retry
                    const err_name = @errorName(err);
                    if (providers.reliable.isContextExhausted(err_name) and
                        self.history.items.len > CONTEXT_RECOVERY_MIN_HISTORY and
                        self.forceCompressHistory())
                    {
                        self.context_was_compacted = true;
                        const recovery_msgs = self.buildMessageSlice() catch return err;
                        defer self.allocator.free(recovery_msgs);
                        break :retry_blk self.provider.chat(
                            self.allocator,
                            .{
                                .messages = recovery_msgs,
                                .model = self.model_name,
                                .temperature = self.temperature,
                                .max_tokens = self.max_tokens,
                                .tools = if (native_tools_enabled) self.tool_specs else null,
                                .timeout_secs = self.message_timeout_secs,
                            },
                            self.model_name,
                            self.temperature,
                        ) catch return err;
                    }

                    // Retry once
                    std.Thread.sleep(500 * std.time.ns_per_ms);
                    break :retry_blk self.provider.chat(
                        self.allocator,
                        .{
                            .messages = messages,
                            .model = self.model_name,
                            .temperature = self.temperature,
                            .max_tokens = self.max_tokens,
                            .tools = if (native_tools_enabled) self.tool_specs else null,
                            .timeout_secs = self.message_timeout_secs,
                        },
                        self.model_name,
                        self.temperature,
                    ) catch |retry_err| {
                        // Context exhaustion recovery: if we have enough history,
                        // force-compress and retry once more
                        if (self.history.items.len > CONTEXT_RECOVERY_MIN_HISTORY and self.forceCompressHistory()) {
                            self.context_was_compacted = true;
                            const recovery_msgs = self.buildMessageSlice() catch return retry_err;
                            defer self.allocator.free(recovery_msgs);
                            break :retry_blk self.provider.chat(
                                self.allocator,
                                .{
                                    .messages = recovery_msgs,
                                    .model = self.model_name,
                                    .temperature = self.temperature,
                                    .max_tokens = self.max_tokens,
                                    .tools = if (native_tools_enabled) self.tool_specs else null,
                                    .timeout_secs = self.message_timeout_secs,
                                },
                                self.model_name,
                                self.temperature,
                            ) catch return retry_err;
                        }
                        return retry_err;
                    };
                };
            }

            const duration_ms: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - timer_start)));
            const resp_event = ObserverEvent{ .llm_response = .{
                .provider = self.provider.getName(),
                .model = self.model_name,
                .duration_ms = duration_ms,
                .success = true,
                .error_message = null,
            } };
            self.observer.recordEvent(&resp_event);

            // Track tokens
            self.total_tokens += response.usage.total_tokens;

            const response_text = response.contentOrEmpty();
            const use_native = response.hasToolCalls();
            if (response_text.len == 0 and response.tool_calls.len == 0) {
                self.freeResponseFields(&response);
                return error.NoResponseContent;
            }

            // Determine tool calls: structured (native) first, then XML fallback.
            // Mirrors ZeroClaw's run_tool_call_loop logic.
            var parsed_calls: []ParsedToolCall = &.{};
            var parsed_text: []const u8 = "";
            var assistant_history_content: []const u8 = "";

            // Track what we need to free
            var free_parsed_calls = false;
            var free_parsed_text = false;
            var free_assistant_history = false;

            defer {
                if (free_parsed_calls) {
                    for (parsed_calls) |call| {
                        self.allocator.free(call.name);
                        self.allocator.free(call.arguments_json);
                        if (call.tool_call_id) |id| self.allocator.free(id);
                    }
                    self.allocator.free(parsed_calls);
                }
                if (free_parsed_text and parsed_text.len > 0) self.allocator.free(parsed_text);
                if (free_assistant_history and assistant_history_content.len > 0) self.allocator.free(assistant_history_content);
            }

            if (use_native) {
                // Provider returned structured tool_calls — convert them
                parsed_calls = try dispatcher.parseStructuredToolCalls(self.allocator, response.tool_calls);
                free_parsed_calls = true;

                if (parsed_calls.len == 0 and !used_stream_response) {
                    // Structured calls were empty (e.g. all had empty names) — try XML fallback
                    // only for non-streaming path to preserve stream-native tool semantics.
                    self.allocator.free(parsed_calls);
                    free_parsed_calls = false;

                    const xml_parsed = try dispatcher.parseToolCalls(self.allocator, response_text);
                    parsed_calls = xml_parsed.calls;
                    free_parsed_calls = true;
                    parsed_text = xml_parsed.text;
                    free_parsed_text = true;
                }

                // Build history content with serialized tool calls
                assistant_history_content = try buildAssistantHistoryWithToolCalls(
                    self.allocator,
                    response_text,
                    parsed_calls,
                );
                free_assistant_history = true;
            } else {
                // No native tool calls — parse response text for XML tool calls
                const xml_parsed = try dispatcher.parseToolCalls(self.allocator, response_text);
                parsed_calls = xml_parsed.calls;
                free_parsed_calls = true;
                parsed_text = xml_parsed.text;
                free_parsed_text = true;
                // For XML path, store the raw response text as history
                assistant_history_content = response_text;
            }

            // Determine display text
            const display_text = if (parsed_text.len > 0) parsed_text else response_text;

            if (parsed_calls.len == 0) {
                // No tool calls — final response
                const final_text = if (self.context_was_compacted) blk: {
                    self.context_was_compacted = false;
                    break :blk try std.fmt.allocPrint(self.allocator, "[Контекст сжат]\n\n{s}", .{display_text});
                } else try self.allocator.dupe(u8, display_text);

                var final_text_returned = false;
                errdefer if (!final_text_returned) self.allocator.free(final_text);

                // Dupe from display_text directly (not from final_text) to avoid double-dupe
                const display_history = try self.allocator.dupe(u8, display_text);
                var history_transferred = false;
                errdefer if (!history_transferred) self.allocator.free(display_history);

                try self.history.append(self.allocator, .{
                    .role = .assistant,
                    .content = display_history,
                });
                history_transferred = true;

                // Auto-compaction before hard trimming to preserve context
                self.last_turn_compacted = self.autoCompactHistory() catch false;
                self.trimHistory();

                // Auto-save assistant response
                if (self.auto_save) {
                    if (self.mem) |mem| {
                        const summary = if (final_text.len > 100) final_text[0..100] else final_text;
                        const ts = @as(u64, @intCast(std.time.timestamp()));
                        const save_key = try std.fmt.allocPrint(self.allocator, "autosave_assistant_{d}", .{ts});
                        defer self.allocator.free(save_key);
                        mem.store(save_key, summary, .daily, null) catch {};
                    }
                }

                const complete_event = ObserverEvent{ .turn_complete = {} };
                self.observer.recordEvent(&complete_event);
                self.emitHook(.{ .turn_complete = .{
                    .response_len = final_text.len,
                    .used_tools = used_tools_in_turn,
                } });

                // Free provider response fields (content, tool_calls, model)
                // All borrows have been duped into final_text and history at this point.
                self.freeResponseFields(&response);

                final_text_returned = true;
                return final_text;
            }

            const tool_signature = hashParsedToolCalls(parsed_calls);
            try tool_signature_history.append(self.allocator, tool_signature);
            if (tool_signature_history.items.len > TOOL_LOOP_SIGNATURE_WINDOW) {
                const tail = tool_signature_history.items[1..];
                std.mem.copyForwards(u64, tool_signature_history.items[0..tail.len], tail);
                tool_signature_history.items.len -= 1;
            }

            const history_len = tool_signature_history.items.len;
            if (history_len >= 2 and
                tool_signature_history.items[history_len - 1] == tool_signature_history.items[history_len - 2])
            {
                repeated_signature_streak += 1;
            } else {
                repeated_signature_streak = 1;
            }

            if (isAbabToolPattern(tool_signature_history.items)) {
                abab_streak += 1;
            } else {
                abab_streak = 0;
            }

            if (display_text.len == 0) {
                no_progress_streak += 1;
            } else {
                no_progress_streak = 0;
            }

            const loop_warning = repeated_signature_streak >= TOOL_LOOP_WARN_REPEAT_STREAK or
                abab_streak >= TOOL_LOOP_WARN_ABAB_STREAK or
                no_progress_streak >= TOOL_LOOP_WARN_NO_PROGRESS_STREAK;
            const loop_critical = repeated_signature_streak >= TOOL_LOOP_CRITICAL_REPEAT_STREAK or
                abab_streak >= TOOL_LOOP_CRITICAL_ABAB_STREAK or
                no_progress_streak >= TOOL_LOOP_CRITICAL_NO_PROGRESS_STREAK;

            if (loop_warning) {
                const warn_event = ObserverEvent{ .err = .{
                    .component = "agent.tool_loop",
                    .message = "warning",
                } };
                self.observer.recordEvent(&warn_event);
                self.emitHook(.{ .tool_loop_warning = .{
                    .repeat_streak = repeated_signature_streak,
                    .abab_streak = abab_streak,
                    .no_progress_streak = no_progress_streak,
                } });
            }

            if (loop_critical) {
                const breaker_event = ObserverEvent{ .err = .{
                    .component = "agent.tool_loop",
                    .message = "critical_breaker",
                } };
                self.observer.recordEvent(&breaker_event);
                self.emitHook(.{ .tool_loop_breaker = .{
                    .repeat_streak = repeated_signature_streak,
                    .abab_streak = abab_streak,
                    .no_progress_streak = no_progress_streak,
                } });

                const breaker_text = "Stopped due to repeated tool-call loop without progress. Please refine the request or add constraints.";
                const final_text = try self.allocator.dupe(u8, breaker_text);
                var final_text_returned = false;
                errdefer if (!final_text_returned) self.allocator.free(final_text);

                const breaker_history = try self.allocator.dupe(u8, breaker_text);
                var history_transferred = false;
                errdefer if (!history_transferred) self.allocator.free(breaker_history);

                try self.history.append(self.allocator, .{
                    .role = .assistant,
                    .content = breaker_history,
                });
                history_transferred = true;

                self.trimHistory();
                self.freeResponseFields(&response);
                self.emitHook(.{ .turn_complete = .{
                    .response_len = final_text.len,
                    .used_tools = true,
                } });

                final_text_returned = true;
                return final_text;
            }

            used_tools_in_turn = true;
            // There are tool calls — print intermediary text
            if (display_text.len > 0 and parsed_calls.len > 0 and !is_streaming) {
                var out_buf: [4096]u8 = undefined;
                var bw = std.fs.File.stdout().writer(&out_buf);
                const w = &bw.interface;
                w.print("{s}", .{display_text}) catch {};
                w.flush() catch {};
            }

            // Record assistant message with tool calls in history.
            // Native path (free_assistant_history=true): transfer ownership directly to avoid
            // a redundant allocation; clear the flag so the outer defer does not double-free.
            // XML path (free_assistant_history=false): response_text is not owned, must dupe.
            const assistant_content: []const u8 = if (free_assistant_history) blk: {
                free_assistant_history = false;
                break :blk assistant_history_content;
            } else try self.allocator.dupe(u8, assistant_history_content);
            var assistant_transferred = false;
            errdefer if (!assistant_transferred) self.allocator.free(assistant_content);

            try self.history.append(self.allocator, .{
                .role = .assistant,
                .content = assistant_content,
            });
            assistant_transferred = true;

            // Execute each tool call
            var results_buf: std.ArrayListUnmanaged(ToolExecutionResult) = .empty;
            defer results_buf.deinit(self.allocator);
            try results_buf.ensureTotalCapacity(self.allocator, parsed_calls.len);

            for (parsed_calls) |call| {
                const tool_start_event = ObserverEvent{ .tool_call_start = .{ .tool = call.name } };
                self.observer.recordEvent(&tool_start_event);

                const tool_timer = std.time.milliTimestamp();
                const result = self.executeTool(call);
                const tool_duration: u64 = @as(u64, @intCast(@max(0, std.time.milliTimestamp() - tool_timer)));

                const tool_event = ObserverEvent{ .tool_call = .{
                    .tool = call.name,
                    .duration_ms = tool_duration,
                    .success = result.success,
                } };
                self.observer.recordEvent(&tool_event);

                try results_buf.append(self.allocator, result);
            }

            // Format tool results, scrub credentials, add reflection prompt, and add to history
            const formatted_results = try dispatcher.formatToolResults(arena, results_buf.items);
            const scrubbed_results = try providers.scrubToolOutput(arena, formatted_results);
            const with_reflection = if (loop_warning)
                try std.fmt.allocPrint(
                    arena,
                    "{s}\n\nTool-loop warning: repeated tool patterns were detected with limited progress. Do not repeat identical tool calls unless new state has changed.\n\nReflect on the tool results above and decide your next steps.",
                    .{scrubbed_results},
                )
            else
                try std.fmt.allocPrint(
                    arena,
                    "{s}\n\nReflect on the tool results above and decide your next steps.",
                    .{scrubbed_results},
                );

            const reflection_content = try self.allocator.dupe(u8, with_reflection);
            var reflection_transferred = false;
            errdefer if (!reflection_transferred) self.allocator.free(reflection_content);

            try self.history.append(self.allocator, .{
                .role = .user,
                .content = reflection_content,
            });
            reflection_transferred = true;

            self.trimHistory();

            // Free provider response fields now that all borrows are consumed.
            self.freeResponseFields(&response);
        }

        return error.MaxToolIterationsExceeded;
    }

    /// Execute a tool by name lookup.
    /// Parses arguments_json once into a std.json.ObjectMap and passes it to the tool.
    fn executeTool(self: *Agent, call: ParsedToolCall) ToolExecutionResult {
        for (self.tools) |t| {
            if (std.mem.eql(u8, t.name(), call.name)) {
                // Parse arguments JSON to ObjectMap ONCE
                const parsed = std.json.parseFromSlice(
                    std.json.Value,
                    self.allocator,
                    call.arguments_json,
                    .{},
                ) catch {
                    return .{
                        .name = call.name,
                        .output = "Invalid arguments JSON",
                        .success = false,
                        .tool_call_id = call.tool_call_id,
                    };
                };
                defer parsed.deinit();

                const args: std.json.ObjectMap = switch (parsed.value) {
                    .object => |o| o,
                    else => {
                        return .{
                            .name = call.name,
                            .output = "Arguments must be a JSON object",
                            .success = false,
                            .tool_call_id = call.tool_call_id,
                        };
                    },
                };

                const result = t.execute(self.allocator, args) catch |err| {
                    return .{
                        .name = call.name,
                        .output = @errorName(err),
                        .success = false,
                        .tool_call_id = call.tool_call_id,
                    };
                };
                return .{
                    .name = call.name,
                    .output = if (result.success) result.output else (result.error_msg orelse result.output),
                    .success = result.success,
                    .tool_call_id = call.tool_call_id,
                };
            }
        }

        return .{
            .name = call.name,
            .output = "Unknown tool",
            .success = false,
            .tool_call_id = call.tool_call_id,
        };
    }

    /// Build an assistant history entry that includes serialized tool calls as XML.
    ///
    /// When the provider returns structured tool_calls, we serialize them as
    /// `<tool_call>` XML tags so the conversation history stays in a canonical
    /// format regardless of whether tools came from native API or XML parsing.
    ///
    /// Mirrors ZeroClaw's `build_assistant_history_with_tool_calls`.
    pub fn buildAssistantHistoryWithToolCalls(
        allocator: std.mem.Allocator,
        response_text: []const u8,
        parsed_calls: []const ParsedToolCall,
    ) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);

        if (response_text.len > 0) {
            try w.writeAll(response_text);
            try w.writeByte('\n');
        }

        for (parsed_calls) |call| {
            try w.writeAll("<tool_call>\n");
            try std.fmt.format(w, "{{\"name\": \"{s}\", \"arguments\": {s}}}", .{
                call.name,
                call.arguments_json,
            });
            try w.writeAll("\n</tool_call>\n");
        }

        return buf.toOwnedSlice(allocator);
    }

    /// Build a flat ChatMessage slice from owned history.
    fn buildMessageSlice(self: *Agent) ![]ChatMessage {
        const messages = try self.allocator.alloc(ChatMessage, self.history.items.len);
        for (self.history.items, 0..) |*msg, i| {
            messages[i] = msg.toChatMessage();
        }
        return messages;
    }

    /// Free heap-allocated fields of a ChatResponse.
    /// Providers allocate content, tool_calls, and model on the heap.
    /// After extracting/duping what we need, call this to prevent leaks.
    fn freeResponseFields(self: *Agent, resp: *ChatResponse) void {
        if (resp.content) |c| {
            if (c.len > 0) self.allocator.free(c);
        }
        for (resp.tool_calls) |tc| {
            if (tc.id.len > 0) self.allocator.free(tc.id);
            if (tc.name.len > 0) self.allocator.free(tc.name);
            if (tc.arguments.len > 0) self.allocator.free(tc.arguments);
        }
        if (resp.tool_calls.len > 0) self.allocator.free(resp.tool_calls);
        if (resp.model.len > 0) self.allocator.free(resp.model);
        if (resp.reasoning_content) |rc| {
            if (rc.len > 0) self.allocator.free(rc);
        }
        // Mark as consumed to prevent double-free
        resp.content = null;
        resp.tool_calls = &.{};
        resp.model = "";
        resp.reasoning_content = null;
    }

    /// Trim history to prevent unbounded growth.
    /// Preserves the system prompt (first message) and the most recent messages.
    fn trimHistory(self: *Agent) void {
        const max = self.max_history_messages;
        if (self.history.items.len <= max + 1) return; // +1 for system prompt

        const has_system = self.history.items.len > 0 and self.history.items[0].role == .system;
        const start: usize = if (has_system) 1 else 0;
        const non_system_count = self.history.items.len - start;

        if (non_system_count <= max) return;

        const to_remove = non_system_count - max;
        // Free the messages being removed
        for (self.history.items[start .. start + to_remove]) |*msg| {
            msg.deinit(self.allocator);
        }

        // Shift remaining elements
        const src = self.history.items[start + to_remove ..];
        std.mem.copyForwards(OwnedMessage, self.history.items[start..], src);
        self.history.items.len -= to_remove;

        // Shrink backing array if capacity is much larger than needed
        if (self.history.capacity > self.history.items.len * 2 + 8) {
            self.history.shrinkAndFree(self.allocator, self.history.items.len);
        }
    }

    /// Run a single message through the agent and return the response.
    pub fn runSingle(self: *Agent, message: []const u8) ![]const u8 {
        return self.turn(message);
    }

    /// Clear conversation history (for starting a new session).
    pub fn clearHistory(self: *Agent) void {
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.items.len = 0;
        self.has_system_prompt = false;
    }

    /// Get total tokens used.
    pub fn tokensUsed(self: *const Agent) u64 {
        return self.total_tokens;
    }

    /// Get current history length.
    pub fn historyLen(self: *const Agent) usize {
        return self.history.items.len;
    }

    /// Load persisted messages into history (for session restore).
    /// Each entry has .role ("user"/"assistant") and .content.
    /// The agent takes ownership of the content strings.
    pub fn loadHistory(self: *Agent, entries: anytype) !void {
        for (entries) |entry| {
            const role: providers.Role = if (std.mem.eql(u8, entry.role, "assistant"))
                .assistant
            else if (std.mem.eql(u8, entry.role, "system"))
                .system
            else
                .user;

            const entry_content = try self.allocator.dupe(u8, entry.content);
            var entry_transferred = false;
            errdefer if (!entry_transferred) self.allocator.free(entry_content);

            try self.history.append(self.allocator, .{
                .role = role,
                .content = entry_content,
            });
            entry_transferred = true;
        }
    }

    /// Get history entries as role-string + content pairs (for persistence).
    /// Caller owns the returned slice but NOT the inner strings (borrows from history).
    pub fn getHistory(self: *const Agent, allocator: std.mem.Allocator) ![]struct { role: []const u8, content: []const u8 } {
        const Pair = struct { role: []const u8, content: []const u8 };
        const result = try allocator.alloc(Pair, self.history.items.len);
        for (self.history.items, 0..) |*msg, i| {
            result[i] = .{
                .role = switch (msg.role) {
                    .system => "system",
                    .user => "user",
                    .assistant => "assistant",
                    .tool => "tool",
                },
                .content = msg.content,
            };
        }
        return result;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Top-level run() — entry point for CLI
// ═══════════════════════════════════════════════════════════════════════════

/// Streaming callback that writes chunks directly to stdout.
fn cliStreamCallback(_: *anyopaque, chunk: providers.StreamChunk) void {
    if (chunk.delta.len == 0) return;
    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    const wr = &bw.interface;
    wr.print("{s}", .{chunk.delta}) catch {};
    wr.flush() catch {};
}

fn decodeWindowsBytesToUtf8(allocator: std.mem.Allocator, code_page: u32, bytes: []const u8) ?[]u8 {
    if (builtin.os.tag != .windows) return null;
    if (bytes.len == 0) return null;

    const c_int_max: usize = @intCast(std.math.maxInt(c_int));
    if (bytes.len > c_int_max) return null;
    const byte_len: c_int = @intCast(bytes.len);

    const Win = struct {
        extern "kernel32" fn MultiByteToWideChar(
            code_page: u32,
            flags: u32,
            multi_byte_str: [*]const u8,
            multi_byte_len: c_int,
            wide_char_str: ?[*]u16,
            wide_char_len: c_int,
        ) callconv(.winapi) c_int;

        extern "kernel32" fn WideCharToMultiByte(
            code_page: u32,
            flags: u32,
            wide_char_str: [*]const u16,
            wide_char_len: c_int,
            multi_byte_str: ?[*]u8,
            multi_byte_len: c_int,
            default_char: ?[*:0]const u8,
            used_default_char: ?*i32,
        ) callconv(.winapi) c_int;
    };

    const wide_len = Win.MultiByteToWideChar(code_page, 0, bytes.ptr, byte_len, null, 0);
    if (wide_len <= 0) return null;

    const wide: []u16 = allocator.alloc(u16, @intCast(wide_len)) catch return null;
    defer allocator.free(wide);

    const converted_wide = Win.MultiByteToWideChar(code_page, 0, bytes.ptr, byte_len, wide.ptr, wide_len);
    if (converted_wide <= 0) return null;

    const utf8_len = Win.WideCharToMultiByte(65001, 0, wide.ptr, converted_wide, null, 0, null, null);
    if (utf8_len <= 0) return null;

    const utf8: []u8 = allocator.alloc(u8, @intCast(utf8_len)) catch return null;
    errdefer allocator.free(utf8);

    const converted_utf8 = Win.WideCharToMultiByte(65001, 0, wide.ptr, converted_wide, utf8.ptr, utf8_len, null, null);
    if (converted_utf8 <= 0) return null;

    if (!std.unicode.utf8ValidateSlice(utf8)) {
        allocator.free(utf8);
        return null;
    }
    return utf8;
}

fn lossyBytesToUtf8(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (bytes) |b| {
        if (b < 0x80) {
            try out.append(allocator, b);
        } else {
            // U+FFFD replacement char for undecodable byte.
            try out.appendSlice(allocator, &.{ 0xEF, 0xBF, 0xBD });
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn normalizeCliLine(allocator: std.mem.Allocator, raw_line: []const u8) !NormalizedCliLine {
    const trimmed = std.mem.trimRight(u8, raw_line, "\r");
    if (trimmed.len == 0) return .{ .text = trimmed, .owned = false };

    if (std.unicode.utf8ValidateSlice(trimmed)) {
        return .{ .text = trimmed, .owned = false };
    }

    if (builtin.os.tag == .windows) {
        // Git Bash/MSYS can deliver CP936 bytes for CJK IME input.
        if (decodeWindowsBytesToUtf8(allocator, 936, trimmed)) |decoded| {
            return .{ .text = decoded, .owned = true };
        }
        // Fallback to current ANSI code page.
        if (decodeWindowsBytesToUtf8(allocator, 0, trimmed)) |decoded| {
            return .{ .text = decoded, .owned = true };
        }
    }

    // Last resort: replace undecodable bytes so downstream JSON remains valid UTF-8.
    return .{ .text = try lossyBytesToUtf8(allocator, trimmed), .owned = true };
}

/// Run the agent in single-message or interactive REPL mode.
/// This is the main entry point called by `nullclaw agent`.
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    var cfg = Config.load(allocator) catch {
        log.err("No config found. Run `nullclaw onboard` first.", .{});
        return;
    };
    defer cfg.deinit();

    var out_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&out_buf);
    const w = &bw.interface;

    // Parse agent-specific flags
    var message_arg: ?[]const u8 = null;
    var session_id: ?[]const u8 = null;
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg: []const u8 = args[i];
            if ((std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) and i + 1 < args.len) {
                i += 1;
                message_arg = args[i];
            } else if ((std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) and i + 1 < args.len) {
                i += 1;
                session_id = args[i];
            }
        }
    }

    // Create a noop observer
    var noop = observability.NoopObserver{};
    const obs = noop.observer();

    // Record agent start
    const start_event = ObserverEvent{ .agent_start = .{
        .provider = cfg.default_provider,
        .model = cfg.default_model orelse "(default)",
    } };
    obs.recordEvent(&start_event);

    // Initialize MCP tools from config
    const mcp_mod = @import("../mcp.zig");
    const mcp_tools: ?[]const tools_mod.Tool = if (cfg.mcp_servers.len > 0)
        mcp_mod.initMcpTools(allocator, cfg.mcp_servers) catch |err| blk: {
            log.warn("MCP: init failed: {}", .{err});
            break :blk null;
        }
    else
        null;

    var subagent_manager = subagent_mod.SubagentManager.init(allocator, &cfg, null, .{
        .max_iterations = cfg.agent.max_tool_iterations,
        .max_concurrent = cfg.scheduler.max_concurrent,
    });
    defer subagent_manager.deinit();

    // Create tools (with agents config for delegate depth enforcement)
    const tools = try tools_mod.allTools(allocator, cfg.workspace_dir, .{
        .http_enabled = cfg.http_request.enabled,
        .browser_enabled = cfg.browser.enabled,
        .mcp_tools = mcp_tools,
        .agents = cfg.agents,
        .fallback_api_key = cfg.defaultProviderKey(),
        .subagent_manager = &subagent_manager,
        .tools_config = cfg.tools,
        .security_config = cfg.security,
    });
    defer allocator.free(tools);

    // Create memory (optional — don't fail if it can't init)
    var mem_opt: ?Memory = null;
    const db_path = try std.fs.path.joinZ(allocator, &.{ cfg.workspace_dir, "memory.db" });
    defer allocator.free(db_path);
    if (memory_mod.createMemory(allocator, cfg.memory.backend, db_path)) |mem| {
        mem_opt = mem;
    } else |_| {}

    // Create provider via ProviderHolder (concrete struct lives on the stack)
    const ProviderHolder = union(enum) {
        openrouter: providers.openrouter.OpenRouterProvider,
        anthropic: providers.anthropic.AnthropicProvider,
        openai: providers.openai.OpenAiProvider,
        openai_codex: providers.openai_codex.OpenAiCodexProvider,
        gemini: providers.gemini.GeminiProvider,
        ollama: providers.ollama.OllamaProvider,
        compatible: providers.compatible.OpenAiCompatibleProvider,
        claude_cli: providers.claude_cli.ClaudeCliProvider,
        codex_cli: providers.codex_cli.CodexCliProvider,
    };

    const kind = providers.classifyProvider(cfg.default_provider);
    var holder: ProviderHolder = switch (kind) {
        .anthropic_provider => .{ .anthropic = providers.anthropic.AnthropicProvider.init(
            allocator,
            cfg.defaultProviderKey(),
            if (std.mem.startsWith(u8, cfg.default_provider, "anthropic-custom:"))
                cfg.default_provider["anthropic-custom:".len..]
            else
                cfg.getProviderBaseUrl(cfg.default_provider),
        ) },
        .openai_provider => .{ .openai = providers.openai.OpenAiProvider.initWithBaseUrl(allocator, cfg.defaultProviderKey(), cfg.getProviderBaseUrl(cfg.default_provider)) },
        .openai_codex_provider => .{ .openai_codex = providers.openai_codex.OpenAiCodexProvider.init(allocator, cfg.defaultProviderKey()) },
        .gemini_provider => .{ .gemini = providers.gemini.GeminiProvider.initWithBaseUrl(allocator, cfg.defaultProviderKey(), cfg.getProviderBaseUrl(cfg.default_provider)) },
        .ollama_provider => .{ .ollama = providers.ollama.OllamaProvider.init(allocator, cfg.getProviderBaseUrl(cfg.default_provider)) },
        .openrouter_provider => .{ .openrouter = providers.openrouter.OpenRouterProvider.initWithBaseUrl(allocator, cfg.defaultProviderKey(), cfg.getProviderBaseUrl(cfg.default_provider)) },
        .compatible_provider => .{ .compatible = providers.compatible.OpenAiCompatibleProvider.init(
            allocator,
            cfg.default_provider,
            if (std.mem.startsWith(u8, cfg.default_provider, "custom:"))
                cfg.default_provider["custom:".len..]
            else
                cfg.getProviderBaseUrl(cfg.default_provider) orelse
                    providers.compatibleProviderUrl(cfg.default_provider) orelse "https://openrouter.ai/api/v1",
            cfg.defaultProviderKey(),
            .bearer,
        ) },
        .claude_cli_provider => if (providers.claude_cli.ClaudeCliProvider.init(allocator, null)) |p|
            .{ .claude_cli = p }
        else |_|
            .{ .openrouter = providers.openrouter.OpenRouterProvider.init(allocator, cfg.defaultProviderKey()) },
        .codex_cli_provider => if (providers.codex_cli.CodexCliProvider.init(allocator, null)) |p|
            .{ .codex_cli = p }
        else |_|
            .{ .openrouter = providers.openrouter.OpenRouterProvider.init(allocator, cfg.defaultProviderKey()) },
        .unknown => .{ .openrouter = providers.openrouter.OpenRouterProvider.init(allocator, cfg.defaultProviderKey()) },
    };

    const provider_i: Provider = switch (holder) {
        .openrouter => |*p| p.provider(),
        .anthropic => |*p| p.provider(),
        .openai => |*p| p.provider(),
        .openai_codex => |*p| p.provider(),
        .gemini => |*p| p.provider(),
        .ollama => |*p| p.provider(),
        .compatible => |*p| p.provider(),
        .claude_cli => |*p| p.provider(),
        .codex_cli => |*p| p.provider(),
    };

    const supports_streaming = provider_i.supportsStreaming();

    // Single message mode: nullclaw agent -m "hello"
    if (message_arg) |message| {
        try w.print("Sending to {s}...\n", .{cfg.default_provider});
        if (session_id) |sid| {
            try w.print("Session: {s}\n", .{sid});
        }
        try w.flush();

        const normalized_message = try normalizeCliLine(allocator, message);
        defer if (normalized_message.owned) allocator.free(normalized_message.text);

        var agent = try Agent.fromConfig(allocator, &cfg, provider_i, tools, mem_opt, obs);
        defer agent.deinit();

        // Enable streaming if provider supports it
        var stream_ctx: u8 = 0;
        if (supports_streaming) {
            agent.stream_callback = cliStreamCallback;
            agent.stream_ctx = @ptrCast(&stream_ctx);
        }

        const response = try agent.turn(normalized_message.text);
        defer allocator.free(response);

        if (supports_streaming) {
            try w.print("\n", .{});
        } else {
            try w.print("{s}\n", .{response});
        }
        try w.flush();
        return;
    }

    // Interactive REPL mode
    try w.print("nullclaw Agent -- Interactive Mode\n", .{});
    try w.print("Provider: {s} | Model: {s}\n", .{
        cfg.default_provider,
        cfg.default_model orelse "(default)",
    });
    if (session_id) |sid| {
        try w.print("Session: {s}\n", .{sid});
    }
    if (supports_streaming) {
        try w.print("Streaming: enabled\n", .{});
    }
    try w.print("Type your message (Ctrl+D or 'exit' to quit):\n\n", .{});
    try w.flush();

    // Load command history
    const history_path = cli_mod.defaultHistoryPath(allocator) catch null;
    defer if (history_path) |hp| allocator.free(hp);

    var repl_history: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        // Save history on exit
        if (history_path) |hp| {
            cli_mod.saveHistory(repl_history.items, hp) catch {};
        }
        for (repl_history.items) |entry| allocator.free(entry);
        repl_history.deinit(allocator);
    }

    // Seed history from file
    if (history_path) |hp| {
        const loaded = cli_mod.loadHistory(allocator, hp) catch null;
        if (loaded) |entries| {
            defer allocator.free(entries);
            for (entries) |entry| {
                repl_history.append(allocator, entry) catch {
                    allocator.free(entry);
                };
            }
        }
    }

    if (repl_history.items.len > 0) {
        try w.print("[History: {d} entries loaded]\n", .{repl_history.items.len});
        try w.flush();
    }

    var agent = try Agent.fromConfig(allocator, &cfg, provider_i, tools, mem_opt, obs);
    defer agent.deinit();

    // Enable streaming if provider supports it
    var stream_ctx: u8 = 0;
    if (supports_streaming) {
        agent.stream_callback = cliStreamCallback;
        agent.stream_ctx = @ptrCast(&stream_ctx);
    }

    const stdin = std.fs.File.stdin();
    var line_buf: [4096]u8 = undefined;

    while (true) {
        try w.print("> ", .{});
        try w.flush();

        // Read a line from stdin byte-by-byte
        var pos: usize = 0;
        while (pos < line_buf.len) {
            const n = stdin.read(line_buf[pos .. pos + 1]) catch return;
            if (n == 0) return; // EOF (Ctrl+D)
            if (line_buf[pos] == '\n') break;
            pos += 1;
        }
        const raw_line = line_buf[0..pos];
        const normalized_line = try normalizeCliLine(allocator, raw_line);
        defer if (normalized_line.owned) allocator.free(normalized_line.text);
        const line = normalized_line.text;

        if (line.len == 0) continue;
        if (cli_mod.CliChannel.isQuitCommand(line)) return;

        // Append to history (avoid leaking the duplicated line on append failure)
        const line_copy = allocator.dupe(u8, line) catch continue;
        repl_history.append(allocator, line_copy) catch {
            allocator.free(line_copy);
        };

        const response = agent.turn(line) catch |err| {
            try w.print("Error: {}\n", .{err});
            try w.flush();
            continue;
        };
        defer allocator.free(response);

        if (supports_streaming) {
            try w.print("\n\n", .{});
        } else {
            try w.print("\n{s}\n\n", .{response});
        }
        try w.flush();
    }
}

/// Process a single message through the full agent pipeline (for channel use).
/// Returns the agent's response. Caller owns the returned string.
pub fn processMessage(
    allocator: std.mem.Allocator,
    cfg: *const Config,
    provider_i: Provider,
    tools: []const Tool,
    mem: ?Memory,
    observer_i: Observer,
    message: []const u8,
) ![]const u8 {
    var agent = try Agent.fromConfig(allocator, cfg, provider_i, tools, mem, observer_i);
    defer agent.deinit();

    return agent.turn(message);
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "Agent.OwnedMessage toChatMessage" {
    const msg = Agent.OwnedMessage{
        .role = .user,
        .content = "hello",
    };
    const chat = msg.toChatMessage();
    try std.testing.expect(chat.role == .user);
    try std.testing.expectEqualStrings("hello", chat.content);
}

test "Agent trim history preserves system prompt" {
    const allocator = std.testing.allocator;

    // Create a minimal agent config
    const cfg = Config{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .allocator = allocator,
    };

    var noop = observability.NoopObserver{};

    // We can't create a real provider in tests, but we can test trimHistory
    // by creating an Agent with minimal fields
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = cfg.default_model orelse "test",
        .temperature = 0.7,
        .workspace_dir = cfg.workspace_dir,
        .max_tool_iterations = 10,
        .max_history_messages = 5,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    // Add system prompt
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system prompt"),
    });

    // Add more messages than max
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg {d}", .{i}),
        });
    }

    try std.testing.expect(agent.history.items.len == 11); // 1 system + 10 user

    agent.trimHistory();

    // System prompt should be preserved
    try std.testing.expect(agent.history.items[0].role == .system);
    try std.testing.expectEqualStrings("system prompt", agent.history.items[0].content);

    // Should be trimmed to max + 1 (system)
    try std.testing.expect(agent.history.items.len <= 6); // 1 system + 5 messages

    // Most recent message should be the last one added
    const last = agent.history.items[agent.history.items.len - 1];
    try std.testing.expectEqualStrings("msg 9", last.content);
}

test "Agent clear history" {
    const allocator = std.testing.allocator;

    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = true,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    try std.testing.expectEqual(@as(usize, 2), agent.historyLen());

    agent.clearHistory();

    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expect(!agent.has_system_prompt);
}

test "dispatcher module reexport" {
    // Verify dispatcher types are accessible
    _ = dispatcher.ParsedToolCall;
    _ = dispatcher.ToolExecutionResult;
    _ = dispatcher.parseToolCalls;
    _ = dispatcher.formatToolResults;
    _ = dispatcher.buildToolInstructions;
}

test "prompt module reexport" {
    _ = prompt.buildSystemPrompt;
    _ = prompt.PromptContext;
}

test "memory_loader module reexport" {
    _ = memory_loader.loadContext;
    _ = memory_loader.enrichMessage;
}

test {
    _ = dispatcher;
    _ = prompt;
    _ = memory_loader;
}

// ── Additional agent tests ──────────────────────────────────────

test "Agent.OwnedMessage system role" {
    const msg = Agent.OwnedMessage{
        .role = .system,
        .content = "system prompt",
    };
    const chat = msg.toChatMessage();
    try std.testing.expect(chat.role == .system);
    try std.testing.expectEqualStrings("system prompt", chat.content);
}

test "Agent.OwnedMessage assistant role" {
    const msg = Agent.OwnedMessage{
        .role = .assistant,
        .content = "I can help with that.",
    };
    const chat = msg.toChatMessage();
    try std.testing.expect(chat.role == .assistant);
    try std.testing.expectEqualStrings("I can help with that.", chat.content);
}

test "Agent initial state" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.5,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expectEqual(@as(u64, 0), agent.tokensUsed());
    try std.testing.expect(!agent.has_system_prompt);
}

test "Agent tokens tracking" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    agent.total_tokens = 100;
    try std.testing.expectEqual(@as(u64, 100), agent.tokensUsed());
    agent.total_tokens += 50;
    try std.testing.expectEqual(@as(u64, 150), agent.tokensUsed());
}

test "Agent trimHistory no-op when under limit" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    agent.trimHistory();
    try std.testing.expectEqual(@as(usize, 2), agent.historyLen());
}

test "Agent trimHistory without system prompt" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 3,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    // Add 6 user messages (no system prompt)
    for (0..6) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg {d}", .{i}),
        });
    }

    agent.trimHistory();
    // Should trim to max_history_messages (3) + 1 for system = 4, but no system
    try std.testing.expect(agent.history.items.len <= 4);
}

test "Agent clearHistory resets all state" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = true,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "hi"),
    });

    try std.testing.expectEqual(@as(usize, 3), agent.historyLen());
    try std.testing.expect(agent.has_system_prompt);

    agent.clearHistory();

    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expect(!agent.has_system_prompt);
}

test "Agent buildMessageSlice" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const messages = try agent.buildMessageSlice();
    defer allocator.free(messages);

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expect(messages[0].role == .system);
    try std.testing.expect(messages[1].role == .user);
    try std.testing.expectEqualStrings("sys", messages[0].content);
    try std.testing.expectEqualStrings("hello", messages[1].content);
}

test "Agent max_tool_iterations default" {
    try std.testing.expectEqual(@as(u32, 10), DEFAULT_MAX_TOOL_ITERATIONS);
}

test "Agent max_history default" {
    try std.testing.expectEqual(@as(u32, 50), DEFAULT_MAX_HISTORY);
}

test "Agent trimHistory keeps most recent messages" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 3,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
    defer agent.deinit();

    // Add system + 5 messages
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    for (0..5) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg-{d}", .{i}),
        });
    }

    agent.trimHistory();

    // Should keep system + last 3 messages
    try std.testing.expectEqual(@as(usize, 4), agent.historyLen());
    try std.testing.expect(agent.history.items[0].role == .system);
    // Last message should be msg-4
    try std.testing.expectEqualStrings("msg-4", agent.history.items[3].content);
}

test "Agent clearHistory then add messages" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = true,
    };
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "old"),
    });
    agent.clearHistory();

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "new"),
    });
    try std.testing.expectEqual(@as(usize, 1), agent.historyLen());
    try std.testing.expectEqualStrings("new", agent.history.items[0].content);
}

// ── buildAssistantHistoryWithToolCalls tests ─────────────────────

test "buildAssistantHistoryWithToolCalls with text and calls" {
    const allocator = std.testing.allocator;
    const calls = [_]ParsedToolCall{
        .{ .name = "shell", .arguments_json = "{\"command\":\"ls\"}" },
        .{ .name = "file_read", .arguments_json = "{\"path\":\"a.txt\"}" },
    };
    const result = try Agent.buildAssistantHistoryWithToolCalls(
        allocator,
        "Let me check that.",
        &calls,
    );
    defer allocator.free(result);

    // Should contain the response text
    try std.testing.expect(std.mem.indexOf(u8, result, "Let me check that.") != null);
    // Should contain tool_call XML tags
    try std.testing.expect(std.mem.indexOf(u8, result, "<tool_call>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</tool_call>") != null);
    // Should contain tool names
    try std.testing.expect(std.mem.indexOf(u8, result, "\"shell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"file_read\"") != null);
    // Should contain two tool_call tags
    var count: usize = 0;
    var search = result;
    while (std.mem.indexOf(u8, search, "<tool_call>")) |idx| {
        count += 1;
        search = search[idx + 11 ..];
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "buildAssistantHistoryWithToolCalls empty text" {
    const allocator = std.testing.allocator;
    const calls = [_]ParsedToolCall{
        .{ .name = "shell", .arguments_json = "{}" },
    };
    const result = try Agent.buildAssistantHistoryWithToolCalls(
        allocator,
        "",
        &calls,
    );
    defer allocator.free(result);

    // Should NOT start with a newline (no empty text prefix)
    try std.testing.expect(result[0] == '<');
    try std.testing.expect(std.mem.indexOf(u8, result, "<tool_call>") != null);
}

test "buildAssistantHistoryWithToolCalls no calls" {
    const allocator = std.testing.allocator;
    const result = try Agent.buildAssistantHistoryWithToolCalls(
        allocator,
        "Just text, no tools.",
        &.{},
    );
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Just text, no tools.\n", result);
}

test "buildAssistantHistoryWithToolCalls empty text and no calls" {
    const allocator = std.testing.allocator;
    const result = try Agent.buildAssistantHistoryWithToolCalls(
        allocator,
        "",
        &.{},
    );
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "buildAssistantHistoryWithToolCalls preserves arguments JSON" {
    const allocator = std.testing.allocator;
    const calls = [_]ParsedToolCall{
        .{ .name = "file_write", .arguments_json = "{\"path\":\"test.py\",\"content\":\"print('hello')\"}" },
    };
    const result = try Agent.buildAssistantHistoryWithToolCalls(
        allocator,
        "",
        &calls,
    );
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"file_write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "print('hello')") != null);
}

// ── parseStructuredToolCalls tests ──────────────────────────────

test "parseStructuredToolCalls converts ToolCalls to ParsedToolCalls" {
    const allocator = std.testing.allocator;
    const tool_calls = [_]providers.ToolCall{
        .{ .id = "call_1", .name = "shell", .arguments = "{\"command\":\"ls\"}" },
        .{ .id = "call_2", .name = "file_read", .arguments = "{\"path\":\"a.txt\"}" },
    };

    const result = try dispatcher.parseStructuredToolCalls(allocator, &tool_calls);
    defer {
        for (result) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("shell", result[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", result[0].arguments_json);
    try std.testing.expectEqualStrings("call_1", result[0].tool_call_id.?);
    try std.testing.expectEqualStrings("file_read", result[1].name);
    try std.testing.expectEqualStrings("call_2", result[1].tool_call_id.?);
}

test "parseStructuredToolCalls skips empty names" {
    const allocator = std.testing.allocator;
    const tool_calls = [_]providers.ToolCall{
        .{ .id = "tc1", .name = "", .arguments = "{}" },
        .{ .id = "tc2", .name = "shell", .arguments = "{}" },
    };

    const result = try dispatcher.parseStructuredToolCalls(allocator, &tool_calls);
    defer {
        for (result) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("shell", result[0].name);
}

test "parseStructuredToolCalls empty input" {
    const allocator = std.testing.allocator;
    const result = try dispatcher.parseStructuredToolCalls(allocator, &.{});
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "parseStructuredToolCalls empty id yields null tool_call_id" {
    const allocator = std.testing.allocator;
    const tool_calls = [_]providers.ToolCall{
        .{ .id = "", .name = "shell", .arguments = "{}" },
    };

    const result = try dispatcher.parseStructuredToolCalls(allocator, &tool_calls);
    defer {
        for (result) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].tool_call_id == null);
}

// ── Slash Command Tests ──────────────────────────────────────────

fn makeTestAgent(allocator: std.mem.Allocator) !Agent {
    var noop = observability.NoopObserver{};
    return Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
}

const StreamingTestScenario = enum {
    tool_then_text,
    empty_then_chat_text,
    empty_then_chat_empty,
};

const StreamingTestProvider = struct {
    scenario: StreamingTestScenario,
    stream_calls: usize = 0,
    chat_calls: usize = 0,

    pub fn provider(self: *StreamingTestProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
        .stream_chat = streamChatImpl,
        .supports_streaming = supportsStreamingImpl,
    };

    fn chatWithSystemImpl(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        return allocator.dupe(u8, "");
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!ChatResponse {
        const self: *StreamingTestProvider = @ptrCast(@alignCast(ptr));
        self.chat_calls += 1;
        return switch (self.scenario) {
            .tool_then_text => .{
                .content = try allocator.dupe(u8, "tool-finished"),
                .tool_calls = &.{},
                .usage = .{},
                .model = "",
            },
            .empty_then_chat_text => .{
                .content = try allocator.dupe(u8, "fallback reply"),
                .tool_calls = &.{},
                .usage = .{},
                .model = "",
            },
            .empty_then_chat_empty => .{
                .content = null,
                .tool_calls = &.{},
                .usage = .{},
                .model = "",
            },
        };
    }

    fn streamChatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
        _: []const u8,
        _: f64,
        callback: providers.StreamCallback,
        callback_ctx: *anyopaque,
    ) anyerror!providers.StreamChatResult {
        const self: *StreamingTestProvider = @ptrCast(@alignCast(ptr));
        self.stream_calls += 1;

        return switch (self.scenario) {
            .tool_then_text => if (self.stream_calls == 1) blk: {
                const calls = try allocator.alloc(providers.ToolCall, 1);
                calls[0] = .{
                    .id = try allocator.dupe(u8, "call_stream_1"),
                    .name = try allocator.dupe(u8, "test_tool"),
                    .arguments = try allocator.dupe(u8, "{\"value\":1}"),
                };
                break :blk .{
                    .content = null,
                    .tool_calls = calls,
                    .usage = .{},
                    .model = "",
                };
            } else blk: {
                const text = try allocator.dupe(u8, "tool-finished");
                callback(callback_ctx, providers.StreamChunk.textDelta(text));
                callback(callback_ctx, providers.StreamChunk.finalChunk());
                break :blk .{
                    .content = text,
                    .tool_calls = &.{},
                    .usage = .{},
                    .model = "",
                };
            },
            .empty_then_chat_text, .empty_then_chat_empty => .{
                .content = null,
                .tool_calls = &.{},
                .usage = .{},
                .model = "",
            },
        };
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return true;
    }

    fn supportsStreamingImpl(_: *anyopaque) bool {
        return true;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "stream-test-provider";
    }

    fn deinitImpl(_: *anyopaque) void {}
};

const CountingTestTool = struct {
    calls: usize = 0,

    pub fn tool(self: *CountingTestTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Tool.VTable{
        .execute = executeImpl,
        .name = nameImpl,
        .description = descriptionImpl,
        .parameters_json = paramsImpl,
    };

    fn executeImpl(
        ptr: *anyopaque,
        _: std.mem.Allocator,
        _: tools_mod.JsonObjectMap,
    ) anyerror!ToolResult {
        const self: *CountingTestTool = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return ToolResult.ok("ok");
    }

    fn nameImpl(_: *anyopaque) []const u8 {
        return "test_tool";
    }

    fn descriptionImpl(_: *anyopaque) []const u8 {
        return "test tool";
    }

    fn paramsImpl(_: *anyopaque) []const u8 {
        return "{\"type\":\"object\"}";
    }
};

fn makeStreamingAgent(
    allocator: std.mem.Allocator,
    provider_i: Provider,
    tools: []const Tool,
    workspace_dir: []const u8,
) !Agent {
    var noop = observability.NoopObserver{};
    const tool_specs = try allocator.alloc(ToolSpec, tools.len);
    for (tools, 0..) |t, i| {
        tool_specs[i] = .{
            .name = t.name(),
            .description = t.description(),
            .parameters_json = t.parametersJson(),
        };
    }

    return .{
        .allocator = allocator,
        .provider = provider_i,
        .tools = tools,
        .tool_specs = tool_specs,
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = workspace_dir,
        .max_tool_iterations = 6,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
}

const StreamCapture = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *StreamCapture) void {
        self.text.deinit(self.allocator);
    }

    fn onChunk(ctx: *anyopaque, chunk: providers.StreamChunk) void {
        if (chunk.is_final or chunk.delta.len == 0) return;
        const self: *StreamCapture = @ptrCast(@alignCast(ctx));
        self.text.appendSlice(self.allocator, chunk.delta) catch {};
    }
};

test "Agent turn executes tool when stream returns only tool_calls" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const workspace_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_dir);

    var provider_state = StreamingTestProvider{ .scenario = .tool_then_text };
    var tool_state = CountingTestTool{};
    var tools = [_]Tool{tool_state.tool()};
    var agent = try makeStreamingAgent(allocator, provider_state.provider(), &tools, workspace_dir);
    defer agent.deinit();
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    agent.has_system_prompt = true;

    var capture = StreamCapture{ .allocator = allocator };
    defer capture.deinit();
    agent.stream_callback = StreamCapture.onChunk;
    agent.stream_ctx = @ptrCast(&capture);

    const response = try agent.turn("run tool");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("tool-finished", response);
    try std.testing.expectEqual(@as(usize, 1), tool_state.calls);
    try std.testing.expectEqual(@as(usize, 2), provider_state.stream_calls);
    try std.testing.expectEqual(@as(usize, 0), provider_state.chat_calls);
}

test "Agent turn falls back to blocking chat when stream is empty" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const workspace_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_dir);

    var provider_state = StreamingTestProvider{ .scenario = .empty_then_chat_text };
    var tool_state = CountingTestTool{};
    var tools = [_]Tool{tool_state.tool()};
    var agent = try makeStreamingAgent(allocator, provider_state.provider(), &tools, workspace_dir);
    defer agent.deinit();
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    agent.has_system_prompt = true;

    var capture = StreamCapture{ .allocator = allocator };
    defer capture.deinit();
    agent.stream_callback = StreamCapture.onChunk;
    agent.stream_ctx = @ptrCast(&capture);

    const response = try agent.turn("hello");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("fallback reply", response);
    try std.testing.expectEqualStrings("fallback reply", capture.text.items);
    try std.testing.expectEqual(@as(usize, 1), provider_state.stream_calls);
    try std.testing.expectEqual(@as(usize, 1), provider_state.chat_calls);
}

test "Agent turn returns NoResponseContent when stream and blocking are both empty" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const workspace_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_dir);

    var provider_state = StreamingTestProvider{ .scenario = .empty_then_chat_empty };
    var tool_state = CountingTestTool{};
    var tools = [_]Tool{tool_state.tool()};
    var agent = try makeStreamingAgent(allocator, provider_state.provider(), &tools, workspace_dir);
    defer agent.deinit();
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    agent.has_system_prompt = true;

    var capture = StreamCapture{ .allocator = allocator };
    defer capture.deinit();
    agent.stream_callback = StreamCapture.onChunk;
    agent.stream_ctx = @ptrCast(&capture);

    try std.testing.expectError(error.NoResponseContent, agent.turn("hello"));
    try std.testing.expectEqual(@as(usize, 1), provider_state.stream_calls);
    try std.testing.expectEqual(@as(usize, 1), provider_state.chat_calls);
}

test "Agent hooks emit lifecycle events on normal turn" {
    const HookCapture = struct {
        message_received: usize = 0,
        agent_bootstrap: usize = 0,
        stream_fallback: usize = 0,
        turn_complete: usize = 0,
        last_response_len: usize = 0,
        last_used_tools: bool = false,

        fn onEvent(ctx_ptr: *anyopaque, event: *const HookEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            switch (event.*) {
                .message_received => self.message_received += 1,
                .agent_bootstrap => self.agent_bootstrap += 1,
                .stream_fallback => self.stream_fallback += 1,
                .turn_complete => |tc| {
                    self.turn_complete += 1;
                    self.last_response_len = tc.response_len;
                    self.last_used_tools = tc.used_tools;
                },
                else => {},
            }
        }
    };

    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const workspace_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_dir);

    var provider_state = StreamingTestProvider{ .scenario = .empty_then_chat_text };
    const no_tools = [_]Tool{};
    var agent = try makeStreamingAgent(allocator, provider_state.provider(), &no_tools, workspace_dir);
    defer agent.deinit();

    var hook_bus = HookBus.init(allocator);
    defer hook_bus.deinit();
    var hook_capture = HookCapture{};
    _ = try hook_bus.subscribe(null, HookCapture.onEvent, @ptrCast(&hook_capture));
    agent.setInternalHooks(&hook_bus);

    const response = try agent.turn("hello hooks");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("fallback reply", response);
    try std.testing.expectEqual(@as(usize, 1), hook_capture.message_received);
    try std.testing.expectEqual(@as(usize, 1), hook_capture.agent_bootstrap);
    try std.testing.expectEqual(@as(usize, 1), hook_capture.turn_complete);
    try std.testing.expectEqual(@as(usize, 0), hook_capture.stream_fallback);
    try std.testing.expectEqual(response.len, hook_capture.last_response_len);
    try std.testing.expect(!hook_capture.last_used_tools);
}

test "Agent hooks emit stream_fallback for empty streaming response" {
    const HookCapture = struct {
        stream_fallback: usize = 0,

        fn onEvent(ctx_ptr: *anyopaque, event: *const HookEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            if (event.* == .stream_fallback) self.stream_fallback += 1;
        }
    };

    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const workspace_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_dir);

    var provider_state = StreamingTestProvider{ .scenario = .empty_then_chat_text };
    const no_tools = [_]Tool{};
    var agent = try makeStreamingAgent(allocator, provider_state.provider(), &no_tools, workspace_dir);
    defer agent.deinit();

    var stream_capture = StreamCapture{ .allocator = allocator };
    defer stream_capture.deinit();
    agent.stream_callback = StreamCapture.onChunk;
    agent.stream_ctx = @ptrCast(&stream_capture);

    var hook_bus = HookBus.init(allocator);
    defer hook_bus.deinit();
    var hook_capture = HookCapture{};
    _ = try hook_bus.subscribe(.stream_fallback, HookCapture.onEvent, @ptrCast(&hook_capture));
    agent.setInternalHooks(&hook_bus);

    const response = try agent.turn("hello stream fallback");
    defer allocator.free(response);

    try std.testing.expectEqualStrings("fallback reply", response);
    try std.testing.expectEqual(@as(usize, 1), hook_capture.stream_fallback);
}

test "slash /new clears history" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add some history
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });
    agent.has_system_prompt = true;

    const response = (try agent.handleSlashCommand("/new")).?;
    defer allocator.free(response);

    try std.testing.expectEqualStrings("Session cleared.", response);
    try std.testing.expectEqual(@as(usize, 0), agent.historyLen());
    try std.testing.expect(!agent.has_system_prompt);
}

test "slash /help returns help text" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/help")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "/new") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/help") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/status") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/model") != null);
}

test "slash /status returns agent info" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.total_tokens = 42;
    const response = (try agent.handleSlashCommand("/status")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "test-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "42") != null);
}

test "slash /model switches model" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/model gpt-4o")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "gpt-4o") != null);
    try std.testing.expectEqualStrings("gpt-4o", agent.model_name);
}

test "slash /model without name shows current" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("/model ")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "test-model") != null);
}

test "non-slash message returns null" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = try agent.handleSlashCommand("hello world");
    try std.testing.expect(response == null);
}

test "slash command with whitespace" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    const response = (try agent.handleSlashCommand("  /help  ")).?;
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "/new") != null);
}

// ── Session Consolidation Enhancement Tests ─────────────────────

test "tokenEstimate empty history" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Empty history: (0 + 3) / 4 = 0
    try std.testing.expectEqual(@as(u64, 0), agent.tokenEstimate());
}

test "tokenEstimate with messages" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add messages with known content lengths
    // "hello" = 5 chars, "world" = 5 chars => total 10 chars => (10 + 3) / 4 = 3
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "world"),
    });

    try std.testing.expectEqual(@as(u64, 3), agent.tokenEstimate());
}

test "tokenEstimate heuristic accuracy" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // 400 chars should estimate ~100 tokens
    const content = try allocator.alloc(u8, 400);
    defer allocator.free(content);
    @memset(content, 'a');

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, content),
    });

    // (400 + 3) / 4 = 100
    try std.testing.expectEqual(@as(u64, 100), agent.tokenEstimate());
}

test "autoCompactHistory no-op below count and token thresholds" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    agent.token_limit = DEFAULT_TOKEN_LIMIT;

    // Add a few small messages — well below both thresholds
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const compacted = try agent.autoCompactHistory();
    try std.testing.expect(!compacted);
    try std.testing.expectEqual(@as(usize, 2), agent.historyLen());
}

test "DEFAULT_TOKEN_LIMIT constant" {
    try std.testing.expectEqual(@as(u64, 128_000), DEFAULT_TOKEN_LIMIT);
}

// ── Context Exhaustion Recovery Tests ────────────────────────────

test "forceCompressHistory keeps system + last 4 messages" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add system prompt + 8 messages
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system prompt"),
    });
    for (0..8) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg-{d}", .{i}),
        });
    }
    try std.testing.expectEqual(@as(usize, 9), agent.historyLen());

    const compressed = agent.forceCompressHistory();
    try std.testing.expect(compressed);

    // Should keep system + last 4
    try std.testing.expectEqual(@as(usize, 5), agent.historyLen());
    try std.testing.expect(agent.history.items[0].role == .system);
    try std.testing.expectEqualStrings("system prompt", agent.history.items[0].content);
    try std.testing.expectEqualStrings("msg-4", agent.history.items[1].content);
    try std.testing.expectEqualStrings("msg-7", agent.history.items[4].content);
}

test "forceCompressHistory without system prompt" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add 8 messages (no system prompt)
    for (0..8) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg-{d}", .{i}),
        });
    }

    const compressed = agent.forceCompressHistory();
    try std.testing.expect(compressed);

    // Should keep last 4
    try std.testing.expectEqual(@as(usize, 4), agent.historyLen());
    try std.testing.expectEqualStrings("msg-4", agent.history.items[0].content);
    try std.testing.expectEqualStrings("msg-7", agent.history.items[3].content);
}

test "forceCompressHistory no-op when history is small" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const compressed = agent.forceCompressHistory();
    try std.testing.expect(!compressed);
    try std.testing.expectEqual(@as(usize, 2), agent.historyLen());
}

test "CONTEXT_RECOVERY constants" {
    try std.testing.expectEqual(@as(usize, 6), CONTEXT_RECOVERY_MIN_HISTORY);
    try std.testing.expectEqual(@as(usize, 4), CONTEXT_RECOVERY_KEEP);
}

test "Agent streaming fields default to null" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
    };
    defer agent.deinit();

    try std.testing.expect(agent.stream_callback == null);
    try std.testing.expect(agent.stream_ctx == null);
}

test "cliStreamCallback handles empty delta" {
    const chunk = providers.StreamChunk.finalChunk();
    cliStreamCallback(undefined, chunk);
}

test "cliStreamCallback text delta chunk" {
    const chunk = providers.StreamChunk.textDelta("hello");
    try std.testing.expectEqualStrings("hello", chunk.delta);
    try std.testing.expect(!chunk.is_final);
    try std.testing.expectEqual(@as(u32, 2), chunk.token_count);
}

test "normalizeCliLine keeps valid utf8 unchanged" {
    const allocator = std.testing.allocator;
    const result = try normalizeCliLine(allocator, "你好");
    defer if (result.owned) allocator.free(result.text);

    try std.testing.expect(!result.owned);
    try std.testing.expectEqualStrings("你好", result.text);
}

test "normalizeCliLine converts GBK bytes on windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const gbk_hello = [_]u8{ 0xC4, 0xE3, 0xBA, 0xC3 }; // "你好" in GBK/CP936
    const result = try normalizeCliLine(allocator, &gbk_hello);
    defer if (result.owned) allocator.free(result.text);

    try std.testing.expect(result.owned);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.text));
    try std.testing.expectEqualStrings("你好", result.text);
}

// ── Bug regression tests ─────────────────────────────────────────

// Bug 1: /model command should dupe the arg to avoid use-after-free.
// model_name must survive past the stack buffer that held the original message.
test "slash /model dupe prevents use-after-free" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Build message in a buffer that we then invalidate (simulate stack lifetime end)
    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "/model new-model-xyz", .{}) catch unreachable;
    const response = (try agent.handleSlashCommand(msg)).?;
    defer allocator.free(response);

    // Overwrite the source buffer to verify model_name is an independent copy
    @memset(&msg_buf, 0);
    try std.testing.expectEqualStrings("new-model-xyz", agent.model_name);
}

// Bug 2: @intCast on negative i64 duration should not panic.
// Simulate by verifying the @max(0, ...) clamping logic.
test "milliTimestamp negative difference clamps to zero" {
    // Simulate: timer_start is in the future relative to "now" (negative diff)
    const timer_start = std.time.milliTimestamp() + 10_000;
    const diff = std.time.milliTimestamp() - timer_start;
    // diff < 0 here; @max(0, diff) must clamp to 0 without panic
    const clamped = @max(0, diff);
    const duration: u64 = @as(u64, @intCast(clamped));
    try std.testing.expectEqual(@as(u64, 0), duration);
}

test "Agent streaming fields can be set" {
    const allocator = std.testing.allocator;
    var noop = observability.NoopObserver{};
    var agent = Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
    };
    defer agent.deinit();

    var ctx: u8 = 42;
    agent.stream_callback = cliStreamCallback;
    agent.stream_ctx = @ptrCast(&ctx);

    try std.testing.expect(agent.stream_callback != null);
    try std.testing.expect(agent.stream_ctx != null);
}

test "hashParsedToolCalls stable for same input" {
    const calls_a = [_]ParsedToolCall{
        .{ .name = "shell", .arguments_json = "{\"command\":\"ls\"}", .tool_call_id = "tc1" },
        .{ .name = "file_read", .arguments_json = "{\"path\":\"a.txt\"}", .tool_call_id = "tc2" },
    };
    const calls_b = [_]ParsedToolCall{
        .{ .name = "shell", .arguments_json = "{\"command\":\"ls\"}", .tool_call_id = "tc1" },
        .{ .name = "file_read", .arguments_json = "{\"path\":\"a.txt\"}", .tool_call_id = "tc2" },
    };
    const calls_c = [_]ParsedToolCall{
        .{ .name = "shell", .arguments_json = "{\"command\":\"pwd\"}", .tool_call_id = "tc1" },
        .{ .name = "file_read", .arguments_json = "{\"path\":\"a.txt\"}", .tool_call_id = "tc2" },
    };

    const h1 = hashParsedToolCalls(&calls_a);
    const h2 = hashParsedToolCalls(&calls_b);
    const h3 = hashParsedToolCalls(&calls_c);

    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}

test "isAbabToolPattern detects pattern" {
    const sigs_true = [_]u64{ 11, 22, 11, 22 };
    const sigs_false_same = [_]u64{ 11, 11, 11, 11 };
    const sigs_false_short = [_]u64{ 11, 22, 11 };
    const sigs_false_diff = [_]u64{ 11, 22, 33, 22 };

    try std.testing.expect(isAbabToolPattern(&sigs_true));
    try std.testing.expect(!isAbabToolPattern(&sigs_false_same));
    try std.testing.expect(!isAbabToolPattern(&sigs_false_short));
    try std.testing.expect(!isAbabToolPattern(&sigs_false_diff));
}

const LoopBreakerProvider = struct {
    pub fn provider(self: *LoopBreakerProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
    };

    fn chatWithSystemImpl(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        return allocator.dupe(u8, "");
    }

    fn chatImpl(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!ChatResponse {
        const calls = try allocator.alloc(providers.ToolCall, 1);
        calls[0] = .{
            .id = try allocator.dupe(u8, "call_loop"),
            .name = try allocator.dupe(u8, "test_tool"),
            .arguments = try allocator.dupe(u8, "{\"x\":1}"),
        };
        return .{
            .content = null,
            .tool_calls = calls,
            .usage = .{},
            .model = "",
        };
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return true;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "loop-breaker-provider";
    }

    fn deinitImpl(_: *anyopaque) void {}
};

test "Agent tool loop breaker stops repeated native tool calls" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const workspace_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_dir);

    var provider_state = LoopBreakerProvider{};
    var tool_state = CountingTestTool{};
    var tools = [_]Tool{tool_state.tool()};
    var agent = try makeStreamingAgent(allocator, provider_state.provider(), &tools, workspace_dir);
    defer agent.deinit();
    agent.max_tool_iterations = 20;
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    agent.has_system_prompt = true;

    const response = try agent.turn("trigger loop");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Stopped due to repeated tool-call loop") != null);
    try std.testing.expect(tool_state.calls < agent.max_tool_iterations);
}
