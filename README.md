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

`-Dspindle=true` requires `-Dprofile=runtime`; it resolves the local spindle
submodule only for its compile-time integration check. NAR core does not import
spindle.

## Current scope

This bootstrap provides the `nar` Zig package entry point, profile selection,
and validation steps. Agent execution, tools, model backends, trace/replay, and
the C ABI are intentionally not implemented yet.
