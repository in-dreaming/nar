# NAR 实施统一上下文

本目录将 `docs/arch.md` 收敛为可顺序执行的首版任务。实现 agent 必须完整阅读本文件和被分配的单个任务文档。若与架构原文的开放性建议或已完成任务文档冲突，以本文件和当前任务文档为准。

## 1. 当前基线

- 已完成并提交任务 00-06：工程骨架、基础领域类型、Model/Mock、Tool Runtime、Context/Session/Budget、Trace 格式、同步 Agent Loop。
- 当前 HEAD 之后的第一项工作是任务 07；不得重做或改写 00-06 的历史提交。任务 07 被授权破坏性调整它们建立的公开 API 和实现。
- 固定 Zig `0.16.0`，包名 `nar`，公开 Zig 入口 `src/nar.zig`，公共 C 头 `include/nar.h`。
- `deps/fund` 固定为 `https://github.com/in-dreaming/fund.git` main。其 Zig 包位于 `deps/fund/foundation`，负责公共 memory/buffer、JSON/schema、HTTP/SSE 等基础能力。
- `deps/spindle` 固定为 `https://github.com/in-dreaming/spindle.git` main，当前基线 `2a1f5e074fcc4c63a61e4b7437c288a2db9bb24b` 或更新的显式提交。它已经完成开发并提供稳定 aggregate Runtime、Clock、Executor、Pump、Task Graph、Resource Graph、observability 和 staged shutdown。
- 不得修改两个子模块内部文件；只更新父仓库记录的 gitlink。

## 2. 产品边界

NAR 是可嵌入游戏 Runtime、Editor、自动化测试程序和独立服务的 Zig 原生 Agent Harness，通过稳定 C ABI 暴露。它负责低频决策循环、模型抽象、结构化工具调用、权限、预算、上下文、异步操作和确定性 Trace/Replay。

首版交付：

- 单 Agent 流式 Agent Loop；
- OpenAI-compatible 与确定性 Mock backend；
- Tool Registry、JSON Schema 子集、Capability/Policy；
- Memory Session、Context Builder、Turn Budget；
- spindle 驱动的 compute/blocking/pump execution 与异步 Operation；
- Stable ObjectRef、World Revision、ResourceAccess 到 spindle Resource Graph 的无损映射；
- append-only Trace、Replay 与差异比较；
- Zig API、稳定 C ABI、C/C++ smoke test；
- minimal/runtime 两个真正裁剪的 profile。

首版不实现 Anthropic/Gemini/llama.cpp、WASM/WAMR、MCP、SQLite Session、长期记忆/RAG、多 Agent、远程 Agent Server、完整多模态、Gameplay 调试面板或通用 Workflow DSL。spindle 的 ECS 和 Durable Workflow 已完成，但 NAR 首版不依赖它们，不创建空入口。

## 3. 依赖与所有权决策

依赖方向：

```text
cabi / examples
      |
      v
spindle_host ----> spindle public root
      |
      v
    core
 /    |     \
model context tool
 \    |     /
 session/trace
      |
 fund/foundation
```

已决策约束：

1. 不再维护 NAR 自研 Executor、线程池、Pump、Clock、detached tracker、task graph 或 resource scheduler。相关能力直接使用 spindle 公共 API。
2. NAR core 不创建 spindle 私有对象，也不导入 `deps/spindle/src/zruntime/**`；只通过 `@import("spindle")` 的公开类型和一个 `ExecutionServices`/host boundary 使用它。
3. Zig host 拥有 `std.Io`、`spindle.runtime.Runtime` 和 NAR Runtime。NAR Runtime 默认借用 host services，不能比 spindle Runtime 活得更久。
4. C ABI wrapper 可以拥有 `std.Io.Threaded`、spindle Runtime 和 NAR Runtime，但必须使用地址稳定分配和严格逆序 shutdown/deinit。
5. runtime profile 的 spindle features 固定为 `task-graph=true`、`resource-graph=true`、`ecs=false`、`workflow=false`、所有 workflow persistence/archive feature=false。
6. minimal profile 仍依赖 spindle 的 core/executor 类型，但设置 `task-graph=false`、`resource-graph=false`、`ecs=false`、`workflow=false`；不得启动 worker、I/O 线程或 aggregate Runtime。使用 Inline/Deterministic 或调用方驱动执行。
7. 删除 `-Dspindle` 开关和 standalone executor 产品路径。spindle 是基础依赖，不再是可选集成。
8. fund cancellation 可以保留为 NAR 对外带 reason 的 Turn/Operation 取消契约；提交到 spindle 的 Task 还必须同步取消其 Task state。不得复制第三套 cancellation。
9. ResourceAccess 必须映射为 spindle `ResourceKey`、`ResourceRange`、`AccessMode`、`VersionConstraint`。无法无损表达的访问返回明确错误，禁止扩大为 whole write。
10. NAR 不使用 spindle Durable Workflow 保存 Session 或 Turn。Agent 决策循环不是 durable workflow；持久 Session 属于未来独立任务。

## 4. 全局运行时约束

1. LLM 只产生低频 Goal/Intent/Tool call，不进入逐帧控制环。
2. Agent Core 不拥有游戏世界，只消费 immutable snapshot、稳定句柄和 revision。
3. 网络、模型、跨帧工具和持久操作必须显式异步、可轮询、可取消；主线程不得等待 worker 或网络。
4. 动态对象使用 `{id,generation}`，每次 dispatch 前重新验证 generation 和 revision；禁止裸指针跨 API。
5. 工具校验顺序固定：存在性 -> profile -> capability/policy -> schema -> budget -> object/revision -> resource mapping -> dispatch。
6. MainThread tool 只提交到 spindle Pump executor，并由宿主显式 pump。compute/blocking worker 不能执行 main-thread callback。
7. Runtime shutdown 使用 spindle staged shutdown 的单一 monotonic deadline。先拒绝新 Turn/Operation，再取消 pending，等待 running 协作收敛；不得强杀线程。
8. Pull event API 有明确所有权与背压。不得丢失 terminal、tool call/result、error、cancelled 和 operation terminal。
9. 每个 Turn 使用独立临时分配域；持久状态显式复制。allocator 由调用方注入，拥有资源的类型成对 init/deinit。
10. 稳定 ErrorCode 数值只能追加。错误保留 retryable/model-visible/security-sensitive 元数据。
11. Trace/Replay 格式使用 magic、version、little-endian、length、checksum，不持久化指针、函数地址、进程 slot 或不稳定 enum ordinal。
12. Replay 模式不得调用 live model、tool 或 executor callback；缺 record 明确失败。
13. 生产代码不得有 TODO/FIXME、空实现、固定成功返回、睡眠模拟并发、吞错或仅为测试通过的分支。
14. 公共 API 用 `///` 写明线程安全、所有权、生命周期、取消、错误和 host shutdown 顺序。

## 5. 固定公开语义

- Agent 状态：idle、building_context、waiting_model、waiting_tool、waiting_operation、completed、failed、cancelled。
- Model 事件：start、text_delta、tool_call_start/delta/end、usage、finish、error/cancelled；每请求唯一 terminal。
- Tool callback 返回 completed、pending OperationId 或 typed error；同步 callback 不保留 invocation context。
- Operation 状态：pending、queued、running、completed、failed、cancelled、timed_out；terminal 单向且唯一。
- Agent Loop 每次 tick 做有界工作。Main-thread pump 是宿主显式 API，不由 tick 隐式执行。
- 相同 canonical tool call 按配置次数检测循环；不同工具不共享计数。
- Context 裁剪永不删除 system 安全约束和当前工具结果。

## 6. 工程布局

```text
build.zig
build.zig.zon
include/nar.h
src/nar.zig
src/foundation/
src/core/
src/model/backends/
src/tool/
src/context/
src/session/
src/trace/
src/cabi/
src/runtime/
adapters/spindle/
examples/minimal_agent/
examples/runtime_agent/
examples/c_api/
tests/unit/
tests/integration/
tests/replay/
tests/fixtures/
```

可按内聚性合并文件，但不能逆转依赖方向。跨模块只导入公开聚合入口。

## 7. Build Profile 与 feature

- `minimal`：fund + spindle core/executor 类型、Mock/model abstraction、同步 Tool、Agent Loop、Memory Session、Trace memory sink、C ABI；不启用 task/resource graph、HTTP、文件 Trace 或任何线程。
- `runtime`（默认）：启用 spindle task/resource graph、aggregate Runtime host、OpenAI-compatible、异步 Operation、Trace file/Replay。
- 删除 `-Dspindle`。任何代码和任务文档不得继续测试 `-Dspindle=true/false`。
- NAR 构建必须显式向 spindle dependency 传递所有 feature 值，不能依赖 spindle 默认值，防止未来默认变更改变产物。

统一命令：

```text
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime
zig build test
zig build test-integration
zig build test-cabi
zig build test-feature-matrix
zig build test-all
```

`test-feature-matrix` 必须以编译/符号检查证明 minimal 未启用 task_graph、resource_graph、workflow、HTTP 和 worker 初始化；runtime 启用 task/resource graph 但不启用 ECS/workflow/SQLite/archive。

## 8. 当前任务顺序

| ID | 文档 | 直接依赖 | 状态 |
|---|---|---|---|
| 00 | `00-bootstrap.md` | 无 | 已完成，历史参考 |
| 01 | `01-foundation-domain.md` | 00 | 已完成，任务 07 会破坏性迁移部分契约 |
| 02 | `02-model-stream.md` | 01 | 已完成 |
| 03 | `03-tool-runtime.md` | 01 | 已完成 |
| 04 | `04-context-session-budget.md` | 01、03 | 已完成，任务 07 会迁移 Clock/Runtime 接线 |
| 05 | `05-trace-format.md` | 01 | 已完成 |
| 06 | `06-agent-loop.md` | 02、03、04、05 | 已完成，任务 07 会改 Runtime ownership |
| 07 | `07-spindle-runtime-migration.md` | 00-06、spindle 2a1f5e0+ | 待执行 |
| 08 | `08-async-operations.md` | 07 | 待执行 |
| 09 | `09-openai-compatible.md` | 08 | 待执行 |
| 10 | `10-replay-diff.md` | 08、09 | 待执行 |
| 11 | `11-c-abi.md` | 07、08、10 | 待执行 |
| 12 | `12-runtime-acceptance.md` | 09、10、11 | 待执行 |

一个 agent 一次只实现一个任务。任务 07 被明确授权删除或重命名 00-06 的旧公开 API；之后的任务不得保留兼容 shim，除非当前任务明确要求。

## 9. 每任务完成定义

1. 运行 `zig fmt` 与 `zig fmt --check`。
2. 运行任务专项命令和 `zig build test-all`。
3. 检查所有公开导出和 feature boundary。
4. 检查 `git diff --check`，确认子模块内部 clean。
5. 正常、错误、取消、超时、资源耗尽、shutdown、背压、stale handle 和竞态按任务风险有真实测试。
6. commit subject 精确为 `<task-id> done`；未通过不得提交成功标记。
