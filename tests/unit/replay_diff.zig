const std = @import("std");
const nar = @import("nar");
const trace = nar.trace;
const model = nar.model;

fn writer(sink: *trace.MemorySink) !trace.Writer {
    return trace.Writer.init(std.testing.allocator, sink.sink(), .{ .session_id = 7, .runtime_id = nar.RuntimeId.init(1).? }, .{});
}

fn recordedModelTrace() ![]u8 {
    var sink = trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var out = try writer(&sink);
    defer out.deinit();
    try out.appendCanonical(.model_request, "{\"messages\":0,\"model_id\":\"m\",\"tools\":0}");
    const start = try trace.modelEventPayload(std.testing.allocator, .{ .start = {} });
    defer std.testing.allocator.free(start);
    try out.appendCanonical(.model_event, start);
    var buffer = try @import("foundation").memory.SharedBuffer.initCopy(std.testing.allocator, "recorded", .general);
    defer buffer.release();
    const text = try trace.modelEventPayload(std.testing.allocator, .{ .text_delta = buffer });
    defer std.testing.allocator.free(text);
    try out.appendCanonical(.model_event, text);
    try out.appendCanonical(.terminal, "{\"reason\":\"completed\"}");
    return sink.snapshot(std.testing.allocator);
}

test "replay backend returns recorded pull events and never calls live services" {
    const bytes = try recordedModelTrace();
    defer std.testing.allocator.free(bytes);
    var session = try trace.ReplaySession.init(bytes, .strict);
    var replay = try trace.ReplayBackend.init(std.testing.allocator, &session, .{ .provider_id = "replay", .model_id = "m", .capabilities = .{ .streaming = true } });
    const backend = replay.backend();
    const handle = try backend.start(.{ .model_id = "m" });
    var first = (try backend.poll(handle)).?;
    defer first.deinit();
    try std.testing.expect(first == .start);
    var second = (try backend.poll(handle)).?;
    defer second.deinit();
    try std.testing.expectEqualStrings("recorded", try second.text_delta.bytes());
    backend.release(handle);
    try std.testing.expectError(error.IncompleteReplay, session.finish());
}

test "replay detects strict divergence, terminal omissions, and corrupt streams" {
    const bytes = try recordedModelTrace();
    defer std.testing.allocator.free(bytes);
    var session = try trace.ReplaySession.init(bytes, .strict);
    try std.testing.expectError(error.Diverged, session.expect(.turn_start, "{}"));
    try std.testing.expectEqual(@as(u64, 1), session.divergence.?.sequence);

    var sink = trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var out = try writer(&sink);
    defer out.deinit();
    try out.appendCanonical(.model_request, "{\"messages\":0,\"model_id\":\"m\",\"tools\":0}");
    const incomplete = try sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(incomplete);
    try std.testing.expectError(error.IncompleteReplay, trace.ReplaySession.init(incomplete, .strict));

    const changed = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(changed);
    changed[trace.header_size + trace.record_prefix_size + 1] = 'x';
    try std.testing.expectError(error.ChecksumMismatch, trace.diff(bytes, changed, .{}));
}

test "trace diff distinguishes strict payloads from semantic model chunks and protects values" {
    var left_sink = trace.MemorySink.init(std.testing.allocator);
    defer left_sink.deinit();
    var left_writer = try writer(&left_sink);
    defer left_writer.deinit();
    try left_writer.appendCanonical(.model_event, "{\"type\":\"text_delta\",\"value\":\"secret-a\"}");
    try left_writer.appendCanonical(.terminal, "{\"reason\":\"completed\"}");
    const left = try left_sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(left);
    var right_sink = trace.MemorySink.init(std.testing.allocator);
    defer right_sink.deinit();
    var right_writer = try writer(&right_sink);
    defer right_writer.deinit();
    try right_writer.appendCanonical(.model_event, "{\"type\":\"text_delta\",\"value\":\"secret-b\"}");
    try right_writer.appendCanonical(.terminal, "{\"reason\":\"completed\"}");
    const right = try right_sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(right);
    try std.testing.expect((try trace.diff(left, right, .{ .mode = .semantic })) == null);
    const mismatch = (try trace.diff(left, right, .{})).?;
    try std.testing.expectEqualStrings("[redacted]", mismatch.expected);
    try std.testing.expectEqualStrings("[redacted]", mismatch.actual);
}

test "replay model enforces capacity cancellation and stale handle ownership" {
    const bytes = try recordedModelTrace();
    defer std.testing.allocator.free(bytes);
    var session = try trace.ReplaySession.init(bytes, .semantic);
    var replay = try trace.ReplayBackend.init(std.testing.allocator, &session, .{ .provider_id = "replay", .model_id = "m" });
    const backend = replay.backend();
    const first = try backend.start(.{ .model_id = "m" });
    try std.testing.expectError(error.BudgetExceeded, backend.start(.{ .model_id = "m" }));
    try backend.cancel(first);
    var cancelled = (try backend.poll(first)).?;
    defer cancelled.deinit();
    try std.testing.expect(cancelled == .cancelled);
    backend.release(first);
    try std.testing.expectError(error.InvalidState, backend.poll(first));
}

test "replay session serializes concurrent expectations" {
    var sink = trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var out = try writer(&sink);
    defer out.deinit();
    try out.appendCanonical(.budget, "{}");
    try out.appendCanonical(.budget, "{}");
    try out.appendCanonical(.terminal, "{\"reason\":\"completed\"}");
    const bytes = try sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var session = try trace.ReplaySession.init(bytes, .strict);
    const Worker = struct {
        session: *trace.ReplaySession,
        fn run(self: *@This()) void {
            self.session.expect(.budget, "{}") catch @panic("replay expectation failed");
        }
    };
    var a = Worker{ .session = &session };
    var b = Worker{ .session = &session };
    const left = try std.Thread.spawn(.{}, Worker.run, .{&a});
    const right = try std.Thread.spawn(.{}, Worker.run, .{&b});
    left.join();
    right.join();
    try session.expect(.terminal, "{\"reason\":\"completed\"}");
    try session.finish();
}
