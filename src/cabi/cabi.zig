//! C ABI owner and handle bridge.  C-visible values never expose Zig pointers.
const std = @import("std");
const foundation = @import("foundation");
const nar = @import("../nar.zig");
const core = nar.core;
const tool = nar.tool;
const context = nar.context;
const operation = nar.operation;
const trace = nar.trace;

const Slice = extern struct { data: ?[*]const u8, size: usize };
const RuntimeConfig = extern struct { struct_size: u32, api_version: u32, profile: u32, reserved0: u32, max_agents: u64, mailbox_capacity: u64, operation_capacity: u64, compute_workers: u64, blocking_workers: u64, queue_capacity: u64, observability_capacity: u64 };
const ResourceAccess = extern struct { key: u64, mode: u32, reserved: u32 };
const ToolDescriptor = extern struct { struct_size: u32, api_version: u32, name: Slice, description: Slice, version: Slice, input_schema: Slice, output_schema: Slice, required_capabilities: u64, resources: ?[*]const ResourceAccess, resource_count: usize, thread_affinity: u32, flags: u32, profile_mask: u32, revision_policy: u32 };
const Budget = extern struct { wall_time_ns: u64, model_calls: u64, tool_calls: u64, context_tokens: u64, output_tokens: u64, cost_micros: u64, trace_bytes: u64 };
const AgentConfig = extern struct { struct_size: u32, api_version: u32, provider_id: Slice, model_id: Slice, system_context: Slice, static_context: Slice, allowed_tools: ?[*]const Slice, allowed_tool_count: usize, budget: Budget, max_repeated_tool_calls: u64, tool_error_policy: u32, reserved: u32 };
const WorldSection = extern struct { name: Slice, payload: Slice };
const SubmitRequest = extern struct { struct_size: u32, api_version: u32, input: Slice, world_revision: u64, captured_at_ns: u64, sections: ?[*]const WorldSection, section_count: usize };
const Invocation = extern struct { arguments_json: Slice, world_revision: u64, object_id: u64, object_generation: u32, reserved: u32, operation: u64 };
const ResultSink = extern struct { complete: *const fn (*ResultSink, Slice) callconv(.c) u32, fail: *const fn (*ResultSink, u32) callconv(.c) u32, userdata: ?*anyopaque };
const Buffer = extern struct { data: ?[*]const u8, size: usize, release: ?*const fn (*Buffer) callconv(.c) void, userdata: ?*anyopaque };
const Event = extern struct { struct_size: u32, api_version: u32, kind: u32, reserved: u32, sequence: u64, turn: u64, timestamp_ns: u64, operation: u64, err: u32, cancel_reason: u32, buffer: Buffer };

pub const api_version: u32 = 1;
const Allocator = std.heap.smp_allocator;

const RuntimeSlot = struct { generation: u32 = 1, state: ?*State = null };
const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};
var runtime_mutex: Mutex = .{};
var runtime_slots: std.ArrayListUnmanaged(RuntimeSlot) = .empty;

const Host = union(enum) { production: nar.spindle.Host, deterministic: nar.spindle.TestHost };
const AgentSlot = struct { generation: u32 = 1, agent: ?*CAgent = null };
const CAgent = struct { agent: *core.Agent, provider: []u8, model: []u8, system: []u8, static: []u8, allowed: [][]const u8 };
const State = struct {
    host: Host,
    agents: std.ArrayListUnmanaged(AgentSlot) = .empty,
    tools: std.ArrayListUnmanaged(*CTool) = .empty,
    users: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    destroying: bool = false,
    allocator: std.mem.Allocator = Allocator,
    replay_bytes: ?[]u8 = null,
    replay_session: ?trace.ReplaySession = null,
    replay_backend: ?trace.ReplayBackend = null,
    fn runtime(self: *State) *core.Runtime {
        return switch (self.host) {
            .production => |*v| v.runtime(),
            .deterministic => |*v| v.runtime(),
        };
    }
    fn operations(self: *State) *operation.Registry {
        return switch (self.host) {
            .production => |*v| v.operations(),
            .deterministic => |*v| v.operations(),
        };
    }
    fn pump(self: *State, jobs: usize, ns: u64) usize {
        return switch (self.host) {
            .production => |*v| v.runtime().pumpMainThread(jobs, ns),
            .deterministic => |*v| v.pump(jobs, ns),
        };
    }
    fn deinit(self: *State) void {
        for (self.agents.items) |slot| if (slot.agent) |agent| self.destroyAgent(agent);
        self.agents.deinit(self.allocator);
        for (self.tools.items) |tool_value| tool_value.release();
        self.tools.deinit(self.allocator);
        _ = switch (self.host) {
            .production => |*v| v.deinit(),
            .deterministic => |*v| v.deinit(),
        };
        if (self.replay_bytes) |bytes| self.allocator.free(bytes);
        self.allocator.destroy(self);
    }
    fn destroyAgent(self: *State, value: *CAgent) void {
        _ = self.runtime().destroyAgent(value.agent);
        for (value.allowed) |name| self.allocator.free(@constCast(name));
        self.allocator.free(value.allowed);
        self.allocator.free(value.provider);
        self.allocator.free(value.model);
        self.allocator.free(value.system);
        self.allocator.free(value.static);
        self.allocator.destroy(value);
    }
};

fn code(err: anyerror) u32 {
    return @intFromEnum(nar.domain.errorCodeFromZig(err));
}
fn slice(raw: ?[*]const u8, len: usize) ?[]const u8 {
    if (raw == null and len != 0) return null;
    return if (raw) |p| p[0..len] else &.{};
}
fn optionalSlice(raw: ?[*]const u8, len: usize) ?[]const u8 {
    if (raw == null and len == 0) return null;
    return slice(raw, len);
}
fn validHeader(size: u32, needed: usize, version: u32) bool {
    return version == api_version and size >= needed;
}
fn handle(slot: usize, generation: u32) u64 {
    return (@as(u64, generation) << 32) | @as(u64, @intCast(slot + 1));
}
fn parts(value: u64) ?struct { slot: usize, generation: u32 } {
    const low: u32 = @truncate(value);
    const gen: u32 = @truncate(value >> 32);
    if (low == 0 or gen == 0) return null;
    return .{ .slot = low - 1, .generation = gen };
}
fn acquire(value: u64) ?*State {
    runtime_mutex.lock();
    defer runtime_mutex.unlock();
    const p = parts(value) orelse return null;
    if (p.slot >= runtime_slots.items.len) return null;
    const slot = runtime_slots.items[p.slot];
    const state = slot.state orelse return null;
    if (slot.generation != p.generation or state.destroying) return null;
    _ = state.users.fetchAdd(1, .acq_rel);
    return state;
}
fn release(state: *State) void {
    _ = state.users.fetchSub(1, .acq_rel);
}
fn agentFor(state: *State, value: u64) ?*CAgent {
    const p = parts(value) orelse return null;
    if (p.slot >= state.agents.items.len) return null;
    const slot = state.agents.items[p.slot];
    if (slot.generation != p.generation) return null;
    return slot.agent;
}

pub export fn nar_api_version() callconv(.c) u32 {
    return api_version;
}
pub export fn nar_runtime_create(raw: ?*const RuntimeConfig, out: ?*u64) callconv(.c) u32 {
    return create(raw, out);
}
pub export fn nar_replay_runtime_create(raw: ?*const RuntimeConfig, trace_bytes: Slice, out: ?*u64) callconv(.c) u32 {
    const bytes = slice(trace_bytes.data, trace_bytes.size) orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    if (bytes.len == 0) return @intFromEnum(nar.ErrorCode.invalid_argument);
    var runtime: u64 = 0;
    const created = create(raw, &runtime);
    if (created != 0) return created;
    const state = acquire(runtime) orelse {
        nar_runtime_destroy(runtime);
        return @intFromEnum(nar.ErrorCode.internal_error);
    };
    var failure: u32 = 0;
    const owned = state.allocator.dupe(u8, bytes) catch null;
    if (owned) |trace_copy| {
        state.replay_bytes = trace_copy;
        const replay_session = trace.ReplaySession.init(trace_copy, .semantic) catch null;
        if (replay_session) |session| {
            state.replay_session = session;
        } else {
            state.allocator.free(trace_copy);
            state.replay_bytes = null;
            failure = @intFromEnum(nar.ErrorCode.invalid_argument);
        }
        if (failure == 0) {
            const replay_backend = trace.ReplayBackend.init(state.allocator, &state.replay_session.?, .{
                .provider_id = "replay",
                .model_id = "replay",
                .capabilities = .{ .streaming = true, .tool_calling = true },
            }) catch null;
            if (replay_backend) |backend| {
                state.replay_backend = backend;
            } else {
                failure = @intFromEnum(nar.ErrorCode.internal_error);
            }
            if (failure == 0) state.runtime().models.register(state.replay_backend.?.backend()) catch {
                failure = @intFromEnum(nar.ErrorCode.internal_error);
            };
        }
    } else failure = @intFromEnum(nar.ErrorCode.budget_exceeded);
    release(state);
    if (failure != 0) {
        nar_runtime_destroy(runtime);
        return failure;
    }
    out.?.* = runtime;
    return @intFromEnum(nar.ErrorCode.ok);
}
fn create(raw: ?*const RuntimeConfig, out: ?*u64) u32 {
    const config = raw orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    if (out == null or !validHeader(config.struct_size, @sizeOf(RuntimeConfig), config.api_version)) return @intFromEnum(nar.ErrorCode.invalid_argument);
    if (config.profile > 1) return @intFromEnum(nar.ErrorCode.invalid_argument);
    const max_agents = bounded(config.max_agents, 16, 4096) orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    const mailbox_capacity = bounded(config.mailbox_capacity, 64, 1 << 20) orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    const operation_capacity = bounded(config.operation_capacity, 64, 1 << 20) orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    const compute_workers = bounded(config.compute_workers, 1, 1024) orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    const blocking_workers = bounded(config.blocking_workers, 1, 1024) orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    const queue_capacity = bounded(config.queue_capacity, 64, 1 << 20) orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    const observability_capacity = bounded(config.observability_capacity, 128, 1 << 20) orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    const state = Allocator.create(State) catch return @intFromEnum(nar.ErrorCode.budget_exceeded);
    errdefer Allocator.destroy(state);
    if (config.profile == 0) state.* = .{ .host = .{ .deterministic = nar.spindle.TestHost.initWithOperationCapacity(Allocator, queue_capacity, operation_capacity) catch |err| return code(err) } } else {
        if (!nar.hasRuntimeSupport()) return @intFromEnum(nar.ErrorCode.invalid_state);
        state.* = .{ .host = .{ .production = nar.spindle.Host.init(Allocator, .{ .compute_workers = compute_workers, .blocking_workers = blocking_workers, .queue_capacity = queue_capacity, .operation_capacity = operation_capacity, .observability_capacity = observability_capacity }) catch |err| return code(err) } };
    }
    state.runtime().config.max_agents = max_agents;
    state.runtime().config.mailbox_capacity = mailbox_capacity;
    runtime_mutex.lock();
    defer runtime_mutex.unlock();
    var index: usize = 0;
    while (index < runtime_slots.items.len and runtime_slots.items[index].state != null) : (index += 1) {}
    if (index == runtime_slots.items.len) runtime_slots.append(Allocator, .{}) catch {
        state.deinit();
        return @intFromEnum(nar.ErrorCode.budget_exceeded);
    };
    runtime_slots.items[index].state = state;
    out.?.* = handle(index, runtime_slots.items[index].generation);
    return @intFromEnum(nar.ErrorCode.ok);
}
fn bounded(value: u64, default: usize, maximum: usize) ?usize {
    const selected = if (value == 0) default else std.math.cast(usize, value) orelse return null;
    return if (selected <= maximum) selected else null;
}
pub export fn nar_runtime_shutdown(value: u64, deadline: u64) callconv(.c) u32 {
    const state = acquire(value) orelse return @intFromEnum(nar.ErrorCode.invalid_state);
    defer release(state);
    return switch (state.host) {
        .production => |*v| blk: {
            const report = v.shutdown(if (deadline == 0) null else deadline);
            if (report.failed_stage != null) break :blk @intFromEnum(nar.ErrorCode.internal_error);
            break :blk @intFromEnum(if (report.completed) nar.ErrorCode.ok else nar.ErrorCode.timeout);
        },
        .deterministic => |*v| blk: {
            v.runtime().shutdown();
            break :blk @intFromEnum(nar.ErrorCode.ok);
        },
    };
}
pub export fn nar_runtime_destroy(value: u64) callconv(.c) void {
    runtime_mutex.lock();
    const p = parts(value) orelse {
        runtime_mutex.unlock();
        return;
    };
    if (p.slot >= runtime_slots.items.len) {
        runtime_mutex.unlock();
        return;
    }
    const slot = &runtime_slots.items[p.slot];
    const state = slot.state orelse {
        runtime_mutex.unlock();
        return;
    };
    if (slot.generation != p.generation) {
        runtime_mutex.unlock();
        return;
    }
    slot.state = null;
    slot.generation +%= 1;
    if (slot.generation == 0) slot.generation = 1;
    state.destroying = true;
    runtime_mutex.unlock();
    while (state.users.load(.acquire) != 0) std.Thread.yield() catch {};
    state.deinit();
}

pub export fn nar_tool_register(runtime: u64, raw: ?*const ToolDescriptor, callback: ?*const fn (*const Invocation, *ResultSink, ?*anyopaque) callconv(.c) void, userdata: ?*anyopaque, out: ?*u64) callconv(.c) u32 {
    const state = acquire(runtime) orelse return @intFromEnum(nar.ErrorCode.invalid_state);
    defer release(state);
    const d = raw orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    if (state.runtime().stopped) return @intFromEnum(nar.ErrorCode.invalid_state);
    if (callback == null or out == null or !validHeader(d.struct_size, @sizeOf(ToolDescriptor), d.api_version)) return @intFromEnum(nar.ErrorCode.invalid_argument);
    if (d.thread_affinity > 2 or d.flags > 3 or d.profile_mask > 3 or d.revision_policy > 1) return @intFromEnum(nar.ErrorCode.invalid_argument);
    if (d.thread_affinity == 2 and state.host == .deterministic) return @intFromEnum(nar.ErrorCode.invalid_state);
    const name = slice(d.name.data, d.name.size) orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    const description = slice(d.description.data, d.description.size) orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    const version = slice(d.version.data, d.version.size) orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    const schema = slice(d.input_schema.data, d.input_schema.size) orelse return @intFromEnum(nar.ErrorCode.invalid_argument);
    const output_schema = optionalSlice(d.output_schema.data, d.output_schema.size);
    if (d.output_schema.data == null and d.output_schema.size != 0) return @intFromEnum(nar.ErrorCode.invalid_argument);
    const raw_resources = d.resources orelse if (d.resource_count != 0) return @intFromEnum(nar.ErrorCode.invalid_argument) else &[_]ResourceAccess{};
    const resources = Allocator.alloc(tool.ResourceAccess, d.resource_count) catch return @intFromEnum(nar.ErrorCode.budget_exceeded);
    defer Allocator.free(resources);
    for (raw_resources[0..d.resource_count], 0..) |resource, index| {
        if (resource.key == 0 or resource.mode > 1 or resource.reserved != 0) return @intFromEnum(nar.ErrorCode.invalid_argument);
        resources[index] = .{ .key = resource.key, .mode = if (resource.mode == 0) .read else .write };
    }
    const entry = Allocator.create(CTool) catch return @intFromEnum(nar.ErrorCode.budget_exceeded);
    entry.* = .{ .callback = callback.?, .userdata = userdata, .affinity = @enumFromInt(d.thread_affinity), .state = state };
    const profile_bits = if (d.profile_mask == 0) 3 else d.profile_mask;
    const registered = state.runtime().tools.register(.{
        .name = name,
        .description = description,
        .version = version,
        .input_schema = schema,
        .output_schema = output_schema,
        .flags = .{ .debug_only = (d.flags & 1) != 0, .deterministic = (d.flags & 2) != 0 },
        .thread_affinity = .any,
        .required_capabilities = .{ .bits = d.required_capabilities },
        .resources = resources,
        .revision_policy = if (d.revision_policy == 0) .none else .exact,
        .profiles = .{ .minimal = (profile_bits & 1) != 0, .runtime = (profile_bits & 2) != 0 },
    }, cTool, entry) catch |err| {
        entry.release();
        return code(err);
    };
    state.tools.append(Allocator, entry) catch {
        state.runtime().tools.unregister(registered) catch {};
        entry.release();
        return @intFromEnum(nar.ErrorCode.budget_exceeded);
    };
    entry.handle = registered;
    out.?.* = handle(registered.id.toInt() - 1, registered.generation);
    return 0;
}
pub export fn nar_tool_unregister(runtime: u64, value: u64) callconv(.c) u32 {
    const state = acquire(runtime) orelse return 2;
    defer release(state);
    const p = parts(value) orelse return 2;
    const h: tool.ToolHandle = .{ .id = nar.ToolId.fromInt(p.slot + 1), .generation = p.generation };
    const raw = state.runtime().tools.callbackContextFor(h) orelse return 2;
    const c: *CTool = @ptrCast(@alignCast(raw));
    state.runtime().tools.unregister(h) catch |err| return code(err);
    for (state.tools.items, 0..) |item, index| if (item == c) {
        _ = state.tools.swapRemove(index);
        break;
    };
    c.release();
    return 0;
}

const CTool = struct {
    callback: *const fn (*const Invocation, *ResultSink, ?*anyopaque) callconv(.c) void,
    userdata: ?*anyopaque,
    affinity: tool.ThreadAffinity,
    state: *State,
    handle: tool.ToolHandle = .{},
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    fn retain(self: *CTool) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }
    fn release(self: *CTool) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) Allocator.destroy(self);
    }
};
const Sink = struct { sink: ResultSink, result: ?tool.CallbackResult = null, operation: ?nar.OperationId = null };
fn sinkComplete(raw: *ResultSink, value: Slice) callconv(.c) u32 {
    const sink: *Sink = @fieldParentPtr("sink", raw);
    if (sink.result != null) return 2;
    const bytes = slice(value.data, value.size) orelse return 1;
    const buffer = foundation.memory.SharedBuffer.initCopy(Allocator, bytes, .general) catch return 5;
    if (sink.operation) |id| {
        const state: *State = @ptrCast(@alignCast(sink.sink.userdata.?));
        if (!state.operations().completeExternal(id, buffer)) return 2;
    } else sink.result = .{ .completed = buffer };
    return 0;
}
fn sinkFail(raw: *ResultSink, value: u32) callconv(.c) u32 {
    const sink: *Sink = @fieldParentPtr("sink", raw);
    const err = errorCode(value) orelse return 1;
    if (sink.result != null) return 2;
    if (sink.operation) |id| {
        const state: *State = @ptrCast(@alignCast(sink.sink.userdata.?));
        if (!state.operations().failExternal(id, err)) return 2;
    } else sink.result = .{ .failure = err };
    return 0;
}
fn cTool(raw: ?*anyopaque, invocation: tool.InvocationContext) !tool.CallbackResult {
    const value: *CTool = @ptrCast(@alignCast(raw.?));
    if (value.affinity != .any) {
        const args = try std.json.Stringify.valueAlloc(Allocator, invocation.arguments.*, .{});
        const work = Allocator.create(CPumpWork) catch {
            Allocator.free(args);
            return error.OutOfMemory;
        };
        value.retain();
        work.* = .{ .tool = value, .arguments = args, .world_revision = invocation.world_revision, .target = invocation.target };
        const id = try value.state.operations().submitOwned(.{ .affinity = if (value.affinity == .main) .pump else .compute }, runCPumpTool, work, deinitCPumpWork);
        return .{ .pending = id };
    }
    return invokeTool(value, invocation, null);
}
const CPumpWork = struct {
    tool: *CTool,
    arguments: []u8,
    world_revision: nar.WorldRevision,
    target: ?nar.ObjectRef,
};
fn runCPumpTool(op_context: *operation.Context) void {
    const work: *CPumpWork = @ptrCast(@alignCast(op_context.userData().?));
    var sink = Sink{ .sink = .{ .complete = sinkComplete, .fail = sinkFail, .userdata = work.tool.state }, .operation = op_context.operationId() };
    const call = Invocation{
        .arguments_json = .{ .data = work.arguments.ptr, .size = work.arguments.len },
        .world_revision = work.world_revision.toInt(),
        .object_id = if (work.target) |target| target.id else 0,
        .object_generation = if (work.target) |target| target.generation else 0,
        .reserved = 0,
        .operation = op_context.operationId().toInt(),
    };
    work.tool.callback(&call, &sink.sink, work.tool.userdata);
}
fn deinitCPumpWork(_: std.mem.Allocator, raw: ?*anyopaque) void {
    const work: *CPumpWork = @ptrCast(@alignCast(raw.?));
    work.tool.release();
    Allocator.free(work.arguments);
    Allocator.destroy(work);
}
fn invokeTool(value: *CTool, invocation: tool.InvocationContext, op: ?nar.OperationId) !tool.CallbackResult {
    const args = try std.json.Stringify.valueAlloc(Allocator, invocation.arguments.*, .{});
    defer Allocator.free(args);
    var sink = Sink{ .sink = .{ .complete = sinkComplete, .fail = sinkFail, .userdata = value.state }, .operation = op };
    const call = Invocation{ .arguments_json = .{ .data = args.ptr, .size = args.len }, .world_revision = invocation.world_revision.toInt(), .object_id = if (invocation.target) |target| target.id else 0, .object_generation = if (invocation.target) |target| target.generation else 0, .reserved = 0, .operation = if (op) |id| id.toInt() else 0 };
    value.callback(&call, &sink.sink, value.userdata);
    if (op != null) return .{ .pending = op.? };
    return sink.result orelse .{ .failure = .operation_failed };
}
fn errorCode(value: u32) ?nar.ErrorCode {
    if (value > @intFromEnum(nar.ErrorCode.internal_error)) return null;
    return @enumFromInt(value);
}

pub export fn nar_agent_create(runtime: u64, raw: ?*const AgentConfig, out: ?*u64) callconv(.c) u32 {
    const state = acquire(runtime) orelse return 2;
    defer release(state);
    const c = raw orelse return 1;
    if (state.runtime().stopped) return 2;
    if (out == null or !validHeader(c.struct_size, @sizeOf(AgentConfig), c.api_version)) return 1;
    const agent = Allocator.create(CAgent) catch return 5;
    errdefer Allocator.destroy(agent);
    agent.provider = Allocator.dupe(u8, slice(c.provider_id.data, c.provider_id.size) orelse return 1) catch return 5;
    errdefer Allocator.free(agent.provider);
    agent.model = Allocator.dupe(u8, slice(c.model_id.data, c.model_id.size) orelse return 1) catch return 5;
    errdefer Allocator.free(agent.model);
    agent.system = Allocator.dupe(u8, slice(c.system_context.data, c.system_context.size) orelse return 1) catch return 5;
    errdefer Allocator.free(agent.system);
    agent.static = Allocator.dupe(u8, slice(c.static_context.data, c.static_context.size) orelse return 1) catch return 5;
    errdefer Allocator.free(agent.static);
    const allowed = c.allowed_tools orelse if (c.allowed_tool_count != 0) return 1 else &[_]Slice{};
    agent.allowed = Allocator.alloc([]const u8, c.allowed_tool_count) catch return 5;
    errdefer Allocator.free(agent.allowed);
    for (allowed[0..c.allowed_tool_count], 0..) |name, i| agent.allowed[i] = Allocator.dupe(u8, slice(name.data, name.size) orelse return 1) catch return 5;
    agent.agent = state.runtime().createAgent(.{ .provider_id = agent.provider, .definition = .{ .model_id = agent.model, .system_context = agent.system, .static_context = agent.static, .allowed_tools = agent.allowed, .default_budget = .{ .wall_time_ns = c.budget.wall_time_ns, .model_calls = c.budget.model_calls, .tool_calls = c.budget.tool_calls, .context_tokens = c.budget.context_tokens, .output_tokens = c.budget.output_tokens, .cost_micros = c.budget.cost_micros, .trace_bytes = c.budget.trace_bytes } }, .max_repeated_tool_calls = @intCast(if (c.max_repeated_tool_calls == 0) 2 else c.max_repeated_tool_calls) }) catch |err| return code(err);
    var index: usize = 0;
    while (index < state.agents.items.len and state.agents.items[index].agent != null) : (index += 1) {}
    if (index == state.agents.items.len) state.agents.append(Allocator, .{}) catch return 5;
    state.agents.items[index].agent = agent;
    out.?.* = handle(index, state.agents.items[index].generation);
    return 0;
}
pub export fn nar_agent_destroy(runtime: u64, value: u64) callconv(.c) u32 {
    const state = acquire(runtime) orelse return 2;
    defer release(state);
    const p = parts(value) orelse return 2;
    const agent = agentFor(state, value) orelse return 2;
    state.destroyAgent(agent);
    state.agents.items[p.slot].agent = null;
    state.agents.items[p.slot].generation +%= 1;
    if (state.agents.items[p.slot].generation == 0) state.agents.items[p.slot].generation = 1;
    return 0;
}

pub export fn nar_agent_submit(runtime: u64, value: u64, raw: ?*const SubmitRequest, out: ?*u64) callconv(.c) u32 {
    const state = acquire(runtime) orelse return 2;
    defer release(state);
    const agent = agentFor(state, value) orelse return 2;
    const request = raw orelse return 1;
    if (out == null or !validHeader(request.struct_size, @sizeOf(SubmitRequest), request.api_version)) return 1;
    const sections = request.sections orelse if (request.section_count != 0) return 1 else &[_]WorldSection{};
    var owned = Allocator.alloc(context.WorldSection, request.section_count) catch return 5;
    defer Allocator.free(owned);
    for (sections[0..request.section_count], 0..) |section, i| owned[i] = .{ .name = slice(section.name.data, section.name.size) orelse return 1, .payload = slice(section.payload.data, section.payload.size) orelse return 1 };
    var world = context.WorldSnapshot.initCopy(Allocator, nar.WorldRevision.fromInt(request.world_revision), .{ .nanoseconds = request.captured_at_ns }, owned) catch |err| return code(err);
    defer world.deinit();
    const turn = agent.agent.submit(.{ .input = slice(request.input.data, request.input.size) orelse return 1, .world = &world }) catch |err| return code(err);
    out.?.* = turn.toInt();
    return 0;
}
pub export fn nar_agent_tick(runtime: u64, value: u64, out: ?*u32) callconv(.c) u32 {
    const state = acquire(runtime) orelse return 2;
    defer release(state);
    const agent = agentFor(state, value) orelse return 2;
    if (out == null) return 1;
    out.?.* = @intFromEnum(agent.agent.tick());
    return 0;
}
pub export fn nar_runtime_pump_main_thread(runtime: u64, jobs: usize, ns: u64, out: ?*usize) callconv(.c) u32 {
    const state = acquire(runtime) orelse return 2;
    defer release(state);
    if (out == null) return 1;
    out.?.* = state.pump(jobs, ns);
    return 0;
}
pub export fn nar_agent_cancel(runtime: u64, value: u64, reason: u32) callconv(.c) u32 {
    const state = acquire(runtime) orelse return 2;
    defer release(state);
    const agent = agentFor(state, value) orelse return 2;
    if (reason > 3) return 1;
    const parsed: nar.CancelReason = @enumFromInt(reason);
    agent.agent.cancel(parsed);
    return 0;
}
pub export fn nar_agent_poll(runtime: u64, value: u64, out: ?*Event) callconv(.c) u32 {
    const state = acquire(runtime) orelse return 2;
    defer release(state);
    const agent = agentFor(state, value) orelse return 2;
    const event = out orelse return 1;
    if (!validHeader(event.struct_size, @sizeOf(Event), event.api_version)) return 1;
    event.* = .{ .struct_size = @sizeOf(Event), .api_version = api_version, .kind = 0, .reserved = 0, .sequence = 0, .turn = 0, .timestamp_ns = 0, .operation = 0, .err = 0, .cancel_reason = 0, .buffer = .{ .data = null, .size = 0, .release = null, .userdata = null } };
    var value_event = agent.agent.poll() orelse return 0;
    defer value_event.deinit();
    event.sequence = value_event.sequence;
    event.turn = value_event.turn_id.toInt();
    event.timestamp_ns = value_event.timestamp.nanoseconds;
    switch (value_event.payload) {
        .text_delta => |buffer| {
            event.kind = 1;
            event.buffer = makeBuffer(buffer) catch return 5;
        },
        .final_response => |buffer| {
            event.kind = 2;
            event.buffer = makeBuffer(buffer) catch return 5;
        },
        .operation_progress => |buffer| {
            event.kind = 4;
            event.buffer = makeBuffer(buffer) catch return 5;
        },
        .system => |buffer| {
            event.kind = 7;
            event.buffer = makeBuffer(buffer) catch return 5;
        },
        .tool_completed => |completion| {
            event.kind = 3;
            event.operation = completion.operation_id.toInt();
            event.buffer = makeBuffer(completion.result) catch return 5;
        },
        .failed => |err| {
            event.kind = 5;
            event.err = @intFromEnum(err);
        },
        .cancelled => |reason| {
            event.kind = 6;
            event.cancel_reason = @intFromEnum(reason);
        },
        .none => {},
    }
    return 0;
}
const BufferOwner = struct { buffer: foundation.memory.SharedBuffer };
fn makeBuffer(source: foundation.memory.SharedBuffer) !Buffer {
    const owner = try Allocator.create(BufferOwner);
    owner.* = .{ .buffer = try source.clone() };
    return .{ .data = (try owner.buffer.bytes()).ptr, .size = (try owner.buffer.bytes()).len, .release = releaseBuffer, .userdata = owner };
}
fn releaseBuffer(raw: *Buffer) callconv(.c) void {
    const pointer = raw.userdata orelse return;
    const owner: *BufferOwner = @ptrCast(@alignCast(pointer));
    owner.buffer.release();
    Allocator.destroy(owner);
    raw.* = .{ .data = null, .size = 0, .release = null, .userdata = null };
}
pub export fn nar_buffer_release(value: ?*Buffer) callconv(.c) void {
    if (value) |buffer| if (buffer.release) |release_fn| release_fn(buffer);
}
pub export fn nar_operation_complete(runtime: u64, value: u64, bytes: Slice) callconv(.c) u32 {
    const state = acquire(runtime) orelse return 2;
    defer release(state);
    const id = nar.OperationId.init(value) orelse return 1;
    const data = slice(bytes.data, bytes.size) orelse return 1;
    const buffer = foundation.memory.SharedBuffer.initCopy(Allocator, data, .general) catch return 5;
    return if (state.operations().completeExternal(id, buffer)) 0 else 2;
}
pub export fn nar_operation_fail(runtime: u64, value: u64, err: u32) callconv(.c) u32 {
    const state = acquire(runtime) orelse return 2;
    defer release(state);
    const id = nar.OperationId.init(value) orelse return 1;
    const value_err = errorCode(err) orelse return 1;
    return if (state.operations().failExternal(id, value_err)) 0 else 2;
}
pub export fn nar_operation_cancel(runtime: u64, value: u64, reason: u32) callconv(.c) u32 {
    const state = acquire(runtime) orelse return 2;
    defer release(state);
    const id = nar.OperationId.init(value) orelse return 1;
    if (reason > 3) return 1;
    const parsed: nar.CancelReason = @enumFromInt(reason);
    if (state.operations().stateOf(id) == null) return 2;
    state.operations().cancel(id, parsed);
    return 0;
}
