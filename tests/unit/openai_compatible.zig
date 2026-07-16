const std = @import("std");
const nar = @import("nar");
const foundation = @import("foundation");

const openai = nar.openai;

fn backend(mock: *foundation.http.MockClient, executor: foundation.executor.Executor, max_requests: usize, response_limit: usize) !openai.Backend {
    return openai.Backend.init(std.testing.allocator, .{ .base_url = "http://127.0.0.1:9988/v1/chat/completions", .model_id = "fixture", .max_requests = max_requests, .response_limit = response_limit, .queue_capacity = 16 }, mock.client(), executor);
}
fn request() nar.model.ModelRequest {
    return .{ .model_id = "fixture", .messages = &.{.{ .role = .user, .content = &.{.{ .text = "hello" }} }} };
}

test "OpenAI backend enforces exact loopback and HTTPS origin boundaries" {
    var mock = foundation.http.MockClient.init(std.testing.allocator);
    defer mock.deinit();
    var immediate = foundation.executor.ImmediateExecutor{};
    try std.testing.expectError(error.InvalidArgument, openai.Backend.init(std.testing.allocator, .{
        .base_url = "http://localhost.evil/v1/chat/completions",
        .model_id = "fixture",
    }, mock.client(), immediate.executor()));
    try std.testing.expectError(error.InvalidArgument, openai.Backend.init(std.testing.allocator, .{
        .base_url = "https://api.example.com.evil/v1/chat/completions",
        .model_id = "fixture",
        .allowed_origins = &.{"https://api.example.com"},
    }, mock.client(), immediate.executor()));
    var allowed = try openai.Backend.init(std.testing.allocator, .{
        .base_url = "https://api.example.com/v1/chat/completions",
        .model_id = "fixture",
        .allowed_origins = &.{"https://api.example.com"},
    }, mock.client(), immediate.executor());
    allowed.deinit();
}

test "OpenAI backend maps SSE text, split tool arguments, tool end, and one terminal" {
    var mock = foundation.http.MockClient.init(std.testing.allocator);
    defer mock.deinit();
    var immediate = foundation.executor.ImmediateExecutor{};
    var value = try backend(&mock, immediate.executor(), 1, 4096);
    defer value.deinit();
    try mock.append(.{ .response = .{ .body = ": keepalive\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hi\\nthere\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"weather\",\"arguments\":\"{\\\"city\\\":\"}}]},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"Paris\\\"}\"}}]},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n" } });
    const handle = try value.start(request());
    defer value.release(handle);
    mock.pump();
    var count: usize = 0;
    var saw_text = false;
    var saw_tool = false;
    var saw_tool_end = false;
    var saw_finish = false;
    var terminal_count: usize = 0;
    var arguments: std.ArrayListUnmanaged(u8) = .empty;
    defer arguments.deinit(std.testing.allocator);
    while (try value.poll(handle)) |event_value| {
        var event = event_value;
        defer event.deinit();
        count += 1;
        switch (event) {
            .text_delta => |buffer| {
                saw_text = true;
                try std.testing.expectEqualStrings("Hi\nthere", try buffer.bytes());
            },
            .tool_call_start => saw_tool = true,
            .arguments_delta => |buffer| try arguments.appendSlice(std.testing.allocator, try buffer.bytes()),
            .tool_call_end => saw_tool_end = true,
            .finish => {
                saw_finish = true;
                terminal_count += 1;
            },
            .@"error", .cancelled => terminal_count += 1,
            else => {},
        }
    }
    try std.testing.expect(count >= 7);
    try std.testing.expect(saw_text and saw_tool and saw_tool_end and saw_finish);
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", arguments.items);
    try std.testing.expectEqual(@as(usize, 1), terminal_count);
}

test "OpenAI backend maps transport failures, cancellation, and response limits" {
    var mock = foundation.http.MockClient.init(std.testing.allocator);
    defer mock.deinit();
    var immediate = foundation.executor.ImmediateExecutor{};
    var value = try backend(&mock, immediate.executor(), 1, 32);
    defer value.deinit();
    try mock.append(.{ .failure = .{ .category = .timeout, .message = "secret-token-not-exposed" } });
    const failed = try value.start(request());
    mock.pump();
    var failure = (try value.poll(failed)).?;
    defer failure.deinit();
    try std.testing.expect(failure == .@"error" and failure.@"error" == .timeout);
    value.release(failed);
    const cancelled = try value.start(request());
    try value.cancel(cancelled);
    mock.pump();
    var cancelled_event = (try value.poll(cancelled)).?;
    defer cancelled_event.deinit();
    try std.testing.expect(cancelled_event == .cancelled);
    value.release(cancelled);
    try mock.append(.{ .response = .{ .body = "this body deliberately exceeds the configured response limit" } });
    const exhausted = try value.start(request());
    mock.pump();
    var exhausted_event = (try value.poll(exhausted)).?;
    defer exhausted_event.deinit();
    try std.testing.expect(exhausted_event == .@"error" and exhausted_event.@"error" == .budget_exceeded);
    value.release(exhausted);
}

test "OpenAI backend preserves one terminal when event backpressure is exceeded" {
    var mock = foundation.http.MockClient.init(std.testing.allocator);
    defer mock.deinit();
    var immediate = foundation.executor.ImmediateExecutor{};
    var value = try openai.Backend.init(std.testing.allocator, .{
        .base_url = "http://127.0.0.1:9988/v1/chat/completions",
        .model_id = "fixture",
        .queue_capacity = 1,
        .max_requests = 1,
    }, mock.client(), immediate.executor());
    defer value.deinit();
    try mock.append(.{ .response = .{ .body = "data: {\"choices\":[{\"delta\":{\"content\":\"one\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n" } });
    const handle = try value.start(request());
    defer value.release(handle);
    mock.pump();
    var event = (try value.poll(handle)).?;
    defer event.deinit();
    try std.testing.expect(event == .@"error" and event.@"error" == .budget_exceeded);
    try std.testing.expect((try value.poll(handle)) == null);
}

test "OpenAI backend release is stale-safe and independent consumers can poll concurrently" {
    const Worker = struct {
        backend_value: *openai.Backend,
        handle: nar.model.ModelRequestHandle,
        events: usize = 0,
        fn run(self: *@This()) void {
            while (self.backend_value.poll(self.handle) catch return) |event_value| {
                var event = event_value;
                self.events += 1;
                const done = event.isTerminal();
                event.deinit();
                if (done) return;
            }
        }
    };
    var mock = foundation.http.MockClient.init(std.testing.allocator);
    defer mock.deinit();
    var immediate = foundation.executor.ImmediateExecutor{};
    var value = try backend(&mock, immediate.executor(), 2, 4096);
    defer value.deinit();
    try mock.append(.{ .response = .{ .body = "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: [DONE]\n\n" } });
    try mock.append(.{ .response = .{ .body = "data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}\n\ndata: [DONE]\n\n" } });
    const stale = try value.start(request());
    value.release(stale);
    try std.testing.expectError(error.InvalidState, value.poll(stale));
    const one = try value.start(request());
    const two = try value.start(request());
    defer value.release(one);
    defer value.release(two);
    mock.pump();
    mock.pump();
    mock.pump();
    var first = Worker{ .backend_value = &value, .handle = one };
    var second = Worker{ .backend_value = &value, .handle = two };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.events >= 2 and second.events >= 2);
}
