//! Native Agent Runtime public Zig module.
//!
//! This bootstrap surface intentionally exposes only build configuration. Agent
//! behavior and C ABI entry points are added by their dedicated tasks.

const foundation = @import("foundation");

/// Build-time configuration selected by the package consumer.
/// Reading this value is thread-safe and has no ownership or lifetime concerns.
pub const build_options = @import("nar_build_options");

/// NAR build profile. `minimal` excludes runtime-only integrations; `runtime`
/// permits them when their corresponding build options are enabled.
pub const Profile = @TypeOf(build_options.profile);

/// Returns the selected build profile without initializing runtime state.
pub fn profile() Profile {
    return build_options.profile;
}

/// Reports whether this build was compiled with the runtime profile.
pub fn hasRuntimeSupport() bool {
    return build_options.runtime;
}

comptime {
    _ = foundation;
}
