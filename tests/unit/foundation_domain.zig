const std = @import("std");
const nar = @import("nar");
const domain = nar.domain;
const foundation = @import("foundation");

fn textEvent(turn: domain.TurnId, text: []const u8, priority: domain.EventPriority) !domain.AgentEvent {
    return .{
        .turn_id = turn,
        .timestamp = .{ .nanoseconds = 1 },
        .priority = priority,
        .payload = .{ .text_delta = try foundation.memory.SharedBuffer.initCopy(std.testing.allocator, text, .general) },
    };
}

test "error codes are stable and metadata maps security and retry behavior" {
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(domain.ErrorCode.invalid_argument));
    try std.testing.expectEqual(@as(u32, 16), @intFromEnum(domain.ErrorCode.internal_error));
    try std.testing.expect(domain.errorMetadata(.network_error).retryable);
    try std.testing.expect(domain.errorMetadata(.tool_permission_denied).security_sensitive);
    try std.testing.expect(!domain.errorMetadata(.internal_error).model_visible);
    try std.testing.expectEqual(domain.ErrorCode.timeout, domain.errorCodeFromZig(error.Timeout));
    try std.testing.expectEqual(error.ToolNotFound, domain.zigErrorFromCode(.tool_not_found).?);
    try std.testing.expect(domain.zigErrorFromCode(.ok) == null);
}

test "IDs reject zero and registry rejects stale double removal" {
    try std.testing.expect(domain.AgentId.init(0) == null);
    const agent = domain.AgentId.init(99).?;
    try std.testing.expect(agent.isValid());
    try std.testing.expectEqual(@as(u64, 99), agent.toInt());
    try std.testing.expect(!(domain.ObjectRef{}).isValid());
    try std.testing.expect((domain.ObjectRef{ .id = 1, .generation = 1 }).isValid());

    const Registry = domain.GenerationalRegistry(u32, struct {
        const name = "unit";
    });
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const first = try registry.insert(4);
    try std.testing.expectEqual(@as(?u32, 4), registry.remove(first));
    try std.testing.expect(registry.remove(first) == null);
    const replacement = try registry.insert(9);
    try std.testing.expectEqual(first.index(), replacement.index());
    try std.testing.expect(first.generation() != replacement.generation());
}

test "cancellation is idempotent and visible through cloned tokens" {
    var source = try domain.CancellationSource.init(std.testing.allocator);
    defer source.deinit();
    var token = source.token();
    defer token.deinit();
    var clone = token.clone();
    defer clone.deinit();
    try std.testing.expect(source.cancel(.timeout));
    try std.testing.expect(!source.cancel(.requested));
    try std.testing.expect(token.isCancelled());
    try std.testing.expectEqual(domain.CancelReason.timeout, clone.reason().?);
}

test "mailbox preserves FIFO sequence, merges adjacent deltas, and reports backpressure" {
    const turn = domain.TurnId.init(1).?;
    var mailbox = try domain.EventMailbox.init(std.testing.allocator, 2);
    defer mailbox.deinit();
    try mailbox.post(try textEvent(turn, "hel", .normal));
    try mailbox.post(try textEvent(turn, "lo", .normal));
    try std.testing.expectEqual(@as(usize, 1), mailbox.len());
    var merged = mailbox.poll().?;
    defer merged.deinit();
    try std.testing.expectEqual(@as(u64, 1), merged.sequence);
    try std.testing.expectEqualStrings("hello", try merged.payload.text_delta.bytes());

    try mailbox.post(try textEvent(turn, "a", .normal));
    const terminal = domain.AgentEvent{ .turn_id = turn, .timestamp = .{}, .priority = .critical, .payload = .{ .failed = .timeout } };
    try mailbox.post(terminal);
    var extra = try textEvent(turn, "b", .normal);
    try std.testing.expectError(error.Backpressure, mailbox.post(extra));
    extra.deinit();
    var first = mailbox.poll().?;
    defer first.deinit();
    var second = mailbox.poll().?;
    defer second.deinit();
    try std.testing.expectEqual(@as(u64, 2), first.sequence);
    try std.testing.expectEqual(@as(u64, 3), second.sequence);
    try std.testing.expect(second.isTerminal());
}

test "mailbox deinitialization releases queued payloads and capacity allocation fails" {
    var budget = foundation.memory.AllocationBudget.init(3);
    try std.testing.expectError(error.BudgetExceeded, foundation.memory.SharedBuffer.initCopyWithBudget(std.testing.allocator, "four", .general, &budget, .{}));

    const Probe = struct {
        var releases: usize = 0;
        fn release(_: ?*anyopaque, bytes: []u8) void {
            releases += 1;
            std.testing.allocator.free(bytes);
        }
    };
    Probe.releases = 0;
    const bytes = try std.testing.allocator.dupe(u8, "owned");
    var mailbox = try domain.EventMailbox.init(std.testing.allocator, 1);
    const event = domain.AgentEvent{ .turn_id = domain.TurnId.init(1).?, .timestamp = .{}, .payload = .{ .final_response = try foundation.memory.SharedBuffer.adopt(std.testing.allocator, bytes, .mutable, .general, Probe.release, null, null, .{}) } };
    try mailbox.post(event);
    mailbox.deinit();
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, domain.EventMailbox.init(failing.allocator(), 1));
}

test "delta coalescing releases both replaced payload owners exactly once" {
    const Probe = struct {
        var releases: usize = 0;
        fn release(_: ?*anyopaque, bytes: []u8) void {
            releases += 1;
            std.testing.allocator.free(bytes);
        }
    };
    Probe.releases = 0;
    const turn = domain.TurnId.init(1).?;
    var mailbox = try domain.EventMailbox.init(std.testing.allocator, 1);
    defer mailbox.deinit();
    const first_bytes = try std.testing.allocator.dupe(u8, "a");
    const second_bytes = try std.testing.allocator.dupe(u8, "b");
    try mailbox.post(.{
        .turn_id = turn,
        .timestamp = .{},
        .payload = .{ .text_delta = try foundation.memory.SharedBuffer.adopt(std.testing.allocator, first_bytes, .mutable, .general, Probe.release, null, null, .{}) },
    });
    try mailbox.post(.{
        .turn_id = turn,
        .timestamp = .{},
        .payload = .{ .text_delta = try foundation.memory.SharedBuffer.adopt(std.testing.allocator, second_bytes, .mutable, .general, Probe.release, null, null, .{}) },
    });
    try std.testing.expectEqual(@as(usize, 2), Probe.releases);
    var merged = mailbox.poll().?;
    merged.deinit();
}

test "concurrent producers retain every accepted event" {
    const producer_count = 3;
    const per_producer = 20;
    const Worker = struct {
        mailbox: *domain.EventMailbox,
        turn: domain.TurnId,
        fn run(self: *@This()) void {
            for (0..per_producer) |index| {
                const event = domain.AgentEvent{
                    .turn_id = self.turn,
                    .timestamp = .{ .nanoseconds = index },
                    .payload = .{ .operation_progress = foundation.memory.SharedBuffer.initCopy(std.testing.allocator, "progress", .general) catch @panic("allocation failed") },
                };
                while (true) {
                    self.mailbox.post(event) catch |err| switch (err) {
                        error.Backpressure => {
                            std.Thread.yield() catch {};
                            continue;
                        },
                        else => @panic("unexpected mailbox error"),
                    };
                    break;
                }
            }
        }
    };
    var mailbox = try domain.EventMailbox.init(std.testing.allocator, producer_count * per_producer);
    defer mailbox.deinit();
    var states: [producer_count]Worker = undefined;
    var threads: [producer_count]std.Thread = undefined;
    for (&states, 0..) |*state, index| {
        state.* = .{ .mailbox = &mailbox, .turn = domain.TurnId.init(@as(u64, @intCast(index + 1))).? };
        threads[index] = try std.Thread.spawn(.{}, Worker.run, .{state});
    }
    for (threads) |thread| thread.join();
    var count: usize = 0;
    var prior: u64 = 0;
    while (mailbox.poll()) |event| {
        var owned = event;
        defer owned.deinit();
        try std.testing.expect(owned.sequence > prior);
        prior = owned.sequence;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, producer_count * per_producer), count);
}
