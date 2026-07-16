const std = @import("std");
const nar = @import("nar");
const spindle = @import("spindle");
const foundation = @import("foundation");
const script = @import("script_backend");

const move_phase = [_]script.Event{ .start, .{ .tool_start = .{ .id = "move-1", .name = "move_async" } }, .{ .arguments = "{\"x\":4}" }, .{ .tool_end = "move-1" } };
const final_phase = [_]script.Event{ .start, .{ .text = "moved" }, .{ .finish = .stop } };
const move_phases = [_][]const script.Event{ &move_phase, &final_phase };

const MoveState = struct {
    host: *nar.spindle.TestHost,
    operation: ?nar.OperationId = null,
    calls: usize = 0,
};

fn completeMove(context: *nar.operation.Context) void {
    const payload = foundation.memory.SharedBuffer.initCopy(std.testing.allocator, "{\"moved\":true}", .general) catch return;
    _ = context.complete(payload);
}
fn moveAsync(raw: ?*anyopaque, _: nar.tool.InvocationContext) !nar.tool.CallbackResult {
    const state: *MoveState = @ptrCast(@alignCast(raw.?));
    state.calls += 1;
    const id = try state.host.operations().submit(.{ .affinity = .pump }, completeMove);
    state.operation = id;
    return .{ .pending = id };
}
fn world() !nar.context.WorldSnapshot {
    return nar.context.WorldSnapshot.initCopy(std.testing.allocator, nar.WorldRevision.fromInt(9), .{ .nanoseconds = 0 }, &.{});
}
fn config() nar.core.AgentConfig {
    return .{ .provider_id = "example", .definition = .{ .model_id = "script", .system_context = "Move once.", .default_budget = .{ .model_calls = 2, .tool_calls = 1, .output_tokens = 16 } } };
}

test "async move reaches waiting operation, requires pump, and preserves trace order" {
    var host = try nar.spindle.TestHost.init(std.testing.allocator, 4);
    defer host.deinit();
    var backend = script.Backend{ .allocator = std.testing.allocator, .phases = &move_phases };
    try host.runtime().models.register(backend.model());
    var state = MoveState{ .host = &host };
    _ = try host.runtime().tools.register(.{ .name = "move_async", .input_schema = "{\"type\":\"object\",\"required\":[\"x\"],\"properties\":{\"x\":{\"type\":\"integer\"}}}" }, moveAsync, &state);
    const agent = try host.runtime().createAgent(config());
    var snapshot = try world();
    defer snapshot.deinit();
    var sink = nar.trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var writer = try nar.trace.Writer.init(std.testing.allocator, sink.sink(), .{ .session_id = 1, .runtime_id = nar.RuntimeId.init(1).? }, .{});
    defer writer.deinit();
    agent.setTraceWriter(&writer);
    _ = try agent.submit(.{ .input = "move", .world = &snapshot });
    for (0..12) |_| {
        _ = agent.tick();
        if (agent.state == .waiting_operation) break;
    }
    try std.testing.expectEqual(nar.core.TurnState.waiting_operation, agent.state);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(nar.core.TickResult.would_block, agent.tick());
    try std.testing.expectEqual(@as(usize, 1), host.pump(1, std.time.ns_per_s));
    for (0..16) |_| if (agent.tick() == .terminal) break;
    try std.testing.expectEqual(nar.core.TurnState.completed, agent.state);

    const bytes = try sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var reader = try nar.trace.Reader.init(bytes, .{});
    var saw_queued = false;
    var saw_completed = false;
    var saw_terminal = false;
    while (try reader.next()) |record| switch (record.kind) {
        .operation_transition => {
            if (std.mem.indexOf(u8, record.payload, "queued") != null) saw_queued = true;
            if (std.mem.indexOf(u8, record.payload, "completed") != null) saw_completed = true;
        },
        .terminal => saw_terminal = saw_queued and saw_completed,
        else => {},
    };
    try std.testing.expect(saw_terminal);
}

test "owner cancellation wins waiting operation and rejects late completion" {
    var host = try nar.spindle.TestHost.init(std.testing.allocator, 2);
    defer host.deinit();
    var backend = script.Backend{ .allocator = std.testing.allocator, .phases = &move_phases };
    try host.runtime().models.register(backend.model());
    var state = MoveState{ .host = &host };
    _ = try host.runtime().tools.register(.{ .name = "move_async", .input_schema = "{\"type\":\"object\"}" }, moveAsync, &state);
    const agent = try host.runtime().createAgent(config());
    var snapshot = try world();
    defer snapshot.deinit();
    _ = try agent.submit(.{ .input = "move", .world = &snapshot });
    for (0..12) |_| {
        _ = agent.tick();
        if (agent.state == .waiting_operation) break;
    }
    const operation = state.operation.?;
    agent.cancel(.owner_destroyed);
    const late = try foundation.memory.SharedBuffer.initCopy(std.testing.allocator, "{}", .general);
    try std.testing.expect(!host.operations().completeExternal(operation, late));
    try std.testing.expectEqual(nar.core.TurnState.cancelled, agent.state);
    var terminals: usize = 0;
    while (agent.poll()) |raw| {
        var event = raw;
        defer event.deinit();
        if (event.payload == .cancelled) {
            terminals += 1;
            try std.testing.expectEqual(nar.CancelReason.owner_destroyed, event.payload.cancelled);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), terminals);
}

test "fresh replay reproduces success without live model tool or executor callbacks" {
    const text_phase = [_]script.Event{ .start, .{ .text = "offline" }, .{ .finish = .stop } };
    const phases = [_][]const script.Event{&text_phase};
    var live_host = try nar.spindle.TestHost.init(std.testing.allocator, 2);
    defer live_host.deinit();
    var live_backend = script.Backend{ .allocator = std.testing.allocator, .phases = &phases };
    try live_host.runtime().models.register(live_backend.model());
    const live_agent = try live_host.runtime().createAgent(.{ .provider_id = "example", .definition = .{ .model_id = "script", .system_context = "Answer.", .default_budget = .{ .model_calls = 1, .output_tokens = 16 } } });
    var snapshot = try world();
    defer snapshot.deinit();
    var sink = nar.trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var writer = try nar.trace.Writer.init(std.testing.allocator, sink.sink(), .{ .session_id = 2, .runtime_id = nar.RuntimeId.init(2).? }, .{});
    defer writer.deinit();
    live_agent.setTraceWriter(&writer);
    _ = try live_agent.submit(.{ .input = "answer", .world = &snapshot });
    for (0..8) |_| if (live_agent.tick() == .terminal) break;
    const bytes = try sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    var replay_session = try nar.trace.ReplaySession.init(bytes, .strict);
    var replay_backend = try nar.trace.ReplayBackend.init(std.testing.allocator, &replay_session, .{ .provider_id = "replay", .model_id = "script", .capabilities = .{ .streaming = true } });
    var replay_host = try nar.spindle.TestHost.init(std.testing.allocator, 2);
    defer replay_host.deinit();
    try replay_host.runtime().models.register(replay_backend.backend());
    const replay_agent = try replay_host.runtime().createAgent(.{ .provider_id = "replay", .definition = .{ .model_id = "script", .system_context = "Answer.", .default_budget = .{ .model_calls = 1, .output_tokens = 16 } } });
    _ = try replay_agent.submit(.{ .input = "answer", .world = &snapshot });
    for (0..8) |_| if (replay_agent.tick() == .terminal) break;
    try std.testing.expectEqual(nar.core.TurnState.completed, replay_agent.state);
    try replay_session.expect(.terminal, "{\"reason\":\"completed\"}");
    try replay_session.finish();
    try std.testing.expectEqual(@as(usize, 0), replay_host.pump(8, std.time.ns_per_s));
}

test "fresh replay reproduces owner cancellation without queued work" {
    const pending_phase = [_]script.Event{.start};
    const phases = [_][]const script.Event{&pending_phase};
    var live_host = try nar.spindle.TestHost.init(std.testing.allocator, 2);
    defer live_host.deinit();
    var live_backend = script.Backend{ .allocator = std.testing.allocator, .phases = &phases };
    try live_host.runtime().models.register(live_backend.model());
    const live_agent = try live_host.runtime().createAgent(.{ .provider_id = "example", .definition = .{ .model_id = "script", .system_context = "Wait.", .default_budget = .{ .model_calls = 1 } } });
    var snapshot = try world();
    defer snapshot.deinit();
    var sink = nar.trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var writer = try nar.trace.Writer.init(std.testing.allocator, sink.sink(), .{ .session_id = 3, .runtime_id = nar.RuntimeId.init(3).? }, .{});
    defer writer.deinit();
    live_agent.setTraceWriter(&writer);
    _ = try live_agent.submit(.{ .input = "wait", .world = &snapshot });
    try std.testing.expectEqual(nar.core.TickResult.progressed, live_agent.tick());
    try std.testing.expectEqual(nar.core.TickResult.progressed, live_agent.tick());
    live_agent.cancel(.owner_destroyed);
    const bytes = try sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    var replay_session = try nar.trace.ReplaySession.init(bytes, .strict);
    var replay_backend = try nar.trace.ReplayBackend.init(std.testing.allocator, &replay_session, .{ .provider_id = "replay", .model_id = "script", .capabilities = .{ .streaming = true } });
    var replay_host = try nar.spindle.TestHost.init(std.testing.allocator, 2);
    defer replay_host.deinit();
    try replay_host.runtime().models.register(replay_backend.backend());
    const replay_agent = try replay_host.runtime().createAgent(.{ .provider_id = "replay", .definition = .{ .model_id = "script", .system_context = "Wait.", .default_budget = .{ .model_calls = 1 } } });
    _ = try replay_agent.submit(.{ .input = "wait", .world = &snapshot });
    try std.testing.expectEqual(nar.core.TickResult.progressed, replay_agent.tick());
    try std.testing.expectEqual(nar.core.TickResult.progressed, replay_agent.tick());
    replay_agent.cancel(.owner_destroyed);
    try std.testing.expectEqual(nar.core.TurnState.cancelled, replay_agent.state);
    try replay_session.expect(.terminal, "{\"reason\":\"cancelled_owner_destroyed\"}");
    try replay_session.finish();
    try std.testing.expectEqual(@as(usize, 0), replay_host.pump(8, std.time.ns_per_s));
}

test "spindle resource graph preserves RAW WAR and WAW hazards" {
    const resource = spindle.resource_graph.ResourceKey.named(.custom, spindle.core.StableId.zero, "player-position");
    var graph = spindle.resource_graph.ResourceTaskGraph.init(std.testing.allocator);
    defer graph.deinit();
    const write_a = try graph.addTask(.{ .name = "write-a" });
    const read = try graph.addTask(.{ .name = "read" });
    const write_b = try graph.addTask(.{ .name = "write-b" });
    try graph.addAccess(write_a, .{ .key = resource, .mode = .write });
    try graph.addAccess(read, .{ .key = resource, .mode = .read });
    try graph.addAccess(write_b, .{ .key = resource, .mode = .write });
    var plan = try graph.compile(std.testing.allocator);
    defer plan.deinit();
    var raw = false;
    var war = false;
    var waw = false;
    for (plan.diagnostics) |diagnostic| switch (diagnostic.hazard) {
        .raw => raw = true,
        .war => war = true,
        .waw => waw = true,
        else => {},
    };
    try std.testing.expect(raw and war and waw);
}
