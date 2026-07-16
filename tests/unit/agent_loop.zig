const std = @import("std");
const nar = @import("nar");
const foundation = @import("foundation");

const model = nar.model;
const core = nar.core;
const context = nar.context;
const tool = nar.tool;

const ScriptBackend = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    next_request: u32 = 0,
    active: bool = false,
    generation: u32 = 1,
    phase: u32 = 0,
    cursor: u32 = 0,
    cancelled: bool = false,
    releases: u32 = 0,

    const Mode = enum { tool_sequence, pending, malformed };

    fn backend(self: *ScriptBackend) model.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: model.Backend.VTable = .{
        .descriptor = descriptor,
        .start = start,
        .poll = poll,
        .cancel = cancel,
        .release = release,
    };

    fn cast(raw: *anyopaque) *ScriptBackend {
        return @ptrCast(@alignCast(raw));
    }

    fn descriptor(_: *anyopaque) model.ModelDescriptor {
        return .{
            .provider_id = "script",
            .model_id = "agent-test",
            .capabilities = .{ .streaming = true, .tool_calling = true },
        };
    }

    fn start(raw: *anyopaque, request: model.ModelRequest) !model.ModelRequestHandle {
        const self = cast(raw);
        if (self.active) return error.InvalidState;
        if (!std.mem.eql(u8, request.model_id, "agent-test")) return error.ModelUnavailable;
        self.active = true;
        self.phase = self.next_request;
        self.next_request += 1;
        self.cursor = 0;
        self.cancelled = false;
        return .{ .index = 0, .generation = self.generation };
    }

    fn poll(raw: *anyopaque, handle: model.ModelRequestHandle) !?model.ModelEvent {
        const self = cast(raw);
        try self.validate(handle);
        if (self.cancelled) return .{ .cancelled = {} };
        if (self.mode == .pending) return null;
        if (self.mode == .malformed) {
            self.cursor += 1;
            return if (self.cursor == 1)
                .{ .arguments_delta = try self.buffer("{}") }
            else
                null;
        }

        const event = switch (self.phase) {
            0 => switch (self.cursor) {
                0 => model.ModelEvent{ .start = {} },
                1 => model.ModelEvent{ .tool_call_start = .{ .call_id = try self.buffer("query-1"), .name = try self.buffer("query_player") } },
                2 => model.ModelEvent{ .arguments_delta = try self.buffer("{}") },
                3 => model.ModelEvent{ .tool_call_end = .{ .call_id = try self.buffer("query-1") } },
                else => return null,
            },
            1 => switch (self.cursor) {
                0 => model.ModelEvent{ .start = {} },
                1 => model.ModelEvent{ .tool_call_start = .{ .call_id = try self.buffer("move-1"), .name = try self.buffer("move_to") } },
                2 => model.ModelEvent{ .arguments_delta = try self.buffer("{\"x\":4}") },
                3 => model.ModelEvent{ .tool_call_end = .{ .call_id = try self.buffer("move-1") } },
                else => return null,
            },
            2 => switch (self.cursor) {
                0 => model.ModelEvent{ .start = {} },
                1 => model.ModelEvent{ .text_delta = try self.buffer("done") },
                2 => model.ModelEvent{ .finish = .stop },
                else => return null,
            },
            else => return error.ModelProtocolError,
        };
        self.cursor += 1;
        return event;
    }

    fn cancel(raw: *anyopaque, handle: model.ModelRequestHandle) !void {
        const self = cast(raw);
        try self.validate(handle);
        self.cancelled = true;
    }

    fn release(raw: *anyopaque, handle: model.ModelRequestHandle) void {
        const self = cast(raw);
        self.validate(handle) catch return;
        self.active = false;
        self.cancelled = false;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.releases += 1;
    }

    fn validate(self: *ScriptBackend, handle: model.ModelRequestHandle) !void {
        if (!self.active or handle.index != 0 or handle.generation != self.generation) return error.InvalidState;
    }

    fn buffer(self: *ScriptBackend, bytes: []const u8) !foundation.memory.SharedBuffer {
        return foundation.memory.SharedBuffer.initCopy(self.allocator, bytes, .general);
    }
};

const ToolState = struct {
    query_calls: u32 = 0,
    move_calls: u32 = 0,
};

fn queryPlayer(raw: ?*anyopaque, invocation: tool.InvocationContext) !tool.CallbackResult {
    const state: *ToolState = @ptrCast(@alignCast(raw.?));
    state.query_calls += 1;
    return .{ .completed = try foundation.memory.SharedBuffer.initCopy(invocation.allocator, "{\"health\":100}", .general) };
}

fn moveTo(raw: ?*anyopaque, invocation: tool.InvocationContext) !tool.CallbackResult {
    const state: *ToolState = @ptrCast(@alignCast(raw.?));
    state.move_calls += 1;
    return .{ .completed = try foundation.memory.SharedBuffer.initCopy(invocation.allocator, "{\"moved\":true}", .general) };
}

fn snapshot() !context.WorldSnapshot {
    return context.WorldSnapshot.initCopy(
        std.testing.allocator,
        nar.WorldRevision.fromInt(1),
        .{ .nanoseconds = 1 },
        &.{.{ .name = "player", .payload = "{\"alive\":true}" }},
    );
}

fn agentConfig() core.AgentConfig {
    return .{
        .provider_id = "script",
        .definition = .{
            .system_context = "Use registered tools.",
            .model_id = "agent-test",
            .allowed_tools = &.{ "query_player", "move_to" },
            .default_budget = .{ .model_calls = 4, .tool_calls = 3, .output_tokens = 32 },
        },
    };
}

test "agent loop executes query and action tools before final response" {
    var backend = ScriptBackend{ .allocator = std.testing.allocator, .mode = .tool_sequence };
    var runtime = try core.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try runtime.models.register(backend.backend());

    var state = ToolState{};
    _ = try runtime.tools.register(.{ .name = "query_player", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false}" }, queryPlayer, &state);
    _ = try runtime.tools.register(.{ .name = "move_to", .input_schema = "{\"type\":\"object\",\"required\":[\"x\"],\"properties\":{\"x\":{\"type\":\"integer\"}},\"additionalProperties\":false}" }, moveTo, &state);

    const agent = try runtime.createAgent(agentConfig());
    var world = try snapshot();
    defer world.deinit();
    _ = try agent.submit(.{ .input = "Move to the target.", .world = &world });

    for (0..32) |_| {
        if (agent.tick() == .terminal) break;
    }
    try std.testing.expectEqual(core.TurnState.completed, agent.state);
    try std.testing.expectEqual(@as(u32, 1), state.query_calls);
    try std.testing.expectEqual(@as(u32, 1), state.move_calls);
    try std.testing.expectEqual(@as(u32, 3), backend.releases);

    try std.testing.expectError(error.InvalidState, agent.submit(.{ .input = "next", .world = &world }));

    var final_count: usize = 0;
    while (agent.poll()) |raw_event| {
        var event = raw_event;
        defer event.deinit();
        if (event.payload == .final_response) {
            final_count += 1;
            try std.testing.expectEqualStrings("done", try event.payload.final_response.bytes());
        }
    }
    try std.testing.expectEqual(@as(usize, 1), final_count);
}

test "agent cancellation releases an active request and posts one terminal" {
    var backend = ScriptBackend{ .allocator = std.testing.allocator, .mode = .pending };
    var runtime = try core.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try runtime.models.register(backend.backend());
    const agent = try runtime.createAgent(agentConfig());
    var world = try snapshot();
    defer world.deinit();
    _ = try agent.submit(.{ .input = "wait", .world = &world });
    try std.testing.expectEqual(core.TickResult.progressed, agent.tick());
    try std.testing.expectEqual(core.TickResult.would_block, agent.tick());
    agent.cancel(.owner_destroyed);
    agent.cancel(.shutdown);
    try std.testing.expectEqual(core.TurnState.cancelled, agent.state);
    try std.testing.expectEqual(@as(u32, 1), backend.releases);

    var cancelled_count: usize = 0;
    while (agent.poll()) |raw_event| {
        var event = raw_event;
        defer event.deinit();
        if (event.payload == .cancelled) {
            cancelled_count += 1;
            try std.testing.expectEqual(nar.CancelReason.owner_destroyed, event.payload.cancelled);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), cancelled_count);
}

test "arguments without a tool call fail with a protocol terminal" {
    var backend = ScriptBackend{ .allocator = std.testing.allocator, .mode = .malformed };
    var runtime = try core.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try runtime.models.register(backend.backend());
    const agent = try runtime.createAgent(agentConfig());
    var world = try snapshot();
    defer world.deinit();
    _ = try agent.submit(.{ .input = "bad stream", .world = &world });
    try std.testing.expectEqual(core.TickResult.progressed, agent.tick());
    try std.testing.expectEqual(core.TickResult.terminal, agent.tick());
    try std.testing.expectEqual(core.TurnState.failed, agent.state);
    try std.testing.expectEqual(@as(u32, 1), backend.releases);

    var failure_count: usize = 0;
    while (agent.poll()) |raw_event| {
        var event = raw_event;
        defer event.deinit();
        if (event.payload == .failed) {
            failure_count += 1;
            try std.testing.expectEqual(nar.ErrorCode.model_protocol_error, event.payload.failed);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), failure_count);
}

test "agent does not consume model events while mailbox is full" {
    var backend = ScriptBackend{ .allocator = std.testing.allocator, .mode = .tool_sequence, .next_request = 2 };
    var runtime = try core.Runtime.init(std.testing.allocator, .{ .mailbox_capacity = 1 });
    defer runtime.deinit();
    try runtime.models.register(backend.backend());
    const agent = try runtime.createAgent(agentConfig());
    var world = try snapshot();
    defer world.deinit();
    _ = try agent.submit(.{ .input = "answer", .world = &world });
    try std.testing.expectEqual(core.TickResult.progressed, agent.tick());
    try std.testing.expectEqual(core.TickResult.progressed, agent.tick());
    try std.testing.expectEqual(core.TickResult.progressed, agent.tick());
    try std.testing.expectEqual(core.TickResult.would_block, agent.tick());
    var text = agent.poll().?;
    defer text.deinit();
    try std.testing.expect(text.payload == .text_delta);
    try std.testing.expectEqual(core.TickResult.terminal, agent.tick());
    var final = agent.poll().?;
    defer final.deinit();
    try std.testing.expect(final.payload == .final_response);
}

test "agent execution enforces allowed tools and capabilities" {
    var backend = ScriptBackend{ .allocator = std.testing.allocator, .mode = .tool_sequence };
    var runtime = try core.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try runtime.models.register(backend.backend());
    var state = ToolState{};
    _ = try runtime.tools.register(.{ .name = "query_player", .input_schema = "{\"type\":\"object\"}", .required_capabilities = .{ .bits = 1 } }, queryPlayer, &state);
    var config = agentConfig();
    config.definition.allowed_tools = &.{"query_player"};
    config.capabilities = .{ .bits = 0 };
    config.tool_error_policy = .fail_turn;
    const agent = try runtime.createAgent(config);
    var world = try snapshot();
    defer world.deinit();
    _ = try agent.submit(.{ .input = "query", .world = &world });
    for (0..12) |_| if (agent.tick() == .terminal) break;
    try std.testing.expectEqual(core.TurnState.failed, agent.state);
    try std.testing.expectEqual(@as(u32, 0), state.query_calls);

    var denied_backend = ScriptBackend{ .allocator = std.testing.allocator, .mode = .tool_sequence };
    var denied_runtime = try core.Runtime.init(std.testing.allocator, .{});
    defer denied_runtime.deinit();
    try denied_runtime.models.register(denied_backend.backend());
    _ = try denied_runtime.tools.register(.{ .name = "query_player", .input_schema = "{\"type\":\"object\"}" }, queryPlayer, &state);
    config.definition.allowed_tools = &.{"move_to"};
    const denied = try denied_runtime.createAgent(config);
    _ = try denied.submit(.{ .input = "query", .world = &world });
    for (0..12) |_| if (denied.tick() == .terminal) break;
    try std.testing.expectEqual(core.TurnState.failed, denied.state);
    try std.testing.expectEqual(@as(u32, 0), state.query_calls);
}

test "trace sink failure fails closed before model dispatch" {
    const FailingSink = struct {
        appends: usize = 0,
        fn append(raw: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.appends += 1;
            if (self.appends > 1) return error.StorageUnavailable;
        }
    };
    var backend = ScriptBackend{ .allocator = std.testing.allocator, .mode = .pending };
    var runtime = try core.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try runtime.models.register(backend.backend());
    const agent = try runtime.createAgent(agentConfig());
    var sink = FailingSink{};
    var writer = try nar.trace.Writer.init(std.testing.allocator, .{ .context = &sink, .append_fn = FailingSink.append }, .{ .session_id = 9, .runtime_id = nar.RuntimeId.init(9).? }, .{});
    defer writer.deinit();
    agent.setTraceWriter(&writer);
    var world = try snapshot();
    defer world.deinit();
    _ = try agent.submit(.{ .input = "trace", .world = &world });
    try std.testing.expectEqual(core.TickResult.terminal, agent.tick());
    try std.testing.expectEqual(core.TurnState.failed, agent.state);
    try std.testing.expect(!backend.active);
    var terminal = agent.poll().?;
    defer terminal.deinit();
    try std.testing.expect(terminal.payload == .failed and terminal.payload.failed == .storage_error);
}

test "replay charges the same tool call budget as live dispatch" {
    var live_backend = ScriptBackend{ .allocator = std.testing.allocator, .mode = .tool_sequence };
    var live_runtime = try core.Runtime.init(std.testing.allocator, .{});
    defer live_runtime.deinit();
    try live_runtime.models.register(live_backend.backend());
    var live_state = ToolState{};
    _ = try live_runtime.tools.register(.{ .name = "query_player", .input_schema = "{\"type\":\"object\"}" }, queryPlayer, &live_state);
    _ = try live_runtime.tools.register(.{ .name = "move_to", .input_schema = "{\"type\":\"object\",\"required\":[\"x\"],\"properties\":{\"x\":{\"type\":\"integer\"}}}" }, moveTo, &live_state);
    const live_agent = try live_runtime.createAgent(agentConfig());
    var world = try snapshot();
    defer world.deinit();
    var sink = nar.trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var writer = try nar.trace.Writer.init(std.testing.allocator, sink.sink(), .{ .session_id = 10, .runtime_id = nar.RuntimeId.init(10).? }, .{});
    defer writer.deinit();
    live_agent.setTraceWriter(&writer);
    _ = try live_agent.submit(.{ .input = "move", .world = &world });
    for (0..32) |_| if (live_agent.tick() == .terminal) break;
    try std.testing.expectEqual(core.TurnState.completed, live_agent.state);

    const bytes = try sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var replay_session = try nar.trace.ReplaySession.init(bytes, .strict);
    var replay_backend = try nar.trace.ReplayBackend.init(std.testing.allocator, &replay_session, .{ .provider_id = "replay", .model_id = "agent-test", .capabilities = .{ .streaming = true, .tool_calling = true } });
    var replay_runtime = try core.Runtime.init(std.testing.allocator, .{ .replay = &replay_session });
    defer replay_runtime.deinit();
    try replay_runtime.models.register(replay_backend.backend());
    var replay_state = ToolState{};
    _ = try replay_runtime.tools.register(.{ .name = "query_player", .input_schema = "{\"type\":\"object\"}" }, queryPlayer, &replay_state);
    _ = try replay_runtime.tools.register(.{ .name = "move_to", .input_schema = "{\"type\":\"object\",\"required\":[\"x\"],\"properties\":{\"x\":{\"type\":\"integer\"}}}" }, moveTo, &replay_state);
    var replay_config = agentConfig();
    replay_config.provider_id = "replay";
    replay_config.definition.default_budget.tool_calls = 1;
    replay_config.tool_error_policy = .fail_turn;
    const replay_agent = try replay_runtime.createAgent(replay_config);
    _ = try replay_agent.submit(.{ .input = "move", .world = &world });
    for (0..32) |_| if (replay_agent.tick() == .terminal) break;
    try std.testing.expectEqual(core.TurnState.failed, replay_agent.state);
    var saw_budget_failure = false;
    while (replay_agent.poll()) |raw| {
        var event = raw;
        defer event.deinit();
        if (event.payload == .failed and event.payload.failed == .budget_exceeded) saw_budget_failure = true;
    }
    try std.testing.expect(saw_budget_failure);
    try std.testing.expectEqual(@as(u32, 0), replay_state.query_calls);
    try std.testing.expectEqual(@as(u32, 0), replay_state.move_calls);
}
