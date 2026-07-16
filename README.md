# NAR

NAR is a Zig-native agent harness for runtimes, editors, automation tools, and
standalone services. It provides a pull-driven single-agent loop, model and
tool contracts, bounded context/session state, Spindle-backed asynchronous
operations, deterministic trace/replay, an OpenAI-compatible backend, and a
stable C11 ABI.

## Requirements

- Zig `0.16.0`
- Initialized `deps/fund` and `deps/spindle` submodules

```powershell
git submodule update --init --recursive
zig build test-all
```

Runnable examples are part of `test-all`. Their sources are:

- `examples/minimal_agent`: query, synchronous tool, final response
- `examples/runtime_agent`: compute operation, caller-pumped confirmation,
  final response, finite staged shutdown
- `examples/c_api`: C11 ownership and pump setup; `header_check.cpp` verifies
  the same header from C++17

## Architecture

```text
C ABI / examples
       |
       v
Spindle Host ----> Spindle public runtime
       |
       v
Agent core
  |-- model / OpenAI-compatible HTTP-SSE
  |-- context / memory session / turn budget
  |-- tool policy / JSON Schema / operations
  `-- trace / replay / diff
       |
       v
fund foundation
```

`nar.spindle.Host` owns address-stable `std.Io.Threaded`, Spindle Runtime,
operation registry, incremental resource coordinator, and NAR Runtime state. `core.Runtime` borrows its execution
services and must be destroyed first. Call `Host.shutdown(deadline)` to reject
new work, cancel turns and operations, and request Spindle staged shutdown;
then call `Host.deinit()`. `deinit` performs an unbounded convergence shutdown
when a finite attempt reported a timeout.

`nar.spindle.TestHost` owns no threads. It uses a virtual clock, deterministic
compute executor, inline blocking executor, and caller-driven pump. It is the
minimal profile host and the deterministic test host.

## Profiles

| Capability | `minimal` | `runtime` |
|---|---:|---:|
| Mock/model, tools, agent loop, memory session | yes | yes |
| C ABI and in-memory trace | yes | yes |
| Worker threads / aggregate production host | no | yes |
| OpenAI-compatible HTTP/SSE | no | yes |
| Spindle task graph / resource graph | no | yes |
| ECS / workflow / SQLite / archive | no | no |

Spindle is always a dependency; there is no `-Dspindle` switch. Build profile
features are passed explicitly so future dependency defaults cannot change the
NAR product.

```powershell
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime
zig build test-feature-matrix
zig build release-check
```

## Threading And Pumping

Agent `tick` performs one bounded action and never pumps main-thread work.
Network requests, compute work, blocking work, and persistent operations are
pollable and cancellable. A host must call `pumpMainThread(max_jobs,
max_nanos)` at a suitable frame or event-loop boundary. C tools declared
`NAR_THREAD_MAIN` are queued to this pump; their callback is not invoked before
the caller pumps.

Operation identities are generation checked. Terminal results remain owned by
the registry until observed and released. Late completion after cancellation,
timeout, release, or owner destruction is rejected, and transferred buffers
are still consumed exactly once.

Runtime resource operations map their complete key, range, access mode, and
version constraint to Spindle's incremental scheduler. Conflicting operations
remain ordered across agents and turns; version mismatch is rejected before
the operation callback. Minimal builds reject resource-scheduled operations.

## C ABI

Include `include/nar.h` from C11 or C++. The current breaking ABI version is
`NAR_API_VERSION == 2`. Handles are opaque `uint64_t` values;
zero is invalid. Every input structure starts with `struct_size` and
`api_version`. NAR-owned output uses `nar_buffer`; always call
`nar_buffer_release`, including for events ignored by the application.

`nar_runtime_create` creates either the no-thread minimal owner or the runtime
owner. `nar_replay_runtime_create` validates and copies an offline trace, then
registers the fixed replay route `provider_id="replay", model_id="replay"`.
Replay creation rejects corrupt, truncated, or non-terminal streams.

Destroy agents and unregister tools before runtime destruction when practical.
`nar_runtime_destroy` is nevertheless the final owner: it rejects new users,
waits for in-flight ABI calls, cancels active work, releases callback state,
and invalidates all child handles.

ABI v2 uses fixed-width lengths and counts. Runtime policy fields form the
capability ceiling; each agent supplies its own capabilities, and
`allowed_tools` is an execution ACL rather than prompt-only metadata. Optional
dispatch and resource-version callbacks borrow their arguments only for the
callback and must not retain them.

## Safety Defaults

Tool dispatch validation order is existence, profile, capability/policy, JSON
Schema, budget, object/revision, resource mapping, then callback. Tool and model
streams are bounded; terminal mailbox events are not silently dropped. Runtime
configuration rejects oversized capacities and worker counts before allocation.
No public API exposes a borrowed world pointer or an executor task address.

The OpenAI-compatible backend parses SSE incrementally. Connect, first-byte,
and overall deadlines are independent; deltas become pollable before the HTTP
terminal response, and consumer backpressure aborts with a bounded error rather
than accumulating an unbounded response body.

Trace files use `NARTRACE`, explicit little-endian fields, versioned records,
monotonic sequence numbers, lengths, and checksums. Payloads are canonical JSON.
Replay validates the complete stream before use and never falls back to a live
model or HTTP backend when a record is absent. Tool argument trace policy is
redact, hash, or omit.

## Known Limits

The first release supports one agent loop per agent and memory-backed sessions.
It does not provide durable sessions, MCP, RAG, multi-agent orchestration,
WASM, a remote agent server, Anthropic/Gemini/llama.cpp backends, ECS, or
durable workflow integration. Semantic replay permits model text chunking
differences; strict replay requires exact canonical request and event payloads.
