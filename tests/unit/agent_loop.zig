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
