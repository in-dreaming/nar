//! Bounded, owned context assembly, session history, tool visibility, and budgets.
const std = @import("std");
const domain = @import("../foundation/domain.zig");
const model = @import("../model/model.zig");
const tool = @import("../tool/runtime.zig");

const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};

/// A host-owned world section is copied into this immutable snapshot.
pub const WorldSection = struct { name: []const u8, payload: []const u8 };
/// Immutable owned world view. It may safely outlive the host buffers supplied to `initCopy`.
pub const WorldSnapshot = struct {
    allocator: std.mem.Allocator,
    revision: domain.WorldRevision,
    captured_at: domain.Timestamp,
    sections: []WorldSection,
    pub fn initCopy(allocator: std.mem.Allocator, revision: domain.WorldRevision, captured_at: domain.Timestamp, source: []const WorldSection) !WorldSnapshot {
        if (!revision.isValid()) return error.InvalidArgument;
        const sections = try allocator.alloc(WorldSection, source.len);
        errdefer allocator.free(sections);
        var initialized: usize = 0;
        errdefer for (sections[0..initialized]) |section| {
            allocator.free(section.name);
            allocator.free(section.payload);
        };
        for (source, 0..) |value, index| {
            if (value.name.len == 0 or !std.unicode.utf8ValidateSlice(value.name) or !std.unicode.utf8ValidateSlice(value.payload)) return error.InvalidArgument;
            const name = try allocator.dupe(u8, value.name);
            errdefer allocator.free(name);
            const payload = try allocator.dupe(u8, value.payload);
            sections[index] = .{ .name = name, .payload = payload };
            initialized += 1;
        }
        return .{ .allocator = allocator, .revision = revision, .captured_at = captured_at, .sections = sections };
    }
    pub fn deinit(self: *WorldSnapshot) void {
        for (self.sections) |value| {
            self.allocator.free(value.name);
            self.allocator.free(value.payload);
        }
        self.allocator.free(self.sections);
        self.sections = &.{};
    }
};

pub const ContextStrategy = struct { max_history_messages: usize = 16, max_tools: usize = 32 };
/// Static agent configuration is borrowed by the caller; `ContextBuilder.build` copies all retained bytes.
pub const AgentDefinition = struct {
    system_context: []const u8 = "",
    static_context: []const u8 = "",
    model_id: []const u8,
    allowed_tools: []const []const u8 = &.{},
    default_budget: TurnBudgetLimits = .{},
    context_strategy: ContextStrategy = .{},
};

pub const SessionKind = enum { message, tool_call, tool_result, turn_outcome };
pub const SessionEntry = struct { kind: SessionKind, role: model.MessageRole, content: []const u8 };
/// Mutex-protected in-memory working history. Append copies its input; snapshots are independently owned.
pub const MemorySession = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(SessionEntry) = .empty,
    mutex: Mutex = .{},
    pub fn init(allocator: std.mem.Allocator) MemorySession {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *MemorySession) void {
        self.clear();
        self.entries.deinit(self.allocator);
        self.entries = .empty;
    }
    pub fn append(self: *MemorySession, kind: SessionKind, role: model.MessageRole, content: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidArgument;
        const copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(copy);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.entries.append(self.allocator, .{ .kind = kind, .role = role, .content = copy });
    }
    pub fn clear(self: *MemorySession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| self.allocator.free(entry.content);
        self.entries.clearRetainingCapacity();
    }
    /// Returns an owned point-in-time view; callers must call `SessionSnapshot.deinit`.
    pub fn snapshot(self: *MemorySession, allocator: std.mem.Allocator) !SessionSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entries = try allocator.alloc(SessionEntry, self.entries.items.len);
        errdefer allocator.free(entries);
        var initialized: usize = 0;
        errdefer for (entries[0..initialized]) |entry| allocator.free(entry.content);
        for (self.entries.items, 0..) |entry, index| {
            entries[index] = .{ .kind = entry.kind, .role = entry.role, .content = try allocator.dupe(u8, entry.content) };
            initialized += 1;
        }
        return .{ .allocator = allocator, .entries = entries };
    }
};
pub const SessionSnapshot = struct {
    allocator: std.mem.Allocator,
    entries: []SessionEntry,
    pub fn deinit(self: *SessionSnapshot) void {
        for (self.entries) |entry| self.allocator.free(entry.content);
        self.allocator.free(self.entries);
        self.entries = &.{};
    }
};

pub const Estimator = union(enum) { utf8_bytes: void, provider: *const fn ([]const u8) u64 };
pub fn estimateTokens(estimator: Estimator, bytes: []const u8) u64 {
    return switch (estimator) {
        .utf8_bytes => bytes.len,
        .provider => |callback| callback(bytes),
    };
}

pub const TurnBudgetLimits = struct { wall_time_ns: u64 = 0, model_calls: u64 = 0, tool_calls: u64 = 0, context_tokens: u64 = 0, output_tokens: u64 = 0, cost_micros: u64 = 0, trace_bytes: u64 = 0 };
pub const BudgetKind = enum { model_calls, tool_calls, context_tokens, output_tokens, cost_micros, trace_bytes };
/// Per-turn checked accounting. A zero limit means unlimited; overflow is always `BudgetExceeded`.
pub const TurnBudget = struct {
    limits: TurnBudgetLimits,
    used: TurnBudgetLimits = .{},
    start_ns: u64,
    pub fn init(limits: TurnBudgetLimits, start_ns: u64) TurnBudget {
        return .{ .limits = limits, .start_ns = start_ns };
    }
    pub fn check(self: *const TurnBudget, now_ns: u64, cancellation: ?*const domain.CancellationToken) domain.Error!void {
        if (cancellation) |token| if (token.isCancelled()) return error.Cancelled;
        if (self.limits.wall_time_ns != 0 and (now_ns < self.start_ns or now_ns - self.start_ns > self.limits.wall_time_ns)) return error.Timeout;
    }
    pub fn charge(self: *TurnBudget, kind: BudgetKind, amount: u64) domain.Error!void {
        const used = field(&self.used, kind);
        const limit = field(&self.limits, kind);
        const next = std.math.add(u64, used.*, amount) catch return error.BudgetExceeded;
        if (limit.* != 0 and next > limit.*) return error.BudgetExceeded;
        used.* = next;
    }
    fn field(value: *TurnBudgetLimits, kind: BudgetKind) *u64 {
        return switch (kind) {
            .model_calls => &value.model_calls,
            .tool_calls => &value.tool_calls,
            .context_tokens => &value.context_tokens,
            .output_tokens => &value.output_tokens,
            .cost_micros => &value.cost_micros,
            .trace_bytes => &value.trace_bytes,
        };
    }
};

pub const ToolResolver = struct {
    allowed_names: []const []const u8 = &.{},
    capabilities: tool.CapabilitySet = .{ .bits = 0 },
    shipping: bool = false,
    runtime_profile: bool = true,
    max_tools: usize = 32,
    /// Returns owned, deterministic schemas. Unauthorized descriptors never appear in the result.
    pub fn resolve(self: ToolResolver, allocator: std.mem.Allocator, descriptors: []const tool.ToolDescriptor) !ResolvedTools {
        var selected = std.ArrayListUnmanaged(model.ToolSchema).empty;
        errdefer {
            for (selected.items) |schema| {
                allocator.free(@constCast(schema.name));
                allocator.free(@constCast(schema.json_schema));
            }
            selected.deinit(allocator);
        }
        for (descriptors) |descriptor| {
            if (!contains(self.allowed_names, descriptor.name)) continue;
            if (!self.capabilities.contains(descriptor.required_capabilities) or (self.shipping and descriptor.flags.debug_only)) continue;
            if ((!self.runtime_profile and !descriptor.profiles.minimal) or (self.runtime_profile and !descriptor.profiles.runtime)) continue;
            const name = try allocator.dupe(u8, descriptor.name);
            errdefer allocator.free(name);
            const schema = try allocator.dupe(u8, descriptor.input_schema);
            errdefer allocator.free(schema);
            try selected.append(allocator, .{ .name = name, .json_schema = schema });
        }
        std.mem.sort(model.ToolSchema, selected.items, {}, lessSchema);
        if (selected.items.len > self.max_tools) {
            for (selected.items[self.max_tools..]) |schema| {
                allocator.free(@constCast(schema.name));
                allocator.free(@constCast(schema.json_schema));
            }
            selected.shrinkRetainingCapacity(self.max_tools);
        }
        return .{ .allocator = allocator, .schemas = try selected.toOwnedSlice(allocator) };
    }
};
pub const ResolvedTools = struct {
    allocator: std.mem.Allocator,
    schemas: []model.ToolSchema,
    pub fn deinit(self: *ResolvedTools) void {
        for (self.schemas) |schema| {
            self.allocator.free(@constCast(schema.name));
            self.allocator.free(@constCast(schema.json_schema));
        }
        self.allocator.free(self.schemas);
        self.schemas = &.{};
    }
};

pub const ContextItemSource = enum { system, static, world, history, current_input, tool_result };
pub const TrimReason = enum { history_strategy, budget };
pub const ContextItem = struct { source: ContextItemSource, bytes: usize, trimmed: bool = false, trim_reason: ?TrimReason = null };
pub const ContextManifest = struct {
    allocator: std.mem.Allocator,
    items: []ContextItem,
    pub fn deinit(self: *ContextManifest) void {
        self.allocator.free(self.items);
        self.items = &.{};
    }
};
pub const BuildInput = struct { world: *const WorldSnapshot, session: *const SessionSnapshot, current_input: []const u8, current_tool_result: ?[]const u8 = null, descriptors: []const tool.ToolDescriptor = &.{}, budget: ?*TurnBudget = null };
/// An owned model request and manifest. All slices exposed by `request` remain valid until `deinit`.
pub const BuiltContext = struct {
    allocator: std.mem.Allocator,
    model_id: []u8,
    messages: []model.ModelMessage,
    blocks: []model.ContentBlock,
    tools: ResolvedTools,
    manifest: ContextManifest,
    pub fn request(self: *const BuiltContext) model.ModelRequest {
        return .{ .model_id = self.model_id, .messages = self.messages, .tools = self.tools.schemas };
    }
    pub fn deinit(self: *BuiltContext) void {
        for (self.blocks) |block| if (block == .text) self.allocator.free(@constCast(block.text));
        self.allocator.free(self.blocks);
        self.allocator.free(self.messages);
        self.allocator.free(self.model_id);
        self.tools.deinit();
        self.manifest.deinit();
    }
};

/// Builds in fixed priority order. System, static context, and a current tool result are mandatory; any budget too small for them fails.
pub const ContextBuilder = struct {
    allocator: std.mem.Allocator,
    definition: AgentDefinition,
    estimator: Estimator = .{ .utf8_bytes = {} },
    resolver_capabilities: tool.CapabilitySet = .{ .bits = 0 },
    shipping: bool = false,
    runtime_profile: bool = true,
    pub fn build(self: ContextBuilder, input: BuildInput) !BuiltContext {
        if (!std.unicode.utf8ValidateSlice(self.definition.system_context) or !std.unicode.utf8ValidateSlice(input.current_input)) return error.InvalidArgument;
        var entries = std.ArrayListUnmanaged(struct { source: ContextItemSource, role: model.MessageRole, text: []const u8, mandatory: bool, strategy_trimmed: bool = false }).empty;
        defer entries.deinit(self.allocator);
        try entries.append(self.allocator, .{ .source = .system, .role = .system, .text = self.definition.system_context, .mandatory = true });
        if (self.definition.static_context.len != 0) try entries.append(self.allocator, .{ .source = .static, .role = .system, .text = self.definition.static_context, .mandatory = true });
        for (input.world.sections) |section| try entries.append(self.allocator, .{ .source = .world, .role = .system, .text = section.payload, .mandatory = false });
        const history_start = if (input.session.entries.len > self.definition.context_strategy.max_history_messages) input.session.entries.len - self.definition.context_strategy.max_history_messages else 0;
        for (input.session.entries, 0..) |entry, index| try entries.append(self.allocator, .{ .source = .history, .role = entry.role, .text = entry.content, .mandatory = false, .strategy_trimmed = index < history_start });
        try entries.append(self.allocator, .{ .source = .current_input, .role = .user, .text = input.current_input, .mandatory = true });
        if (input.current_tool_result) |result| try entries.append(self.allocator, .{ .source = .tool_result, .role = .tool, .text = result, .mandatory = true });
        var kept = try self.allocator.alloc(bool, entries.items.len);
        defer self.allocator.free(kept);
        for (entries.items, 0..) |entry, index| kept[index] = !entry.strategy_trimmed;
        if (input.budget) |budget| {
            var total: u64 = 0;
            for (entries.items, 0..) |entry, index| {
                if (!kept[index]) continue;
                const amount = estimateTokens(self.estimator, entry.text);
                const next = std.math.add(u64, total, amount) catch return error.BudgetExceeded;
                if (budget.limits.context_tokens != 0 and next > budget.limits.context_tokens) {
                    if (entry.mandatory) return error.BudgetExceeded;
                    kept[index] = false;
                } else total = next;
            }
            try budget.charge(.context_tokens, total);
        }
        var kept_count: usize = 0;
        for (kept) |include| {
            if (include) kept_count += 1;
        }
        const messages = try self.allocator.alloc(model.ModelMessage, kept_count);
        errdefer self.allocator.free(messages);
        var output_index: usize = 0;
        const blocks = try self.allocator.alloc(model.ContentBlock, kept_count);
        errdefer self.allocator.free(blocks);
        errdefer for (blocks[0..output_index]) |block| if (block == .text) self.allocator.free(@constCast(block.text));
        const items = try self.allocator.alloc(ContextItem, entries.items.len);
        errdefer self.allocator.free(items);
        for (entries.items, 0..) |entry, index| {
            items[index] = .{ .source = entry.source, .bytes = entry.text.len, .trimmed = !kept[index], .trim_reason = if (kept[index]) null else if (entry.strategy_trimmed) .history_strategy else .budget };
            if (!kept[index]) continue;
            const copy = try self.allocator.dupe(u8, entry.text);
            blocks[output_index] = .{ .text = copy };
            messages[output_index] = .{ .role = entry.role, .content = blocks[output_index .. output_index + 1] };
            output_index += 1;
        }
        var tools = try (ToolResolver{ .allowed_names = self.definition.allowed_tools, .capabilities = self.resolver_capabilities, .shipping = self.shipping, .runtime_profile = self.runtime_profile, .max_tools = self.definition.context_strategy.max_tools }).resolve(self.allocator, input.descriptors);
        errdefer tools.deinit();
        return .{ .allocator = self.allocator, .model_id = try self.allocator.dupe(u8, self.definition.model_id), .messages = messages, .blocks = blocks, .tools = tools, .manifest = .{ .allocator = self.allocator, .items = items } };
    }
};

/// Canonicalizes a JSON value with lexicographically ordered object keys. Array order is retained.
pub fn canonicalJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{ .duplicate_field_behavior = .@"error", .allocate = .alloc_always }) catch return error.InvalidArgument;
    defer parsed.deinit();
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    try writeJson(parsed.value, &output, allocator);
    return output.toOwnedSlice();
}
/// Returns an owned repeat-detection key made from a tool name and canonical JSON arguments.
pub fn loopKey(allocator: std.mem.Allocator, name: []const u8, arguments: []const u8) ![]u8 {
    const canonical = try canonicalJson(allocator, arguments);
    defer allocator.free(canonical);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ name, canonical });
}
fn writeJson(value: std.json.Value, output: *std.array_list.Managed(u8), allocator: std.mem.Allocator) !void {
    switch (value) {
        .object => |object| {
            try output.append('{');
            const Entry = struct { key: []const u8, value: std.json.Value };
            var values = std.array_list.Managed(Entry).init(allocator);
            defer values.deinit();
            var it = object.iterator();
            while (it.next()) |entry| try values.append(.{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
            std.mem.sort(Entry, values.items, {}, struct {
                fn less(_: void, a: Entry, b: Entry) bool {
                    return std.mem.order(u8, a.key, b.key) == .lt;
                }
            }.less);
            for (values.items, 0..) |entry, index| {
                if (index != 0) try output.append(',');
                try writeString(output, entry.key);
                try output.append(':');
                try writeJson(entry.value, output, allocator);
            }
            try output.append('}');
        },
        .array => |array| {
            try output.append('[');
            for (array.items, 0..) |item, index| {
                if (index != 0) try output.append(',');
                try writeJson(item, output, allocator);
            }
            try output.append(']');
        },
        .null => try output.appendSlice("null"),
        .bool => |boolean| try output.appendSlice(if (boolean) "true" else "false"),
        .integer => |integer| {
            var buffer: [32]u8 = undefined;
            try output.appendSlice(try std.fmt.bufPrint(&buffer, "{d}", .{integer}));
        },
        .float => |float| {
            var buffer: [64]u8 = undefined;
            try output.appendSlice(try std.fmt.bufPrint(&buffer, "{d}", .{float}));
        },
        .number_string => |number| try output.appendSlice(number),
        .string => |string| try writeString(output, string),
    }
}
fn writeString(output: *std.array_list.Managed(u8), value: []const u8) !void {
    try output.append('"');
    for (value) |byte| switch (byte) {
        '"' => try output.appendSlice("\\\""),
        '\\' => try output.appendSlice("\\\\"),
        '\n' => try output.appendSlice("\\n"),
        '\r' => try output.appendSlice("\\r"),
        '\t' => try output.appendSlice("\\t"),
        0...7, 11, 14...0x1f => {
            var buffer: [6]u8 = undefined;
            try output.appendSlice(try std.fmt.bufPrint(&buffer, "\\u00{x:0>2}", .{byte}));
        },
        else => try output.append(byte),
    };
    try output.append('"');
}
fn contains(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}
fn lessSchema(_: void, a: model.ToolSchema, b: model.ToolSchema) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}
