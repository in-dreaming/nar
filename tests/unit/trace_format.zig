const std = @import("std");
const nar = @import("nar");
const trace = nar.trace;
const golden_turn_start = @embedFile("fixtures/trace_v1_turn_start.json");

fn newWriter(sink: *trace.MemorySink, budget: trace.TraceBudget) !trace.Writer {
    return trace.Writer.init(std.testing.allocator, sink.sink(), .{ .session_id = 17, .runtime_id = nar.RuntimeId.init(9).? }, budget);
}

test "trace round trips canonical events and terminal state" {
    var sink = trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var writer = try newWriter(&sink, .{});
    defer writer.deinit();
    try writer.append(.{ .kind = .turn_start, .payload = golden_turn_start });
    try writer.append(.{ .kind = .terminal, .payload = "{\"reason\":\"completed\"}" });
    try std.testing.expectError(error.InvalidState, writer.append(.{ .kind = .model_event, .payload = "{}" }));
    const bytes = try sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var reader = try trace.Reader.init(bytes, .{});
    try std.testing.expectEqual(@as(u64, 17), reader.header.session_id);
    const first = (try reader.next()).?;
    try std.testing.expectEqual(trace.EventType.turn_start, first.kind);
    try std.testing.expectEqualStrings("{\"a\":true,\"z\":1}", first.payload);
    try std.testing.expectEqual(trace.EventType.terminal, (try reader.next()).?.kind);
    try std.testing.expect((try reader.next()) == null);
}

test "trace rejects corrupt, truncated, oversized, unknown, and disordered records" {
    var sink = trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var writer = try newWriter(&sink, .{});
    defer writer.deinit();
    try writer.append(.{ .kind = .budget, .payload = "{}" });
    const source = try sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(source);
    var corrupt = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(corrupt);
    corrupt[trace.header_size + trace.record_prefix_size] ^= 1;
    var checksum_reader = try trace.Reader.init(corrupt, .{});
    try std.testing.expectError(error.ChecksumMismatch, checksum_reader.next());
    var truncated = try trace.Reader.init(source[0 .. source.len - 1], .{});
    try std.testing.expectError(error.Truncated, truncated.next());
    var oversized = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(oversized);
    oversized[trace.header_size + 12] = 0xff;
    oversized[trace.header_size + 13] = 0xff;
    oversized[trace.header_size + 14] = 0xff;
    oversized[trace.header_size + 15] = 0x7f;
    var length_reader = try trace.Reader.init(oversized, .{});
    try std.testing.expectError(error.InvalidLength, length_reader.next());
    var unknown = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(unknown);
    unknown[trace.header_size] = 0xff;
    unknown[trace.header_size + 1] = 0x7f;
    var unknown_reader = try trace.Reader.init(unknown, .{});
    try std.testing.expectError(error.InvalidRecordType, unknown_reader.next());
    var disorder = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(disorder);
    disorder[trace.header_size + 4] = 2;
    var sequence_reader = try trace.Reader.init(disorder, .{});
    try std.testing.expectError(error.SequenceMismatch, sequence_reader.next());
}

test "trace policies prevent raw tool arguments and budgets stop writes" {
    var sink = trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var writer = try newWriter(&sink, .{ .max_records = 1 });
    defer writer.deinit();
    try writer.appendToolCall("credential", "{\"token\":\"top-secret\"}", .hash);
    try std.testing.expectError(error.BudgetExceeded, writer.append(.{ .kind = .budget, .payload = "{}" }));
    const bytes = try sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "top-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "wyhash64:") != null);
    var reader = try trace.Reader.init(bytes, .{});
    _ = (try reader.next()).?;
    const terminal = (try reader.next()).?;
    try std.testing.expectEqual(trace.EventType.terminal, terminal.kind);
    try std.testing.expectEqualStrings("{\"reason\":\"budget_exceeded\"}", terminal.payload);
}

test "trace records a cancellation terminal event" {
    var sink = trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var writer = try newWriter(&sink, .{});
    defer writer.deinit();
    try writer.append(.{ .kind = .terminal, .payload = "{\"reason\":\"cancelled\"}" });
    const bytes = try sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var reader = try trace.Reader.init(bytes, .{});
    const event = (try reader.next()).?;
    try std.testing.expectEqual(trace.EventType.terminal, event.kind);
    try std.testing.expectEqualStrings("{\"reason\":\"cancelled\"}", event.payload);
}

test "trace maps sink failure to storage error without a record commit" {
    const Failing = struct {
        calls: usize = 0,
        fn append(raw: *anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return error.NoSpace;
        }
    };
    var failing = Failing{};
    const sink = trace.Sink{ .context = &failing, .append_fn = Failing.append };
    try std.testing.expectError(error.StorageError, trace.Writer.init(std.testing.allocator, sink, .{ .session_id = 1, .runtime_id = nar.RuntimeId.init(1).? }, .{}));
    try std.testing.expectEqual(@as(usize, 1), failing.calls);
}

test "concurrent trace writers serialize complete records" {
    const count = 20;
    const Worker = struct {
        writer: *trace.Writer,
        fn run(self: *@This()) void {
            for (0..count) |_| self.writer.appendCanonical(.model_event, "{}") catch @panic("trace append failed");
        }
    };
    var sink = trace.MemorySink.init(std.testing.allocator);
    defer sink.deinit();
    var writer = try newWriter(&sink, .{});
    defer writer.deinit();
    var left = Worker{ .writer = &writer };
    var right = Worker{ .writer = &writer };
    const a = try std.Thread.spawn(.{}, Worker.run, .{&left});
    const b = try std.Thread.spawn(.{}, Worker.run, .{&right});
    a.join();
    b.join();
    const bytes = try sink.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var reader = try trace.Reader.init(bytes, .{});
    var actual: usize = 0;
    while (try reader.next()) |_| actual += 1;
    try std.testing.expectEqual(@as(usize, count * 2), actual);
}
