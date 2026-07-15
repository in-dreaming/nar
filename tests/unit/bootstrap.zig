const std = @import("std");
const nar = @import("nar");

comptime {
    _ = @import("foundation_domain.zig");
}

test "public build configuration is internally consistent" {
    try std.testing.expect(nar.profile() == nar.build_options.profile);
    try std.testing.expectEqual(nar.hasRuntimeSupport(), nar.build_options.runtime);
}
