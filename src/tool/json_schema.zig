//! Bounded JSON parsing and the JSON Schema subset used by NAR tools.
const std = @import("std");

pub const Document = struct {
    parsed: std.json.Parsed(std.json.Value),
    pub fn deinit(self: *Document) void {
        self.parsed.deinit();
    }
    pub fn root(self: *const Document) *const std.json.Value {
        return &self.parsed.value;
    }
};
pub const Failure = struct {
    path: []u8,
    pub fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};
pub const Limits = struct { max_bytes: usize = 4 * 1024 * 1024, max_depth: usize = 64, max_nodes: usize = 100_000, max_string_bytes: usize = 1024 * 1024 };
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !Document {
    if (bytes.len > limits.max_bytes) return error.LimitExceeded;
    return .{ .parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .duplicate_field_behavior = .@"error", .allocate = .alloc_always, .max_value_len = limits.max_string_bytes }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ValueTooLong => return error.LimitExceeded,
        else => return error.InvalidJson,
    } };
}
pub const Schema = struct {
    parsed: std.json.Parsed(std.json.Value),
    pub fn deinit(self: *Schema) void {
        self.parsed.deinit();
    }
    pub fn validate(self: *const Schema, allocator: std.mem.Allocator, value: *const std.json.Value) !?Failure {
        return validateNode(allocator, &self.parsed.value, value, "$", 0);
    }
};
pub fn compile(allocator: std.mem.Allocator, bytes: []const u8) !Schema {
    const parsed = try parse(allocator, bytes, .{});
    errdefer {
        var owned = parsed;
        owned.deinit();
    }
    if (parsed.parsed.value != .object) return error.InvalidSchema;
    return .{ .parsed = parsed.parsed };
}
fn validateNode(allocator: std.mem.Allocator, schema: *const std.json.Value, value: *const std.json.Value, path: []const u8, depth: usize) !?Failure {
    if (depth > 64 or schema.* != .object) return error.InvalidSchema;
    const obj = schema.object;
    if (obj.get("type")) |kind| if (!matchesType(kind, value)) return try fail(allocator, path);
    if (obj.get("enum")) |values| {
        if (values != .array) return error.InvalidSchema;
        for (values.array.items) |*item| if (equal(item, value)) break else return try fail(allocator, path);
    }
    if (number(value)) |n| {
        if (obj.get("minimum")) |m| if (n < number(&m) orelse return error.InvalidSchema) return try fail(allocator, path);
        if (obj.get("maximum")) |m| if (n > number(&m) orelse return error.InvalidSchema) return try fail(allocator, path);
    }
    if (value.* == .string) {
        const len = std.unicode.utf8CountCodepoints(value.string) catch return try fail(allocator, path);
        if (obj.get("minLength")) |m| if (len < integer(&m) orelse return error.InvalidSchema) return try fail(allocator, path);
        if (obj.get("maxLength")) |m| if (len > integer(&m) orelse return error.InvalidSchema) return try fail(allocator, path);
    }
    if (value.* == .array) if (obj.get("items")) |items| for (value.array.items, 0..) |*item, index| {
        const child = try pathIndex(allocator, path, index);
        defer allocator.free(child);
        if (try validateNode(allocator, &items, item, child, depth + 1)) |failure| return failure;
    };
    if (value.* == .object) {
        if (obj.get("required")) |required| {
            if (required != .array) return error.InvalidSchema;
            for (required.array.items) |field| {
                if (field != .string) return error.InvalidSchema;
                if (!value.object.contains(field.string)) {
                    const child = try pathKey(allocator, path, field.string);
                    return .{ .path = child };
                }
            }
        }
        const properties = obj.get("properties");
        const additional = if (obj.get("additionalProperties")) |v| if (v == .bool) v.bool else return error.InvalidSchema else true;
        var it = value.object.iterator();
        while (it.next()) |entry| {
            const child_schema = if (properties) |p| if (p == .object) p.object.get(entry.key_ptr.*) else return error.InvalidSchema else null;
            const child = try pathKey(allocator, path, entry.key_ptr.*);
            defer allocator.free(child);
            if (child_schema) |s| {
                if (try validateNode(allocator, &s, entry.value_ptr, child, depth + 1)) |failure| return failure;
            } else if (!additional) return try fail(allocator, child);
        }
    }
    return null;
}
fn matchesType(kind: std.json.Value, value: *const std.json.Value) bool {
    if (kind == .string) return typeOne(kind.string, value);
    if (kind != .array) return false;
    for (kind.array.items) |item| if (item == .string and typeOne(item.string, value)) return true;
    return false;
}
fn typeOne(kind: []const u8, value: *const std.json.Value) bool {
    return std.mem.eql(u8, kind, "null") and value.* == .null or std.mem.eql(u8, kind, "boolean") and value.* == .bool or std.mem.eql(u8, kind, "integer") and value.* == .integer or std.mem.eql(u8, kind, "number") and (value.* == .integer or value.* == .float) or std.mem.eql(u8, kind, "string") and value.* == .string or std.mem.eql(u8, kind, "array") and value.* == .array or std.mem.eql(u8, kind, "object") and value.* == .object;
}
fn number(value: *const std.json.Value) ?f64 {
    return switch (value.*) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => null,
    };
}
fn integer(value: *const std.json.Value) ?usize {
    return if (value.* == .integer and value.integer >= 0) @intCast(value.integer) else null;
}
fn equal(a: *const std.json.Value, b: *const std.json.Value) bool {
    if (@as(std.meta.Tag(std.json.Value), a.*) != @as(std.meta.Tag(std.json.Value), b.*)) return false;
    return switch (a.*) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .string => std.mem.eql(u8, a.string, b.string),
        else => false,
    };
}
fn fail(allocator: std.mem.Allocator, path: []const u8) !Failure {
    return .{ .path = try allocator.dupe(u8, path) };
}
fn pathKey(allocator: std.mem.Allocator, path: []const u8, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, key });
}
fn pathIndex(allocator: std.mem.Allocator, path: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index });
}
