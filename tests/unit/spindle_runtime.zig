const std = @import("std");
const nar = @import("nar");
const spindle = @import("spindle");

test "test host virtual clock drives core runtime deadlines" {
    var host = try nar.spindle.TestHost.init(std.testing.allocator, 2);
    defer host.deinit();
    try std.testing.expectEqual(@as(u64, 0), host.runtime().config.services.clock.now());
    host.advance(42);
    try std.testing.expectEqual(@as(u64, 42), host.runtime().config.services.clock.now());
    try std.testing.expectEqual(@as(usize, 1), host.runtime().config.services.compute.workerCount());
}

test "production host owns runtime and finite shutdown cancels pending pump task" {
    var host = try nar.spindle.Host.init(std.testing.allocator, .{ .queue_capacity = 2 });
    defer host.deinit();
    var task = spindle.executor.Task.init(struct {
        fn run(_: *spindle.executor.Task) void {
            @panic("cancelled pump task ran");
        }
    }.run, null);
    try host.spindleRuntime().pumpExecutor().submit(&task, .{});
    const report = host.shutdown(host.spindleRuntime().clock().monotonicNow() + std.time.ns_per_s);
    try std.testing.expect(report.completed);
    try std.testing.expectEqual(spindle.executor.TaskState.cancelled, task.status());
}

test "production host initialization failures release owned threaded services" {
    try std.testing.expectError(error.InjectedFailure, nar.spindle.Host.init(std.testing.allocator, .{ .fault = .compute }));
}

test "test host reports bounded caller pump backpressure" {
    var host = try nar.spindle.TestHost.init(std.testing.allocator, 2);
    defer host.deinit();
    var first = spindle.executor.Task.init(noop, null);
    var second = spindle.executor.Task.init(noop, null);
    var third = spindle.executor.Task.init(noop, null);
    try host.submitPump(&first);
    try host.submitPump(&second);
    try std.testing.expectError(error.Backpressure, host.submitPump(&third));
    try std.testing.expectEqual(@as(usize, 2), host.pump(2, std.time.ns_per_s));
    try std.testing.expectEqual(spindle.executor.TaskState.completed, first.status());
}

test "virtual clock is synchronized for concurrent host callers" {
    var host = try nar.spindle.TestHost.init(std.testing.allocator, 2);
    defer host.deinit();
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, advanceClock, .{&host});
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u64, 400), host.runtime().config.services.clock.now());
}

fn noop(_: *spindle.executor.Task) void {}
fn advanceClock(host: *nar.spindle.TestHost) void {
    for (0..100) |_| host.advance(1);
}
