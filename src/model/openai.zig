//! Bounded OpenAI-compatible streaming backend over Foundation HTTP/SSE.
const std = @import("std");
const foundation = @import("foundation");
const model = @import("model.zig");
const domain = @import("../foundation/domain.zig");

const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};

pub const HeaderProvider = *const fn (?*anyopaque, std.mem.Allocator) anyerror![]foundation.http.Header;
pub const Config = struct {
    provider_id: []const u8 = "openai-compatible",
    base_url: []const u8,
    model_id: []const u8,
    allowed_origins: []const []const u8 = &.{},
    headers: ?HeaderProvider = null,
    header_context: ?*anyopaque = null,
    connect_timeout_ms: u64 = 10_000,
    timeout_ms: u64 = 30_000,
    first_byte_timeout_ms: u64 = 10_000,
    response_limit: usize = 1024 * 1024,
    event_limit: usize = 64 * 1024,
    queue_capacity: usize = 128,
    max_requests: usize = 8,
};

const Queued = struct { event: model.ModelEvent };
const Callback = struct { backend: *Backend, handle: model.ModelRequestHandle };
const Slot = struct {
    generation: u32 = 1,
    active: bool = false,
    terminal: bool = false,
    cancelled: bool = false,
    started: bool = false,
    operation: ?*foundation.http.HttpOperation = null,
    parser: ?foundation.sse.Parser = null,
    callback: Callback = undefined,
    queue: std.ArrayListUnmanaged(Queued) = .empty,
    tool_ids: [16]?[]u8 = [_]?[]u8{null} ** 16,
    tool_names: [16]?[]u8 = [_]?[]u8{null} ** 16,
    fn reset(self: *Slot, allocator: std.mem.Allocator) void {
        for (self.queue.items) |*item| item.event.deinit();
        self.queue.clearRetainingCapacity();
        for (&self.tool_ids) |*value| if (value.*) |bytes| allocator.free(bytes);
        for (&self.tool_names) |*value| if (value.*) |bytes| allocator.free(bytes);
        self.active = false;
        self.terminal = false;
        self.cancelled = false;
        self.started = false;
        self.operation = null;
        if (self.parser) |*parser| parser.deinit();
        self.parser = null;
        self.tool_ids = [_]?[]u8{null} ** 16;
        self.tool_names = [_]?[]u8{null} ** 16;
    }
    fn deinit(self: *Slot, allocator: std.mem.Allocator) void {
        self.reset(allocator);
        self.queue.deinit(allocator);
    }
};

/// A host-driven backend. Call the configured transport's pump/IO loop, then
/// poll requests. NAR owns no network thread and all provider secrets stay in
/// the header provider's temporary request headers.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    config: Config,
    http: foundation.http.HttpClient,
    completion_executor: foundation.executor.Executor,
    descriptor_value: model.ModelDescriptor,
    slots: []Slot,
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, config: Config, http: foundation.http.HttpClient, completion_executor: foundation.executor.Executor) !Backend {
        if (config.base_url.len == 0 or config.model_id.len == 0 or config.response_limit == 0 or config.event_limit == 0 or config.queue_capacity == 0 or config.max_requests == 0) return error.InvalidArgument;
        if (!originAllowed(config.base_url, config.allowed_origins)) return error.InvalidArgument;
        const slots = try allocator.alloc(Slot, config.max_requests);
        errdefer allocator.free(slots);
        @memset(slots, Slot{});
        var initialized: usize = 0;
        errdefer for (slots[0..initialized]) |*slot| slot.queue.deinit(allocator);
        for (slots) |*slot| {
            try slot.queue.ensureTotalCapacity(allocator, config.queue_capacity);
            initialized += 1;
        }
        return .{ .allocator = allocator, .config = config, .http = http, .completion_executor = completion_executor, .descriptor_value = .{ .provider_id = config.provider_id, .model_id = config.model_id, .capabilities = .{ .streaming = true, .tool_calling = true, .json_mode = true } }, .slots = slots };
    }
    pub fn deinit(self: *Backend) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots) |*slot| {
            if (slot.operation) |operation| operation.deinit();
            slot.deinit(self.allocator);
        }
        self.allocator.free(self.slots);
        self.slots = &.{};
    }
    pub fn backend(self: *Backend) model.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: model.Backend.VTable = .{ .descriptor = descriptor, .start = startErased, .poll = pollErased, .cancel = cancelErased, .release = releaseErased };
    fn cast(raw: *anyopaque) *Backend {
        return @ptrCast(@alignCast(raw));
    }
    fn descriptor(raw: *anyopaque) model.ModelDescriptor {
        return cast(raw).descriptor_value;
    }
    fn startErased(raw: *anyopaque, request: model.ModelRequest) !model.ModelRequestHandle {
        return cast(raw).start(request);
    }
    fn pollErased(raw: *anyopaque, handle: model.ModelRequestHandle) !?model.ModelEvent {
        return cast(raw).poll(handle);
    }
    fn cancelErased(raw: *anyopaque, handle: model.ModelRequestHandle) !void {
        return cast(raw).cancel(handle);
    }
    fn releaseErased(raw: *anyopaque, handle: model.ModelRequestHandle) void {
        cast(raw).release(handle);
    }

    pub fn start(self: *Backend, request: model.ModelRequest) !model.ModelRequestHandle {
        if (!std.mem.eql(u8, request.model_id, self.config.model_id) or request.requiresVision()) return error.ModelUnavailable;
        const body = try encodeRequest(self.allocator, request, self.config.model_id);
        defer self.allocator.free(body);
        var headers: std.ArrayListUnmanaged(foundation.http.Header) = .empty;
        defer headers.deinit(self.allocator);
        try headers.append(self.allocator, .{ .name = "content-type", .value = "application/json" });
        try headers.append(self.allocator, .{ .name = "accept", .value = "text/event-stream" });
        var supplied: []foundation.http.Header = &.{};
        if (self.config.headers) |provider| {
            supplied = try provider(self.config.header_context, self.allocator);
            defer self.allocator.free(supplied);
            try headers.appendSlice(self.allocator, supplied);
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots, 0..) |*slot, index| if (!slot.active) {
            slot.reset(self.allocator);
            slot.active = true;
            slot.parser = foundation.sse.Parser.init(self.allocator, .{ .max_field_bytes = self.config.event_limit, .max_event_bytes = self.config.event_limit }, .reject);
            const handle = model.ModelRequestHandle{ .index = @intCast(index), .generation = slot.generation };
            slot.callback = .{ .backend = self, .handle = handle };
            slot.operation = self.http.startStream(self.allocator, .{ .url = self.config.base_url, .method = .post, .headers = headers.items, .body = body }, .{ .connect_timeout_ms = self.config.connect_timeout_ms, .first_byte_timeout_ms = self.config.first_byte_timeout_ms, .timeout_ms = self.config.timeout_ms, .response_body_limit = self.config.response_limit, .redirects = .deny, .executor = self.completion_executor }, .{ .callback = streamData, .context = &slot.callback, .head = streamHead }, completed, &slot.callback) catch |err| {
                slot.reset(self.allocator);
                return err;
            };
            return handle;
        };
        return error.BudgetExceeded;
    }
    pub fn poll(self: *Backend, handle: model.ModelRequestHandle) !?model.ModelEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = try self.requestSlot(handle);
        if (slot.queue.items.len == 0) return null;
        const item = slot.queue.orderedRemove(0);
        return item.event;
    }
    pub fn cancel(self: *Backend, handle: model.ModelRequestHandle) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = try self.requestSlot(handle);
        if (slot.terminal or slot.cancelled) return error.InvalidState;
        slot.cancelled = true;
        if (slot.operation) |operation| operation.cancel();
    }
    pub fn release(self: *Backend, handle: model.ModelRequestHandle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = self.requestSlot(handle) catch return;
        if (slot.operation) |operation| operation.deinit();
        slot.reset(self.allocator);
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }
    fn requestSlot(self: *Backend, handle: model.ModelRequestHandle) !*Slot {
        if (!handle.isValid() or handle.index >= self.slots.len) return error.InvalidState;
        const slot = &self.slots[handle.index];
        if (!slot.active or slot.generation != handle.generation) return error.InvalidState;
        return slot;
    }
    fn completed(raw: ?*anyopaque, result: foundation.http.Result) void {
        const callback: *Callback = @ptrCast(@alignCast(raw.?));
        const self = callback.backend;
        const handle = callback.handle;
        var owned = result;
        defer owned.deinit();
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = self.requestSlot(handle) catch return;
        const operation = slot.operation orelse return;
        slot.operation = null;
        defer operation.deinit();
        if (slot.cancelled) {
            self.push(slot, .{ .cancelled = {} });
            slot.terminal = true;
            return;
        }
        switch (owned) {
            .cancelled => {
                self.push(slot, .{ .cancelled = {} });
                slot.terminal = true;
            },
            .failure => |failure| {
                self.push(slot, .{ .@"error" = errorForFailure(failure.category) });
                slot.terminal = true;
            },
            .response => |response| {
                if (response.status < 200 or response.status >= 300) {
                    self.push(slot, .{ .@"error" = if (response.status == 408 or response.status == 504) .timeout else .network_error });
                    slot.terminal = true;
                    return;
                }
                var parse_context = ParseContext{ .backend = self, .slot = slot };
                if (slot.parser) |*parser| parser.finish(onSse, &parse_context) catch {
                    self.protocol(slot);
                    return;
                };
                if (!slot.terminal) self.protocol(slot);
            },
        }
    }
    fn push(self: *Backend, slot: *Slot, event: model.ModelEvent) void {
        if (slot.terminal) {
            var dropped = event;
            dropped.deinit();
            return;
        }
        if (slot.queue.items.len >= self.config.queue_capacity) {
            var dropped = event;
            dropped.deinit();
            for (slot.queue.items) |*item| item.event.deinit();
            slot.queue.clearRetainingCapacity();
            slot.queue.appendAssumeCapacity(.{ .event = .{ .@"error" = .budget_exceeded } });
            slot.terminal = true;
            return;
        }
        slot.queue.appendAssumeCapacity(.{ .event = event });
    }
    fn protocol(self: *Backend, slot: *Slot) void {
        if (!slot.terminal) {
            self.push(slot, .{ .@"error" = .model_protocol_error });
            slot.terminal = true;
        }
    }
};

fn streamHead(raw: ?*anyopaque, head: foundation.http.ResponseHead) foundation.http.StreamError!void {
    const callback: *Callback = @ptrCast(@alignCast(raw.?));
    const self = callback.backend;
    self.mutex.lock();
    defer self.mutex.unlock();
    const slot = self.requestSlot(callback.handle) catch return error.InvalidData;
    if (slot.cancelled or slot.terminal) return error.Backpressure;
    if (head.status < 200 or head.status >= 300) {
        self.push(slot, .{ .@"error" = if (head.status == 408 or head.status == 504) .timeout else .network_error });
        slot.terminal = true;
        return error.InvalidData;
    }
}

fn streamData(raw: ?*anyopaque, bytes: []const u8) foundation.http.StreamError!void {
    const callback: *Callback = @ptrCast(@alignCast(raw.?));
    const self = callback.backend;
    self.mutex.lock();
    defer self.mutex.unlock();
    const slot = self.requestSlot(callback.handle) catch return error.InvalidData;
    if (slot.cancelled or slot.terminal) return error.Backpressure;
    if (!slot.started) {
        self.push(slot, .{ .start = {} });
        slot.started = true;
    }
    var parse_context = ParseContext{ .backend = self, .slot = slot };
    if (slot.parser) |*parser| parser.feed(bytes, onSse, &parse_context) catch {
        self.protocol(slot);
        return error.InvalidData;
    } else return error.InvalidData;
    if (slot.terminal) return;
    if (slot.queue.items.len >= self.config.queue_capacity) return error.Backpressure;
}

const ParseContext = struct { backend: *Backend, slot: *Slot };
fn onSse(raw: ?*anyopaque, event: foundation.sse.Event) void {
    const context: *ParseContext = @ptrCast(@alignCast(raw.?));
    if (context.slot.terminal) return;
    if (std.mem.eql(u8, event.data, "[DONE]")) {
        const reason: model.FinishReason = if (hasOpenToolCalls(context.slot)) .tool_calls else .stop;
        closeToolCalls(context.backend, context.slot) catch {
            context.backend.protocol(context.slot);
            return;
        };
        context.backend.push(context.slot, .{ .finish = reason });
        context.slot.terminal = true;
        return;
    }
    parseChunk(context.backend, context.slot, event.data) catch context.backend.protocol(context.slot);
}
fn parseChunk(backend: *Backend, slot: *Slot, data: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, backend.allocator, data, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .max_value_len = backend.config.event_limit,
    });
    defer parsed.deinit();
    const root = object(parsed.value) orelse return error.InvalidJson;
    const choices_value = root.get("choices") orelse return error.InvalidJson;
    const choices = array(choices_value) orelse return error.InvalidJson;
    if (choices.items.len == 0) return error.InvalidJson;
    for (choices.items) |choice_value| {
        const choice = object(choice_value) orelse return error.InvalidJson;
        if (choice.get("delta")) |delta_value| {
            const delta = object(delta_value) orelse return error.InvalidJson;
            if (optionalString(delta, "content") catch return error.InvalidJson) |content| {
                if (content.len != 0) backend.push(slot, .{ .text_delta = try foundation.memory.SharedBuffer.initCopy(backend.allocator, content, .network) });
            }
            if (delta.get("tool_calls")) |calls_value| {
                const calls = array(calls_value) orelse return error.InvalidJson;
                for (calls.items) |call_value| try parseToolCall(backend, slot, call_value);
            }
        }
        if (choice.get("finish_reason")) |reason_value| switch (reason_value) {
            .null => {},
            .string => |reason| {
                const finish = finishReason(reason) orelse return error.InvalidJson;
                if (finish == .tool_calls) try closeToolCalls(backend, slot);
                backend.push(slot, .{ .finish = finish });
                slot.terminal = true;
                return;
            },
            else => return error.InvalidJson,
        };
    }
}

fn parseToolCall(backend: *Backend, slot: *Slot, value: std.json.Value) !void {
    const call = object(value) orelse return error.InvalidJson;
    const index_value = call.get("index") orelse return error.InvalidJson;
    const index = switch (index_value) {
        .integer => |number| if (number >= 0) @as(usize, @intCast(number)) else return error.InvalidJson,
        else => return error.InvalidJson,
    };
    if (index >= slot.tool_ids.len) return error.InvalidJson;
    const function_value = call.get("function") orelse return error.InvalidJson;
    const function = object(function_value) orelse return error.InvalidJson;
    const incoming_id = try optionalString(call, "id");
    const incoming_name = try optionalString(function, "name");
    if (slot.tool_ids[index] == null) {
        const id = incoming_id orelse return error.InvalidJson;
        const name = incoming_name orelse return error.InvalidJson;
        slot.tool_ids[index] = try backend.allocator.dupe(u8, id);
        errdefer {
            backend.allocator.free(slot.tool_ids[index].?);
            slot.tool_ids[index] = null;
        }
        slot.tool_names[index] = try backend.allocator.dupe(u8, name);
        backend.push(slot, .{ .tool_call_start = .{
            .call_id = try foundation.memory.SharedBuffer.initCopy(backend.allocator, id, .network),
            .name = try foundation.memory.SharedBuffer.initCopy(backend.allocator, name, .network),
        } });
    } else {
        if (incoming_id) |id| if (!std.mem.eql(u8, id, slot.tool_ids[index].?)) return error.InvalidJson;
        if (incoming_name) |name| if (!std.mem.eql(u8, name, slot.tool_names[index].?)) return error.InvalidJson;
    }
    if (try optionalString(function, "arguments")) |arguments| {
        if (arguments.len != 0) backend.push(slot, .{ .arguments_delta = try foundation.memory.SharedBuffer.initCopy(backend.allocator, arguments, .network) });
    }
}

fn closeToolCalls(backend: *Backend, slot: *Slot) !void {
    for (slot.tool_ids) |maybe_id| if (maybe_id) |id| {
        backend.push(slot, .{ .tool_call_end = .{ .call_id = try foundation.memory.SharedBuffer.initCopy(backend.allocator, id, .network) } });
    };
}

fn hasOpenToolCalls(slot: *const Slot) bool {
    for (slot.tool_ids) |id| if (id != null) return true;
    return false;
}

fn finishReason(value: []const u8) ?model.FinishReason {
    if (std.mem.eql(u8, value, "stop")) return .stop;
    if (std.mem.eql(u8, value, "tool_calls")) return .tool_calls;
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "content_filter")) return .content_filter;
    return null;
}

fn object(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => null,
    };
}

fn array(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |items| items,
        else => null,
    };
}

fn optionalString(map: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = map.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        .null => null,
        else => error.InvalidJson,
    };
}
fn errorForFailure(category: foundation.errors.ErrorCategory) domain.ErrorCode {
    return switch (category) {
        .cancelled => .cancelled,
        .timeout => .timeout,
        .resource_exhausted => .budget_exceeded,
        .protocol, .corrupted_data => .model_protocol_error,
        .unavailable => .model_unavailable,
        else => .network_error,
    };
}
fn originAllowed(url: []const u8, allowed: []const []const u8) bool {
    if (matchesOrigin(url, "http://127.0.0.1", true) or matchesOrigin(url, "http://localhost", true) or matchesOrigin(url, "http://[::1]", true)) return true;
    for (allowed) |origin| if (std.mem.startsWith(u8, origin, "https://") and matchesOrigin(url, origin, false)) return true;
    return false;
}

fn matchesOrigin(url: []const u8, origin: []const u8, allow_port: bool) bool {
    if (!std.mem.startsWith(u8, url, origin)) return false;
    if (url.len == origin.len) return true;
    return switch (url[origin.len]) {
        '/', '?', '#' => true,
        ':' => allow_port,
        else => false,
    };
}
fn encodeRequest(allocator: std.mem.Allocator, request: model.ModelRequest, model_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("model");
    try json.write(model_id);
    try json.objectField("stream");
    try json.write(true);
    try json.objectField("messages");
    try json.beginArray();
    for (request.messages) |message| {
        try json.beginObject();
        try json.objectField("role");
        try json.write(@tagName(message.role));
        try json.objectField("content");
        if (message.content.len == 1 and message.content[0] == .text) {
            try json.write(message.content[0].text);
        } else {
            try json.beginArray();
            for (message.content) |block| switch (block) {
                .text => |text| {
                    try json.beginObject();
                    try json.objectField("type");
                    try json.write("text");
                    try json.objectField("text");
                    try json.write(text);
                    try json.endObject();
                },
                .image_url => return error.ModelUnavailable,
            };
            try json.endArray();
        }
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("tools");
    try json.beginArray();
    for (request.tools) |tool_schema| {
        var schema = try std.json.parseFromSlice(std.json.Value, allocator, tool_schema.json_schema, .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        });
        defer schema.deinit();
        try json.beginObject();
        try json.objectField("type");
        try json.write("function");
        try json.objectField("function");
        try json.beginObject();
        try json.objectField("name");
        try json.write(tool_schema.name);
        try json.objectField("parameters");
        try json.write(schema.value);
        try json.endObject();
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    return out.toOwnedSlice();
}
