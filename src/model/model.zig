//! Provider-neutral streaming model contracts and deterministic test backend.
const std = @import("std");
const foundation = @import("foundation");
const domain = @import("../foundation/domain.zig");

const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};

/// Capabilities advertised by a model before a request is accepted.
pub const Capabilities = packed struct(u8) {
    streaming: bool = false,
    tool_calling: bool = false,
    vision: bool = false,
    json_mode: bool = false,
    _reserved: u4 = 0,

    /// Returns whether this capability set includes every requested capability.
    pub fn supports(self: Capabilities, required: Capabilities) bool {
        return (!required.streaming or self.streaming) and
            (!required.tool_calling or self.tool_calling) and
            (!required.vision or self.vision) and
            (!required.json_mode or self.json_mode);
    }
};

/// Immutable provider/model metadata. Its strings are borrowed from the backend.
pub const ModelDescriptor = struct {
    provider_id: []const u8,
    model_id: []const u8,
    capabilities: Capabilities = .{},
    context_window_tokens: u32 = 0,
    max_output_tokens: u32 = 0,
    priority: i32 = 0,
};

/// A JSON Schema view for one callable tool. Both slices are borrowed by start.
pub const ToolSchema = struct { name: []const u8, json_schema: []const u8 };
pub const MessageRole = enum { system, user, assistant, tool };
/// One multimodal message block. Image URLs require the vision capability.
pub const ContentBlock = union(enum) { text: []const u8, image_url: []const u8 };
/// Borrowed message view valid through `Backend.start`.
pub const ModelMessage = struct { role: MessageRole, content: []const ContentBlock };

/// Borrowed request view. Backends copy any data retained after `start` returns.
pub const ModelRequest = struct {
    model_id: []const u8,
    prompt: []const u8 = "",
    messages: []const ModelMessage = &.{},
    tools: []const ToolSchema = &.{},
    require_json: bool = false,
    allocation_budget: ?*foundation.memory.AllocationBudget = null,

    /// Reports whether the request contains image content.
    pub fn requiresVision(self: ModelRequest) bool {
        for (self.messages) |message| for (message.content) |block| switch (block) {
            .image_url => return true,
            .text => {},
        };
        return false;
    }
};

pub const Usage = struct { input_tokens: u32 = 0, output_tokens: u32 = 0 };
pub const FinishReason = enum { stop, tool_calls, length, content_filter };
/// Generation-checked request handle. A zero generation is invalid.
pub const ModelRequestHandle = struct {
    index: u32 = 0,
    generation: u32 = 0,
    pub fn isValid(self: ModelRequestHandle) bool {
        return self.generation != 0;
    }
};

/// A caller-owned pull event. Release buffer-bearing events with `deinit`.
pub const ModelEvent = union(enum) {
    start: void,
    text_delta: foundation.memory.SharedBuffer,
    tool_call_start: ToolCallStart,
    arguments_delta: foundation.memory.SharedBuffer,
    tool_call_end: ToolCallEnd,
    usage: Usage,
    finish: FinishReason,
    @"error": domain.ErrorCode,
    cancelled: void,

    pub const ToolCallStart = struct { call_id: foundation.memory.SharedBuffer, name: foundation.memory.SharedBuffer };
    pub const ToolCallEnd = struct { call_id: foundation.memory.SharedBuffer };

    pub fn isTerminal(self: ModelEvent) bool {
        return switch (self) {
            .finish, .@"error", .cancelled => true,
            else => false,
        };
    }
    pub fn deinit(self: *ModelEvent) void {
        switch (self.*) {
            .text_delta, .arguments_delta => |*buffer| buffer.release(),
            .tool_call_start => |*value| {
                value.call_id.release();
                value.name.release();
            },
            .tool_call_end => |*value| value.call_id.release(),
            else => {},
        }
        self.* = .{ .start = {} };
    }
};

/// Erased pull-model interface. Calls for one request may be made from one
/// consumer thread; implementations must document any broader thread safety.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        descriptor: *const fn (*anyopaque) ModelDescriptor,
        start: *const fn (*anyopaque, ModelRequest) anyerror!ModelRequestHandle,
        poll: *const fn (*anyopaque, ModelRequestHandle) anyerror!?ModelEvent,
        cancel: *const fn (*anyopaque, ModelRequestHandle) anyerror!void,
        release: *const fn (*anyopaque, ModelRequestHandle) void,
    };
    pub fn descriptor(self: Backend) ModelDescriptor {
        return self.vtable.descriptor(self.ptr);
    }
    pub fn start(self: Backend, request: ModelRequest) !ModelRequestHandle {
        return self.vtable.start(self.ptr, request);
    }
    pub fn poll(self: Backend, handle: ModelRequestHandle) !?ModelEvent {
        return self.vtable.poll(self.ptr, handle);
    }
    pub fn cancel(self: Backend, handle: ModelRequestHandle) !void {
        return self.vtable.cancel(self.ptr, handle);
    }
    pub fn release(self: Backend, handle: ModelRequestHandle) void {
        self.vtable.release(self.ptr, handle);
    }
};

const Entry = struct { descriptor: ModelDescriptor, backend: Backend };
/// Mutex-protected, non-owning backend registry. Registered backends must outlive it.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Registry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| {
            self.allocator.free(@constCast(entry.descriptor.provider_id));
            self.allocator.free(@constCast(entry.descriptor.model_id));
        }
        self.entries.deinit(self.allocator);
        self.entries = .empty;
    }
    /// Copies descriptor IDs and rejects empty or duplicate provider/model pairs.
    pub fn register(self: *Registry, backend: Backend) !void {
        const raw = backend.descriptor();
        if (raw.provider_id.len == 0 or raw.model_id.len == 0) return error.InvalidArgument;
        const provider = try self.allocator.dupe(u8, raw.provider_id);
        errdefer self.allocator.free(provider);
        const model = try self.allocator.dupe(u8, raw.model_id);
        errdefer self.allocator.free(model);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.descriptor.provider_id, provider) and std.mem.eql(u8, entry.descriptor.model_id, model)) return error.InvalidState;
        try self.entries.append(self.allocator, .{ .descriptor = .{ .provider_id = provider, .model_id = model, .capabilities = raw.capabilities, .context_window_tokens = raw.context_window_tokens, .max_output_tokens = raw.max_output_tokens, .priority = raw.priority }, .backend = backend });
    }
    /// Returns a registered backend or null. The returned backend is non-owning.
    pub fn find(self: *Registry, provider_id: []const u8, model_id: []const u8) ?Backend {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.descriptor.provider_id, provider_id) and std.mem.eql(u8, entry.descriptor.model_id, model_id)) return entry.backend;
        return null;
    }
};

/// Deterministic selection constraints. An explicit model never falls back to another.
pub const RouteRequest = struct {
    provider_id: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    allowed_models: []const []const u8 = &.{},
    required_capabilities: Capabilities = .{},
};

/// Resolves registered models by explicit IDs, allow list, capabilities, priority, then IDs.
pub const Router = struct {
    registry: *Registry,
    pub fn resolve(self: Router, provider_id: []const u8, request: ModelRequest) !Backend {
        return self.route(.{ .provider_id = provider_id, .model_id = request.model_id, .required_capabilities = requirements(request) });
    }
    pub fn route(self: Router, route_request: RouteRequest) !Backend {
        self.registry.mutex.lock();
        defer self.registry.mutex.unlock();
        var selected: ?Entry = null;
        for (self.registry.entries.items) |entry| {
            if (route_request.provider_id) |provider| if (!std.mem.eql(u8, provider, entry.descriptor.provider_id)) continue;
            if (route_request.model_id) |model| if (!std.mem.eql(u8, model, entry.descriptor.model_id)) continue;
            if (route_request.allowed_models.len != 0 and !contains(route_request.allowed_models, entry.descriptor.model_id)) continue;
            if (!entry.descriptor.capabilities.supports(route_request.required_capabilities)) continue;
            if (selected == null or comesBefore(entry.descriptor, selected.?.descriptor)) selected = entry;
        }
        return (selected orelse return error.ModelUnavailable).backend;
    }
};

pub const MockStep = union(enum) {
    start: void,
    text_delta: []const u8,
    tool_call_start: struct { call_id: []const u8, name: []const u8 },
    arguments_delta: []const u8,
    tool_call_end: []const u8,
    usage: Usage,
    finish: FinishReason,
    @"error": domain.ErrorCode,
    pending_ticks: u32,
};
const OwnedStep = union(enum) {
    start: void,
    text_delta: []u8,
    tool_call_start: struct { call_id: []u8, name: []u8 },
    arguments_delta: []u8,
    tool_call_end: []u8,
    usage: Usage,
    finish: FinishReason,
    @"error": domain.ErrorCode,
    pending_ticks: u32,
    fn deinit(self: *OwnedStep, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text_delta, .arguments_delta, .tool_call_end => |bytes| allocator.free(bytes),
            .tool_call_start => |value| {
                allocator.free(value.call_id);
                allocator.free(value.name);
            },
            else => {},
        }
    }
};
const Slot = struct {
    generation: u32 = 1,
    active: bool = false,
    cursor: usize = 0,
    pending_step: ?usize = null,
    pending_remaining: u32 = 0,
    terminal: bool = false,
    cancelled: bool = false,
    usage: Usage = .{},
    budget: ?*foundation.memory.AllocationBudget = null,
};

/// Deterministic pull backend. Script payloads are copied at initialization and
/// each request owns independent progress, so polling uses no sleep or shared script mutation.
pub const MockBackend = struct {
    allocator: std.mem.Allocator,
    descriptor_value: ModelDescriptor,
    owned_provider_id: []u8,
    owned_model_id: []u8,
    steps: []OwnedStep,
    slots: []Slot,
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, source_descriptor: ModelDescriptor, source_steps: []const MockStep, max_requests: usize) !MockBackend {
        if (max_requests == 0 or source_descriptor.provider_id.len == 0 or source_descriptor.model_id.len == 0) return error.InvalidArgument;
        const provider = try allocator.dupe(u8, source_descriptor.provider_id);
        errdefer allocator.free(provider);
        const model = try allocator.dupe(u8, source_descriptor.model_id);
        errdefer allocator.free(model);
        const steps = try allocator.alloc(OwnedStep, source_steps.len);
        errdefer allocator.free(steps);
        var copied: usize = 0;
        errdefer for (steps[0..copied]) |*step| step.deinit(allocator);
        for (source_steps) |step| {
            steps[copied] = try copyStep(allocator, step);
            copied += 1;
        }
        const slots = try allocator.alloc(Slot, max_requests);
        @memset(slots, Slot{});
        return .{ .allocator = allocator, .descriptor_value = .{ .provider_id = provider, .model_id = model, .capabilities = source_descriptor.capabilities, .context_window_tokens = source_descriptor.context_window_tokens, .max_output_tokens = source_descriptor.max_output_tokens, .priority = source_descriptor.priority }, .owned_provider_id = provider, .owned_model_id = model, .steps = steps, .slots = slots };
    }
    pub fn deinit(self: *MockBackend) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.steps) |*step| step.deinit(self.allocator);
        self.allocator.free(self.steps);
        self.allocator.free(self.slots);
        self.allocator.free(self.owned_provider_id);
        self.allocator.free(self.owned_model_id);
        self.steps = &.{};
        self.slots = &.{};
        self.owned_provider_id = &.{};
        self.owned_model_id = &.{};
    }
    pub fn backend(self: *MockBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: Backend.VTable = .{ .descriptor = descriptor, .start = startErased, .poll = pollErased, .cancel = cancelErased, .release = releaseErased };
    fn descriptor(raw: *anyopaque) ModelDescriptor {
        return cast(raw).descriptor_value;
    }
    fn startErased(raw: *anyopaque, request: ModelRequest) !ModelRequestHandle {
        return cast(raw).start(request);
    }
    fn pollErased(raw: *anyopaque, handle: ModelRequestHandle) !?ModelEvent {
        return cast(raw).poll(handle);
    }
    fn cancelErased(raw: *anyopaque, handle: ModelRequestHandle) !void {
        return cast(raw).cancel(handle);
    }
    fn releaseErased(raw: *anyopaque, handle: ModelRequestHandle) void {
        cast(raw).release(handle);
    }
    fn cast(raw: *anyopaque) *MockBackend {
        return @ptrCast(@alignCast(raw));
    }

    pub fn start(self: *MockBackend, request: ModelRequest) !ModelRequestHandle {
        if (!std.mem.eql(u8, request.model_id, self.descriptor_value.model_id) or !self.descriptor_value.capabilities.supports(requirements(request))) return error.ModelUnavailable;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots, 0..) |*slot, index| if (!slot.active) {
            slot.* = .{ .generation = slot.generation, .active = true, .budget = request.allocation_budget };
            return .{ .index = @intCast(index), .generation = slot.generation };
        };
        return error.BudgetExceeded;
    }
    pub fn poll(self: *MockBackend, handle: ModelRequestHandle) !?ModelEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = try self.requestSlot(handle);
        if (slot.cancelled) {
            slot.cancelled = false;
            slot.terminal = true;
            return .{ .cancelled = {} };
        }
        if (slot.terminal) return null;
        while (slot.cursor < self.steps.len) {
            const step = &self.steps[slot.cursor];
            switch (step.*) {
                .pending_ticks => |ticks| {
                    if (slot.pending_step != slot.cursor) {
                        slot.pending_step = slot.cursor;
                        slot.pending_remaining = ticks;
                    }
                    if (slot.pending_remaining != 0) {
                        slot.pending_remaining -= 1;
                        return null;
                    }
                    slot.pending_step = null;
                    slot.cursor += 1;
                },
                .start => {
                    slot.cursor += 1;
                    return .{ .start = {} };
                },
                .usage => |value| {
                    slot.cursor += 1;
                    if (!addUsage(&slot.usage, value)) {
                        slot.terminal = true;
                        return .{ .@"error" = .model_protocol_error };
                    }
                    return .{ .usage = value };
                },
                .finish => |value| {
                    slot.cursor += 1;
                    slot.terminal = true;
                    return .{ .finish = value };
                },
                .@"error" => |value| {
                    slot.cursor += 1;
                    slot.terminal = true;
                    return .{ .@"error" = value };
                },
                .text_delta => |bytes| {
                    slot.cursor += 1;
                    return self.bufferEvent(.text_delta, bytes, slot);
                },
                .arguments_delta => |bytes| {
                    slot.cursor += 1;
                    return self.bufferEvent(.arguments_delta, bytes, slot);
                },
                .tool_call_start => |value| {
                    slot.cursor += 1;
                    return self.toolStartEvent(value, slot);
                },
                .tool_call_end => |id| {
                    slot.cursor += 1;
                    return self.toolEndEvent(id, slot);
                },
            }
        }
        slot.terminal = true;
        return .{ .@"error" = .model_protocol_error };
    }
    pub fn cancel(self: *MockBackend, handle: ModelRequestHandle) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = try self.requestSlot(handle);
        if (slot.terminal) return error.InvalidState;
        slot.cancelled = true;
    }
    pub fn release(self: *MockBackend, handle: ModelRequestHandle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = self.requestSlot(handle) catch return;
        slot.active = false;
        slot.terminal = true;
        slot.cancelled = false;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }
    fn requestSlot(self: *MockBackend, handle: ModelRequestHandle) !*Slot {
        if (!handle.isValid() or handle.index >= self.slots.len) return error.InvalidArgument;
        const slot = &self.slots[handle.index];
        if (!slot.active or slot.generation != handle.generation) return error.InvalidState;
        return slot;
    }
    fn bufferEvent(self: *MockBackend, comptime tag: std.meta.FieldEnum(ModelEvent), bytes: []const u8, slot: *Slot) ModelEvent {
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            slot.terminal = true;
            return .{ .@"error" = .model_protocol_error };
        }
        const buffer = foundation.memory.SharedBuffer.initCopyWithBudget(self.allocator, bytes, .general, slot.budget, .{}) catch {
            slot.terminal = true;
            return .{ .@"error" = .budget_exceeded };
        };
        return @unionInit(ModelEvent, @tagName(tag), buffer);
    }
    fn toolStartEvent(self: *MockBackend, value: anytype, slot: *Slot) ModelEvent {
        if (!std.unicode.utf8ValidateSlice(value.call_id) or !std.unicode.utf8ValidateSlice(value.name)) {
            slot.terminal = true;
            return .{ .@"error" = .model_protocol_error };
        }
        var call_id = foundation.memory.SharedBuffer.initCopyWithBudget(self.allocator, value.call_id, .general, slot.budget, .{}) catch {
            slot.terminal = true;
            return .{ .@"error" = .budget_exceeded };
        };
        errdefer call_id.release();
        const name = foundation.memory.SharedBuffer.initCopyWithBudget(self.allocator, value.name, .general, slot.budget, .{}) catch {
            slot.terminal = true;
            return .{ .@"error" = .budget_exceeded };
        };
        return .{ .tool_call_start = .{ .call_id = call_id, .name = name } };
    }
    fn toolEndEvent(self: *MockBackend, id: []const u8, slot: *Slot) ModelEvent {
        if (!std.unicode.utf8ValidateSlice(id)) {
            slot.terminal = true;
            return .{ .@"error" = .model_protocol_error };
        }
        const call_id = foundation.memory.SharedBuffer.initCopyWithBudget(self.allocator, id, .general, slot.budget, .{}) catch {
            slot.terminal = true;
            return .{ .@"error" = .budget_exceeded };
        };
        return .{ .tool_call_end = .{ .call_id = call_id } };
    }
};

fn requirements(request: ModelRequest) Capabilities {
    return .{ .tool_calling = request.tools.len != 0, .vision = request.requiresVision(), .json_mode = request.require_json };
}
fn contains(items: []const []const u8, value: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}
fn comesBefore(left: ModelDescriptor, right: ModelDescriptor) bool {
    if (left.priority != right.priority) return left.priority > right.priority;
    const provider_order = std.mem.order(u8, left.provider_id, right.provider_id);
    return provider_order == .lt or (provider_order == .eq and std.mem.order(u8, left.model_id, right.model_id) == .lt);
}
fn addUsage(total: *Usage, value: Usage) bool {
    total.input_tokens = std.math.add(u32, total.input_tokens, value.input_tokens) catch return false;
    total.output_tokens = std.math.add(u32, total.output_tokens, value.output_tokens) catch return false;
    return true;
}
fn copyStep(allocator: std.mem.Allocator, step: MockStep) !OwnedStep {
    return switch (step) {
        .start => .{ .start = {} },
        .text_delta => |v| .{ .text_delta = try allocator.dupe(u8, v) },
        .tool_call_start => |v| blk: {
            const id = try allocator.dupe(u8, v.call_id);
            errdefer allocator.free(id);
            break :blk .{ .tool_call_start = .{ .call_id = id, .name = try allocator.dupe(u8, v.name) } };
        },
        .arguments_delta => |v| .{ .arguments_delta = try allocator.dupe(u8, v) },
        .tool_call_end => |v| .{ .tool_call_end = try allocator.dupe(u8, v) },
        .usage => |v| .{ .usage = v },
        .finish => |v| .{ .finish = v },
        .@"error" => |v| .{ .@"error" = v },
        .pending_ticks => |v| .{ .pending_ticks = v },
    };
}
