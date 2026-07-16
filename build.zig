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
        .name = "nar-minimal-agent-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/minimal_agent/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const script_backend = b.createModule(.{
        .root_source_file = b.path("examples/script_backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    script_backend.addImport("nar", nar);
    script_backend.addImport("foundation", foundation);
    consumer.root_module.addImport("nar", nar);
    consumer.root_module.addImport("foundation", foundation);
    consumer.root_module.addImport("script_backend", script_backend);

    const runtime_example = if (profile == .runtime) b.addExecutable(.{
        .name = "nar-runtime-agent-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/runtime_agent/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }) else null;
    if (runtime_example) |example| {
        example.root_module.addImport("nar", nar);
        example.root_module.addImport("foundation", foundation);
        example.root_module.addImport("script_backend", script_backend);
    }

    const c_example = b.addExecutable(.{
        .name = "nar-c-api-example",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    c_example.root_module.addCSourceFile(.{ .file = b.path("examples/c_api/main.c"), .flags = &.{"-std=c11"} });
    c_example.root_module.addIncludePath(b.path("include"));
    c_example.root_module.linkLibrary(static_library);
    c_example.root_module.link_libc = true;

    const cpp_header_check = b.addExecutable(.{
        .name = "nar-cpp-header-check",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    cpp_header_check.root_module.addCSourceFile(.{ .file = b.path("examples/c_api/header_check.cpp"), .flags = &.{"-std=c++17"} });
    cpp_header_check.root_module.addIncludePath(b.path("include"));
    cpp_header_check.root_module.linkLibrary(static_library);
    cpp_header_check.root_module.link_libcpp = true;

    const check = b.step("check", "Compile NAR and its external Zig consumer");
    check.dependOn(&static_library.step);
    check.dependOn(&consumer.step);
    check.dependOn(&c_example.step);
    check.dependOn(&cpp_header_check.step);
    if (runtime_example) |example| check.dependOn(&example.step);
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
    if (profile == .runtime) {
        const runtime_acceptance_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration/runtime_acceptance.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        runtime_acceptance_tests.root_module.addImport("nar", nar);
        runtime_acceptance_tests.root_module.addImport("foundation", foundation);
        runtime_acceptance_tests.root_module.addImport("spindle", spindle);
        runtime_acceptance_tests.root_module.addImport("script_backend", script_backend);
        integration.dependOn(&b.addRunArtifact(runtime_acceptance_tests).step);
    }

    const cabi_bootstrap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cabi/bootstrap_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cabi_bootstrap_tests.root_module.addImport("nar", nar);
    cabi_bootstrap_tests.root_module.addImport("foundation", foundation);
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
    inline for (.{ Profile.minimal, Profile.runtime }) |matrix_profile| {
        const matrix_foundation_dependency = b.dependency("foundation", .{
            .profile = if (matrix_profile == .runtime) "agent" else "core",
            .http = matrix_profile == .runtime,
            .testing = true,
        });
        const matrix_foundation = matrix_foundation_dependency.module("foundation");
        const matrix_spindle = b.dependency("spindle", .{
            .@"task-graph" = matrix_profile == .runtime,
            .@"resource-graph" = matrix_profile == .runtime,
            .ecs = false,
            .workflow = false,
            .@"workflow-sqlite" = false,
            .@"workflow-archive" = false,
            .@"workflow-archive-http" = false,
        }).module("spindle");
        const matrix_options = b.addOptions();
        matrix_options.addOption(Profile, "profile", matrix_profile);
        matrix_options.addOption(bool, "runtime", matrix_profile == .runtime);
        matrix_options.addOption(bool, "spindle", true);
        const matrix_nar = b.createModule(.{
            .root_source_file = b.path("src/nar.zig"),
            .target = target,
            .optimize = optimize,
        });
        matrix_nar.addImport("foundation", matrix_foundation);
        matrix_nar.addImport("spindle", matrix_spindle);
        matrix_nar.addOptions("nar_build_options", matrix_options);
        const matrix_test = b.addTest(.{
            .name = b.fmt("nar-feature-{s}", .{@tagName(matrix_profile)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration/spindle_dependency.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        matrix_test.root_module.addImport("nar", matrix_nar);
        matrix_test.root_module.addImport("spindle", matrix_spindle);
        feature_matrix.dependOn(&b.addRunArtifact(matrix_test).step);
    }

    const all = b.step("test-all", "Run all bootstrap validation suites");
    all.dependOn(check);
    all.dependOn(test_step);
    all.dependOn(integration);
    all.dependOn(cabi);
    all.dependOn(feature_matrix);
    all.dependOn(&b.addRunArtifact(consumer).step);
    all.dependOn(&b.addRunArtifact(c_example).step);
    all.dependOn(&b.addRunArtifact(cpp_header_check).step);
    if (runtime_example) |example| all.dependOn(&b.addRunArtifact(example).step);

    const release_check = b.step("release-check", "Run tests, examples, and C/C++ public header checks");
    release_check.dependOn(all);
    const release_hygiene = b.addSystemCommand(&.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" });
    release_hygiene.addFileArg(b.path("tools/release_check.ps1"));
    release_check.dependOn(&release_hygiene.step);
}
