const std = @import("std");
const nar = @import("nar");

test "external consumer imports the public nar module" {
    try std.testing.expect(@TypeOf(nar.profile()) == nar.Profile);
}
