//! Native Agent Runtime public Zig module.
//!
//! This bootstrap surface intentionally exposes only build configuration. Agent
//! behavior and C ABI entry points are added by their dedicated tasks.

const foundation = @import("foundation");

/// Stable foundation domain types used by all NAR subsystems.
pub const domain = @import("foundation/domain.zig");
pub const ErrorCode = domain.ErrorCode;
pub const Error = domain.Error;
pub const RuntimeId = domain.RuntimeId;
pub const AgentId = domain.AgentId;
pub const TurnId = domain.TurnId;
pub const ToolId = domain.ToolId;
pub const OperationId = domain.OperationId;
pub const ObjectRef = domain.ObjectRef;
pub const WorldRevision = domain.WorldRevision;
pub const AgentEvent = domain.AgentEvent;
pub const EventMailbox = domain.EventMailbox;
pub const EventPriority = domain.EventPriority;
pub const CancellationSource = domain.CancellationSource;
pub const CancellationToken = domain.CancellationToken;
pub const CancelReason = domain.CancelReason;
pub const GenerationalRegistry = domain.GenerationalRegistry;

/// Streaming model backend contracts, router, and deterministic mock backend.
pub const model = @import("model/model.zig");

/// Tool registry, JSON Schema validation, policy enforcement, and dispatch.
pub const tool = @import("tool/runtime.zig");

/// Owned context assembly, working-memory session, deterministic tool visibility, and turn budgets.
pub const context = @import("context/runtime.zig");

/// Append-only, checksummed turn trace encoding and bounded reader.
pub const trace = @import("trace/runtime.zig");

/// Bounded deterministic runtime, agent, and turn state machine.
pub const core = @import("core/agent_loop.zig");

/// Spindle-backed production and deterministic test hosts. A host owns its
/// Spindle runtime while `core.Runtime` only borrows the exposed services.
pub const spindle = @import("adapters/spindle/host.zig");

/// Host-owned asynchronous operation registry and executor affinity contracts.
pub const operation = @import("runtime/operation.zig");

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
