const std = @import("std");
const nar = @import("nar");

test "C ABI bootstrap check records that no C ABI is published yet" {
    try std.testing.expect(!@hasDecl(nar, "cabi"));
}
