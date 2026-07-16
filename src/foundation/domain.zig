//! Stable domain primitives shared by NAR core, adapters, and public APIs.
const std = @import("std");
const foundation = @import("foundation");

const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};

/// Stable runtime error values. Numeric assignments are part of NAR's ABI;
/// future values must be appended without changing existing assignments.
pub const ErrorCode = enum(u32) {
    ok = 0,
    invalid_argument = 1,
    invalid_state = 2,
    cancelled = 3,
    timeout = 4,
    budget_exceeded = 5,
    model_unavailable = 6,
    model_protocol_error = 7,
    tool_not_found = 8,
    tool_schema_error = 9,
    tool_permission_denied = 10,
    stale_object = 11,
    stale_world_revision = 12,
    operation_failed = 13,
    storage_error = 14,
    network_error = 15,
    internal_error = 16,
};

pub const Error = error{
    InvalidArgument,
    InvalidState,
    Cancelled,
    Timeout,
    BudgetExceeded,
    ModelUnavailable,
    ModelProtocolError,
    ToolNotFound,
    ToolSchemaError,
    ToolPermissionDenied,
    StaleObject,
    StaleWorldRevision,
    OperationFailed,
    StorageError,
    NetworkError,
    InternalError,
};

pub const ErrorMetadata = struct {
    retryable: bool,
    model_visible: bool,
    security_sensitive: bool,
};

pub fn errorMetadata(code: ErrorCode) ErrorMetadata {
    return switch (code) {
        .ok => .{ .retryable = false, .model_visible = false, .security_sensitive = false },
        .invalid_argument, .invalid_state, .tool_schema_error, .stale_object, .stale_world_revision => .{ .retryable = false, .model_visible = true, .security_sensitive = false },
        .cancelled => .{ .retryable = true, .model_visible = true, .security_sensitive = false },
        .timeout, .model_unavailable, .operation_failed, .storage_error, .network_error => .{ .retryable = true, .model_visible = false, .security_sensitive = false },
        .budget_exceeded, .model_protocol_error, .tool_not_found => .{ .retryable = false, .model_visible = true, .security_sensitive = false },
        .tool_permission_denied => .{ .retryable = false, .model_visible = true, .security_sensitive = true },
        .internal_error => .{ .retryable = false, .model_visible = false, .security_sensitive = false },
    };
}

pub fn errorCodeFromZig(err: anyerror) ErrorCode {
    return switch (err) {
        error.InvalidArgument => .invalid_argument,
        error.InvalidState => .invalid_state,
        error.Cancelled => .cancelled,
        error.Timeout => .timeout,
        error.BudgetExceeded => .budget_exceeded,
        error.ModelUnavailable => .model_unavailable,
        error.ModelProtocolError => .model_protocol_error,
        error.ToolNotFound => .tool_not_found,
        error.ToolSchemaError => .tool_schema_error,
        error.ToolPermissionDenied => .tool_permission_denied,
        error.StaleObject => .stale_object,
        error.StaleWorldRevision => .stale_world_revision,
        error.OperationFailed => .operation_failed,
        error.StorageError => .storage_error,
        error.NetworkError => .network_error,
        else => .internal_error,
    };
}

pub fn zigErrorFromCode(code: ErrorCode) ?Error {
    return switch (code) {
        .ok => null,
        .invalid_argument => error.InvalidArgument,
        .invalid_state => error.InvalidState,
        .cancelled => error.Cancelled,
        .timeout => error.Timeout,
        .budget_exceeded => error.BudgetExceeded,
        .model_unavailable => error.ModelUnavailable,
        .model_protocol_error => error.ModelProtocolError,
        .tool_not_found => error.ToolNotFound,
        .tool_schema_error => error.ToolSchemaError,
        .tool_permission_denied => error.ToolPermissionDenied,
        .stale_object => error.StaleObject,
        .stale_world_revision => error.StaleWorldRevision,
        .operation_failed => error.OperationFailed,
        .storage_error => error.StorageError,
        .network_error => error.NetworkError,
        .internal_error => error.InternalError,
    };
}

/// A non-zero, fixed-width identifier. The `Tag` parameter prevents accidental
/// interchange between NAR ID domains while preserving a u64 wire format.
pub fn Id(comptime Tag: type) type {
    _ = Tag;
    return struct {
        value: u64 = 0,

        pub fn init(value: u64) ?@This() {
            return if (value == 0) null else .{ .value = value };
        }
        pub fn fromInt(value: u64) @This() {
            return .{ .value = value };
        }
        pub fn toInt(self: @This()) u64 {
            return self.value;
        }
        pub fn isValid(self: @This()) bool {
            return self.value != 0;
        }
    };
}

pub const RuntimeId = Id(struct {
    const name = "RuntimeId";
});
pub const AgentId = Id(struct {
    const name = "AgentId";
});
pub const TurnId = Id(struct {
    const name = "TurnId";
});
pub const ToolId = Id(struct {
    const name = "ToolId";
});
/// A generation-checked operation identity. The low 32 bits name a registry
/// slot and the high 32 bits are advanced whenever that slot is reused.
pub const OperationId = struct {
    value: u64 = 0,

    pub fn init(value: u64) ?OperationId {
        return if (value == 0) null else .{ .value = value };
    }
    /// Compatibility constructor for externally supplied, non-registry IDs.
    pub fn fromInt(value: u64) OperationId {
        return if (value > 0 and value <= std.math.maxInt(u32)) fromParts(@intCast(value), 1) else .{ .value = value };
    }
    pub fn fromParts(slot_value: u32, generation_value: u32) OperationId {
        return .{ .value = (@as(u64, generation_value) << 32) | slot_value };
    }
    pub fn slot(self: OperationId) u32 {
        return @truncate(self.value);
    }
    pub fn generation(self: OperationId) u32 {
        return @truncate(self.value >> 32);
    }
    pub fn toInt(self: OperationId) u64 {
        return self.value;
    }
    pub fn isValid(self: OperationId) bool {
        return self.slot() != 0 and self.generation() != 0;
    }
};
pub const WorldRevision = Id(struct {
    const name = "WorldRevision";
});

/// An opaque, generation-checked host object reference. It is fixed-width and
/// never exposes host pointers across the NAR boundary.
pub const ObjectRef = struct {
    id: u64 = 0,
    generation: u32 = 0,

    pub fn isValid(self: ObjectRef) bool {
        return self.id != 0 and self.generation != 0;
    }
};

/// NAR's strongly typed wrapper around fund's generation-safe handle table.
/// This registry is non-concurrent; synchronize owner-side mutations.
pub fn GenerationalRegistry(comptime T: type, comptime Tag: type) type {
    return struct {
        const Table = foundation.ids.HandleTable(T, Tag);
        pub const Handle = foundation.ids.Handle(Tag);
        table: Table,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .table = Table.init(allocator) };
        }
        pub fn deinit(self: *@This()) void {
            self.table.deinit();
        }
        pub fn insert(self: *@This(), value: T) !Handle {
            return self.table.insert(value);
        }
        pub fn get(self: *@This(), handle: Handle) ?*T {
            return self.table.get(handle);
        }
        pub fn remove(self: *@This(), handle: Handle) ?T {
            return self.table.remove(handle);
        }
        pub fn len(self: *const @This()) usize {
            return self.table.len();
        }
    };
}

/// NAR intentionally reuses fund's cross-thread cancellation implementation.
pub const CancellationSource = foundation.cancellation.CancellationSource;
pub const CancellationToken = foundation.cancellation.Token;
pub const CancelReason = foundation.cancellation.CancelReason;

pub const EventPriority = enum(u8) { critical, high, normal, low, background };

/// Host-supplied monotonically comparable timestamp in nanoseconds.
pub const Timestamp = struct { nanoseconds: u64 = 0 };

pub const ToolCompletion = struct {
    operation_id: OperationId,
    result: foundation.memory.SharedBuffer,

    fn deinit(self: *ToolCompletion) void {
        self.result.release();
    }
};

/// Pull event payload. Buffer-bearing variants own a `SharedBuffer`; consumers
/// must call `AgentEvent.deinit` once, or transfer it back to a mailbox.
pub const EventPayload = union(enum) {
    text_delta: foundation.memory.SharedBuffer,
    final_response: foundation.memory.SharedBuffer,
    tool_completed: ToolCompletion,
    operation_progress: foundation.memory.SharedBuffer,
    failed: ErrorCode,
    cancelled: CancelReason,
    system: foundation.memory.SharedBuffer,
    none: void,

    fn deinit(self: *EventPayload) void {
        switch (self.*) {
            .text_delta, .final_response, .operation_progress, .system => |*buffer| buffer.release(),
            .tool_completed => |*completion| completion.deinit(),
            else => {},
        }
        self.* = .{ .none = {} };
    }
};

pub const AgentEvent = struct {
    sequence: u64 = 0,
    turn_id: TurnId,
    timestamp: Timestamp,
    priority: EventPriority = .normal,
    payload: EventPayload,

    pub fn isTerminal(self: AgentEvent) bool {
        return switch (self.payload) {
            .final_response, .failed, .cancelled => true,
            else => false,
        };
    }
    pub fn deinit(self: *AgentEvent) void {
        self.payload.deinit();
    }
};

pub const MailboxError = error{ InvalidCapacity, Backpressure, Closed };

/// Bounded, mutex-protected MPSC pull mailbox. Events retain FIFO order and
/// receive monotonic sequence numbers. Adjacent text deltas for one turn are
/// coalesced; every other full-queue submission returns `Backpressure` while
/// leaving ownership with the caller, including terminal/high-priority events.
pub const EventMailbox = struct {
    allocator: std.mem.Allocator,
    items: []?AgentEvent,
    mutex: Mutex = .{},
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    next_sequence: u64 = 1,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !EventMailbox {
        if (capacity == 0) return error.InvalidCapacity;
        const items = try allocator.alloc(?AgentEvent, capacity);
        @memset(items, null);
        return .{ .allocator = allocator, .items = items };
    }
    pub fn deinit(self: *EventMailbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.popLocked()) |event| {
            var owned = event;
            owned.deinit();
        }
        self.allocator.free(self.items);
        self.items = &.{};
        self.closed = true;
    }
    pub fn close(self: *EventMailbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
    }
    pub fn len(self: *EventMailbox) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count;
    }
    /// On an error, `event` remains caller-owned and must be deinitialized by
    /// the caller. On success the mailbox owns it, including after coalescing.
    pub fn post(self: *EventMailbox, event: AgentEvent) MailboxError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        if (tryMergeTail(self, event)) return;
        if (self.count == self.items.len) return error.Backpressure;
        var owned = event;
        owned.sequence = self.next_sequence;
        self.next_sequence +%= 1;
        if (self.next_sequence == 0) self.next_sequence = 1;
        self.items[self.tail] = owned;
        self.tail = (self.tail + 1) % self.items.len;
        self.count += 1;
    }
    /// Returns one caller-owned event, or null when no event is pending.
    pub fn poll(self: *EventMailbox) ?AgentEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.popLocked();
    }

    fn popLocked(self: *EventMailbox) ?AgentEvent {
        if (self.count == 0) return null;
        const event = self.items[self.head].?;
        self.items[self.head] = null;
        self.head = (self.head + 1) % self.items.len;
        self.count -= 1;
        return event;
    }
    fn tryMergeTail(self: *EventMailbox, incoming: AgentEvent) bool {
        if (self.count == 0) return false;
        const tail = if (self.tail == 0) self.items.len - 1 else self.tail - 1;
        const previous = &self.items[tail].?;
        const old_buffer = switch (previous.payload) {
            .text_delta => |buffer| buffer,
            else => return false,
        };
        const new_buffer = switch (incoming.payload) {
            .text_delta => |buffer| buffer,
            else => return false,
        };
        if (previous.turn_id.value != incoming.turn_id.value) return false;
        const old_bytes = old_buffer.bytes() catch return false;
        const new_bytes = new_buffer.bytes() catch return false;
        const total = std.math.add(usize, old_bytes.len, new_bytes.len) catch return false;
        const merged_bytes = self.allocator.alloc(u8, total) catch return false;
        defer self.allocator.free(merged_bytes);
        @memcpy(merged_bytes[0..old_bytes.len], old_bytes);
        @memcpy(merged_bytes[old_bytes.len..], new_bytes);
        const merged = foundation.memory.SharedBuffer.initCopy(self.allocator, merged_bytes, .general) catch return false;
        previous.deinit();
        var discarded = incoming;
        discarded.deinit();
        previous.payload = .{ .text_delta = merged };
        return true;
    }
};
