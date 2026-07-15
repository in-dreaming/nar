const spindle = @import("spindle");

test "optional spindle dependency has a public module root" {
    _ = spindle.executor;
}
