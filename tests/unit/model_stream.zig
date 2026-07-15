const std = @import("std");
const nar = @import("nar");
const foundation = @import("foundation");

const model = nar.model;

fn descriptor(provider: []const u8, name: []const u8, capabilities: model.Capabilities) model.ModelDescriptor {
    return .{ .provider_id = provider, .model_id = name, .capabilities = capabilities };
}

fn request(name: []const u8) model.ModelRequest {
    return .{ .model_id = name };
}

test "mock streams text, tool calls, byte ordered arguments, usage, and finish" {
    const steps = [_]model.MockStep{
        .start,
        .{ .text_delta = "Hello " },
        .{ .text_delta = "world" },
        .{ .tool_call_start = .{ .call_id = "call-1", .name = "weather" } },
        .{ .arguments_delta = "{\"city\":" },
        .{ .arguments_delta = "\"Beijing\"" },
        .{ .tool_call_end = "call-1" },
        .{ .usage = .{ .input_tokens = 3, .output_tokens = 5 } },
        .{ .finish = .tool_calls },
    };
    var backend = try model.MockBackend.init(std.testing.allocator, descriptor("mock", "chat", .{ .streaming = true, .tool_calling = true }), &steps, 1);
    defer backend.deinit();
    const handle = try backend.start(request("chat"));
    defer backend.release(handle);

    for (0..9) |index| {
        var event = (try backend.poll(handle)).?;
        defer event.deinit();
        switch (index) {
            0 => try std.testing.expect(event == .start),
            1, 2 => try std.testing.expect(event == .text_delta),
            3 => try std.testing.expect(event == .tool_call_start),
            4, 5 => try std.testing.expect(event == .arguments_delta),
            6 => try std.testing.expect(event == .tool_call_end),
            7 => try std.testing.expect(event == .usage),
            8 => try std.testing.expect(event == .finish and event.finish == .tool_calls),
            else => try std.testing.expect(false),
        }
    }
    try std.testing.expect((try backend.poll(handle)) == null);
}

test "mock cancellation is terminal before start, while pending, and invalid after terminal" {
    const steps = [_]model.MockStep{ .start, .{ .pending_ticks = 2 }, .{ .finish = .stop }, .{ .finish = .length } };
    var backend = try model.MockBackend.init(std.testing.allocator, descriptor("mock", "chat", .{}), &steps, 1);
    defer backend.deinit();
    const handle = try backend.start(request("chat"));
    try backend.cancel(handle);
    var event = (try backend.poll(handle)).?;
    defer event.deinit();
    try std.testing.expect(event == .cancelled);
    try std.testing.expect((try backend.poll(handle)) == null);
    try std.testing.expectError(error.InvalidState, backend.cancel(handle));
    backend.release(handle);

    const pending_handle = try backend.start(request("chat"));
    var start = (try backend.poll(pending_handle)).?;
    defer start.deinit();
    try std.testing.expect(start == .start);
    try std.testing.expect((try backend.poll(pending_handle)) == null);
    try backend.cancel(pending_handle);
    var pending_cancelled = (try backend.poll(pending_handle)).?;
    defer pending_cancelled.deinit();
    try std.testing.expect(pending_cancelled == .cancelled);
    backend.release(pending_handle);

    const terminal_handle = try backend.start(request("chat"));
    var terminal_start = (try backend.poll(terminal_handle)).?;
    defer terminal_start.deinit();
    try std.testing.expect(terminal_start == .start);
    try std.testing.expect((try backend.poll(terminal_handle)) == null);
    try std.testing.expect((try backend.poll(terminal_handle)) == null);
    var finish = (try backend.poll(terminal_handle)).?;
    defer finish.deinit();
    try std.testing.expect(finish == .finish);
    try std.testing.expect((try backend.poll(terminal_handle)) == null);
    try std.testing.expectError(error.InvalidState, backend.cancel(terminal_handle));
    backend.release(terminal_handle);
}

test "mock rejects malformed stream and allocation exhaustion with one terminal error" {
    const malformed = [_]model.MockStep{.{ .text_delta = &[_]u8{0xff} }};
    var invalid = try model.MockBackend.init(std.testing.allocator, descriptor("mock", "bad", .{}), &malformed, 1);
    defer invalid.deinit();
    const invalid_handle = try invalid.start(request("bad"));
    defer invalid.release(invalid_handle);
    var invalid_event = (try invalid.poll(invalid_handle)).?;
    defer invalid_event.deinit();
    try std.testing.expect(invalid_event == .@"error" and invalid_event.@"error" == .model_protocol_error);
    try std.testing.expect((try invalid.poll(invalid_handle)) == null);

    const text = [_]model.MockStep{.{ .text_delta = "large" }};
    var exhausted = try model.MockBackend.init(std.testing.allocator, descriptor("mock", "budget", .{}), &text, 1);
    defer exhausted.deinit();
    var budget = foundation.memory.AllocationBudget.init(2);
    const handle = try exhausted.start(.{ .model_id = "budget", .allocation_budget = &budget });
    defer exhausted.release(handle);
    var event = (try exhausted.poll(handle)).?;
    defer event.deinit();
    try std.testing.expect(event == .@"error" and event.@"error" == .budget_exceeded);
    try std.testing.expectEqual(@as(usize, 0), budget.bytesUsed());
}

test "registry routing is deterministic and explicit selection never falls back" {
    var low = try model.MockBackend.init(std.testing.allocator, descriptor("alpha", "low", .{ .json_mode = true }), &.{.{ .finish = .stop }}, 1);
    defer low.deinit();
    var high = try model.MockBackend.init(std.testing.allocator, .{ .provider_id = "beta", .model_id = "high", .capabilities = .{ .json_mode = true }, .priority = 10 }, &.{.{ .finish = .stop }}, 1);
    defer high.deinit();
    var registry = model.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(low.backend());
    try registry.register(high.backend());
    const router = model.Router{ .registry = &registry };
    try std.testing.expect((try router.route(.{ .required_capabilities = .{ .json_mode = true } })).ptr == high.backend().ptr);
    try std.testing.expectError(error.ModelUnavailable, router.route(.{ .provider_id = "alpha", .model_id = "missing" }));
    try std.testing.expectError(error.ModelUnavailable, router.route(.{ .allowed_models = &.{"missing"} }));
    try std.testing.expectError(error.InvalidState, registry.register(low.backend()));
}

test "usage overflow and released handles are rejected" {
    const steps = [_]model.MockStep{ .{ .usage = .{ .input_tokens = std.math.maxInt(u32) } }, .{ .usage = .{ .input_tokens = 1 } }, .{ .finish = .stop } };
    var backend = try model.MockBackend.init(std.testing.allocator, descriptor("mock", "usage", .{}), &steps, 1);
    defer backend.deinit();
    const handle = try backend.start(request("usage"));
    var usage = (try backend.poll(handle)).?;
    defer usage.deinit();
    var overflow = (try backend.poll(handle)).?;
    defer overflow.deinit();
    try std.testing.expect(overflow == .@"error" and overflow.@"error" == .model_protocol_error);
    backend.release(handle);
    try std.testing.expectError(error.InvalidState, backend.poll(handle));
}

test "pending scripts and slots progress independently across concurrent consumers" {
    const Worker = struct {
        backend: *model.MockBackend,
        handle: model.ModelRequestHandle,
        count: usize = 0,
        fn run(self: *@This()) void {
            while (true) {
                const maybe_event = self.backend.poll(self.handle) catch @panic("poll failed");
                if (maybe_event) |event| {
                    var owned = event;
                    const terminal = owned.isTerminal();
                    owned.deinit();
                    self.count += 1;
                    if (terminal) return;
                }
            }
        }
    };
    const steps = [_]model.MockStep{ .{ .pending_ticks = 3 }, .start, .{ .finish = .stop } };
    var backend = try model.MockBackend.init(std.testing.allocator, descriptor("mock", "concurrent", .{}), &steps, 2);
    defer backend.deinit();
    const first = try backend.start(request("concurrent"));
    defer backend.release(first);
    const second = try backend.start(request("concurrent"));
    defer backend.release(second);
    var one = Worker{ .backend = &backend, .handle = first };
    var two = Worker{ .backend = &backend, .handle = second };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&one});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&two});
    first_thread.join();
    second_thread.join();
    try std.testing.expectEqual(@as(usize, 2), one.count);
    try std.testing.expectEqual(@as(usize, 2), two.count);
}
