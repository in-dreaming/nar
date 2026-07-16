const std = @import("std");
const nar = @import("nar");
const foundation = @import("foundation");
const script = @import("script_backend");

const move_phase = [_]script.Event{ .start, .{ .tool_start = .{ .id = "move-1", .name = "move_async" } }, .{ .arguments = "{\"x\":4}" }, .{ .tool_end = "move-1" } };
const confirm_phase = [_]script.Event{ .start, .{ .tool_start = .{ .id = "confirm-1", .name = "confirm_main" } }, .{ .arguments = "{}" }, .{ .tool_end = "confirm-1" } };
const final_phase = [_]script.Event{ .start, .{ .text = "move confirmed" }, .{ .finish = .stop } };
const phases = [_][]const script.Event{ &move_phase, &confirm_phase, &final_phase };

const ToolState = struct { host: *nar.spindle.Host };

fn completeMove(operation: *nar.operation.Context) void {
    const buffer = foundation.memory.SharedBuffer.initCopy(std.heap.page_allocator, "{\"moved\":true}", .general) catch return;
    _ = operation.complete(buffer);
}
fn completeConfirmation(operation: *nar.operation.Context) void {
    const buffer = foundation.memory.SharedBuffer.initCopy(std.heap.page_allocator, "{\"confirmed\":true}", .general) catch return;
    _ = operation.complete(buffer);
}
fn moveAsync(raw: ?*anyopaque, _: nar.tool.InvocationContext) !nar.tool.CallbackResult {
    const state: *ToolState = @ptrCast(@alignCast(raw.?));
    return .{ .pending = try state.host.operations().submit(.{ .affinity = .compute }, completeMove) };
}
fn confirmMain(raw: ?*anyopaque, _: nar.tool.InvocationContext) !nar.tool.CallbackResult {
    const state: *ToolState = @ptrCast(@alignCast(raw.?));
    return .{ .pending = try state.host.operations().submit(.{ .affinity = .pump }, completeConfirmation) };
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var host = try nar.spindle.Host.init(allocator, .{ .compute_workers = 1, .blocking_workers = 1, .queue_capacity = 8 });
    defer host.deinit();
    var backend = script.Backend{ .allocator = allocator, .phases = &phases };
    try host.runtime().models.register(backend.model());
    var tools = ToolState{ .host = &host };
    _ = try host.runtime().tools.register(.{ .name = "move_async", .input_schema = "{\"type\":\"object\",\"required\":[\"x\"],\"properties\":{\"x\":{\"type\":\"integer\"}}}" }, moveAsync, &tools);
    _ = try host.runtime().tools.register(.{ .name = "confirm_main", .input_schema = "{\"type\":\"object\"}" }, confirmMain, &tools);
    const agent = try host.runtime().createAgent(.{ .provider_id = "example", .definition = .{ .model_id = "script", .system_context = "Move, confirm, then answer.", .allowed_tools = &.{ "move_async", "confirm_main" }, .default_budget = .{ .model_calls = 3, .tool_calls = 2, .output_tokens = 16 } } });
    var world = try nar.context.WorldSnapshot.initCopy(allocator, nar.WorldRevision.fromInt(1), .{ .nanoseconds = host.runtime().config.services.clock.now() }, &.{});
    defer world.deinit();
    _ = try agent.submit(.{ .input = "Move to x=4.", .world = &world });
    for (0..100_000) |_| {
        if (agent.tick() == .terminal) break;
        _ = host.runtime().pumpMainThread(1, std.time.ns_per_ms);
        std.Thread.yield() catch {};
    }
    if (agent.state != .completed) return error.AgentDidNotComplete;
    const report = host.shutdown(host.spindleRuntime().clock().monotonicNow() + std.time.ns_per_s);
    if (!report.completed or report.outstanding_executor_workers != 0 or report.outstanding_pump_work != 0) return error.ShutdownDidNotConverge;
}
