const std = @import("std");
const c = @cImport({
    @cInclude("nar.h");
});
const abi = @import("nar").cabi;

fn config() c.nar_runtime_config {
    return .{ .struct_size = @sizeOf(c.nar_runtime_config), .api_version = c.NAR_API_VERSION, .profile = c.NAR_PROFILE_MINIMAL, .reserved0 = 0, .max_agents = 1, .mailbox_capacity = 4, .operation_capacity = 1, .compute_workers = 0, .blocking_workers = 0, .queue_capacity = 4, .observability_capacity = 4 };
}
fn callback(_: *const c.nar_invocation, sink: *c.nar_result_sink, _: ?*anyopaque) callconv(.c) void {
    const json = "{}";
    _ = sink.complete.?(sink, .{ .data = json.ptr, .size = json.len });
}
fn expectCode(expected: c.nar_error_code, actual: u32) !void {
    try std.testing.expectEqual(@as(u32, @intCast(expected)), actual);
}

test "C ABI validates versioned input, ownership, and stale handles" {
    try std.testing.expectEqual(c.NAR_API_VERSION, abi.nar_api_version());
    var bad = config();
    bad.api_version += 1;
    var runtime: c.nar_runtime_handle = 0;
    try expectCode(c.NAR_INVALID_ARGUMENT, abi.nar_runtime_create(@ptrCast(&bad), &runtime));
    var good = config();
    try expectCode(c.NAR_OK, abi.nar_runtime_create(@ptrCast(&good), &runtime));
    defer abi.nar_runtime_destroy(runtime);
    var jobs: usize = 0;
    try expectCode(c.NAR_OK, abi.nar_runtime_pump_main_thread(runtime, 8, 0, &jobs));
    try expectCode(c.NAR_OK, abi.nar_runtime_shutdown(runtime, 0));
    var descriptor = c.nar_tool_descriptor{ .struct_size = @sizeOf(c.nar_tool_descriptor), .api_version = c.NAR_API_VERSION, .name = .{ .data = "echo".ptr, .size = 4 }, .description = .{ .data = null, .size = 0 }, .version = .{ .data = "1".ptr, .size = 1 }, .input_schema = .{ .data = "{}".ptr, .size = 2 }, .output_schema = .{ .data = null, .size = 0 }, .required_capabilities = 0, .resources = null, .resource_count = 0, .thread_affinity = c.NAR_THREAD_ANY, .flags = 0, .profile_mask = 0, .revision_policy = 0 };
    var tool: c.nar_tool_handle = 0;
    try expectCode(c.NAR_INVALID_STATE, abi.nar_tool_register(runtime, @ptrCast(&descriptor), @ptrCast(&callback), null, &tool));
}

test "C ABI tool handles are generational and registration copies descriptors" {
    var cfg = config();
    var runtime: c.nar_runtime_handle = 0;
    try expectCode(c.NAR_OK, abi.nar_runtime_create(@ptrCast(&cfg), &runtime));
    defer abi.nar_runtime_destroy(runtime);
    var descriptor = c.nar_tool_descriptor{ .struct_size = @sizeOf(c.nar_tool_descriptor), .api_version = c.NAR_API_VERSION, .name = .{ .data = "echo".ptr, .size = 4 }, .description = .{ .data = null, .size = 0 }, .version = .{ .data = "1".ptr, .size = 1 }, .input_schema = .{ .data = "{}".ptr, .size = 2 }, .output_schema = .{ .data = null, .size = 0 }, .required_capabilities = 0, .resources = null, .resource_count = 0, .thread_affinity = c.NAR_THREAD_ANY, .flags = 0, .profile_mask = 0, .revision_policy = 0 };
    var tool: c.nar_tool_handle = 0;
    try expectCode(c.NAR_OK, abi.nar_tool_register(runtime, @ptrCast(&descriptor), @ptrCast(&callback), null, &tool));
    try expectCode(c.NAR_OK, abi.nar_tool_unregister(runtime, tool));
    try expectCode(c.NAR_INVALID_STATE, abi.nar_tool_unregister(runtime, tool));
}
