const std = @import("std");
const nar = @import("nar");
const foundation = @import("foundation");
const tool = nar.tool;

const schema = "{\"type\":\"object\",\"required\":[\"n\"],\"properties\":{\"n\":{\"type\":\"integer\",\"minimum\":1}},\"additionalProperties\":false}";

fn complete(_: ?*anyopaque, invocation: tool.InvocationContext) !tool.CallbackResult {
    return .{ .completed = try foundation.memory.SharedBuffer.initCopyWithBudget(invocation.allocator, "{\"ok\":true}", .general, invocation.allocation_budget, .{}) };
}
fn pending(_: ?*anyopaque, _: tool.InvocationContext) !tool.CallbackResult {
    return .{ .pending = nar.OperationId.fromInt(7) };
}
fn typedFailure(_: ?*anyopaque, _: tool.InvocationContext) !tool.CallbackResult {
    return .{ .failure = .operation_failed };
}
fn rejectStale(_: ?*anyopaque, _: tool.ToolDescriptor, _: *const std.json.Value, target: ?nar.ObjectRef, revision: nar.WorldRevision) nar.Error!void {
    if (target == null or !target.?.isValid()) return error.StaleObject;
    if (!revision.isValid()) return error.StaleWorldRevision;
}
fn descriptor() tool.ToolDescriptor {
    return .{ .name = "test.tool", .version = "1.0", .description = "test", .input_schema = schema, .output_schema = "{\"type\":\"object\",\"required\":[\"ok\"]}" };
}

test "tool dispatch validates input and output, transfers result ownership" {
    var registry = tool.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const handle = try registry.register(descriptor(), complete, null);
    var dispatcher = tool.Dispatcher{ .registry = &registry };
    var result = dispatcher.dispatch(.{ .tool = handle, .arguments_json = "{\"n\":1}" });
    defer result.deinit();
    try std.testing.expect(result == .completed);
    try std.testing.expectEqualStrings("{\"ok\":true}", try result.completed.bytes());
    try std.testing.expectEqual(tool.DispatchResult{ .failure = .tool_schema_error }, dispatcher.dispatch(.{ .tool = handle, .arguments_json = "{\"n\":0}" }));
    try std.testing.expectEqual(tool.DispatchResult{ .failure = .tool_schema_error }, dispatcher.dispatch(.{ .tool = handle, .arguments_json = "{bad" }));
}

test "tool policy, cancellation, host revisions, and typed outcomes are enforced" {
    var registry = tool.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var debug = descriptor();
    debug.flags.debug_only = true;
    debug.required_capabilities = .{ .bits = 2 };
    const handle = try registry.register(debug, pending, null);
    var dispatcher = tool.Dispatcher{ .registry = &registry, .policy = .{ .shipping = true } };
    try std.testing.expectEqual(tool.DispatchResult{ .failure = .tool_permission_denied }, dispatcher.dispatch(.{ .tool = handle, .arguments_json = "{\"n\":1}" }));
    dispatcher.policy.shipping = false;
    dispatcher.policy.runtime_override = .{ .bits = 0 };
    try std.testing.expectEqual(tool.DispatchResult{ .failure = .tool_permission_denied }, dispatcher.dispatch(.{ .tool = handle, .arguments_json = "{\"n\":1}" }));
    dispatcher.policy.runtime_override = .{};
    var source = try nar.CancellationSource.init(std.testing.allocator);
    defer source.deinit();
    var token = source.token();
    defer token.deinit();
    _ = source.cancel(.requested);
    try std.testing.expectEqual(tool.DispatchResult{ .failure = .cancelled }, dispatcher.dispatch(.{ .tool = handle, .arguments_json = "{\"n\":1}", .cancellation = &token }));
    try std.testing.expectEqual(tool.DispatchResult{ .pending = nar.OperationId.fromInt(7) }, dispatcher.dispatch(.{ .tool = handle, .arguments_json = "{\"n\":1}" }));
    const failure_handle = try registry.register(.{ .name = "f", .input_schema = schema }, typedFailure, null);
    try std.testing.expectEqual(tool.DispatchResult{ .failure = .operation_failed }, dispatcher.dispatch(.{ .tool = failure_handle, .arguments_json = "{\"n\":1}" }));
}

test "tool registration rejects bad metadata and stale handles cannot dispatch re-registrations" {
    var registry = tool.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectError(error.InvalidArgument, registry.register(.{ .name = "bad name", .input_schema = schema }, complete, null));
    const first = try registry.register(descriptor(), complete, null);
    try registry.unregister(first);
    const second = try registry.register(descriptor(), complete, null);
    try std.testing.expect(first.id.value == second.id.value and first.generation != second.generation);
    var dispatcher = tool.Dispatcher{ .registry = &registry };
    try std.testing.expectEqual(tool.DispatchResult{ .failure = .tool_not_found }, dispatcher.dispatch(.{ .tool = first, .arguments_json = "{\"n\":1}" }));
}

test "host validation and declared thread affinity precede callbacks" {
    var registry = tool.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var source = descriptor();
    source.thread_affinity = .main;
    source.revision_policy = .exact;
    const handle = try registry.register(source, complete, null);
    var dispatcher = tool.Dispatcher{ .registry = &registry, .host_validator = .{ .validate = rejectStale } };
    try std.testing.expectEqual(tool.DispatchResult{ .failure = .invalid_state }, dispatcher.dispatch(.{ .tool = handle, .arguments_json = "{\"n\":1}", .caller_affinity = .worker }));
    try std.testing.expectEqual(tool.DispatchResult{ .failure = .stale_world_revision }, dispatcher.dispatch(.{ .tool = handle, .arguments_json = "{\"n\":1}", .caller_affinity = .main }));
    try std.testing.expectEqual(tool.DispatchResult{ .failure = .stale_object }, dispatcher.dispatch(.{ .tool = handle, .arguments_json = "{\"n\":1}", .caller_affinity = .main, .world_revision = nar.WorldRevision.fromInt(1) }));
}

test "tool allocation budgets reject callback result without leaking ownership" {
    var registry = tool.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const handle = try registry.register(descriptor(), complete, null);
    var budget = foundation.memory.AllocationBudget.init(2);
    var dispatcher = tool.Dispatcher{ .registry = &registry };
    try std.testing.expectEqual(tool.DispatchResult{ .failure = .budget_exceeded }, dispatcher.dispatch(.{ .tool = handle, .arguments_json = "{\"n\":1}", .allocation_budget = &budget }));
    try std.testing.expectEqual(@as(usize, 0), budget.bytesUsed());
}

test "concurrent dispatch retains entries through unregister" {
    const State = struct {
        registry: *tool.Registry,
        handle: tool.ToolHandle,
        succeeded: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        fn invoke(self: *@This()) void {
            var dispatcher = tool.Dispatcher{ .registry = self.registry };
            for (0..200) |_| {
                var result = dispatcher.dispatch(.{ .tool = self.handle, .arguments_json = "{\"n\":1}" });
                if (result == .completed) _ = self.succeeded.fetchAdd(1, .monotonic);
                result.deinit();
            }
        }
    };
    var registry = tool.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const handle = try registry.register(descriptor(), complete, null);
    var state = State{ .registry = &registry, .handle = handle };
    const thread = try std.Thread.spawn(.{}, State.invoke, .{&state});
    try registry.unregister(handle);
    _ = try registry.register(descriptor(), complete, null);
    thread.join();
    try std.testing.expect(state.succeeded.load(.monotonic) <= 200);
}
