const std = @import("std");

const Profile = enum {
    minimal,
    runtime,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(Profile, "profile", "NAR profile: minimal or runtime") orelse .runtime;
    const spindle_enabled = b.option(bool, "spindle", "Compile the optional spindle integration checks") orelse false;
    const configuration_failure = if (spindle_enabled and profile != .runtime)
        b.addFail("-Dspindle=true requires -Dprofile=runtime")
    else
        null;

    const options = b.addOptions();
    options.addOption(Profile, "profile", profile);
    options.addOption(bool, "runtime", profile == .runtime);
    options.addOption(bool, "spindle", spindle_enabled);

    const foundation = b.dependency("foundation", .{}).module("foundation");
    const nar = b.addModule("nar", .{
        .root_source_file = b.path("src/nar.zig"),
        .target = target,
        .optimize = optimize,
    });
    nar.addImport("foundation", foundation);
    nar.addOptions("nar_build_options", options);

    const static_library = b.addLibrary(.{
        .name = "nar",
        .linkage = .static,
        .root_module = nar,
    });
    b.installArtifact(static_library);

    const shared_library = if (profile == .runtime)
        b.addLibrary(.{
            .name = "nar",
            .linkage = .dynamic,
            .root_module = nar,
        })
    else
        null;
    if (shared_library) |library| b.installArtifact(library);

    const consumer = b.addExecutable(.{
        .name = "nar-consumer-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/minimal_agent/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    consumer.root_module.addImport("nar", nar);

    const check = b.step("check", "Compile NAR and its external Zig consumer");
    check.dependOn(&static_library.step);
    check.dependOn(&consumer.step);
    if (shared_library) |library| check.dependOn(&library.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/bootstrap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("nar", nar);
    unit_tests.root_module.addImport("foundation", foundation);
    const test_step = b.step("test", "Run bootstrap unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/consumer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.root_module.addImport("nar", nar);
    const integration = b.step("test-integration", "Run external Zig consumer integration tests");
    integration.dependOn(&b.addRunArtifact(integration_tests).step);

    const cabi_bootstrap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cabi/bootstrap_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cabi_bootstrap_tests.root_module.addImport("nar", nar);
    const cabi = b.step("test-cabi", "Run the temporary bootstrap check before the C ABI is introduced");
    cabi.dependOn(&b.addRunArtifact(cabi_bootstrap_tests).step);

    if (spindle_enabled and profile == .runtime) {
        const spindle = b.lazyDependency("spindle", .{}) orelse @panic("spindle dependency is unavailable; initialize submodules");
        const spindle_consumer = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration/spindle_dependency.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        spindle_consumer.root_module.addImport("spindle", spindle.module("spindle"));
        check.dependOn(&spindle_consumer.step);
    }

    const all = b.step("test-all", "Run all bootstrap validation suites");
    all.dependOn(check);
    all.dependOn(test_step);
    all.dependOn(integration);
    all.dependOn(cabi);

    if (configuration_failure) |failure| {
        b.getInstallStep().dependOn(&failure.step);
        check.dependOn(&failure.step);
        test_step.dependOn(&failure.step);
        integration.dependOn(&failure.step);
        cabi.dependOn(&failure.step);
    }
}
