const std = @import("std");
const nar = @import("nar");

comptime {
    _ = @import("foundation_domain.zig");
    _ = @import("model_stream.zig");
    _ = @import("tool_runtime.zig");
    _ = @import("context_session_budget.zig");
    _ = @import("trace_format.zig");
    _ = @import("agent_loop.zig");
    _ = @import("spindle_runtime.zig");
    _ = @import("async_operations.zig");
}

test "public build configuration is internally consistent" {
    try std.testing.expect(nar.profile() == nar.build_options.profile);
    try std.testing.expectEqual(nar.hasRuntimeSupport(), nar.build_options.runtime);
}
