const std = @import("std");
const c = @cImport({
    @cInclude("nar.h");
});
const nar = @import("nar");
const abi = nar.cabi;

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

fn appendModelEvent(writer: *nar.trace.Writer, event_value: nar.model.ModelEvent) !void {
    var event = event_value;
    defer event.deinit();
    const payload = try nar.trace.modelEventPayload(std.testing.allocator, event);
    defer std.testing.allocator.free(payload);
    try writer.appendCanonical(.model_event, payload);
}

fn toolReplayTrace() ![]u8 {
    var sink = nar.trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var writer = try nar.trace.Writer.init(std.testing.allocator, sink.sink(), .{ .session_id = 12, .runtime_id = nar.RuntimeId.init(12).? }, .{});
    defer writer.deinit();
    try writer.appendCanonical(.model_request, "{}");
    try appendModelEvent(&writer, .{ .start = {} });
    try appendModelEvent(&writer, .{ .tool_call_start = .{
        .call_id = try @import("foundation").memory.SharedBuffer.initCopy(std.testing.allocator, "confirm-1", .general),
        .name = try @import("foundation").memory.SharedBuffer.initCopy(std.testing.allocator, "confirm_main", .general),
    } });
    try appendModelEvent(&writer, .{ .arguments_delta = try @import("foundation").memory.SharedBuffer.initCopy(std.testing.allocator, "{}", .general) });
    try appendModelEvent(&writer, .{ .tool_call_end = .{ .call_id = try @import("foundation").memory.SharedBuffer.initCopy(std.testing.allocator, "confirm-1", .general) } });
    try writer.appendCanonical(.tool_result, "{}");
    try writer.appendCanonical(.model_request, "{}");
    try appendModelEvent(&writer, .{ .start = {} });
    try appendModelEvent(&writer, .{ .text_delta = try @import("foundation").memory.SharedBuffer.initCopy(std.testing.allocator, "confirmed", .general) });
    try appendModelEvent(&writer, .{ .finish = .stop });
    try writer.appendCanonical(.terminal, "{\"reason\":\"completed\"}");
    return sink.snapshot(std.testing.allocator);
}

fn asyncMainCallback(invocation: *const c.nar_invocation, sink: *c.nar_result_sink, userdata: ?*anyopaque) callconv(.c) void {
    const calls: *usize = @ptrCast(@alignCast(userdata.?));
    if (invocation.operation == 0) return;
    calls.* += 1;
    const result = "{\"confirmed\":true}";
    _ = sink.complete.?(sink, .{ .data = result.ptr, .size = result.len });
}

test "C replay runtime drives an async main-thread tool only through pump" {
    const bytes = try toolReplayTrace();
    defer std.testing.allocator.free(bytes);
    var cfg = config();
    cfg.operation_capacity = 1;
    var runtime: c.nar_runtime_handle = 0;
    try expectCode(c.NAR_OK, abi.nar_replay_runtime_create(@ptrCast(&cfg), .{ .data = bytes.ptr, .size = bytes.len }, &runtime));
    defer abi.nar_runtime_destroy(runtime);

    var calls: usize = 0;
    var descriptor = c.nar_tool_descriptor{ .struct_size = @sizeOf(c.nar_tool_descriptor), .api_version = c.NAR_API_VERSION, .name = .{ .data = "confirm_main".ptr, .size = 12 }, .description = .{ .data = null, .size = 0 }, .version = .{ .data = "1".ptr, .size = 1 }, .input_schema = .{ .data = "{\"type\":\"object\"}".ptr, .size = 17 }, .output_schema = .{ .data = null, .size = 0 }, .required_capabilities = 0, .resources = null, .resource_count = 0, .thread_affinity = c.NAR_THREAD_MAIN, .flags = 0, .profile_mask = 0, .revision_policy = 0 };
    var tool_handle: c.nar_tool_handle = 0;
    try expectCode(c.NAR_OK, abi.nar_tool_register(runtime, @ptrCast(&descriptor), @ptrCast(&asyncMainCallback), &calls, &tool_handle));

    const allowed = [_]c.nar_slice{.{ .data = "confirm_main".ptr, .size = 12 }};
    var agent_config = c.nar_agent_config{ .struct_size = @sizeOf(c.nar_agent_config), .api_version = c.NAR_API_VERSION, .provider_id = .{ .data = "replay".ptr, .size = 6 }, .model_id = .{ .data = "replay".ptr, .size = 6 }, .system_context = .{ .data = "Replay.".ptr, .size = 7 }, .static_context = .{ .data = null, .size = 0 }, .allowed_tools = &allowed, .allowed_tool_count = allowed.len, .budget = .{ .wall_time_ns = 0, .model_calls = 2, .tool_calls = 1, .context_tokens = 0, .output_tokens = 32, .cost_micros = 0, .trace_bytes = 0 }, .max_repeated_tool_calls = 1, .tool_error_policy = 0, .reserved = 0 };
    var agent: c.nar_agent_handle = 0;
    try expectCode(c.NAR_OK, abi.nar_agent_create(runtime, @ptrCast(&agent_config), &agent));
    var request = c.nar_submit_request{ .struct_size = @sizeOf(c.nar_submit_request), .api_version = c.NAR_API_VERSION, .input = .{ .data = "confirm".ptr, .size = 7 }, .world_revision = 1, .captured_at_ns = 1, .sections = null, .section_count = 0 };
    var turn: c.nar_turn_handle = 0;
    try expectCode(c.NAR_OK, abi.nar_agent_submit(runtime, agent, @ptrCast(&request), &turn));
    var tick: u32 = 0;
    for (0..12) |_| {
        try expectCode(c.NAR_OK, abi.nar_agent_tick(runtime, agent, &tick));
        if (tick == c.NAR_TICK_WOULD_BLOCK) break;
    }
    try std.testing.expectEqual(@as(usize, 0), calls);
    var jobs: usize = 0;
    try expectCode(c.NAR_OK, abi.nar_runtime_pump_main_thread(runtime, 1, std.time.ns_per_s, &jobs));
    try std.testing.expectEqual(@as(usize, 1), jobs);
    try std.testing.expectEqual(@as(usize, 1), calls);
    for (0..16) |_| {
        try expectCode(c.NAR_OK, abi.nar_agent_tick(runtime, agent, &tick));
        if (tick == c.NAR_TICK_TERMINAL) break;
    }
    try std.testing.expectEqual(@as(u32, c.NAR_TICK_TERMINAL), tick);
    var event = c.nar_event{ .struct_size = @sizeOf(c.nar_event), .api_version = c.NAR_API_VERSION, .kind = c.NAR_EVENT_NONE, .reserved = 0, .sequence = 0, .turn = 0, .timestamp_ns = 0, .operation = 0, .@"error" = c.NAR_OK, .cancel_reason = c.NAR_CANCEL_REQUESTED, .buffer = .{ .data = null, .size = 0, .release = null, .userdata = null } };
    var saw_final = false;
    while (true) {
        try expectCode(c.NAR_OK, abi.nar_agent_poll(runtime, agent, @ptrCast(&event)));
        if (event.kind == c.NAR_EVENT_NONE) break;
        if (event.kind == c.NAR_EVENT_FINAL_RESPONSE) saw_final = true;
        abi.nar_buffer_release(@ptrCast(&event.buffer));
    }
    try std.testing.expect(saw_final);
    try expectCode(c.NAR_OK, abi.nar_agent_destroy(runtime, agent));
    try expectCode(c.NAR_OK, abi.nar_tool_unregister(runtime, tool_handle));
}

test "C ABI rejects corrupt replay and oversized runtime configuration" {
    var cfg = config();
    var runtime: c.nar_runtime_handle = 0;
    const corrupt = "not-a-trace";
    try expectCode(c.NAR_INVALID_ARGUMENT, abi.nar_replay_runtime_create(@ptrCast(&cfg), .{ .data = corrupt.ptr, .size = corrupt.len }, &runtime));
    cfg.queue_capacity = std.math.maxInt(u64);
    try expectCode(c.NAR_INVALID_ARGUMENT, abi.nar_runtime_create(@ptrCast(&cfg), &runtime));
}

test "C runtime reports an expired finite staged shutdown deadline" {
    if (!nar.hasRuntimeSupport()) return;
    var cfg = config();
    cfg.profile = c.NAR_PROFILE_RUNTIME;
    cfg.compute_workers = 1;
    cfg.blocking_workers = 1;
    var runtime: c.nar_runtime_handle = 0;
    try expectCode(c.NAR_OK, abi.nar_runtime_create(@ptrCast(&cfg), &runtime));
    defer abi.nar_runtime_destroy(runtime);
    try expectCode(c.NAR_TIMEOUT, abi.nar_runtime_shutdown(runtime, 1));
}
