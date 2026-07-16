//! Stable append-only trace encoding for NAR turn decisions.
const std = @import("std");
const domain = @import("../foundation/domain.zig");
const context = @import("../context/runtime.zig");

pub const magic = "NARTRACE";
pub const major_version: u16 = 1;
pub const minor_version: u16 = 0;
pub const header_size = 32;
pub const record_prefix_size = 24;

/// Fixed-width little-endian stream header. It is encoded explicitly and is not
/// written from this Zig struct's memory representation.
pub const TraceHeader = struct {
    major: u16 = major_version,
    minor: u16 = minor_version,
    flags: u32 = 0,
    session_id: u64,
    runtime_id: domain.RuntimeId,
};

/// Explicit wire values; append new values without changing existing ones.
pub const EventType = enum(u16) {
    turn_start = 1,
    context_manifest = 2,
    model_request = 3,
    model_event = 4,
    tool_validation = 5,
    tool_call = 6,
    tool_result = 7,
    operation_transition = 8,
    budget = 9,
    terminal = 10,
};

/// How sensitive tool arguments are represented in an event payload.
pub const SensitivePolicy = enum { redact, hash, omit };
/// One trace event before canonical payload serialization.
pub const Event = struct { kind: EventType, payload: []const u8 };
/// Per-trace limits. Zero means unlimited.
pub const TraceBudget = struct { max_bytes: u64 = 0, max_records: u64 = 0 };
/// Defensive reader limits for untrusted streams.
pub const Limits = struct { max_record_bytes: usize = 1024 * 1024, max_payload_bytes: usize = 1024 * 1024 };

/// Errors reported while persisting or decoding a trace stream.
pub const TraceError = domain.Error || error{ BadMagic, UnsupportedVersion, InvalidLength, ChecksumMismatch, SequenceMismatch, Truncated, InvalidRecordType };

const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};

/// A caller-supplied append target. `append` must either accept all bytes or
/// return an error; this lets Writer preserve append-only record boundaries.
pub const Sink = struct {
    context: *anyopaque,
    append_fn: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,
    pub fn append(self: Sink, bytes: []const u8) !void {
        try self.append_fn(self.context, bytes);
    }
};

/// Thread-safe owned byte sink suitable for tests, embedding, and handoff to a reader.
pub const MemorySink = struct {
    allocator: std.mem.Allocator,
    bytes: std.array_list.Managed(u8),
    mutex: Mutex = .{},
    pub fn init(allocator: std.mem.Allocator) MemorySink {
        return .{ .allocator = allocator, .bytes = std.array_list.Managed(u8).init(allocator) };
    }
    pub fn deinit(self: *MemorySink) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.bytes.deinit();
    }
    pub fn sink(self: *MemorySink) Sink {
        return .{ .context = self, .append_fn = appendErased };
    }
    pub fn snapshot(self: *MemorySink, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return allocator.dupe(u8, self.bytes.items);
    }
    fn appendErased(raw: *anyopaque, bytes: []const u8) !void {
        const self: *MemorySink = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.bytes.appendSlice(bytes);
    }
};

/// Serializes complete records before one sink append. It owns no sink.
pub const Writer = struct {
    allocator: std.mem.Allocator,
    sink: Sink,
    budget: TraceBudget = .{},
    next_sequence: u64 = 1,
    written_bytes: u64 = 0,
    written_records: u64 = 0,
    terminal_written: bool = false,
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, sink: Sink, header: TraceHeader, budget: TraceBudget) !Writer {
        var writer = Writer{ .allocator = allocator, .sink = sink, .budget = budget };
        var encoded: [header_size]u8 = undefined;
        encodeHeader(encoded[0..], header);
        try writer.commit(encoded[0..]);
        return writer;
    }
    pub fn deinit(_: *Writer) void {}
    /// Canonical JSON is used as the version-one payload representation.
    pub fn append(self: *Writer, event: Event) TraceError!void {
        const canonical = context.canonicalJson(self.allocator, event.payload) catch return error.InvalidArgument;
        defer self.allocator.free(canonical);
        try self.appendCanonical(event.kind, canonical);
    }
    /// Appends a payload already canonicalized by the caller.
    pub fn appendCanonical(self: *Writer, kind: EventType, payload: []const u8) TraceError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.terminal_written) return error.InvalidState;
        const total = std.math.add(usize, record_prefix_size, payload.len) catch return error.BudgetExceeded;
        if (total > std.math.maxInt(u32)) return error.BudgetExceeded;
        if (!within(self.budget.max_records, self.written_records, 1) or !within(self.budget.max_bytes, self.written_bytes, total)) {
            try self.appendBudgetTerminalLocked();
            return error.BudgetExceeded;
        }
        var record = std.array_list.Managed(u8).init(self.allocator);
        defer record.deinit();
        record.resize(total) catch return error.InternalError;
        put16(record.items[0..2], @intFromEnum(kind));
        put16(record.items[2..4], 1);
        put64(record.items[4..12], self.next_sequence);
        put32(record.items[12..16], @intCast(payload.len));
        put64(record.items[16..24], checksum(kind, 1, self.next_sequence, payload));
        @memcpy(record.items[24..], payload);
        self.sink.append(record.items) catch return error.StorageError;
        self.written_bytes += total;
        self.written_records += 1;
        self.next_sequence += 1;
        if (kind == .terminal) self.terminal_written = true;
    }
    /// Encodes tool arguments without retaining secret source bytes.
    pub fn appendToolCall(self: *Writer, tool_name: []const u8, arguments: []const u8, policy: SensitivePolicy) TraceError!void {
        const safe = try sanitize(self.allocator, arguments, policy);
        defer self.allocator.free(safe);
        const payload = std.fmt.allocPrint(self.allocator, "{{\"arguments\":{s},\"policy\":\"{s}\",\"tool\":{f}}}", .{ safe, @tagName(policy), std.json.fmt(tool_name, .{}) }) catch return error.InternalError;
        defer self.allocator.free(payload);
        try self.appendCanonical(.tool_call, payload);
    }
    fn commit(self: *Writer, bytes: []const u8) TraceError!void {
        self.sink.append(bytes) catch return error.StorageError;
        self.written_bytes = bytes.len;
    }
    /// A budget terminal is intentionally exempt from the exhausted budget so
    /// consumers can distinguish a truncated trace from an enforced limit.
    fn appendBudgetTerminalLocked(self: *Writer) TraceError!void {
        if (self.terminal_written) return;
        const payload = "{\"reason\":\"budget_exceeded\"}";
        var record: [record_prefix_size + payload.len]u8 = undefined;
        put16(record[0..2], @intFromEnum(EventType.terminal));
        put16(record[2..4], 1);
        put64(record[4..12], self.next_sequence);
        put32(record[12..16], payload.len);
        put64(record[16..24], checksum(.terminal, 1, self.next_sequence, payload));
        @memcpy(record[24..], payload);
        self.sink.append(&record) catch return error.StorageError;
        self.written_bytes += record.len;
        self.written_records += 1;
        self.next_sequence += 1;
        self.terminal_written = true;
    }
};

/// A validated record borrowing its payload from the reader input.
pub const Record = struct { kind: EventType, schema_version: u16, sequence: u64, payload: []const u8 };
/// Incremental bounded parser. Returned payload slices borrow `bytes`.
pub const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,
    expected_sequence: u64 = 1,
    limits: Limits = .{},
    header: TraceHeader,
    pub fn init(bytes: []const u8, limits: Limits) TraceError!Reader {
        if (bytes.len < header_size) return error.Truncated;
        const header = try decodeHeader(bytes[0..header_size]);
        return .{ .bytes = bytes, .offset = header_size, .limits = limits, .header = header };
    }
    pub fn next(self: *Reader) TraceError!?Record {
        if (self.offset == self.bytes.len) return null;
        if (self.bytes.len - self.offset < record_prefix_size) return error.Truncated;
        const prefix = self.bytes[self.offset .. self.offset + record_prefix_size];
        const kind_raw = get16(prefix[0..2]);
        const schema = get16(prefix[2..4]);
        const sequence = get64(prefix[4..12]);
        const length: usize = @intCast(get32(prefix[12..16]));
        const expected_checksum = get64(prefix[16..24]);
        if (length > self.limits.max_payload_bytes or length > self.limits.max_record_bytes -| record_prefix_size) return error.InvalidLength;
        const end = std.math.add(usize, self.offset + record_prefix_size, length) catch return error.InvalidLength;
        if (end > self.bytes.len) return error.Truncated;
        if (sequence != self.expected_sequence) return error.SequenceMismatch;
        const payload = self.bytes[self.offset + record_prefix_size .. end];
        const kind = eventType(kind_raw) orelse return error.InvalidRecordType;
        if (schema != 1) return error.UnsupportedVersion;
        if (checksum(kind, schema, sequence, payload) != expected_checksum) return error.ChecksumMismatch;
        self.offset = end;
        self.expected_sequence += 1;
        return .{ .kind = kind, .schema_version = schema, .sequence = sequence, .payload = payload };
    }
};

fn sanitize(allocator: std.mem.Allocator, arguments: []const u8, policy: SensitivePolicy) TraceError![]u8 {
    return switch (policy) {
        .redact => allocator.dupe(u8, "\"[redacted]\"") catch error.InternalError,
        .omit => allocator.dupe(u8, "null") catch error.InternalError,
        .hash => blk: {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(arguments);
            break :blk std.fmt.allocPrint(allocator, "\"wyhash64:{x}\"", .{hasher.final()}) catch error.InternalError;
        },
    };
}
fn eventType(value: u16) ?EventType {
    return switch (value) {
        1 => .turn_start,
        2 => .context_manifest,
        3 => .model_request,
        4 => .model_event,
        5 => .tool_validation,
        6 => .tool_call,
        7 => .tool_result,
        8 => .operation_transition,
        9 => .budget,
        10 => .terminal,
        else => null,
    };
}
fn within(limit: u64, used: u64, amount: usize) bool {
    return limit == 0 or (amount <= std.math.maxInt(u64) and used <= limit and @as(u64, @intCast(amount)) <= limit - used);
}
fn checksum(kind: EventType, schema: u16, sequence: u64, payload: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x4e41525452414345);
    var fixed: [12]u8 = undefined;
    put16(fixed[0..2], @intFromEnum(kind));
    put16(fixed[2..4], schema);
    put64(fixed[4..12], sequence);
    h.update(&fixed);
    h.update(payload);
    return h.final();
}
fn encodeHeader(out: []u8, header: TraceHeader) void {
    @memcpy(out[0..8], magic);
    put16(out[8..10], header.major);
    put16(out[10..12], header.minor);
    put32(out[12..16], header.flags);
    put64(out[16..24], header.session_id);
    put64(out[24..32], header.runtime_id.value);
}
fn decodeHeader(raw: []const u8) TraceError!TraceHeader {
    if (!std.mem.eql(u8, raw[0..8], magic)) return error.BadMagic;
    const major = get16(raw[8..10]);
    if (major != major_version) return error.UnsupportedVersion;
    return .{ .major = major, .minor = get16(raw[10..12]), .flags = get32(raw[12..16]), .session_id = get64(raw[16..24]), .runtime_id = .fromInt(get64(raw[24..32])) };
}
fn put16(out: []u8, value: u16) void {
    std.mem.writeInt(u16, out[0..2], value, .little);
}
fn put32(out: []u8, value: u32) void {
    std.mem.writeInt(u32, out[0..4], value, .little);
}
fn put64(out: []u8, value: u64) void {
    std.mem.writeInt(u64, out[0..8], value, .little);
}
fn get16(input: []const u8) u16 {
    return std.mem.readInt(u16, input[0..2], .little);
}
fn get32(input: []const u8) u32 {
    return std.mem.readInt(u32, input[0..4], .little);
}
fn get64(input: []const u8) u64 {
    return std.mem.readInt(u64, input[0..8], .little);
}
