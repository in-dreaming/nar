const std = @import("std");
const nar = @import("nar");
const foundation = @import("foundation");
const curl = @import("curl_adapter");
const build_options = @import("build_options");

test "OpenAI backend consumes SSE from a real loopback HTTP process" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .environ = .{ .block = .global } });
    defer threaded.deinit();
    const io = threaded.io();
    const port = "19009";
    var child = try std.process.spawn(io, .{
        .argv = &.{ "powershell", "-ExecutionPolicy", "Bypass", "-File", build_options.server_script, port },
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    defer child.kill(io);
    var ready_buffer: [16]u8 = undefined;
    var ready_reader = child.stdout.?.readerStreaming(io, &ready_buffer);
    const ready = ready_reader.interface.takeArray(7) catch |err| {
        var stderr_reader = child.stderr.?.readerStreaming(io, &.{});
        const stderr = stderr_reader.interface.allocRemaining(std.testing.allocator, .limited(4096)) catch return err;
        defer std.testing.allocator.free(stderr);
        std.debug.print("OpenAI fixture stderr: {s}\n", .{stderr});
        return err;
    };
    try std.testing.expectEqualStrings("READY\r\n", ready);

    var http_client = try curl.CurlClient.init(std.testing.allocator, build_options.curl_library);
    defer http_client.deinit();
    var immediate = foundation.executor.ImmediateExecutor{};
    var backend = try nar.openai.Backend.init(std.testing.allocator, .{
        .base_url = "http://127.0.0.1:19009/v1/chat/completions",
        .model_id = "fixture",
        .max_requests = 1,
    }, http_client.client(), immediate.executor());
    defer backend.deinit();
    const handle = try backend.start(.{
        .model_id = "fixture",
        .messages = &.{.{ .role = .user, .content = &.{.{ .text = "status" }} }},
    });
    defer backend.release(handle);
    http_client.pump();

    var saw_text = false;
    var saw_start = false;
    var saw_end = false;
    var saw_finish = false;
    while (try backend.poll(handle)) |event_value| {
        var event = event_value;
        defer event.deinit();
        switch (event) {
            .text_delta => |buffer| {
                saw_text = true;
                try std.testing.expectEqualStrings("fixture", try buffer.bytes());
            },
            .tool_call_start => saw_start = true,
            .tool_call_end => saw_end = true,
            .finish => saw_finish = true,
            else => {},
        }
    }
    try std.testing.expect(saw_text and saw_start and saw_end and saw_finish);
}
