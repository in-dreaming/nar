const std = @import("std");
const nar = @import("nar");
const foundation = @import("foundation");

pub const Event = union(enum) {
    start,
    text: []const u8,
    tool_start: struct { id: []const u8, name: []const u8 },
    arguments: []const u8,
    tool_end: []const u8,
    finish: nar.model.FinishReason,
};

/// Small deterministic backend used by the runnable examples. Each model
/// request consumes one immutable phase and every payload is independently
/// owned by the returned model event.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    phases: []const []const Event,
    next_phase: usize = 0,
    cursor: usize = 0,
    active: bool = false,
    generation: u32 = 1,

    pub fn model(self: *Backend) nar.model.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: nar.model.Backend.VTable = .{
        .descriptor = descriptor,
        .start = start,
        .poll = poll,
        .cancel = cancel,
        .release = release,
    };

    fn cast(raw: *anyopaque) *Backend {
        return @ptrCast(@alignCast(raw));
    }
    fn descriptor(_: *anyopaque) nar.model.ModelDescriptor {
        return .{ .provider_id = "example", .model_id = "script", .capabilities = .{ .streaming = true, .tool_calling = true } };
    }
    fn start(raw: *anyopaque, request: nar.model.ModelRequest) !nar.model.ModelRequestHandle {
        const self = cast(raw);
        if (self.active or self.next_phase >= self.phases.len) return error.ModelUnavailable;
        if (!std.mem.eql(u8, request.model_id, "script")) return error.ModelUnavailable;
        self.active = true;
        self.cursor = 0;
        return .{ .index = @intCast(self.next_phase), .generation = self.generation };
    }
    fn poll(raw: *anyopaque, handle: nar.model.ModelRequestHandle) !?nar.model.ModelEvent {
        const self = cast(raw);
        try self.validate(handle);
        const phase = self.phases[self.next_phase];
        if (self.cursor >= phase.len) return null;
        const value = phase[self.cursor];
        self.cursor += 1;
        return switch (value) {
            .start => .{ .start = {} },
            .text => |bytes| .{ .text_delta = try self.buffer(bytes) },
            .tool_start => |tool| .{ .tool_call_start = .{ .call_id = try self.buffer(tool.id), .name = try self.buffer(tool.name) } },
            .arguments => |bytes| .{ .arguments_delta = try self.buffer(bytes) },
            .tool_end => |id| .{ .tool_call_end = .{ .call_id = try self.buffer(id) } },
            .finish => |reason| .{ .finish = reason },
        };
    }
    fn cancel(raw: *anyopaque, handle: nar.model.ModelRequestHandle) !void {
        const self = cast(raw);
        try self.validate(handle);
    }
    fn release(raw: *anyopaque, handle: nar.model.ModelRequestHandle) void {
        const self = cast(raw);
        self.validate(handle) catch return;
        self.active = false;
        self.next_phase += 1;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }
    fn validate(self: *Backend, handle: nar.model.ModelRequestHandle) !void {
        if (!self.active or handle.index != self.next_phase or handle.generation != self.generation) return error.InvalidState;
    }
    fn buffer(self: *Backend, bytes: []const u8) !foundation.memory.SharedBuffer {
        return foundation.memory.SharedBuffer.initCopy(self.allocator, bytes, .general);
    }
};
