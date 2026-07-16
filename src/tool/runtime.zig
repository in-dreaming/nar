//! Tool registration, validation, authorization, and synchronous dispatch.
const std = @import("std");
const foundation = @import("foundation");
const domain = @import("../foundation/domain.zig");
const json = @import("json_schema.zig");

const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};

pub const CapabilitySet = struct {
    bits: u64 = std.math.maxInt(u64),
    pub fn contains(self: CapabilitySet, required: CapabilitySet) bool {
        return (self.bits & required.bits) == required.bits;
    }
    pub fn intersect(self: CapabilitySet, other: CapabilitySet) CapabilitySet {
        return .{ .bits = self.bits & other.bits };
    }
};

pub const ThreadAffinity = enum { any, main, worker };
pub const RevisionPolicy = enum { none, exact };
pub const ProfileMask = packed struct(u2) { minimal: bool = true, runtime: bool = true };
pub const ToolFlags = packed struct(u8) { debug_only: bool = false, deterministic: bool = false, _reserved: u6 = 0 };
pub const ResourceAccessMode = enum { read, write };
pub const ResourceAccess = struct { key: u64, mode: ResourceAccessMode };

/// Immutable tool metadata borrowed only during `Registry.register`.
pub const ToolDescriptor = struct {
    name: []const u8,
    description: []const u8 = "",
    version: []const u8 = "1",
    input_schema: []const u8,
    output_schema: ?[]const u8 = null,
    flags: ToolFlags = .{},
    thread_affinity: ThreadAffinity = .any,
    required_capabilities: CapabilitySet = .{ .bits = 0 },
    resources: []const ResourceAccess = &.{},
    revision_policy: RevisionPolicy = .none,
    profiles: ProfileMask = .{},
};

/// A generation-checked registration identity. It is invalid after unregister.
pub const ToolHandle = struct {
    id: domain.ToolId = .{},
    generation: u32 = 0,
    pub fn isValid(self: ToolHandle) bool {
        return self.id.isValid() and self.generation != 0;
    }
};

/// Policy precedence is enforced by intersection: build hard limit, shipping
/// policy, project policy, agent policy, then runtime override.
pub const Policy = struct {
    build_hard_limit: CapabilitySet = .{},
    shipping_policy: CapabilitySet = .{},
    project_policy: CapabilitySet = .{},
    agent_policy: CapabilitySet = .{},
    runtime_override: CapabilitySet = .{},
    shipping: bool = false,
    pub fn effective(self: Policy) CapabilitySet {
        return self.build_hard_limit.intersect(self.shipping_policy).intersect(self.project_policy).intersect(self.agent_policy).intersect(self.runtime_override);
    }
};

pub const HostValidator = struct {
    context: ?*anyopaque = null,
    validate: *const fn (context: ?*anyopaque, descriptor: ToolDescriptor, target: ?domain.ObjectRef, world_revision: domain.WorldRevision) domain.Error!void,
};

pub const InvocationContext = struct {
    allocator: std.mem.Allocator,
    descriptor: ToolDescriptor,
    arguments: *const std.json.Value,
    target: ?domain.ObjectRef,
    world_revision: domain.WorldRevision,
    cancellation: ?*const domain.CancellationToken,
    allocation_budget: ?*foundation.memory.AllocationBudget,
};

/// The completed buffer must contain JSON and transfers ownership to NAR. A
/// pending operation is only an identity here; task 07 supplies its lifecycle.
pub const CallbackResult = union(enum) {
    completed: foundation.memory.SharedBuffer,
    pending: domain.OperationId,
    failure: domain.ErrorCode,
};
pub const ToolCallback = *const fn (context: ?*anyopaque, invocation: InvocationContext) anyerror!CallbackResult;

const Entry = struct {
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    allocator: std.mem.Allocator,
    handle: ToolHandle,
    descriptor: ToolDescriptor,
    input_schema: json.Schema,
    output_schema: ?json.Schema,
    callback: ToolCallback,
    callback_context: ?*anyopaque,

    fn retain(self: *Entry) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }
    fn release(self: *Entry) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.input_schema.deinit();
        if (self.output_schema) |*schema| schema.deinit();
        self.allocator.free(self.descriptor.name);
        self.allocator.free(self.descriptor.description);
        self.allocator.free(self.descriptor.version);
        self.allocator.free(self.descriptor.input_schema);
        if (self.descriptor.output_schema) |schema| self.allocator.free(schema);
        self.allocator.free(self.descriptor.resources);
        self.allocator.destroy(self);
    }
};

const Slot = struct { generation: u32 = 1, entry: ?*Entry = null };

/// Thread-safe registry. Calls already dispatched retain their entry while an
/// unregister/re-register cycle advances the public handle generation.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Registry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots.items) |*slot| if (slot.entry) |entry| entry.release();
        self.slots.deinit(self.allocator);
        self.slots = .empty;
    }

    pub fn register(self: *Registry, source: ToolDescriptor, callback: ToolCallback, callback_context: ?*anyopaque) !ToolHandle {
        try validateDescriptor(source);
        var entry = try makeEntry(self.allocator, source, callback, callback_context);
        errdefer entry.release();
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots.items) |slot| if (slot.entry) |active| {
            if (std.mem.eql(u8, active.descriptor.name, source.name) and std.mem.eql(u8, active.descriptor.version, source.version)) return error.InvalidState;
        };
        var index: usize = 0;
        while (index < self.slots.items.len and self.slots.items[index].entry != null) : (index += 1) {}
        if (index == self.slots.items.len) try self.slots.append(self.allocator, .{});
        const slot = &self.slots.items[index];
        const id_value = std.math.add(u64, @as(u64, @intCast(index)), 1) catch return error.BudgetExceeded;
        entry.handle = .{ .id = domain.ToolId.fromInt(id_value), .generation = slot.generation };
        slot.entry = entry;
        return entry.handle;
    }

    pub fn unregister(self: *Registry, handle: ToolHandle) domain.Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = self.slotFor(handle) orelse return error.ToolNotFound;
        const entry = slot.entry orelse return error.ToolNotFound;
        if (slot.generation != handle.generation) return error.ToolNotFound;
        slot.entry = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        entry.release();
    }

    /// Returns the current handle for a unique registered tool name. The
    /// returned handle is still generation checked by `Dispatcher.dispatch`.
    pub fn handleForName(self: *Registry, name: []const u8) ?ToolHandle {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots.items) |slot| if (slot.entry) |entry| {
            if (std.mem.eql(u8, entry.descriptor.name, name)) return entry.handle;
        };
        return null;
    }

    fn acquire(self: *Registry, handle: ToolHandle) ?*Entry {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = self.slotFor(handle) orelse return null;
        if (slot.generation != handle.generation) return null;
        const entry = slot.entry orelse return null;
        entry.retain();
        return entry;
    }
    fn slotFor(self: *Registry, handle: ToolHandle) ?*Slot {
        if (!handle.isValid()) return null;
        const raw = handle.id.toInt() - 1;
        if (raw > std.math.maxInt(usize)) return null;
        const index: usize = @intCast(raw);
        if (index >= self.slots.items.len) return null;
        return &self.slots.items[index];
    }
};

pub const DispatchRequest = struct {
    tool: ToolHandle,
    arguments_json: []const u8,
    target: ?domain.ObjectRef = null,
    world_revision: domain.WorldRevision = .{},
    cancellation: ?*const domain.CancellationToken = null,
    allocation_budget: ?*foundation.memory.AllocationBudget = null,
    caller_affinity: ThreadAffinity = .any,
};
pub const DispatchResult = union(enum) {
    completed: foundation.memory.SharedBuffer,
    pending: domain.OperationId,
    failure: domain.ErrorCode,
    pub fn deinit(self: *DispatchResult) void {
        if (self.* == .completed) self.completed.release();
    }
};

/// Performs authorization and input validation before calling the registered
/// callback. Callback errors are converted to stable NAR error codes.
pub const Dispatcher = struct {
    registry: *Registry,
    policy: Policy = .{},
    host_validator: ?HostValidator = null,
    json_limits: json.Limits = .{},

    pub fn dispatch(self: *Dispatcher, request: DispatchRequest) DispatchResult {
        const entry = self.registry.acquire(request.tool) orelse return .{ .failure = .tool_not_found };
        defer entry.release();
        if (!profileAllowed(entry.descriptor.profiles) or (self.policy.shipping and entry.descriptor.flags.debug_only)) return .{ .failure = .tool_permission_denied };
        if (!self.policy.effective().contains(entry.descriptor.required_capabilities)) return .{ .failure = .tool_permission_denied };
        if (entry.descriptor.thread_affinity != .any and entry.descriptor.thread_affinity != request.caller_affinity) return .{ .failure = .invalid_state };
        if (request.cancellation) |token| if (token.isCancelled()) return .{ .failure = .cancelled };
        if (entry.descriptor.revision_policy == .exact and !request.world_revision.isValid()) return .{ .failure = .stale_world_revision };
        var document = json.parse(self.registry.allocator, request.arguments_json, self.json_limits) catch |err| return .{ .failure = parseError(err) };
        defer document.deinit();
        if (entry.input_schema.validate(self.registry.allocator, document.root()) catch return .{ .failure = .budget_exceeded }) |failure| {
            var owned = failure;
            owned.deinit(self.registry.allocator);
            return .{ .failure = .tool_schema_error };
        }
        if (self.host_validator) |host| host.validate(host.context, entry.descriptor, request.target, request.world_revision) catch |err| return .{ .failure = domain.errorCodeFromZig(err) };
        const invocation = InvocationContext{ .allocator = self.registry.allocator, .descriptor = entry.descriptor, .arguments = document.root(), .target = request.target, .world_revision = request.world_revision, .cancellation = request.cancellation, .allocation_budget = request.allocation_budget };
        var result = entry.callback(entry.callback_context, invocation) catch |err| return .{ .failure = domain.errorCodeFromZig(err) };
        switch (result) {
            .completed => |*buffer| {
                defer buffer.release();
                const bytes = buffer.bytes() catch return .{ .failure = .internal_error };
                var output = json.parse(self.registry.allocator, bytes, self.json_limits) catch |err| return .{ .failure = parseError(err) };
                defer output.deinit();
                if (entry.output_schema) |*schema| if (schema.validate(self.registry.allocator, output.root()) catch return .{ .failure = .budget_exceeded }) |failure| {
                    var owned = failure;
                    owned.deinit(self.registry.allocator);
                    return .{ .failure = .tool_schema_error };
                };
                return .{ .completed = buffer.clone() catch return .{ .failure = .internal_error } };
            },
            .pending => |operation| return if (operation.isValid()) .{ .pending = operation } else .{ .failure = .invalid_argument },
            .failure => |code| return .{ .failure = code },
        }
    }
};

fn validateDescriptor(descriptor: ToolDescriptor) !void {
    if (descriptor.name.len == 0 or descriptor.version.len == 0 or !asciiIdentifier(descriptor.name) or !asciiVersion(descriptor.version)) return error.InvalidArgument;
    for (descriptor.resources) |resource| if (resource.key == 0) return error.InvalidArgument;
}
fn makeEntry(allocator: std.mem.Allocator, source: ToolDescriptor, callback: ToolCallback, context: ?*anyopaque) !*Entry {
    const input_schema = try json.compile(allocator, source.input_schema);
    errdefer {
        var owned = input_schema;
        owned.deinit();
    }
    var output_schema: ?json.Schema = null;
    if (source.output_schema) |definition| {
        output_schema = try json.compile(allocator, definition);
    }
    errdefer if (output_schema) |*schema| schema.deinit();
    const entry = try allocator.create(Entry);
    errdefer allocator.destroy(entry);
    const name = try allocator.dupe(u8, source.name);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, source.description);
    errdefer allocator.free(description);
    const version = try allocator.dupe(u8, source.version);
    errdefer allocator.free(version);
    const input = try allocator.dupe(u8, source.input_schema);
    errdefer allocator.free(input);
    const output = if (source.output_schema) |value| try allocator.dupe(u8, value) else null;
    errdefer if (output) |value| allocator.free(value);
    const resources = try allocator.dupe(ResourceAccess, source.resources);
    errdefer allocator.free(resources);
    entry.* = .{ .allocator = allocator, .handle = .{}, .descriptor = .{ .name = name, .description = description, .version = version, .input_schema = input, .output_schema = output, .flags = source.flags, .thread_affinity = source.thread_affinity, .required_capabilities = source.required_capabilities, .resources = resources, .revision_policy = source.revision_policy, .profiles = source.profiles }, .input_schema = input_schema, .output_schema = output_schema, .callback = callback, .callback_context = context };
    return entry;
}
fn asciiIdentifier(value: []const u8) bool {
    for (value) |byte| if (!((byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_' or byte == '-' or byte == '.')) return false;
    return true;
}
fn asciiVersion(value: []const u8) bool {
    for (value) |byte| if (!((byte >= '0' and byte <= '9') or byte == '.' or byte == '-' or (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z'))) return false;
    return true;
}
fn profileAllowed(mask: ProfileMask) bool {
    const options = @import("nar_build_options");
    return if (options.runtime) mask.runtime else mask.minimal;
}
fn parseError(err: anyerror) domain.ErrorCode {
    return switch (err) {
        error.OutOfMemory, error.LimitExceeded => .budget_exceeded,
        else => .tool_schema_error,
    };
}
