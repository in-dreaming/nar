//! Spindle ownership adapter. Core receives only borrowed `ExecutionServices`.
const std = @import("std");
const spindle = @import("spindle");
const core = @import("../../core/agent_loop.zig");
const operation = @import("../../runtime/operation.zig");

pub const Config = struct {
    compute_workers: usize = 1,
    blocking_workers: usize = 1,
    queue_capacity: usize = 64,
    operation_capacity: usize = 64,
    observability_capacity: usize = 128,
    fault: spindle.runtime.Fault = .none,
};

/// Production owner. `runtime()` is invalid after `deinit`; the returned core
/// pointer never owns the host's clock, executors, event sink, or `std.Io`.
pub const Host = struct {
    state: *State,

    const State = struct {
        allocator: std.mem.Allocator,
        threaded: std.Io.Threaded,
        spindle_runtime: spindle.runtime.Runtime,
        operations: operation.Registry,
        nar_runtime: core.Runtime,
    };

    /// Allocates an address-stable owner and starts configured worker services.
    pub fn init(allocator: std.mem.Allocator, config: Config) !Host {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.allocator = allocator;
        state.threaded = std.Io.Threaded.init(allocator, .{ .environ = .{ .block = .global } });
        errdefer state.threaded.deinit();
        state.spindle_runtime = try spindle.runtime.Runtime.init(allocator, .{
            .io = state.threaded.io(),
            .compute_workers = config.compute_workers,
            .blocking_workers = config.blocking_workers,
            .queue_capacity = config.queue_capacity,
            .observability_capacity = config.observability_capacity,
            .fault = config.fault,
        });
        errdefer state.spindle_runtime.deinit();
        state.operations = try operation.Registry.init(allocator, .{ .capacity = config.operation_capacity }, state.spindle_runtime.computeExecutor(), state.spindle_runtime.blockingExecutor(), state.spindle_runtime.pumpExecutor());
        errdefer state.operations.deinit();
        state.nar_runtime = try core.Runtime.init(allocator, .{ .services = servicesFor(&state.spindle_runtime, state.threaded.io(), state.operations.services()) });
        return .{ .state = state };
    }

    /// Returns a borrowed runtime pointer valid until `deinit` begins.
    pub fn runtime(self: *Host) *core.Runtime {
        return &self.state.nar_runtime;
    }
    /// Returns borrowed services which must not outlive this host.
    pub fn services(self: *Host) core.ExecutionServices {
        return servicesFor(&self.state.spindle_runtime, self.state.threaded.io(), self.state.operations.services());
    }
    /// Returns the owned Spindle runtime for diagnostics and staged shutdown.
    pub fn spindleRuntime(self: *Host) *spindle.runtime.Runtime {
        return &self.state.spindle_runtime;
    }
    /// Returns the host-owned thread-safe operation registry.
    pub fn operations(self: *Host) *operation.Registry {
        return &self.state.operations;
    }

    /// Cancels NAR turns before requesting Spindle's staged shutdown.
    pub fn shutdown(self: *Host, deadline_monotonic_ns: ?u64) spindle.runtime.ShutdownReport {
        self.state.nar_runtime.shutdown();
        self.state.operations.shutdown();
        return self.state.spindle_runtime.shutdown(deadline_monotonic_ns);
    }

    /// Converges shutdown and destroys NAR, Spindle, then threaded I/O state.
    pub fn deinit(self: *Host) void {
        const state = self.state;
        _ = self.shutdown(null);
        state.nar_runtime.deinit();
        state.spindle_runtime.deinit();
        state.operations.deinit();
        state.threaded.deinit();
        state.allocator.destroy(state);
        self.* = undefined;
    }
};

/// Caller-driven deterministic host for unit tests and minimal embeddings.
/// It owns no threads and uses a virtual clock; callers advance time and pump.
pub const TestHost = struct {
    state: *State,

    const State = struct {
        allocator: std.mem.Allocator,
        clock_source: spindle.core.clock.VirtualClock,
        compute: spindle.executor.DeterministicExecutor,
        blocking: spindle.executor.InlineExecutor = .{},
        pump_executor: spindle.executor.PumpExecutor,
        event_storage: [32]spindle.observability.event.Event = undefined,
        event_ring: spindle.observability.event.RingSink,
        operations: operation.Registry,
        nar_runtime: core.Runtime,
    };

    /// Creates a no-thread host with the default operation capacity.
    pub fn init(allocator: std.mem.Allocator, queue_capacity: usize) !TestHost {
        return initWithOperationCapacity(allocator, queue_capacity, 64);
    }
    /// Creates a no-thread host with explicit bounded queue/table capacities.
    pub fn initWithOperationCapacity(allocator: std.mem.Allocator, queue_capacity: usize, operation_capacity: usize) !TestHost {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.allocator = allocator;
        state.clock_source = spindle.core.clock.VirtualClock.init(0, 0);
        state.compute = spindle.executor.DeterministicExecutor.init(allocator);
        errdefer state.compute.deinit();
        state.blocking = .{};
        state.pump_executor = try spindle.executor.PumpExecutor.init(allocator, queue_capacity);
        errdefer state.pump_executor.deinit();
        state.event_ring = spindle.observability.event.RingSink.init(&state.event_storage);
        state.operations = try operation.Registry.init(allocator, .{ .capacity = operation_capacity }, state.compute.executor(), state.blocking.executor(), state.pump_executor.executor());
        errdefer state.operations.deinit();
        state.nar_runtime = try core.Runtime.init(allocator, .{ .services = servicesForState(state) });
        return .{ .state = state };
    }

    /// Returns a borrowed runtime pointer valid until `deinit`.
    pub fn runtime(self: *TestHost) *core.Runtime {
        return &self.state.nar_runtime;
    }
    /// Advances the synchronized virtual monotonic clock.
    pub fn advance(self: *TestHost, nanoseconds: u64) void {
        self.state.clock_source.advance(nanoseconds, @intCast(nanoseconds / std.time.ns_per_ms));
    }
    /// Runs bounded caller-thread work without implicitly advancing time.
    pub fn pump(self: *TestHost, max_jobs: usize, max_ns: u64) usize {
        return self.state.pump_executor.drainFor(max_jobs, max_ns);
    }
    /// Submits a caller-owned intrusive task; it must outlive queue retirement.
    pub fn submitPump(self: *TestHost, task: *spindle.executor.Task) spindle.executor.SubmitError!void {
        try self.state.pump_executor.submit(task, .{});
    }
    /// Returns the deterministic host's operation registry.
    pub fn operations(self: *TestHost) *operation.Registry {
        return &self.state.operations;
    }
    /// Drains deterministic compute work on the caller thread.
    pub fn runCompute(self: *TestHost) !void {
        try self.state.compute.run();
    }
    /// Returns borrowed deterministic services valid until `deinit`.
    pub fn services(self: *TestHost) core.ExecutionServices {
        return servicesForState(self.state);
    }
    /// Cancels active work and releases all deterministic host state.
    pub fn deinit(self: *TestHost) void {
        const state = self.state;
        state.nar_runtime.deinit();
        state.operations.shutdown();
        state.pump_executor.deinit();
        state.compute.deinit();
        state.operations.deinit();
        state.allocator.destroy(state);
        self.* = undefined;
    }
};

fn servicesForState(state: *TestHost.State) core.ExecutionServices {
    return .{
        .clock = .{ .context = &state.clock_source, .now_fn = virtualNow },
        .compute = .{ .context = &state.compute, .worker_count_fn = deterministicWorkers },
        .blocking = .{ .context = &state.blocking, .worker_count_fn = inlineWorkers },
        .pump = .{ .context = &state.pump_executor, .drain_fn = drainPump },
        .events = .{ .context = &state.event_ring, .emit_fn = emitEvent },
        .operations = state.operations.services(),
    };
}

fn servicesFor(runtime: *spindle.runtime.Runtime, io: std.Io, operations: core.ExecutionServices.Operations) core.ExecutionServices {
    return .{
        .clock = .{ .context = runtime, .now_fn = runtimeNow },
        .compute = .{ .context = runtime, .worker_count_fn = computeWorkers },
        .blocking = .{ .context = runtime, .worker_count_fn = blockingWorkers },
        .pump = .{ .context = runtime, .drain_fn = drainRuntimePump },
        .events = .{ .context = runtime, .emit_fn = emitRuntimeEvent },
        .io = io,
        .operations = operations,
    };
}
fn runtimeNow(raw: ?*anyopaque) u64 {
    return castRuntime(raw).clock().monotonicNow();
}
fn computeWorkers(raw: ?*anyopaque) usize {
    return castRuntime(raw).computeExecutor().workerCount();
}
fn blockingWorkers(raw: ?*anyopaque) usize {
    return castRuntime(raw).blockingExecutor().workerCount();
}
fn drainRuntimePump(raw: ?*anyopaque, max_jobs: usize, max_ns: u64) usize {
    return castRuntime(raw).state.pump.drainFor(max_jobs, max_ns);
}
fn emitRuntimeEvent(raw: ?*anyopaque, kind: []const u8, value: i64) void {
    castRuntime(raw).eventSink().emit(.{ .monotonic_ns = castRuntime(raw).clock().monotonicNow(), .kind = kind, .value = value });
}
fn virtualNow(raw: ?*anyopaque) u64 {
    return (@as(*spindle.core.clock.VirtualClock, @ptrCast(@alignCast(raw.?)))).clock().monotonicNow();
}
fn deterministicWorkers(_: ?*anyopaque) usize {
    return 1;
}
fn inlineWorkers(_: ?*anyopaque) usize {
    return 0;
}
fn drainPump(raw: ?*anyopaque, max_jobs: usize, max_ns: u64) usize {
    return (@as(*spindle.executor.PumpExecutor, @ptrCast(@alignCast(raw.?)))).drainFor(max_jobs, max_ns);
}
fn emitEvent(raw: ?*anyopaque, kind: []const u8, value: i64) void {
    (@as(*spindle.observability.event.RingSink, @ptrCast(@alignCast(raw.?)))).sink().emit(.{ .monotonic_ns = 0, .kind = kind, .value = value });
}
fn castRuntime(raw: ?*anyopaque) *spindle.runtime.Runtime {
    return @ptrCast(@alignCast(raw.?));
}
