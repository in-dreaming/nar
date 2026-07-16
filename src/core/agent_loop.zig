//! Bounded, pull-driven agent/turn state machine.
const std = @import("std");
const foundation = @import("foundation");
const domain = @import("../foundation/domain.zig");
const model = @import("../model/model.zig");
const tool = @import("../tool/runtime.zig");
const context = @import("../context/runtime.zig");
const trace = @import("../trace/runtime.zig");

pub const TurnState = enum { idle, building_context, waiting_model, waiting_tool, waiting_operation, completed, failed, cancelled };
pub const ToolErrorPolicy = enum { return_to_model, fail_turn };
pub const TickResult = enum { progressed, would_block, terminal };
/// Borrowed execution and time services. Their owner must outlive `Runtime`.
/// Core intentionally uses opaque facades so it does not depend on a host adapter.
pub const ExecutionServices = struct {
    pub const Clock = struct {
        context: ?*anyopaque = null,
        now_fn: *const fn (?*anyopaque) u64 = systemNow,
        pub fn now(self: Clock) u64 {
            return self.now_fn(self.context);
        }
    };
    pub const Executor = struct {
        context: ?*anyopaque = null,
        worker_count_fn: *const fn (?*anyopaque) usize = noWorkers,
        pub fn workerCount(self: Executor) usize {
            return self.worker_count_fn(self.context);
        }
    };
    pub const Pump = struct {
        context: ?*anyopaque = null,
        drain_fn: *const fn (?*anyopaque, usize, u64) usize = noDrain,
        pub fn drain(self: Pump, max_jobs: usize, max_ns: u64) usize {
            return self.drain_fn(self.context, max_jobs, max_ns);
        }
    };
    pub const Events = struct {
        context: ?*anyopaque = null,
        emit_fn: *const fn (?*anyopaque, []const u8, i64) void = noEvent,
        pub fn emit(self: Events, kind: []const u8, value: i64) void {
            self.emit_fn(self.context, kind, value);
        }
    };
    /// Host-owned asynchronous operation registry. Completed buffers transfer
    /// to the caller of `poll`; all other results own no caller resources.
    pub const Operations = struct {
        pub const Result = union(enum) {
            pending,
            completed: foundation.memory.SharedBuffer,
            failed: domain.ErrorCode,
            cancelled: domain.CancelReason,
            timed_out,
            stale,
        };
        context: ?*anyopaque = null,
        poll_fn: *const fn (?*anyopaque, domain.OperationId, u64) Result = noOperation,
        cancel_fn: *const fn (?*anyopaque, domain.OperationId, domain.CancelReason) void = noOperationCancel,
        release_fn: *const fn (?*anyopaque, domain.OperationId) void = noOperationRelease,
        pub fn poll(self: Operations, id: domain.OperationId, now: u64) Result {
            return self.poll_fn(self.context, id, now);
        }
        pub fn cancel(self: Operations, id: domain.OperationId, reason: domain.CancelReason) void {
            self.cancel_fn(self.context, id, reason);
        }
        pub fn release(self: Operations, id: domain.OperationId) void {
            self.release_fn(self.context, id);
        }
    };
    clock: Clock = .{},
    compute: Executor = .{},
    blocking: Executor = .{},
    pump: Pump = .{},
    events: Events = .{},
    operations: Operations = .{},
    io: ?std.Io = null,
};
pub const RuntimeConfig = struct { max_agents: usize = 16, mailbox_capacity: usize = 64, services: ExecutionServices = .{} };
pub const AgentConfig = struct { provider_id: []const u8, definition: context.AgentDefinition, tool_error_policy: ToolErrorPolicy = .return_to_model, max_repeated_tool_calls: usize = 2 };
pub const SubmitRequest = struct { input: []const u8, world: *const context.WorldSnapshot };

/// Owner of non-owning model/tool registrations and all created agents.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    config: RuntimeConfig,
    models: model.Registry,
    tools: tool.Registry,
    agents: std.ArrayListUnmanaged(*Agent) = .empty,
    stopped: bool = false,
    pub fn init(allocator: std.mem.Allocator, config: RuntimeConfig) !Runtime {
        if (config.max_agents == 0 or config.mailbox_capacity == 0) return error.InvalidArgument;
        return .{ .allocator = allocator, .config = config, .models = model.Registry.init(allocator), .tools = tool.Registry.init(allocator) };
    }
    pub fn deinit(self: *Runtime) void {
        self.shutdown();
        for (self.agents.items) |agent| {
            agent.deinit();
            self.allocator.destroy(agent);
        }
        self.agents.deinit(self.allocator);
        self.tools.deinit();
        self.models.deinit();
    }
    pub fn createAgent(self: *Runtime, config: AgentConfig) !*Agent {
        if (self.stopped) return error.InvalidState;
        if (self.agents.items.len == self.config.max_agents) return error.BudgetExceeded;
        const agent = try self.allocator.create(Agent);
        errdefer self.allocator.destroy(agent);
        agent.* = try Agent.init(self, config);
        errdefer agent.deinit();
        try self.agents.append(self.allocator, agent);
        return agent;
    }
    /// Cancels all active turns. It does not deinitialize borrowed services.
    pub fn shutdown(self: *Runtime) void {
        if (self.stopped) return;
        self.stopped = true;
        for (self.agents.items) |agent| agent.cancel(.shutdown);
    }
    /// Executes caller-thread work submitted to the host pump executor.
    pub fn pumpMainThread(self: *Runtime, max_jobs: usize, max_nanos: u64) usize {
        return self.config.services.pump.drain(max_jobs, max_nanos);
    }
    pub fn destroyAgent(self: *Runtime, agent: *Agent) bool {
        for (self.agents.items, 0..) |value, i| if (value == agent) {
            _ = self.agents.swapRemove(i);
            agent.deinit();
            self.allocator.destroy(agent);
            return true;
        };
        return false;
    }
};

pub const Agent = struct {
    runtime: *Runtime,
    config: AgentConfig,
    session: context.MemorySession,
    mailbox: domain.EventMailbox,
    state: TurnState = .idle,
    next_turn: u64 = 1,
    turn: ?Turn = null,
    trace_writer: ?*trace.Writer = null,
    fn init(runtime: *Runtime, config: AgentConfig) !Agent {
        if (config.provider_id.len == 0 or config.definition.model_id.len == 0 or config.max_repeated_tool_calls == 0) return error.InvalidArgument;
        return .{ .runtime = runtime, .config = config, .session = context.MemorySession.init(runtime.allocator), .mailbox = try domain.EventMailbox.init(runtime.allocator, runtime.config.mailbox_capacity) };
    }
    pub fn deinit(self: *Agent) void {
        self.cancel(.shutdown);
        if (self.turn) |*turn| turn.deinit(self.runtime.allocator);
        self.mailbox.deinit();
        self.session.deinit();
    }
    pub fn submit(self: *Agent, request: SubmitRequest) !domain.TurnId {
        if (self.state != .idle and !terminal(self.state)) return error.InvalidState;
        if (!std.unicode.utf8ValidateSlice(request.input)) return error.InvalidArgument;
        if (self.turn) |*old| old.deinit(self.runtime.allocator);
        const id = domain.TurnId.init(self.next_turn) orelse return error.BudgetExceeded;
        self.next_turn = std.math.add(u64, self.next_turn, 1) catch return error.BudgetExceeded;
        self.turn = try Turn.init(self.runtime.allocator, id, request, self.runtime.config.services.clock.now(), self.config.definition.default_budget);
        try self.session.append(.message, .user, request.input);
        self.state = .building_context;
        return id;
    }
    pub fn poll(self: *Agent) ?domain.AgentEvent {
        return self.mailbox.poll();
    }
    pub fn cancel(self: *Agent, reason: domain.CancelReason) void {
        if (self.state == .idle or terminal(self.state)) return;
        if (self.turn) |*turn| if (turn.request) |request| request.backend.cancel(request.handle) catch {};
        if (self.turn) |turn| if (turn.operation) |operation| self.runtime.config.services.operations.cancel(operation, reason);
        self.finish(.cancelled, .cancelled, reason);
    }
    /// Performs at most one context/model/tool action or one model event.
    pub fn tick(self: *Agent) TickResult {
        if (self.state == .idle or terminal(self.state)) return .terminal;
        const turn = &(self.turn orelse return .terminal);
        turn.budget.check(self.runtime.config.services.clock.now(), null) catch |err| {
            self.finishError(err);
            return .terminal;
        };
        return switch (self.state) {
            .building_context => self.startModel(turn),
            .waiting_model => self.modelEvent(turn),
            .waiting_tool => self.toolCall(turn),
            .waiting_operation => self.operationEvent(turn),
            else => .terminal,
        };
    }
    fn startModel(self: *Agent, turn: *Turn) TickResult {
        var snapshot = self.session.snapshot(self.runtime.allocator) catch {
            self.finish(.failed, .budget_exceeded, null);
            return .terminal;
        };
        defer snapshot.deinit();
        var built = (context.ContextBuilder{ .allocator = self.runtime.allocator, .definition = self.config.definition }).build(.{ .world = &turn.world, .session = &snapshot, .current_input = turn.input, .current_tool_result = turn.tool_result, .budget = &turn.budget }) catch |err| {
            self.finishError(err);
            return .terminal;
        };
        defer built.deinit();
        turn.budget.charge(.model_calls, 1) catch |err| {
            self.finishError(err);
            return .terminal;
        };
        const backend = self.runtime.models.find(self.config.provider_id, self.config.definition.model_id) orelse {
            self.finish(.failed, .model_unavailable, null);
            return .terminal;
        };
        const handle = backend.start(built.request()) catch |err| {
            self.finishError(err);
            return .terminal;
        };
        turn.request = .{ .backend = backend, .handle = handle };
        if (turn.tool_result) |value| self.runtime.allocator.free(value);
        turn.tool_result = null;
        self.state = .waiting_model;
        self.writeTrace(.model_request, "{}");
        return .progressed;
    }
    fn modelEvent(self: *Agent, turn: *Turn) TickResult {
        const request = &(turn.request orelse {
            self.finish(.failed, .internal_error, null);
            return .terminal;
        });
        var event = request.backend.poll(request.handle) catch |err| {
            self.finishError(err);
            return .terminal;
        } orelse return .would_block;
        defer event.deinit();
        switch (event) {
            .start => return .progressed,
            .text_delta => |buffer| {
                const bytes = buffer.bytes() catch {
                    self.finish(.failed, .internal_error, null);
                    return .terminal;
                };
                turn.output.appendSlice(self.runtime.allocator, bytes) catch {
                    self.finish(.failed, .budget_exceeded, null);
                    return .terminal;
                };
                self.postText(turn.id, buffer) catch return .would_block;
                return .progressed;
            },
            .usage => |usage| {
                turn.budget.charge(.output_tokens, usage.output_tokens) catch |err| {
                    self.finishError(err);
                    return .terminal;
                };
                return .progressed;
            },
            .tool_call_start => |start| {
                if (turn.call != null) {
                    self.finish(.failed, .model_protocol_error, null);
                    return .terminal;
                }
                turn.call = ToolCall.init(self.runtime.allocator, start.call_id.bytes() catch "", start.name.bytes() catch "") catch {
                    self.finish(.failed, .budget_exceeded, null);
                    return .terminal;
                };
                return .progressed;
            },
            .arguments_delta => |buffer| {
                const call = &(turn.call orelse {
                    self.finish(.failed, .model_protocol_error, null);
                    return .terminal;
                });
                call.arguments.appendSlice(self.runtime.allocator, buffer.bytes() catch "") catch {
                    self.finish(.failed, .budget_exceeded, null);
                    return .terminal;
                };
                return .progressed;
            },
            .tool_call_end => |end| {
                const call = &(turn.call orelse {
                    self.finish(.failed, .model_protocol_error, null);
                    return .terminal;
                });
                if (!std.mem.eql(u8, end.call_id.bytes() catch "", call.id)) {
                    self.finish(.failed, .model_protocol_error, null);
                    return .terminal;
                }
                request.backend.release(request.handle);
                turn.request = null;
                self.state = .waiting_tool;
                return .progressed;
            },
            .finish => {
                if (turn.call != null) self.finish(.failed, .model_protocol_error, null) else self.finish(.completed, .ok, null);
                return .terminal;
            },
            .@"error" => |code| {
                self.finish(.failed, code, null);
                return .terminal;
            },
            .cancelled => {
                self.finish(.cancelled, .cancelled, .requested);
                return .terminal;
            },
        }
    }
    fn toolCall(self: *Agent, turn: *Turn) TickResult {
        var call = turn.call orelse {
            self.finish(.failed, .model_protocol_error, null);
            return .terminal;
        };
        defer call.deinit(self.runtime.allocator);
        turn.call = null;
        const key = context.loopKey(self.runtime.allocator, call.name, call.arguments.items) catch {
            self.finish(.failed, .model_protocol_error, null);
            return .terminal;
        };
        defer self.runtime.allocator.free(key);
        if (turn.loop_keys.getPtr(key)) |count| {
            if (count.* >= self.config.max_repeated_tool_calls) {
                self.finish(.failed, .invalid_state, null);
                return .terminal;
            }
            count.* += 1;
        } else {
            const owned_key = self.runtime.allocator.dupe(u8, key) catch {
                self.finish(.failed, .budget_exceeded, null);
                return .terminal;
            };
            turn.loop_keys.put(self.runtime.allocator, owned_key, 1) catch {
                self.runtime.allocator.free(owned_key);
                self.finish(.failed, .budget_exceeded, null);
                return .terminal;
            };
        }
        turn.budget.charge(.tool_calls, 1) catch |err| {
            self.finishError(err);
            return .terminal;
        };
        const handle = self.runtime.tools.handleForName(call.name) orelse return self.toolFailure(turn, .tool_not_found);
        var dispatcher = tool.Dispatcher{ .registry = &self.runtime.tools };
        var result = dispatcher.dispatch(.{ .tool = handle, .arguments_json = call.arguments.items });
        defer result.deinit();
        switch (result) {
            .completed => |buffer| {
                const bytes = buffer.bytes() catch return self.toolFailure(turn, .internal_error);
                turn.tool_result = self.runtime.allocator.dupe(u8, bytes) catch {
                    self.finish(.failed, .budget_exceeded, null);
                    return .terminal;
                };
                self.session.append(.tool_result, .tool, turn.tool_result.?) catch {
                    self.finish(.failed, .budget_exceeded, null);
                    return .terminal;
                };
                self.state = .building_context;
                self.writeTrace(.tool_result, "{}");
                return .progressed;
            },
            .pending => |operation| {
                turn.operation = operation;
                self.state = .waiting_operation;
                self.writeTrace(.operation_transition, "{\"state\":\"queued\"}");
                return .progressed;
            },
            .failure => |code| return self.toolFailure(turn, code),
        }
    }
    fn operationEvent(self: *Agent, turn: *Turn) TickResult {
        const operation = turn.operation orelse {
            self.finish(.failed, .internal_error, null);
            return .terminal;
        };
        var result = self.runtime.config.services.operations.poll(operation, self.runtime.config.services.clock.now());
        switch (result) {
            .pending => return .would_block,
            .completed => |*buffer| {
                defer buffer.release();
                const bytes = buffer.bytes() catch return self.toolFailure(turn, .internal_error);
                turn.tool_result = self.runtime.allocator.dupe(u8, bytes) catch {
                    self.finish(.failed, .budget_exceeded, null);
                    return .terminal;
                };
                self.runtime.config.services.operations.release(operation);
                turn.operation = null;
                self.session.append(.tool_result, .tool, turn.tool_result.?) catch {
                    self.finish(.failed, .budget_exceeded, null);
                    return .terminal;
                };
                self.state = .building_context;
                self.writeTrace(.operation_transition, "{\"state\":\"completed\"}");
                return .progressed;
            },
            .failed => |code| return self.operationFailure(turn, operation, code),
            .cancelled => return self.operationFailure(turn, operation, .cancelled),
            .timed_out => return self.operationFailure(turn, operation, .timeout),
            .stale => return self.operationFailure(turn, operation, .operation_failed),
        }
    }
    fn operationFailure(self: *Agent, turn: *Turn, operation: domain.OperationId, code: domain.ErrorCode) TickResult {
        self.runtime.config.services.operations.release(operation);
        turn.operation = null;
        self.writeTrace(.operation_transition, "{\"state\":\"failed\"}");
        return self.toolFailure(turn, code);
    }
    fn toolFailure(self: *Agent, turn: *Turn, code: domain.ErrorCode) TickResult {
        if (self.config.tool_error_policy == .fail_turn) {
            self.finish(.failed, code, null);
            return .terminal;
        }
        turn.tool_result = std.fmt.allocPrint(self.runtime.allocator, "{{\"error\":\"{s}\"}}", .{@tagName(code)}) catch {
            self.finish(.failed, .budget_exceeded, null);
            return .terminal;
        };
        self.state = .building_context;
        return .progressed;
    }
    fn postText(self: *Agent, id: domain.TurnId, buffer: foundation.memory.SharedBuffer) !void {
        var event = domain.AgentEvent{ .turn_id = id, .timestamp = .{ .nanoseconds = self.runtime.config.services.clock.now() }, .payload = .{ .text_delta = try buffer.clone() } };
        self.mailbox.post(event) catch |err| {
            event.deinit();
            return err;
        };
    }
    fn finishError(self: *Agent, err: anyerror) void {
        self.finish(.failed, switch (err) {
            error.Timeout => .timeout,
            error.BudgetExceeded => .budget_exceeded,
            error.ModelUnavailable => .model_unavailable,
            error.ModelProtocolError => .model_protocol_error,
            else => .internal_error,
        }, null);
    }
    fn finish(self: *Agent, state: TurnState, code: domain.ErrorCode, reason: ?domain.CancelReason) void {
        if (terminal(self.state)) return;
        const turn = &(self.turn orelse return);
        if (turn.request) |request| request.backend.release(request.handle);
        turn.request = null;
        if (turn.operation) |operation| {
            self.runtime.config.services.operations.cancel(operation, reason orelse .requested);
            self.runtime.config.services.operations.release(operation);
            turn.operation = null;
        }
        self.state = state;
        var event = if (state == .completed) domain.AgentEvent{ .turn_id = turn.id, .timestamp = .{ .nanoseconds = self.runtime.config.services.clock.now() }, .priority = .high, .payload = .{ .final_response = foundation.memory.SharedBuffer.initCopy(self.runtime.allocator, turn.output.items, .general) catch return } } else domain.AgentEvent{ .turn_id = turn.id, .timestamp = .{ .nanoseconds = self.runtime.config.services.clock.now() }, .priority = .high, .payload = if (state == .cancelled) .{ .cancelled = reason orelse .requested } else .{ .failed = code } };
        self.mailbox.post(event) catch event.deinit();
        if (state == .completed) _ = self.session.append(.turn_outcome, .assistant, turn.output.items) catch {};
        self.writeTrace(.terminal, if (state == .completed) "{\"reason\":\"completed\"}" else "{\"reason\":\"failed\"}");
    }
    fn writeTrace(self: *Agent, kind: trace.EventType, payload: []const u8) void {
        if (self.trace_writer) |writer| writer.appendCanonical(kind, payload) catch {};
    }
};

const Request = struct { backend: model.Backend, handle: model.ModelRequestHandle };
const ToolCall = struct {
    id: []u8,
    name: []u8,
    arguments: std.ArrayListUnmanaged(u8) = .empty,
    fn init(allocator: std.mem.Allocator, id: []const u8, name: []const u8) !ToolCall {
        return .{ .id = try allocator.dupe(u8, id), .name = try allocator.dupe(u8, name) };
    }
    fn deinit(self: *ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        self.arguments.deinit(allocator);
    }
};
const Turn = struct {
    id: domain.TurnId,
    input: []u8,
    world: context.WorldSnapshot,
    budget: context.TurnBudget,
    request: ?Request = null,
    call: ?ToolCall = null,
    tool_result: ?[]u8 = null,
    operation: ?domain.OperationId = null,
    output: std.ArrayListUnmanaged(u8) = .empty,
    loop_keys: std.StringHashMapUnmanaged(usize) = .empty,
    fn init(allocator: std.mem.Allocator, id: domain.TurnId, submit: SubmitRequest, time: u64, limits: context.TurnBudgetLimits) !Turn {
        return .{ .id = id, .input = try allocator.dupe(u8, submit.input), .world = try context.WorldSnapshot.initCopy(allocator, submit.world.revision, submit.world.captured_at, submit.world.sections), .budget = context.TurnBudget.init(limits, time) };
    }
    fn deinit(self: *Turn, allocator: std.mem.Allocator) void {
        if (self.request) |request| request.backend.release(request.handle);
        if (self.operation) |_| {}
        if (self.call) |*call| call.deinit(allocator);
        allocator.free(self.input);
        self.world.deinit();
        if (self.tool_result) |value| allocator.free(value);
        self.output.deinit(allocator);
        var keys = self.loop_keys.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        self.loop_keys.deinit(allocator);
    }
};
fn terminal(state: TurnState) bool {
    return state == .completed or state == .failed or state == .cancelled;
}
fn systemNow(_: ?*anyopaque) u64 {
    var clock = foundation.time.SystemClock{};
    return @intCast(@max(0, clock.clock().monotonicNow().nanoseconds));
}
fn noWorkers(_: ?*anyopaque) usize {
    return 0;
}
fn noDrain(_: ?*anyopaque, _: usize, _: u64) usize {
    return 0;
}
fn noEvent(_: ?*anyopaque, _: []const u8, _: i64) void {}
fn noOperation(_: ?*anyopaque, _: domain.OperationId, _: u64) ExecutionServices.Operations.Result {
    return .stale;
}
fn noOperationCancel(_: ?*anyopaque, _: domain.OperationId, _: domain.CancelReason) void {}
fn noOperationRelease(_: ?*anyopaque, _: domain.OperationId) void {}
