# NAR

NAR (Native Agent Runtime) is a Zig-native agent harness intended for embedding
in runtimes, editors, automation tools, and standalone services. It will expose
a stable C ABI in a later implementation stage.

## Requirements

- Zig `0.16.0`
- Initialized submodules:

```powershell
git submodule update --init --recursive
```

## Build profiles

`runtime` is the default profile. It produces the static `nar` library and a
shared library. `minimal` produces only the static library.

```powershell
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime
zig build check -Dprofile=runtime -Dspindle=true
zig build test-all
```

Both profiles use Spindle's executor/runtime primitives. `minimal` disables
task graph, resource graph, ECS, workflow, SQLite, and archive features;
`runtime` enables only task and resource graphs. `nar.spindle.Host` owns a
threaded Spindle runtime and exposes borrowed services to `core.Runtime`.
Call `Host.shutdown(deadline)` before `Host.deinit()` to cancel active turns
and perform Spindle's staged shutdown. `nar.spindle.TestHost` provides a
virtual-clock, caller-pumped deterministic host for tests.

## Current scope

This bootstrap provides the `nar` Zig package entry point, profile selection,
and validation steps. Agent execution, tools, model backends, trace/replay, and
the C ABI are intentionally not implemented yet.
