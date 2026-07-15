# NAR 实施统一上下文

本目录将 `docs/arch.md` 收敛为可顺序执行的首版任务。实现 agent 必须完整阅读本文件和被分配的单个任务文档；二者已经包含完成该任务所需的上下文。若与架构原文的开放性建议冲突，以本文件和任务文档中的已决策约束为准。

## 1. 产品边界

NAR（Native Agent Runtime）是可嵌入游戏 Runtime、Editor、自动化测试程序和独立服务的 Zig 原生 Agent Harness，通过稳定 C ABI 暴露。它负责低频决策循环、模型抽象、结构化工具调用、权限、预算、上下文、异步操作和确定性 Trace/Replay。

首版必须交付：

- 单 Agent 的流式 Agent Loop；
- OpenAI-compatible backend 与完全确定性的 Mock backend；
- Tool Registry、JSON Schema 子集、Capability/Policy；
- Memory Session、Context Builder、Turn Budget；
- 可取消的异步 Operation、worker/main-thread executor 抽象；
- Stable ObjectRef、World Revision、资源访问声明；
- append-only Trace、Replay 与差异比较；
- Zig API、稳定 C ABI 和 C smoke test；
- 可选 spindle 调度适配，以及不依赖 spindle 的 standalone 路径。

首版明确不实现：Anthropic/Gemini/llama.cpp、WASM/WAMR、MCP、SQLite Session、长期记忆/RAG、多 Agent、远程 Agent Server、完整多模态、Gameplay 调试面板、通用 Workflow DSL。不得创建这些模块的空壳、TODO 或固定成功返回。

## 2. 技术基线与依赖

- 固定 Zig `0.16.0`；不得套用旧版标准库 API。
- 包名 `nar`，公开 Zig 入口 `src/nar.zig`，公共 C 头 `include/nar.h`。
- `deps/fund` 是 `https://github.com/in-dreaming/fund.git` 的 `main` 分支子模块。其 Zig 包位于 `deps/fund/foundation`；优先复用 error、ids/handles、buffer、cancellation、executor、HTTP/SSE、JSON、trace 等已公开能力，不复制等价基础设施。
- `deps/spindle` 是 `https://github.com/in-dreaming/spindle.git` 的 `main` 分支子模块。只允许最后阶段通过 adapter 使用其公开 `src/root.zig` 能力；NAR core 禁止导入 spindle。
- 两个子模块均应记录 branch=`main`。实现任务不得修改子模块内容或提交子模块内部工作树。
- 新增其他第三方依赖前必须证明 Zig 标准库和 fund 均不能满足，固定哈希并记录许可证；首版原则上不新增。

依赖方向固定为：

```text
cabi / examples / adapters
            |
            v
          core
     /      |      \
 model    context   tool
     \      |      /
      session/trace
            |
       foundation (fund)
```

`core` 不能反向依赖 C ABI、具体游戏系统或 spindle。Model backend 不依赖 Agent Loop；Tool callback 不获得 Runtime 裸指针。

## 3. 全局架构约束

1. LLM 只产生低频 Goal/Intent/Tool call，不进入逐帧移动、动画、碰撞或物理控制环。
2. Agent Core 不拥有游戏世界。它只消费宿主构造的 immutable snapshot、稳定句柄和 revision。
3. 所有跨帧、网络、模型和长工具操作必须显式异步、可轮询且可取消；主线程不得等待网络或 worker。
4. 动态对象使用 `{id, generation}`；每次工具执行前重新验证 generation 和可选 world revision。禁止跨 API 暴露裸指针。
5. 工具必须声明 schema、flags、capabilities、资源读写集合、线程亲和性和 revision 策略。校验顺序固定为：存在性 -> profile 可用性 -> capability/policy -> schema -> budget -> object/revision -> dispatch。
6. Shipping policy 只能收紧 build hard limit；Runtime override 不能放宽更低层限制。默认拒绝未声明 capability。
7. 每个 Turn 都有独立 arena/临时分配域；持久状态必须复制所需数据。任何借用 slice 的生命周期都要在 API 文档中写明。
8. allocator 由调用方注入；拥有资源的类型提供成对 `init/deinit`。失败、取消和 shutdown 路径不得泄漏内存、线程、operation、buffer 或 callback userdata。
9. 错误要保留稳定分类：invalid_argument、invalid_state、cancelled、timeout、budget_exceeded、model_unavailable、model_protocol_error、tool_not_found、tool_schema_error、tool_permission_denied、stale_object、stale_world_revision、operation_failed、storage_error、network_error、internal_error。
10. Pull event API 必须有明确所有权和背压行为。事件队列满时可合并低优先级 delta，但不得丢失 terminal、tool call/result、error、cancelled 事件。
11. Trace/Replay 是基础能力。持久格式使用 magic、schema version、固定 little-endian、长度和校验；不得持久化指针、allocator、函数地址、进程内 slot 或不稳定 enum ordinal。
12. Mock model/tool 必须走与生产相同的接口和状态转换。测试不能用 sleep 伪造并发或网络正确性。
13. 生产代码不得包含 TODO/FIXME、空函数、未接线分支、`unreachable` 代替正常错误处理、仅为测试通过的特殊判断或吞错。
14. 公共 API 必须有 `///` 文档，说明线程安全、所有权、生命周期、取消和错误语义。

## 4. 固定工程布局

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
adapters/standalone_executor/
adapters/spindle/
examples/minimal_agent/
examples/c_api/
tests/unit/
tests/integration/
tests/replay/
tests/fixtures/
```

可按实际内聚性合并文件，但模块边界和依赖方向不可改变。每个模块有聚合入口；跨模块只导入公开入口，禁止绕过边界引用私有实现。

## 5. 固定公开语义

- Handle 的零值无效，释放后 generation 变化；重复释放返回明确错误或幂等无害，但不能访问新对象。
- Agent 状态至少覆盖 idle、building_context、waiting_model、waiting_tool、waiting_operation、completed、failed、cancelled。Terminal 状态不可恢复；新 submit 创建新 Turn。
- Model 统一输出 start、text_delta、tool_call_start/delta/end、usage、finish、error 事件。Backend 每次请求只产生一个 terminal finish/error/cancelled。
- Tool 结果为 completed、pending(operation handle) 或 error。同步 callback 不得保留 invocation context；异步状态由 Operation Registry 持有。
- Agent Loop 的终止原因包括 final_response、cancelled、timeout、budget_exceeded、model_error、tool_error、loop_detected、internal_error。
- 相同规范化 tool name + canonical arguments 的重复调用达到配置阈值时停止，避免无界循环。
- Context 优先级为 build hard/system -> agent static -> current world snapshot -> recent working memory -> retrieved optional memory；裁剪不能删除 system 安全约束和当前工具结果。
- Replay 模式不得调用 live model 或 live tool；缺少记录时明确失败，不得回退到在线执行。

## 6. Build Profile

首版提供 `minimal` 与 `runtime`：

- `minimal`：Mock/model abstraction、Agent Loop、同步 Tool、Memory Session、Cancellation、C ABI；不编译 HTTP backend、Trace 文件 I/O、spindle adapter。
- `runtime`：在 minimal 上增加 OpenAI-compatible、异步 Operation、Capability、Trace/Replay、standalone executor。
- `-Dspindle=true`：仅编译 adapter，隐含 runtime；关闭时不能解析或链接 spindle 实现。

构建配置必须在编译期裁剪，不能只在运行时返回 unsupported。

## 7. 统一验证契约

任务 00 建立并持续维护以下入口：

```text
zig build check
zig build test
zig build test-integration
zig build test-cabi
zig build test-all
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime
zig build check -Dprofile=runtime -Dspindle=true
```

`test-all` 至少依赖 check、test、test-integration、test-cabi；spindle 专项可独立执行，直至任务 11 将其纳入可用组合。每个任务完成前必须：

1. 对 Zig 文件执行 `zig fmt` 并确认 `zig fmt --check`；
2. 运行任务专项验证；
3. 运行 `zig build test-all`；
4. 检查公开导出、依赖方向和 `git diff`；
5. 确认没有修改 `deps/fund`、`deps/spindle` 内部文件。

## 8. 任务依赖与顺序

| ID | 文档 | 直接依赖 |
|---|---|---|
| 00 | `00-bootstrap.md` | 无 |
| 01 | `01-foundation-domain.md` | 00 |
| 02 | `02-model-stream.md` | 01 |
| 03 | `03-tool-runtime.md` | 01 |
| 04 | `04-context-session-budget.md` | 01、03 |
| 05 | `05-trace-format.md` | 01 |
| 06 | `06-agent-loop.md` | 02、03、04、05 |
| 07 | `07-async-operations.md` | 06 |
| 08 | `08-openai-compatible.md` | 02、06、07 |
| 09 | `09-replay-diff.md` | 05、06、07 |
| 10 | `10-c-abi.md` | 06、07、09 |
| 11 | `11-spindle-adapter.md` | 07、10 |
| 12 | `12-runtime-acceptance.md` | 08、09、10、11 |

一个 agent 一次只实现一个任务。不得顺手开始后续任务；需要调整既有公开接口时，必须保持兼容或同步更新全部调用点和测试。

spindle 当前 durable workflow 尾部任务未完成，但本项目仅依赖 executor/task graph/resource access 的已公开稳定表面。任务 00-10 不得因 spindle 状态阻塞。任务 11 若发现所需公开接口确实不存在，应把 adapter 限定到已存在能力并保留 standalone 后备路径；不得修改 spindle、不得依赖 workflow、不得制造空适配器。

## 9. 完成定义

“完成”要求真实行为而非文件存在：正常、错误、取消、超时、预算耗尽、shutdown、队列背压和 stale handle 路径均有测试；模型和 Tool 循环可确定性复现；Replay 能证明没有调用 live backend；C 调用方能创建 Runtime、注册 Tool、提交 Turn、轮询事件、取消和释放；Windows 当前环境测试通过，代码对 Linux/macOS 无平台硬编码并可交叉编译时至少完成编译检查。
