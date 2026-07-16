//! Host-owned asynchronous operations backed by Spindle executors.
const std = @import("std");
const foundation = @import("foundation");
const spindle = @import("spindle");
const domain = @import("../foundation/domain.zig");
const core = @import("../core/agent_loop.zig");

const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};

pub const Affinity = enum { compute, blocking, pump };
pub const State = enum { pending, queued, running, completed, failed, cancelled, timed_out };
pub const Config = struct { capacity: usize = 64 };
pub const SubmitOptions = struct {
    affinity: Affinity = .compute,
    deadline_monotonic_ns: ?u64 = null,
};
pub const OperationFn = *const fn (*Context) void;

/// Callback context. `complete` consumes `payload` in every case. A callback
/// that returns without selecting a terminal result is converted to failure.
pub const Context = struct {
    entry: *Entry,
    pub fn isCancelled(self: *const Context) bool {
        var token = self.entry.cancel_source.token();
        defer token.deinit();
        return token.isCancelled();
    }
    pub fn complete(self: *Context, payload: foundation.memory.SharedBuffer) bool {
        return self.entry.registry.complete(self.entry, payload);
    }
    pub fn fail(self: *Context, code: domain.ErrorCode) bool {
        return self.entry.registry.fail(self.entry, code);
    }
    pub fn cancelReason(self: *const Context) ?domain.CancelReason {
        var token = self.entry.cancel_source.token();
        defer token.deinit();
        return token.reason();
    }
};

const Outcome = union(enum) { none, completed: foundation.memory.SharedBuffer, failed: domain.ErrorCode, cancelled: domain.CancelReason, timed_out: void };
const Entry = struct {
    registry: *Registry,
    id: domain.OperationId,
    state: State = .pending,
    outcome: Outcome = .none,
    deadline_monotonic_ns: ?u64,
    cancel_source: domain.CancellationSource,
    task: spindle.executor.Task,
    callback: OperationFn,
};
const Slot = struct { generation: u32 = 1, entry: ?*Entry = null };

/// A bounded, thread-safe operation table. Entries remain address-stable until
/// `release` after a terminal observation, so Spindle's intrusive Task remains
/// valid through queue cancellation and late completion attempts.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    compute: spindle.executor.Executor,
    blocking: spindle.executor.Executor,
    pump: spindle.executor.Executor,
    capacity: usize,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    retired: std.ArrayListUnmanaged(*Entry) = .empty,
    live: usize = 0,
    stopped: bool = false,
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, config: Config, compute: spindle.executor.Executor, blocking: spindle.executor.Executor, pump: spindle.executor.Executor) !Registry {
        if (config.capacity == 0) return error.InvalidArgument;
        var registry = Registry{ .allocator = allocator, .compute = compute, .blocking = blocking, .pump = pump, .capacity = config.capacity };
        try registry.slots.ensureTotalCapacity(allocator, config.capacity);
        errdefer registry.slots.deinit(allocator);
        try registry.retired.ensureTotalCapacity(allocator, config.capacity);
        return registry;
    }
    pub fn deinit(self: *Registry) void {
        self.shutdown();
        self.mutex.lock();
        for (self.slots.items) |*slot| if (slot.entry) |entry| self.destroyEntry(entry);
        for (self.retired.items) |entry| self.destroyEntry(entry);
        self.slots.deinit(self.allocator);
        self.retired.deinit(self.allocator);
        self.mutex.unlock();
        self.* = undefined;
    }
    pub fn submit(self: *Registry, options: SubmitOptions, callback: OperationFn) !domain.OperationId {
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        var source = try domain.CancellationSource.init(self.allocator);
        errdefer if (source.state != null) source.deinit();
        self.mutex.lock();
        self.collectRetiredLocked();
        if (self.stopped) {
            self.mutex.unlock();
            return error.Shutdown;
        }
        if (self.live == self.capacity) {
            self.mutex.unlock();
            return error.BudgetExceeded;
        }
        var index: usize = 0;
        while (index < self.slots.items.len and self.slots.items[index].entry != null) : (index += 1) {}
        if (index == self.slots.items.len) self.slots.append(self.allocator, .{}) catch {
            self.mutex.unlock();
            return error.OutOfMemory;
        };
        const slot = &self.slots.items[index];
        const id = domain.OperationId.fromParts(@intCast(index + 1), slot.generation);
        entry.* = .{ .registry = self, .id = id, .deadline_monotonic_ns = options.deadline_monotonic_ns, .cancel_source = source, .task = spindle.executor.Task.init(run, null), .callback = callback };
        source = .{ .state = null };
        entry.task.context = entry;
        slot.entry = entry;
        self.live += 1;
        self.mutex.unlock();
        const executor = switch (options.affinity) {
            .compute => self.compute,
            .blocking => self.blocking,
            .pump => self.pump,
        };
        executor.submit(&entry.task, .{}) catch |err| {
            self.abortSubmission(entry);
            return switch (err) {
                error.Backpressure => error.BudgetExceeded,
                error.Shutdown => error.Shutdown,
                else => error.InvalidState,
            };
        };
        self.mutex.lock();
        if (entry.state == .pending) entry.state = .queued;
        self.mutex.unlock();
        return id;
    }
    pub fn services(self: *Registry) core.ExecutionServices.Operations {
        return .{ .context = self, .poll_fn = pollErased, .cancel_fn = cancelErased, .release_fn = releaseErased };
    }
    pub fn stateOf(self: *Registry, id: domain.OperationId) ?State {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.find(id)) |entry| entry.state else null;
    }
    pub fn poll(self: *Registry, id: domain.OperationId, now: u64) core.ExecutionServices.Operations.Result {
        self.mutex.lock();
        self.collectRetiredLocked();
        const entry = self.find(id) orelse {
            self.mutex.unlock();
            return .stale;
        };
        if (entry.deadline_monotonic_ns) |deadline| if (now >= deadline and !terminal(entry.state)) self.setTerminalLocked(entry, .timed_out, .{ .timed_out = {} });
        const result: core.ExecutionServices.Operations.Result = switch (entry.outcome) {
            .none => .pending,
            .completed => |buffer| blk: {
                const clone = buffer.clone() catch break :blk .{ .failed = .internal_error };
                break :blk .{ .completed = clone };
            },
            .failed => |code| .{ .failed = code },
            .cancelled => |reason| .{ .cancelled = reason },
            .timed_out => .timed_out,
        };
        self.mutex.unlock();
        return result;
    }
    pub fn cancel(self: *Registry, id: domain.OperationId, reason: domain.CancelReason) void {
        self.mutex.lock();
        const entry = self.find(id) orelse {
            self.mutex.unlock();
            return;
        };
        _ = entry.cancel_source.cancel(reason);
        if (!terminal(entry.state)) {
            _ = entry.task.cancel();
            self.setTerminalLocked(entry, .cancelled, .{ .cancelled = reason });
        }
        self.mutex.unlock();
    }
    /// Completes a live operation from an embedding callback. Ownership of
    /// `payload` transfers regardless of whether the completion is accepted.
    pub fn completeExternal(self: *Registry, id: domain.OperationId, payload: foundation.memory.SharedBuffer) bool {
        self.mutex.lock();
        const entry = self.find(id) orelse {
            self.mutex.unlock();
            var owned = payload;
            owned.release();
            return false;
        };
        var owned = payload;
        if (terminal(entry.state)) {
            self.mutex.unlock();
            owned.release();
            return false;
        }
        self.setTerminalLocked(entry, .completed, .{ .completed = owned });
        self.mutex.unlock();
        return true;
    }
    pub fn failExternal(self: *Registry, id: domain.OperationId, value: domain.ErrorCode) bool {
        self.mutex.lock();
        const entry = self.find(id) orelse {
            self.mutex.unlock();
            return false;
        };
        if (terminal(entry.state)) {
            self.mutex.unlock();
            return false;
        }
        self.setTerminalLocked(entry, .failed, .{ .failed = value });
        self.mutex.unlock();
        return true;
    }
    pub fn release(self: *Registry, id: domain.OperationId) void {
        self.mutex.lock();
        self.collectRetiredLocked();
        const index = self.indexFor(id) orelse {
            self.mutex.unlock();
            return;
        };
        const slot = &self.slots.items[index];
        const entry = slot.entry orelse {
            self.mutex.unlock();
            return;
        };
        if (slot.generation != id.generation() or !terminal(entry.state)) {
            self.mutex.unlock();
            return;
        }
        slot.entry = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        self.live -= 1;
        self.retired.appendAssumeCapacity(entry);
        self.collectRetiredLocked();
        self.mutex.unlock();
    }
    pub fn shutdown(self: *Registry) void {
        self.mutex.lock();
        self.stopped = true;
        for (self.slots.items) |slot| if (slot.entry) |entry| {
            _ = entry.cancel_source.cancel(.shutdown);
            _ = entry.task.cancel();
            if (!terminal(entry.state)) self.setTerminalLocked(entry, .cancelled, .{ .cancelled = .shutdown });
        };
        self.mutex.unlock();
    }
    fn complete(self: *Registry, entry: *Entry, payload: foundation.memory.SharedBuffer) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var owned = payload;
        if (terminal(entry.state)) {
            owned.release();
            return false;
        }
        self.setTerminalLocked(entry, .completed, .{ .completed = owned });
        return true;
    }
    fn fail(self: *Registry, entry: *Entry, code: domain.ErrorCode) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (terminal(entry.state)) return false;
        self.setTerminalLocked(entry, .failed, .{ .failed = code });
        return true;
    }
    fn abortSubmission(self: *Registry, entry: *Entry) void {
        self.mutex.lock();
        const index = self.indexFor(entry.id).?;
        self.slots.items[index].entry = null;
        self.live -= 1;
        self.mutex.unlock();
        self.destroyEntry(entry);
    }
    fn setTerminalLocked(self: *Registry, entry: *Entry, state: State, outcome: Outcome) void {
        _ = self;
        entry.state = state;
        entry.outcome = outcome;
        switch (state) {
            .cancelled => _ = entry.cancel_source.cancel(.requested),
            .timed_out => _ = entry.cancel_source.cancel(.timeout),
            else => {},
        }
    }
    fn find(self: *Registry, id: domain.OperationId) ?*Entry {
        const index = self.indexFor(id) orelse return null;
        const slot = self.slots.items[index];
        if (slot.generation != id.generation()) return null;
        return slot.entry;
    }
    fn indexFor(self: *Registry, id: domain.OperationId) ?usize {
        if (!id.isValid()) return null;
        const slot = id.slot();
        if (slot == 0) return null;
        const index: usize = slot - 1;
        return if (index < self.slots.items.len) index else null;
    }
    fn destroyEntry(self: *Registry, entry: *Entry) void {
        switch (entry.outcome) {
            .completed => |*buffer| buffer.release(),
            else => {},
        }
        entry.cancel_source.deinit();
        self.allocator.destroy(entry);
    }
    fn collectRetiredLocked(self: *Registry) void {
        var index: usize = 0;
        while (index < self.retired.items.len) {
            const entry = self.retired.items[index];
            const state = entry.task.status();
            if (entry.task.queue_references.load(.acquire) == 0 and (state == .completed or state == .failed or state == .cancelled)) {
                _ = self.retired.swapRemove(index);
                self.destroyEntry(entry);
            } else index += 1;
        }
    }
    fn run(task: *spindle.executor.Task) void {
        const entry: *Entry = @ptrCast(@alignCast(task.context.?));
        entry.registry.mutex.lock();
        if (terminal(entry.state)) {
            entry.registry.mutex.unlock();
            return;
        }
        entry.state = .running;
        entry.registry.mutex.unlock();
        var context = Context{ .entry = entry };
        entry.callback(&context);
        _ = entry.registry.fail(entry, .operation_failed);
    }
    fn pollErased(raw: ?*anyopaque, id: domain.OperationId, now: u64) core.ExecutionServices.Operations.Result {
        return (@as(*Registry, @ptrCast(@alignCast(raw.?)))).poll(id, now);
    }
    fn cancelErased(raw: ?*anyopaque, id: domain.OperationId, reason: domain.CancelReason) void {
        (@as(*Registry, @ptrCast(@alignCast(raw.?)))).cancel(id, reason);
    }
    fn releaseErased(raw: ?*anyopaque, id: domain.OperationId) void {
        (@as(*Registry, @ptrCast(@alignCast(raw.?)))).release(id);
    }
};

fn terminal(state: State) bool {
    return switch (state) {
        .completed, .failed, .cancelled, .timed_out => true,
        else => false,
    };
}
