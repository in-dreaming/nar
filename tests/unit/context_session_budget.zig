const std = @import("std");
const nar = @import("nar");
const context = nar.context;
const tool = nar.tool;

test "session snapshots and contexts own copied host data" {
    var session = context.MemorySession.init(std.testing.allocator);
    defer session.deinit();
    var text = [_]u8{ 'h', 'i' };
    try session.append(.message, .assistant, &text);
    text[0] = 'x';
    var snapshot = try session.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("hi", snapshot.entries[0].content);
    var payload = [_]u8{'w'};
    var world = try context.WorldSnapshot.initCopy(std.testing.allocator, nar.WorldRevision.fromInt(1), .{}, &.{.{ .name = "state", .payload = &payload }});
    defer world.deinit();
    payload[0] = 'x';
    var built = try (context.ContextBuilder{ .allocator = std.testing.allocator, .definition = .{ .model_id = "m", .system_context = "safe", .static_context = "static" } }).build(.{ .world = &world, .session = &snapshot, .current_input = "go" });
    defer built.deinit();
    try std.testing.expectEqualStrings("w", built.request().messages[2].content[0].text);
}
test "budget limits cancellation and overflow are hard failures" {
    var budget = context.TurnBudget.init(.{ .wall_time_ns = 1, .context_tokens = 3, .model_calls = 1 }, 10);
    try budget.charge(.model_calls, 1);
    try std.testing.expectError(error.BudgetExceeded, budget.charge(.model_calls, 1));
    try std.testing.expectError(error.Timeout, budget.check(12, null));
    var overflow = context.TurnBudget.init(.{}, 0);
    try overflow.charge(.trace_bytes, std.math.maxInt(u64));
    try std.testing.expectError(error.BudgetExceeded, overflow.charge(.trace_bytes, 1));
    var source = try nar.CancellationSource.init(std.testing.allocator);
    defer source.deinit();
    var token = source.token();
    defer token.deinit();
    _ = source.cancel(.requested);
    try std.testing.expectError(error.Cancelled, budget.check(10, &token));
}
test "context preserves mandatory safety and tool results while trimming history" {
    var session = context.MemorySession.init(std.testing.allocator);
    defer session.deinit();
    try session.append(.message, .assistant, "old history");
    var snapshot = try session.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    var world = try context.WorldSnapshot.initCopy(std.testing.allocator, nar.WorldRevision.fromInt(1), .{}, &.{});
    defer world.deinit();
    var budget = context.TurnBudget.init(.{ .context_tokens = 12 }, 0);
    var built = try (context.ContextBuilder{ .allocator = std.testing.allocator, .definition = .{ .model_id = "m", .system_context = "safe", .static_context = "", .context_strategy = .{ .max_history_messages = 1 } } }).build(.{ .world = &world, .session = &snapshot, .current_input = "go", .current_tool_result = "ok", .budget = &budget });
    defer built.deinit();
    try std.testing.expect(built.manifest.items[1].trimmed);
    try std.testing.expectEqual(@as(usize, 3), built.request().messages.len);
}
test "tool resolver is stable and does not disclose unauthorized descriptors" {
    const descriptors = [_]tool.ToolDescriptor{ .{ .name = "z", .input_schema = "{}", .required_capabilities = .{ .bits = 1 } }, .{ .name = "a", .input_schema = "{}" }, .{ .name = "debug", .input_schema = "{}", .flags = .{ .debug_only = true } } };
    var resolved = try (context.ToolResolver{ .allowed_names = &.{ "z", "a", "debug" }, .capabilities = .{ .bits = 0 }, .shipping = true }).resolve(std.testing.allocator, &descriptors);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 1), resolved.schemas.len);
    try std.testing.expectEqualStrings("a", resolved.schemas[0].name);
}
test "canonical loop keys sort objects but preserve arrays" {
    const one = try context.loopKey(std.testing.allocator, "x", "{\"b\":2,\"a\":[2,1]}");
    defer std.testing.allocator.free(one);
    const two = try context.loopKey(std.testing.allocator, "x", "{\"a\":[2,1],\"b\":2}");
    defer std.testing.allocator.free(two);
    const three = try context.loopKey(std.testing.allocator, "x", "{\"a\":[1,2],\"b\":2}");
    defer std.testing.allocator.free(three);
    try std.testing.expectEqualStrings(one, two);
    try std.testing.expect(!std.mem.eql(u8, one, three));
}
test "concurrent snapshots remain valid while appending" {
    const State = struct {
        session: *context.MemorySession,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(self: *@This()) void {
            while (!self.done.load(.acquire)) {
                var view = self.session.snapshot(std.heap.page_allocator) catch continue;
                view.deinit();
            }
        }
    };
    var session = context.MemorySession.init(std.testing.allocator);
    defer session.deinit();
    var state = State{ .session = &session };
    const thread = try std.Thread.spawn(.{}, State.run, .{&state});
    for (0..100) |_| try session.append(.message, .user, "x");
    state.done.store(true, .release);
    thread.join();
}
