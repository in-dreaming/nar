const std = @import("std");
const spindle = @import("spindle");
const nar = @import("nar");

test "NAR profile and spindle features agree" {
    try std.testing.expectEqual(nar.hasRuntimeSupport(), spindle.runtime.Features.task_graph);
    try std.testing.expectEqual(nar.hasRuntimeSupport(), spindle.runtime.Features.resource_graph);
    try std.testing.expect(!spindle.runtime.Features.ecs);
    try std.testing.expect(!spindle.runtime.Features.workflow);
    try std.testing.expect(!spindle.runtime.Features.workflow_sqlite);
    try std.testing.expect(!spindle.runtime.Features.workflow_archive);
    try std.testing.expect(!spindle.runtime.Features.workflow_archive_http);
    try std.testing.expectEqual(nar.hasRuntimeSupport(), @hasDecl(nar.openai, "Backend"));
    if (!nar.hasRuntimeSupport()) {
        var host = try nar.spindle.TestHost.init(std.testing.allocator, 2);
        defer host.deinit();
        try std.testing.expectEqual(@as(usize, 1), host.runtime().config.services.compute.workerCount());
        try std.testing.expectEqual(@as(usize, 0), host.runtime().config.services.blocking.workerCount());
    }
}
