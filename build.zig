const std = @import("std");

const Profile = enum {
    minimal,
    runtime,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(Profile, "profile", "NAR profile: minimal or runtime") orelse .runtime;

    const options = b.addOptions();
    options.addOption(Profile, "profile", profile);
    options.addOption(bool, "runtime", profile == .runtime);
    options.addOption(bool, "spindle", true);

    const foundation_dependency = b.dependency("foundation", .{
        .profile = if (profile == .runtime) "agent" else "core",
        .http = profile == .runtime,
        .testing = true,
    });
    const foundation = foundation_dependency.module("foundation");
    const spindle = b.dependency("spindle", .{
        .@"task-graph" = profile == .runtime,
        .@"resource-graph" = profile == .runtime,
        .ecs = false,
        .workflow = false,
        .@"workflow-sqlite" = false,
        .@"workflow-archive" = false,
        .@"workflow-archive-http" = false,
    }).module("spindle");
    const nar = b.addModule("nar", .{
        .root_source_file = b.path("src/nar.zig"),
        .target = target,
        .optimize = optimize,
    });
    nar.addImport("foundation", foundation);
    nar.addImport("spindle", spindle);
    nar.addOptions("nar_build_options", options);

    const static_library = b.addLibrary(.{
        .name = "nar",
        .linkage = .static,
        .root_module = nar,
    });
    b.installArtifact(static_library);
    const install_header = b.addInstallHeaderFile(b.path("include/nar.h"), "nar.h");
    b.getInstallStep().dependOn(&install_header.step);

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
    unit_tests.root_module.addImport("spindle", spindle);
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
    if (profile == .runtime and target.result.os.tag == .windows) {
        const openai_http_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration/openai_http.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        openai_http_tests.root_module.addImport("nar", nar);
        openai_http_tests.root_module.addImport("foundation", foundation);
        openai_http_tests.root_module.addImport("curl_adapter", foundation_dependency.module("curl_adapter"));
        const fixture_options = b.addOptions();
        fixture_options.addOptionPath("server_script", b.path("tests/fixtures/openai_server.ps1"));
        fixture_options.addOptionPath("curl_library", foundation_dependency.path("third_party/curl/windows-x64/bin/libcurl-x64.dll"));
        openai_http_tests.root_module.addOptions("build_options", fixture_options);
        integration.dependOn(&b.addRunArtifact(openai_http_tests).step);
    }

    const cabi_bootstrap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cabi/bootstrap_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cabi_bootstrap_tests.root_module.addImport("nar", nar);
    cabi_bootstrap_tests.root_module.addIncludePath(b.path("include"));
    const cabi = b.step("test-cabi", "Run C ABI ownership and header contract checks");
    cabi.dependOn(&b.addRunArtifact(cabi_bootstrap_tests).step);

    const feature_matrix_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/spindle_dependency.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    feature_matrix_tests.root_module.addImport("nar", nar);
    feature_matrix_tests.root_module.addImport("spindle", spindle);
    const feature_matrix = b.step("test-feature-matrix", "Validate NAR and spindle feature profile agreement");
    feature_matrix.dependOn(&b.addRunArtifact(feature_matrix_tests).step);

    const all = b.step("test-all", "Run all bootstrap validation suites");
    all.dependOn(check);
    all.dependOn(test_step);
    all.dependOn(integration);
    all.dependOn(cabi);
    all.dependOn(feature_matrix);
}
