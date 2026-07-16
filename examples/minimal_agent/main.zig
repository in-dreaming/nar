const std = @import("std");
const nar = @import("nar");
const foundation = @import("foundation");
const script = @import("script_backend");

const query_phase = [_]script.Event{
    .start,
    .{ .tool_start = .{ .id = "query-1", .name = "query_player" } },
    .{ .arguments = "{}" },
    .{ .tool_end = "query-1" },
};
const final_phase = [_]script.Event{ .start, .{ .text = "player ready" }, .{ .finish = .stop } };
const phases = [_][]const script.Event{ &query_phase, &final_phase };

fn queryPlayer(_: ?*anyopaque, invocation: nar.tool.InvocationContext) !nar.tool.CallbackResult {
    return .{ .completed = try foundation.memory.SharedBuffer.initCopy(invocation.allocator, "{\"ready\":true}", .general) };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var host = try nar.spindle.TestHost.init(allocator, 4);
    defer host.deinit();
    var backend = script.Backend{ .allocator = allocator, .phases = &phases };
    try host.runtime().models.register(backend.model());
    _ = try host.runtime().tools.register(.{
        .name = "query_player",
        .input_schema = "{\"type\":\"object\",\"additionalProperties\":false}",
    }, queryPlayer, null);
    const agent = try host.runtime().createAgent(.{
        .provider_id = "example",
        .definition = .{ .model_id = "script", .system_context = "Use the query tool.", .default_budget = .{ .model_calls = 2, .tool_calls = 1, .output_tokens = 16 } },
    });
    var world = try nar.context.WorldSnapshot.initCopy(allocator, nar.WorldRevision.fromInt(1), .{ .nanoseconds = 0 }, &.{});
    defer world.deinit();
    _ = try agent.submit(.{ .input = "Is the player ready?", .world = &world });
    for (0..32) |_| if (agent.tick() == .terminal) break;
    if (agent.state != .completed) return error.AgentDidNotComplete;
    var saw_final = false;
    while (agent.poll()) |raw| {
        var event = raw;
        defer event.deinit();
        if (event.payload == .final_response) {
            saw_final = true;
            if (!std.mem.eql(u8, try event.payload.final_response.bytes(), "player ready")) return error.UnexpectedResponse;
        }
    }
    if (!saw_final) return error.MissingFinalResponse;
}
