//! Lossless NAR tool-resource mapping to Spindle's incremental scheduler.
const std = @import("std");
const spindle = @import("spindle");
const tool = @import("../../tool/runtime.zig");

pub const State = spindle.resource_graph.incremental_scheduler.State;
pub const Route = spindle.resource_graph.incremental_scheduler.Route;
pub const RunFn = spindle.resource_graph.incremental_scheduler.RunFn;
pub const Handle = struct { raw: *spindle.resource_graph.IncrementalResourceSubmission };
pub const ResourceVersion = struct { generation: u64, content_hash: ?u64 = null, exists: bool = true };
pub const VersionResolver = struct {
    context: ?*anyopaque = null,
    resolve: *const fn (?*anyopaque, tool.ResourceKey) ?ResourceVersion,
};

pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    resolver: ?VersionResolver,
    scheduler: spindle.resource_graph.IncrementalResourceScheduler,

    pub fn init(allocator: std.mem.Allocator, compute: spindle.executor.Executor, blocking: spindle.executor.Executor, pump: spindle.executor.Executor, resolver: ?VersionResolver) Coordinator {
        return .{ .allocator = allocator, .resolver = resolver, .scheduler = spindle.resource_graph.IncrementalResourceScheduler.init(allocator, compute, blocking, pump, null) };
    }
    /// Binds the resolver after the coordinator reaches its stable owner address.
    pub fn bindResolver(self: *Coordinator) void {
        self.scheduler.resolver = if (self.resolver == null) null else .{ .context = self, .resolve = resolveVersion };
    }
    pub fn submit(self: *Coordinator, route: Route, declarations: []const tool.ResourceAccess, run: RunFn, context: ?*anyopaque) !Handle {
        const mapped = try self.allocator.alloc(spindle.resource_graph.ResourceAccess, declarations.len);
        defer self.allocator.free(mapped);
        for (declarations, 0..) |declaration, index| mapped[index] = try mapAccess(declaration);
        return .{ .raw = try self.scheduler.submit(route, mapped, run, context) };
    }
    pub fn status(_: *Coordinator, handle: Handle) State {
        return handle.raw.status();
    }
    pub fn failure(_: *Coordinator, handle: Handle) ?anyerror {
        return handle.raw.failure();
    }
    pub fn cancel(self: *Coordinator, handle: Handle) void {
        self.scheduler.cancel(handle.raw);
    }
    pub fn release(self: *Coordinator, handle: Handle) !void {
        try self.scheduler.release(handle.raw);
    }
    pub fn shutdown(self: *Coordinator) void {
        self.scheduler.shutdown();
    }
    pub fn deinit(self: *Coordinator) void {
        self.scheduler.deinit();
    }
    fn resolveVersion(raw: ?*anyopaque, key: spindle.resource_graph.ResourceKey) ?spindle.resource_graph.ResourceVersion {
        const self: *Coordinator = @ptrCast(@alignCast(raw.?));
        const resolver = self.resolver orelse return null;
        const mapped = unmapKey(key);
        const version = resolver.resolve(resolver.context, mapped) orelse return null;
        if (!version.exists) return null;
        return .{ .generation = version.generation, .content_hash = version.content_hash };
    }
};

fn mapAccess(source: tool.ResourceAccess) !spindle.resource_graph.ResourceAccess {
    return .{
        .key = try mapKey(source.key),
        .range = switch (source.range) {
            .whole => .whole,
            .page => |page| .{ .page = page },
            .byte => |range| .{ .byte = .{ .start = range.start, .end = range.end } },
        },
        .mode = @enumFromInt(@intFromEnum(source.mode)),
        .version = switch (source.version) {
            .any => .any,
            .must_not_exist => .must_not_exist,
            .exact => |value| .{ .exact = value },
            .generation => |value| .{ .generation = value },
        },
    };
}
fn mapKey(source: tool.ResourceKey) !spindle.resource_graph.ResourceKey {
    if (source.name.len == 0) return error.InvalidArgument;
    const namespace = spindle.core.StableId{ .high = source.namespace_high, .low = source.namespace_low };
    const kind: spindle.resource_graph.resource_key.Kind = @enumFromInt(@intFromEnum(source.kind));
    return switch (kind) {
        .file => spindle.resource_graph.ResourceKey.fileKey(spindle.resource_graph.FileIdentity.init(namespace, source.name)),
        .page => spindle.resource_graph.ResourceKey.pageKey(spindle.resource_graph.FileIdentity.init(namespace, source.name), source.page orelse return error.InvalidArgument),
        else => spindle.resource_graph.ResourceKey.named(kind, namespace, source.name),
    };
}
fn unmapKey(source: spindle.resource_graph.ResourceKey) tool.ResourceKey {
    return .{ .kind = @enumFromInt(@intFromEnum(source.kind)), .namespace_high = source.namespace.high, .namespace_low = source.namespace.low, .name = source.name, .page = source.page };
}
