//! Stable append-only trace encoding for NAR turn decisions.
const std = @import("std");
const domain = @import("../foundation/domain.zig");
const context = @import("../context/runtime.zig");
const model = @import("../model/model.zig");
const foundation = @import("foundation");

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
/// Replay failures never fall back to a live service.  `Diverged` means the
/// caller did not make the same recorded decision at the same sequence.
pub const ReplayError = TraceError || error{ Diverged, IncompleteReplay, ReplayExhausted };

pub const ReplayMode = enum { strict, semantic };
pub const DiffOptions = struct { mode: ReplayMode = .strict, redact: bool = true };
pub const Divergence = struct {
    sequence: u64,
    path: []const u8,
    expected: []const u8,
    actual: []const u8,
};

/// Compares two complete, checksummed traces without executing any live
/// backend. Semantic comparison permits payload changes except terminal
/// outcomes, preserving cancellation/timeout/completion correctness.
pub fn diff(expected_bytes: []const u8, actual_bytes: []const u8, options: DiffOptions) ReplayError!?Divergence {
    var expected = try Reader.init(expected_bytes, .{});
    var actual = try Reader.init(actual_bytes, .{});
    while (true) {
        const left = try expected.next();
        const right = try actual.next();
        if (left == null and right == null) return null;
        if (left == null or right == null) return .{ .sequence = if (left) |record| record.sequence else right.?.sequence, .path = "sequence", .expected = if (options.redact) "[redacted]" else if (left) |record| record.payload else "<end>", .actual = if (options.redact) "[redacted]" else if (right) |record| record.payload else "<end>" };
        const lhs = left.?;
        const rhs = right.?;
        const payload_required = options.mode == .strict or lhs.kind == .terminal or rhs.kind == .terminal;
        if (lhs.kind != rhs.kind or (payload_required and !std.mem.eql(u8, lhs.payload, rhs.payload))) return .{ .sequence = lhs.sequence, .path = if (lhs.kind != rhs.kind) "kind" else "payload", .expected = if (options.redact) "[redacted]" else lhs.payload, .actual = if (options.redact) "[redacted]" else rhs.payload };
    }
}

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

/// A validated, immutable replay stream. The caller retains `bytes` for this
/// object's lifetime. Access is serialized so one replay may be driven by a
/// host pump and model poller without consuming records out of order.
pub const ReplaySession = struct {
    bytes: []const u8,
    reader: Reader,
    mode: ReplayMode,
    terminal_seen: bool = false,
    divergence: ?Divergence = null,
    mutex: Mutex = .{},

    pub fn init(bytes: []const u8, mode: ReplayMode) ReplayError!ReplaySession {
        var checked = try Reader.init(bytes, .{});
        var terminal = false;
        while (try checked.next()) |record| {
            if (terminal) return error.InvalidState;
            if (record.kind == .terminal) terminal = true;
        }
        if (!terminal) return error.IncompleteReplay;
        return .{ .bytes = bytes, .reader = try Reader.init(bytes, .{}), .mode = mode };
    }
    /// Consumes the next decision. Strict mode compares canonical payloads;
    /// semantic mode compares event identity and terminal outcome only.
    pub fn expect(self: *ReplaySession, kind: EventType, actual: []const u8) ReplayError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const record = try self.reader.next() orelse return error.ReplayExhausted;
        if (record.kind != kind or ((self.mode == .strict or kind == .terminal) and !std.mem.eql(u8, record.payload, actual))) {
            self.divergence = .{ .sequence = record.sequence, .path = if (record.kind != kind) "kind" else "payload", .expected = record.payload, .actual = actual };
            return error.Diverged;
        }
        if (kind == .terminal) self.terminal_seen = true;
    }
    pub fn finish(self: *ReplaySession) ReplayError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.divergence != null) return error.Diverged;
        if (!self.terminal_seen or (try self.reader.next()) != null) return error.IncompleteReplay;
    }
    fn nextModel(self: *ReplaySession, expected: EventType) ReplayError!Record {
        self.mutex.lock();
        defer self.mutex.unlock();
        const record = try self.reader.next() orelse return error.ReplayExhausted;
        if (record.kind != expected) {
            self.divergence = .{ .sequence = record.sequence, .path = "kind", .expected = @tagName(record.kind), .actual = @tagName(expected) };
            return error.Diverged;
        }
        return record;
    }
};

/// Canonical payload representation for a replayable model event. The payload
/// contains only the model protocol value, never a live request handle.
pub fn modelEventPayload(allocator: std.mem.Allocator, event: model.ModelEvent) ![]u8 {
    return switch (event) {
        .start => allocator.dupe(u8, "{\"type\":\"start\"}"),
        .finish => |reason| std.fmt.allocPrint(allocator, "{{\"reason\":\"{s}\",\"type\":\"finish\"}}", .{@tagName(reason)}),
        .usage => |usage| std.fmt.allocPrint(allocator, "{{\"input_tokens\":{d},\"output_tokens\":{d},\"type\":\"usage\"}}", .{ usage.input_tokens, usage.output_tokens }),
        .@"error" => |code| std.fmt.allocPrint(allocator, "{{\"code\":\"{s}\",\"type\":\"error\"}}", .{@tagName(code)}),
        .cancelled => allocator.dupe(u8, "{\"type\":\"cancelled\"}"),
        .text_delta => |buffer| stringEvent(allocator, "text_delta", try buffer.bytes()),
        .arguments_delta => |buffer| stringEvent(allocator, "arguments_delta", try buffer.bytes()),
        .tool_call_end => |value| stringEvent(allocator, "tool_call_end", try value.call_id.bytes()),
        .tool_call_start => |value| std.fmt.allocPrint(allocator, "{{\"call_id\":{f},\"name\":{f},\"type\":\"tool_call_start\"}}", .{ std.json.fmt(try value.call_id.bytes(), .{}), std.json.fmt(try value.name.bytes(), .{}) }),
    };
}
/// Stable request summary used to detect context/model routing divergence
/// without persisting prompt text.
pub fn modelRequestPayload(allocator: std.mem.Allocator, request: model.ModelRequest) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"messages\":{d},\"model_id\":{f},\"tools\":{d}}}", .{ request.messages.len, std.json.fmt(request.model_id, .{}), request.tools.len });
}
fn stringEvent(allocator: std.mem.Allocator, kind: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"type\":{f},\"value\":{f}}}", .{ std.json.fmt(kind, .{}), std.json.fmt(value, .{}) });
}

/// A deterministic backend driven exclusively by `ReplaySession`. Its start
/// consumes a recorded model request and its poll consumes a model event.
pub const ReplayBackend = struct {
    allocator: std.mem.Allocator,
    session: *ReplaySession,
    descriptor_value: model.ModelDescriptor,
    active: bool = false,
    generation: u32 = 1,
    cancelled: bool = false,
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, session: *ReplaySession, descriptor_value: model.ModelDescriptor) !ReplayBackend {
        if (descriptor_value.provider_id.len == 0 or descriptor_value.model_id.len == 0) return error.InvalidArgument;
        return .{ .allocator = allocator, .session = session, .descriptor_value = descriptor_value };
    }
    pub fn backend(self: *ReplayBackend) model.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: model.Backend.VTable = .{ .descriptor = descriptor, .start = start, .poll = poll, .cancel = cancel, .release = release };
    fn cast(raw: *anyopaque) *ReplayBackend {
        return @ptrCast(@alignCast(raw));
    }
    fn descriptor(raw: *anyopaque) model.ModelDescriptor {
        return cast(raw).descriptor_value;
    }
    fn start(raw: *anyopaque, request: model.ModelRequest) !model.ModelRequestHandle {
        const self = cast(raw);
        if (!std.mem.eql(u8, request.model_id, self.descriptor_value.model_id)) return error.ModelUnavailable;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active) return error.BudgetExceeded;
        const record = try self.session.nextModel(.model_request);
        const actual = try modelRequestPayload(self.allocator, request);
        defer self.allocator.free(actual);
        if (self.session.mode == .strict and !std.mem.eql(u8, record.payload, actual)) return error.Diverged;
        self.active = true;
        self.cancelled = false;
        return .{ .index = 0, .generation = self.generation };
    }
    fn poll(raw: *anyopaque, handle: model.ModelRequestHandle) !?model.ModelEvent {
        const self = cast(raw);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.active or handle.index != 0 or handle.generation != self.generation) return error.InvalidState;
        if (self.cancelled) {
            self.cancelled = false;
            return .{ .cancelled = {} };
        }
        const record = try self.session.nextModel(.model_event);
        const event = try decodeModelEvent(self.allocator, record.payload);
        return event;
    }
    fn cancel(raw: *anyopaque, handle: model.ModelRequestHandle) !void {
        const self = cast(raw);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.active or handle.generation != self.generation) return error.InvalidState;
        self.cancelled = true;
    }
    fn release(raw: *anyopaque, handle: model.ModelRequestHandle) void {
        const self = cast(raw);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.active or handle.generation != self.generation) return;
        self.active = false;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }
};

fn decodeModelEvent(allocator: std.mem.Allocator, payload: []const u8) !model.ModelEvent {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.ModelProtocolError,
    };
    const name = try jsonString(object, "type");
    if (std.mem.eql(u8, name, "start")) return .{ .start = {} };
    if (std.mem.eql(u8, name, "cancelled")) return .{ .cancelled = {} };
    if (std.mem.eql(u8, name, "finish")) return .{ .finish = std.meta.stringToEnum(model.FinishReason, try jsonString(object, "reason")) orelse return error.ModelProtocolError };
    if (std.mem.eql(u8, name, "error")) return .{ .@"error" = std.meta.stringToEnum(domain.ErrorCode, try jsonString(object, "code")) orelse return error.ModelProtocolError };
    if (std.mem.eql(u8, name, "usage")) return .{ .usage = .{ .input_tokens = @intCast(try jsonUnsigned(object, "input_tokens")), .output_tokens = @intCast(try jsonUnsigned(object, "output_tokens")) } };
    if (std.mem.eql(u8, name, "text_delta")) return .{ .text_delta = try replayBuffer(allocator, object) };
    if (std.mem.eql(u8, name, "arguments_delta")) return .{ .arguments_delta = try replayBuffer(allocator, object) };
    if (std.mem.eql(u8, name, "tool_call_end")) return .{ .tool_call_end = .{ .call_id = try replayBuffer(allocator, object) } };
    if (std.mem.eql(u8, name, "tool_call_start")) return .{ .tool_call_start = .{ .call_id = try foundation.memory.SharedBuffer.initCopy(allocator, try jsonString(object, "call_id"), .general), .name = try foundation.memory.SharedBuffer.initCopy(allocator, try jsonString(object, "name"), .general) } };
    return error.ModelProtocolError;
}
fn replayBuffer(allocator: std.mem.Allocator, object: std.json.ObjectMap) !foundation.memory.SharedBuffer {
    return foundation.memory.SharedBuffer.initCopy(allocator, try jsonString(object, "value"), .general);
}
fn jsonString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (object.get(key) orelse return error.ModelProtocolError) {
        .string => |value| value,
        else => error.ModelProtocolError,
    };
}
fn jsonUnsigned(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = switch (object.get(key) orelse return error.ModelProtocolError) {
        .integer => |integer| integer,
        else => return error.ModelProtocolError,
    };
    if (value < 0) return error.ModelProtocolError;
    return @intCast(value);
}

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
