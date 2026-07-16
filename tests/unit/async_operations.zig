const std = @import("std");
const nar = @import("nar");
const spindle = @import("spindle");

fn complete(context: *nar.operation.Context) void {
    const payload = foundation.memory.SharedBuffer.initCopy(std.testing.allocator, "{\"ok\":true}", .general) catch return;
    _ = context.complete(payload);
}

const foundation = @import("foundation");

test "operations route through compute blocking and caller pump" {
    var host = try nar.spindle.TestHost.init(std.testing.allocator, 4);
    defer host.deinit();

    const compute = try host.operations().submit(.{ .affinity = .compute }, complete);
    try std.testing.expectEqual(nar.operation.State.queued, host.operations().stateOf(compute).?);
    try host.runCompute();
    try expectPayload(host.operations().poll(compute, 0));
    host.operations().release(compute);

    const blocking = try host.operations().submit(.{ .affinity = .blocking }, complete);
    try expectPayload(host.operations().poll(blocking, 0));
    host.operations().release(blocking);

    const pump = try host.operations().submit(.{ .affinity = .pump }, complete);
    try std.testing.expectEqual(@as(usize, 1), host.pump(1, std.time.ns_per_s));
    try expectPayload(host.operations().poll(pump, 0));
    host.operations().release(pump);
}

test "operation cancellation timeout ownership and stale IDs are terminal" {
    var host = try nar.spindle.TestHost.init(std.testing.allocator, 2);
    defer host.deinit();
    const queued = try host.operations().submit(.{ .affinity = .pump }, complete);
    host.operations().cancel(queued, .requested);
    try std.testing.expectEqual(nar.operation.State.cancelled, host.operations().stateOf(queued).?);
    try std.testing.expectEqual(nar.core.ExecutionServices.Operations.Result{ .cancelled = .requested }, host.operations().poll(queued, 0));
    host.operations().release(queued);
    try std.testing.expectEqual(nar.core.ExecutionServices.Operations.Result.stale, host.operations().poll(queued, 0));

    const timed = try host.operations().submit(.{ .affinity = .pump, .deadline_monotonic_ns = 10 }, complete);
    host.advance(10);
    try std.testing.expectEqual(nar.core.ExecutionServices.Operations.Result.timed_out, host.operations().poll(timed, host.runtime().config.services.clock.now()));
    host.operations().release(timed);
}

test "operation registry rejects bounded capacity and reuses slots generationally" {
    var compute = spindle.executor.DeterministicExecutor.init(std.testing.allocator);
    defer compute.deinit();
    var blocking = spindle.executor.InlineExecutor{};
    var pump = try spindle.executor.PumpExecutor.init(std.testing.allocator, 2);
    var registry = try nar.operation.Registry.init(std.testing.allocator, .{ .capacity = 1 }, compute.executor(), blocking.executor(), pump.executor());
    defer registry.deinit();
    defer pump.deinit();

    const first = try registry.submit(.{ .affinity = .pump }, complete);
    try std.testing.expectError(error.BudgetExceeded, registry.submit(.{ .affinity = .pump }, complete));
    _ = pump.drain(1);
    try expectPayload(registry.poll(first, 0));
    registry.release(first);
    const second = try registry.submit(.{ .affinity = .pump }, complete);
    try std.testing.expect(first.slot() == second.slot());
    try std.testing.expect(first.generation() != second.generation());
    try std.testing.expectEqual(nar.core.ExecutionServices.Operations.Result.stale, registry.poll(first, 0));
}

test "production operation submissions are safe from concurrent callers" {
    var host = try nar.spindle.Host.init(std.testing.allocator, .{ .compute_workers = 2, .queue_capacity = 32 });
    defer host.deinit();
    var ids: [8]nar.OperationId = undefined;
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, submitOne, .{ host.operations(), &ids[index] });
    for (threads) |thread| thread.join();
    for (ids) |id| {
        var attempts: usize = 0;
        while (attempts < 1000) : (attempts += 1) switch (host.operations().poll(id, host.runtime().config.services.clock.now())) {
            .pending => std.Thread.yield() catch {},
            .completed => |buffer| {
                var owned = buffer;
                owned.release();
                host.operations().release(id);
                break;
            },
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expect(attempts < 1000);
    }
}

fn submitOne(registry: *nar.operation.Registry, output: *nar.OperationId) void {
    output.* = registry.submit(.{ .affinity = .compute }, complete) catch @panic("operation submit failed");
}

fn expectPayload(result: nar.core.ExecutionServices.Operations.Result) !void {
    switch (result) {
        .completed => |buffer| {
            var owned = buffer;
            defer owned.release();
            try std.testing.expectEqualStrings("{\"ok\":true}", try owned.bytes());
        },
        else => return error.TestUnexpectedResult,
    }
}
