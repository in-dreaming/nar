# NAR Architecture V2

## 面向 Native 应用与游戏引擎的可嵌入 Agent Runtime

**文档状态：** Proposed / Implementation Convergence Draft  
**基线日期：** 2026-07-24  
**目标仓库：** NAR  
**目标语言：** Zig，稳定 C ABI  
**目标平台：** Windows / Linux / macOS；后续支持 Android / iOS / Console  
**适用范围：** 游戏 Runtime、Editor、自动化测试程序、原生桌面应用、独立服务器  
**与 `arch.md` 的关系：** 本文保留原架构的产品定位和 native-first 原则，进一步收敛为可落地的模块边界、状态机、数据契约和迁移计划。本文成为稳定实现依据后，可逐步替代 `arch.md` 中与实现细节相关的章节。

---

# 0. 摘要

NAR V2 的核心定位是：

> 一个 pull-driven、Host-owned、policy-constrained 的原生 Agent 执行内核。

NAR 不负责接管游戏世界、Gameplay 执行、文件系统、网络权限、UI、存储或平台线程；这些能力属于宿主应用。NAR 负责把模型、上下文、工具、技能、会话和策略组织为可取消、可预算、可观测、可恢复、可回放的 Turn 状态机。

V2 不把 NAR 改造成 Pi、Claude Code 或通用工作流框架。V2 只吸收其中经过验证的基础框架经验，并重新适配 native 应用的约束：

- 从 Pi 吸收模型层与 Agent 层分离、渐进式 Skill 加载、steer/follow-up 输入队列、多 Tool Call、typed hook、append-only durable session 等思想；
- 从 Claude Code 的分析材料吸收分层 Prompt、静态与动态 section、缓存边界、专项 Prompt、Memory 索引与按需加载等工程方法；
- 保留并强化 NAR 已有的 `tick`、caller-owned main-thread pump、generation-checked handle、能力交集、JSON Schema、资源访问声明、World Revision、Trace/Replay 和稳定 C ABI；
- 不吸收 CLI Agent 对 Shell、文件系统、脚本目录、进程权限和聊天 transcript 的默认假设。

V2 的四个首要稳定契约是：

```text
ContextPipeline
ToolOrchestrator
SessionJournal
PromptPack + SkillPack
```

其他能力——长期 Memory、WASM、MCP、更多 Provider、多 Agent 调度和引擎绑定——都应建立在这四个契约之上，而不是继续堆进单体 `agent_loop`。

---

# 1. 当前基线与 V2 改造目标

## 1.1 当前应保留的能力

NAR 当前已经具备一组很适合 native/game 场景的基础能力，V2 必须保持其语义：

1. Agent 由宿主主动调用 `tick` 推进，每次只执行有限工作；
2. `tick` 不隐式 pump 主线程任务；
3. Runtime Profile 与无工作线程的 Minimal/Test Profile 分离；
4. 模型、工具和异步 Operation 可轮询、可取消；
5. Tool Handle、Operation Handle 等对象具有 generation 校验；
6. Runtime、Shipping、Project、Agent 等权限通过交集收紧；
7. Tool 参数使用 JSON Schema 校验；
8. Tool 可声明线程亲和性、资源访问和版本约束；
9. 资源冲突可映射到增量调度器；
10. Trace/Replay 是基础能力，而非附加调试功能；
11. C ABI 使用 opaque handle、固定宽度类型、版本字段和显式 Buffer 所有权；
12. 队列、流、Token、模型调用和 Tool 调用都必须有上限。

## 1.2 当前需要解耦的部分

V2 重点解决以下耦合：

- `Agent` 直接持有具体的内存 Session；
- `Agent Loop` 直接创建固定 `ContextBuilder`；
- Context 只按历史条数和工具数量裁剪；
- World Section 默认作为高优先级指令输入模型；
- Tool 选择主要是过滤、按名称排序和截断；
- 模型响应一次只允许一个 Tool Call；
- Tool 描述、Schema 成本和动态资源没有完整进入规划；
- 缺少 steer、follow-up、world invalidation 等运行期输入；
- Session 主要表现为 transcript，而不是恢复所需的语义日志；
- Working Memory、长期 Memory、World State 和 Skill State 尚未形成明确边界；
- Prompt、Skill、Memory 和 Hook 尚未形成版本化、可观测、可替换的核心契约；
- 每次模型调用可能复制完整 Session 和 Tool Descriptor 集合。

## 1.3 V2 成功标准

V2 完成后应满足：

- `AgentKernel` 不直接依赖具体 Prompt、Memory、Store、Provider 或 Tool 实现；
- 每次 Context 构建都能解释每个 section 为什么进入或未进入模型；
- 一次模型响应可产生多个 Tool Call，并按照资源冲突安全调度；
- 未完成 Provider 请求、Tool Call 和 Compaction 具有明确恢复语义；
- Host 能在模型推理期间 steering、排队后续输入或声明世界快照失效；
- Skill 只能请求已有能力，不能授予新能力；
- Session、Memory、World 和 Skill State 分离；
- 主线程无隐藏阻塞、无隐藏 I/O、无无界队列；
- Minimal Profile 仍可无线程、无网络、确定性运行；
- C ABI 仍然可被 C/C++、Rust、C#、Unity、Unreal 等宿主安全接入。

---

# 2. 产品边界

## 2.1 NAR 负责什么

NAR Kernel 负责：

- Turn 生命周期与状态转换；
- 稳定 ID、Handle 和 generation；
- 输入队列与消费顺序；
- Context Pipeline 的调用与冻结；
- Model Request 生命周期；
- Tool Call 收集、规划、授权、调度和结果归并；
- Budget、Deadline、Cancellation；
- Session Journal 的语义事件；
- Trace、Replay 和 Differential Replay；
- 恢复边界与保守恢复策略；
- 向 Host 暴露可轮询事件和异步 Operation。

## 2.2 Host 负责什么

Host 是以下内容的权威所有者：

- 游戏世界、ECS、场景、对象生命周期和 Savegame；
- 主线程、Job System、网络线程和渲染线程；
- Gameplay Intent 的确定性执行；
- 文件系统、密钥、网络、平台 SDK 和账号权限；
- UI、用户确认、权限提示和错误展示；
- Session/Memory 的实际存储介质；
- Tool、Model、PromptPack、SkillPack 和 Hook 的注册；
- Prompt/Skill 资产信任、签名与发布流程；
- 日志脱敏、数据合规和遥测上传；
- 本地模型进程或远端推理服务的部署。

## 2.3 NAR 不负责什么

NAR V2 仍然不是：

- 行为树、State Tree、GOAP 或 Gameplay Framework；
- ECS、对象系统或资源系统；
- 通用 Workflow DSL；
- 向量数据库或完整 RAG 平台；
- Shell/文件系统自动化运行环境；
- 任意脚本宿主；
- MCP Server 集合；
- 分布式 Agent 平台；
- LLM 推理引擎；
- 让 LLM 逐帧直接控制角色的系统。

---

# 3. 核心设计原则

## 3.1 Kernel 小而具体，边界粗而可替换

Turn 状态机、预算、取消、顺序和错误语义必须由 NAR 直接实现，不应做成任意插件。

只有宿主必须替换的边界使用 VTable 或 Adapter：

- Model Backend；
- World Provider；
- Session Store；
- Memory Store；
- Tool Implementation；
- Host Authorization；
- Tokenizer；
- Trace Sink；
- 可选 WASM Runtime 与 MCP Gateway。

避免为每个内部函数增加插件点。插件点越多，回放和安全语义越难稳定。

## 3.2 Host 是环境权威，模型不是

模型只能提出意图、参数、计划或 Memory Candidate。实际世界状态、对象 generation、资源版本、权限和副作用结果必须由 Host 或 NAR Policy 校验。

## 3.3 Instruction 与 Data 必须分离

World、Tool Result、用户文本、联网内容、UGC、Mod 内容默认都是数据，不得因为使用了 `system` role 就获得指令优先级。

进入 Context 的每个项目必须携带 trust level。只有 Kernel、Host 明确声明的指令和已验证资产可进入高信任指令区。

## 3.4 所有长操作显式异步

模型请求、网络、持久化、用户确认、主线程命令、资源加载、场景切换和长 Tool 都必须表现为可轮询、可取消的 Operation。

## 3.5 所有增长有上限

以下对象必须有容量或预算：

- 输入队列；
- Agent 事件邮箱；
- Model Stream；
- Tool Call Batch；
- Tool 参数和结果；
- Context Item 数量与 Token；
- Session 未 flush 事件；
- Trace Payload；
- Memory 召回数量；
- Skill Catalog；
- 并发 Operation；
- 单帧工作量。

## 3.6 所有关键决策可解释

工具选择、Context 裁剪、权限拒绝、World Stale、恢复策略、重试、Compaction 和 Memory 写入必须在 Manifest、Journal 或 Trace 中留下结构化原因。

## 3.7 确定性优先于“聪明”的隐式行为

选择、排序、裁剪和恢复必须有稳定 tie-break。不得依赖 HashMap 遍历顺序、线程竞速或未记录的随机数。

规则选择能完成的事情，不应默认增加向量检索或额外模型调用。

---

# 4. 总体架构

```text
Native Application / Game Engine
│
├── World / ECS / Object System / Savegame
├── Gameplay / UI / Navigation / Animation
├── Main Thread / Job System / IO / Network
├── Storage / Secrets / Platform Services
├── Prompt & Skill Asset Pipeline
└── User Authorization / Telemetry
                 │
                 │ Stable C ABI / Zig API
                 ▼
┌─────────────────────────────────────────────────────────────┐
│                         NAR Runtime                         │
│                                                             │
│  ┌──────────────────── Agent Kernel ─────────────────────┐  │
│  │ Turn State Machine                                    │  │
│  │ IDs / Budgets / Cancellation / Ordering / Recovery    │  │
│  │ Input Queues / Event Mailbox                          │  │
│  └───────────────┬─────────────────┬─────────────────────┘  │
│                  │                 │                        │
│        ┌─────────▼─────────┐ ┌────▼──────────────┐         │
│        │ ContextPipeline   │ │ ToolOrchestrator  │         │
│        │ Prompt / Skill    │ │ Resolve / Prepare │         │
│        │ World / Memory    │ │ Authorize/Execute │         │
│        └─────────┬─────────┘ └────┬──────────────┘         │
│                  │                 │                        │
│        ┌─────────▼─────────┐ ┌────▼──────────────┐         │
│        │ Model Contract    │ │ Operation Runtime │         │
│        │ Router / Retry    │ │ Resource Scheduler│         │
│        └─────────┬─────────┘ └────┬──────────────┘         │
│                  │                 │                        │
│        ┌─────────▼─────────────────▼──────────────┐         │
│        │ SessionJournal / Trace / Replay / Diff   │         │
│        └──────────────────────────────────────────┘         │
└─────────────────────────────────────────────────────────────┘
                 │
       Adapters supplied by Host
                 │
 Model / Store / Memory / Native Tool / WASM / MCP Gateway
```

## 4.1 控制流与数据流分离

控制流由 Kernel 驱动：

```text
Input → Turn → Context → Model → Tool Batch → Context → Model → Outcome
```

数据流由各 Provider 提供：

```text
PromptPack
SkillPack
World Snapshot
Session View
Working Memory
Retrieved Memory
Tool Catalog
Current Input
Tool Results
```

Provider 不得直接改变 Turn 状态。它只能返回数据或类型化决策，由 Kernel 应用。

## 4.2 主要模块

```text
kernel/        Turn 状态机、预算、取消、输入队列、生命周期
context/       ContextItem、选择、预算、渲染、Manifest
prompt/        PromptPack、Section、组合、缓存策略
skill/         SkillPack、Catalog、Resolver、Instance State
tool/          Descriptor、Resolver、Prepare、Policy、Batch、Result
model/         Provider-neutral Contract、Capabilities、Router、Retry
session/       Semantic Journal、Reducer、Branch、Checkpoint、Recovery
memory/        Working Memory、Long-term Record、Retrieval、Write Policy
world/         Snapshot、Section、Revision、Provider Contract
operation/     异步 Operation 与资源调度
lifecycle/     Typed Hook、Observer、Policy Interceptor
trace/         Trace、Replay、Diff、Redaction
abi/           稳定 C ABI 与 Handle Registry
adapters/      HTTP、SQLite、WASM、MCP、引擎绑定等可选实现
```

---

# 5. 对象与所有权模型

## 5.1 稳定身份

运行期对象使用 generation-checked handle：

```text
RuntimeHandle
AgentHandle
ToolHandle
ModelHandle
OperationHandle
MediaHandle
WorldSnapshotHandle
```

持久化和资产对象使用稳定 ID、版本和内容 Hash：

```text
PromptPackId + version + content_hash
SkillId      + version + content_hash
ToolId       + version + schema_hash
ModelRef     + provider_id + model_id + capability_hash
SessionId
SessionEventId
MemoryId
```

运行期 Handle 不得持久化为恢复依据。恢复只持久化稳定 ID 和版本，随后由 Host 重新注册兼容实现。

## 5.2 Buffer 所有权

所有跨 ABI Buffer 必须属于以下一种模式：

1. **Borrowed for call**：只在 callback 期间有效，不得保留；
2. **NAR-owned output**：由 NAR 分配，Host 调用统一 release；
3. **Host-owned transferred input**：调用成功后所有权转移给 NAR；
4. **Ref-counted host resource**：通过 retain/release VTable 管理，例如 Texture 或 Shared Memory。

任何 API 都不得暴露可长期保存的裸 World 指针或执行器内部地址。

## 5.3 不可变快照

以下对象构建完成后应视为不可变：

- Tool Catalog Generation；
- PromptPack Generation；
- Skill Catalog Generation；
- Context Envelope；
- World Snapshot；
- Session View；
- Prepared Tool Call。

注册表变化通过 generation 切换，不得原地修改正在被 Turn 使用的数据。

---

# 6. Agent Kernel 与 Turn 状态机

## 6.1 状态机

推荐状态：

```text
idle
  │
  ▼
preparing_turn
  │
  ▼
building_context ───────────────┐
  │                             │
  ▼                             │
waiting_model                   │
  │                             │
  ├── final ───────────────► completed
  │
  ├── compact_needed ──────► compacting ───────────┘
  │
  └── tool calls
          │
          ▼
collecting_tool_batch
          │
          ▼
preparing_tools
          │
          ├── authorization needed ─► waiting_authorization
          │                               │
          └───────────────────────────────┘
          │
          ▼
executing_tools
          │
          ├── async/main-thread ───► waiting_operations
          │                              │
          └──────────────────────────────┘
          │
          ▼
committing_tool_results
          │
          └────────────────────────► building_context

任意活动状态：
  ├── cancel      ─► cancelled
  ├── fatal error ─► failed
  ├── crash/reload► interrupted
  └── deadline    ─► failed 或 cancelled，取决于策略
```

## 6.2 `tick` 语义

单次 `agent.tick()`：

- 最多消费一个模型事件、一个 Operation 事件或完成一个有限状态转换；
- 不执行无上限循环；
- 不隐式 pump 主线程任务；
- 不等待网络、磁盘、用户输入或锁；
- 返回 `progressed`、`would_block` 或 `terminal`；
- 若事件邮箱已满，应施加 backpressure，而不是静默丢失语义事件。

## 6.3 安全边界

Steering、取消、World 刷新和配置切换只在明确安全边界应用：

```text
before_context
before_model_start
between_model_events
before_tool_prepare
before_tool_execute
between_tool_completions
before_compaction_commit
before_turn_commit
```

不可在 Host callback 执行中重入同一 Agent。

## 6.4 Turn 结果

Turn 终止结果应区分：

```text
completed
cancelled
interrupted
failed_policy
failed_budget
failed_model
failed_tool
failed_world_stale
failed_protocol
failed_internal
```

用户可见结果、程序错误码和 Trace 原因应分开表示。

---

# 7. 输入队列与 Steering

## 7.1 输入类型

```zig
pub const InputMode = enum {
    steer,
    follow_up,
    next_turn,
    invalidate_world,
};
```

语义：

- `steer`：在下一个安全边界注入当前 Turn；策略允许时可取消当前 Provider 请求并重新构建 Context；
- `follow_up`：当前 Turn 完成后立即成为下一 Turn 的优先输入；
- `next_turn`：普通 FIFO 输入；
- `invalidate_world`：声明当前或指定 Revision 的 World Snapshot 已失效，不一定包含文本。

## 7.2 队列不变量

- 队列有固定容量和字节上限；
- 每条输入具有稳定 QueueItemId；
- 接受输入成功前，Durable Mode 必须先写入 Journal；
- 消费输入时，`turn_started` 必须记录被消费的 QueueItemId；
- Steering 合并策略必须配置化并写入 Trace；
- 不允许在邮箱未清空时强制要求 Agent 只能提交新 Turn；邮箱和输入队列是两个独立概念。

## 7.3 Steering 策略

```text
ignore_until_boundary
cancel_model_and_rebuild
append_to_current_context
queue_for_after_tool_batch
reject_when_busy
```

默认推荐：

- 纯聊天/Editor Agent：`cancel_model_and_rebuild`；
- 游戏 Runtime Agent：`queue_for_after_tool_batch`，除非 World 已明确失效；
- 不可逆写 Tool 执行期间：不得通过 Steering 隐式中断副作用提交。

---

# 8. ContextPipeline

## 8.1 目标

Context 不再是一段按固定顺序拼接的消息列表，而是一条可观测、可预算、可替换的构建管线。

```text
Collect
  ↓
Normalize
  ↓
Resolve
  ↓
Select
  ↓
Budget
  ↓
Render
  ↓
Freeze + Manifest
```

## 8.2 ContextItem

建议核心结构：

```zig
pub const ContextTrust = enum {
    kernel_trusted,
    host_trusted,
    signed_asset,
    tool_trusted,
    untrusted_world,
    untrusted_user,
    external,
};

pub const ContextRole = enum {
    instruction,
    user_input,
    assistant_history,
    tool_result,
    world_data,
    memory_data,
    metadata,
};

pub const CachePolicy = enum {
    never,
    request,
    session,
    pack_generation,
};

pub const ContextItem = struct {
    id: ContextItemId,
    source: ContextSource,
    role: ContextRole,
    trust: ContextTrust,
    priority: i16,
    mandatory: bool,
    revision: ?u64,
    expires_at: ?Timestamp,
    cache_policy: CachePolicy,
    sensitivity: Sensitivity,
    estimated_tokens: u32,
    payload: ContentRef,
};
```

`ContextSource` 至少区分：

```text
kernel_prompt
application_prompt
agent_prompt
skill_prompt
world
session_history
working_memory
retrieved_memory
current_input
tool_result
runtime_metadata
```

## 8.3 Collect

各 Producer 只负责产生候选 Item：

```text
KernelPromptProducer
PromptPackProducer
ActiveSkillProducer
WorldProducer
SessionProducer
WorkingMemoryProducer
LongTermMemoryProducer
ToolResultProducer
RuntimeMetadataProducer
```

Producer 不直接决定 Provider Message Role，也不直接消费总 Token Budget。

## 8.4 Normalize

Normalize 负责：

- 验证 UTF-8、Media 类型和结构化数据；
- 附加 trust、scope、revision、sensitivity；
- 将相同来源的内容转为稳定 ID；
- 去除或标记不可见字段；
- 对数据内容增加清晰边界，防止数据被解释为上层指令；
- 记录内容 Hash；
- 拒绝超过单项大小上限的 Item。

## 8.5 Resolve

Resolve 处理依赖和替换：

- Prompt Section 的 `replace/append`；
- Skill Activation；
- Memory 记录的 supersede/tombstone；
- World Section 的同名 Revision；
- Tool Result 与 Session 中已提交结果的去重；
- Locale、Agent Type、Runtime Profile 和模型能力条件。

## 8.6 Select

Select 只使用确定性规则：

```text
mandatory
scope match
revision validity
expiry
visibility
priority
utility score
estimated token cost
stable item id tie-break
```

首版不要求 Vector DB。长期 Memory 可先使用 scope + tag + recency + salience + confidence 的规则评分。

## 8.7 Budget

Budget 必须先预留，再选择 optional 内容。

推荐顺序：

1. 预留模型最大输出；
2. 预留 Kernel Invariant；
3. 预留当前输入；
4. 预留当前 Tool Results；
5. 预留 Provider framing 和 Tool Schema；
6. 预留最小 Compaction/恢复空间；
7. 按类别配额选择 World、History、Working Memory、Retrieved Memory、Skill 和 Tool；
8. 使用 Provider Tokenizer 做最终计数；
9. 超限时按明确降级顺序重新选择；
10. mandatory 内容仍无法容纳时返回 `context_budget_exceeded`。

示例 Profile：

```text
world              25%
recent history     20%
working memory     10%
retrieved memory   10%
skills              8%
tool schemas       17%
reserve/overhead   10%
```

比例只是配置默认值，不是协议常量。

## 8.8 Tool Schema 计入预算

最终 Context Budget 必须包含：

- Tool name；
- description；
- input schema；
- Provider 的 Tool framing；
- 必要时的 output schema 摘要；
- Skill Catalog 的 name/description；
- Prompt cache marker 或 Provider metadata。

不得只计算 message 文本后再无条件追加工具。

## 8.9 Render

Render 分两层：

```text
ContextItem[]
  → Provider-neutral ModelMessage / ModelTool
  → Provider Adapter Payload
```

NAR Kernel 不持有 OpenAI、Anthropic、Gemini 或本地模型的特殊消息格式。

## 8.10 World 不默认作为 System Instruction

World Section 默认映射为 `world_data`，并渲染为显式数据块：

```text
<world-data section="nearby_entities" revision="1042" trust="untrusted_world">
...
</world-data>
```

只有 Host 明确标记为 `host_trusted instruction` 的内容才可进入高信任指令区。

## 8.11 ContextManifest

每次构建至少记录：

```text
build_id
turn_id
model_ref
provider capability hash
prompt pack id/version/hash
skill ids/versions/hashes
tool catalog generation
world snapshot id/revision
session event range
working memory version
retrieved memory ids

每个 ContextItem：
  id
  source/producer
  role/trust
  priority/mandatory
  content hash
  estimated tokens
  actual tokens（可用时）
  selected/dropped
  drop reason
  revision/expiry
  cache policy
  sensitivity

每个 Tool Schema：
  tool id/version/schema hash
  score
  selected/dropped
  reason
  token cost
```

Manifest 是 Trace 和 Differential Replay 的核心输入，不应只记录 Item 数量。

---

# 9. PromptPack

## 9.1 目标

Prompt 工程从两个大字符串升级为版本化 Section Graph。

```text
PromptPack
├── kernel.invariants
├── application.rules
├── agent.identity
├── agent.behavior
├── runtime.protocol
├── active_skill.*
└── task_prompts
    ├── compaction
    ├── memory_extraction
    ├── memory_rerank
    ├── tool_result_summary
    └── recovery_summary
```

## 9.2 PromptSection

```zig
pub const PromptSection = struct {
    id: PromptSectionId,
    version: SemVer,
    content_hash: Hash,
    namespace: []const u8,
    mode: enum { append, replace },
    precedence: i16,
    trust: ContextTrust,
    condition: ConditionExpr,
    cache_policy: CachePolicy,
    max_tokens: u32,
    locale: ?Locale,
    sensitivity: Sensitivity,
    content: ContentRef,
};
```

## 9.3 组合规则

1. `kernel.*` 只能由 NAR 构建资产定义，应用不得替换；
2. `application.*` 可被同 namespace 的更高版本应用包替换；
3. `agent.*` 由 Agent Definition 选择；
4. `skill.*` 只在 Skill 激活后出现；
5. `runtime.*` 每轮重算；
6. `task_prompts.*` 不自动进入主对话，只供专项子任务使用；
7. append 顺序和 replace 结果必须确定；
8. 最终 section 列表、版本和 Hash 写入 Manifest。

## 9.4 静态与动态缓存边界

Section 应明确：

- 可跨请求缓存的稳定内容；
- 只在当前 Session 有效的内容；
- 每轮变化的 World/Runtime 内容；
- 不可缓存的敏感内容。

Provider 支持 Prompt Cache 时，Adapter 根据 `cache_policy` 设置缓存边界；Provider 不支持时，语义保持不变。

## 9.5 专项 Prompt

Compaction、Memory Extraction、Tool Result Summary 等任务必须使用独立 Prompt ID 和版本，不能把其规则混入主 Agent Prompt。

专项任务的输入、输出和版本应进入 Trace，便于判断摘要差异来自 Prompt、模型还是原始数据。

## 9.6 资产格式

开发期建议：

```text
prompt-pack/
├── manifest.toml
├── sections/
│   ├── kernel-invariants.md
│   ├── application-rules.md
│   └── agent-behavior.md
└── tasks/
    ├── compact.md
    └── memory-extraction.md
```

Shipping 建议编译为只读 `.narprompt`：

- 稳定索引；
- 内容 Hash；
- 可选签名；
- 已验证编码；
- 可选预计算 Token Estimate；
- 不依赖运行时目录扫描。

---

# 10. ToolOrchestrator

## 10.1 Tool 生命周期

```text
Resolve
  ↓
Prepare
  ↓
Authorize
  ↓
Plan
  ↓
Execute
  ↓
Observe / Commit Result
```

## 10.2 ToolDescriptor V2

```zig
pub const ToolDescriptorV2 = struct {
    id: ToolId,
    version: SemVer,
    schema_hash: Hash,

    name: []const u8,
    description: []const u8,
    domain: []const u8,
    group: []const u8,
    tags: []const []const u8,

    input_schema: []const u8,
    output_schema: ?[]const u8,

    required_capabilities: CapabilitySet,
    profiles: ProfileMask,
    thread_affinity: ThreadAffinity,

    side_effect: SideEffectClass,
    idempotency: IdempotencyClass,
    retry_safety: RetrySafety,
    deterministic: bool,

    static_resources: []const ResourceAccess,
    dynamic_resource_planner: bool,

    max_argument_bytes: u32,
    max_model_result_bytes: u32,
    estimated_latency_class: LatencyClass,
    estimated_cost_units: u32,
    serial_group: ?ToolSerialGroup,
};
```

建议枚举：

```text
SideEffectClass:
  none
  read
  reversible_write
  irreversible_write

IdempotencyClass:
  idempotent
  keyed
  non_idempotent

RetrySafety:
  safe
  safe_with_receipt_check
  unsafe
```

## 10.3 Resolve

Tool Resolver 的输入：

- Agent allowed tool IDs；
- Runtime/Shipping/Project/Agent/Skill capability；
- 当前 Runtime Profile；
- Active Skills；
- 当前任务、World Section 和 Agent Type；
- Tool Token 成本；
- 模型能力；
- 当前调用次数和循环状态。

输出：

```zig
pub const ToolCandidate = struct {
    tool: ToolRef,
    score: i32,
    selected: bool,
    reason: ToolSelectionReason,
    estimated_tokens: u32,
};
```

首版推荐确定性评分：

```text
required by active skill       +1000
explicitly requested by host    +800
domain match                    +300
group match                     +150
recently useful                  +50
large schema cost               -cost
irreversible side effect        -policy penalty
stable ToolId                   tie-break
```

不得以名称字典序作为主要选择逻辑。名称只可作为最终稳定 tie-break。

## 10.4 ModelTool

传给模型的工具必须包含：

```zig
pub const ModelTool = struct {
    id: ToolId,
    version: SemVer,
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    schema_hash: Hash,
    estimated_tokens: u32,
};
```

## 10.5 Prepare

Prepare 是无副作用阶段：

```zig
pub const PreparedToolCall = struct {
    call_id: ToolCallId,
    tool: ToolRef,
    canonical_arguments: SharedBuffer,
    target_objects: []ObjectRef,
    dynamic_resources: []ResourceAccess,
    expected_world_revision: WorldRevision,
    side_effect: SideEffectClass,
    idempotency_key: ?IdempotencyKey,
    result_policy: ToolResultPolicy,
};
```

Prepare 负责：

- 解析和 Canonicalize JSON；
- Schema 校验；
- 解析目标 ObjectRef；
- generation 校验；
- 根据参数计算动态 ResourceAccess；
- 生成 Idempotency Key；
- 计算结果限长策略；
- 不执行 Gameplay 副作用。

## 10.6 Authorize

授权结果：

```text
allow
deny
ask_host
defer
```

权限链：

```text
build hard limit
∩ shipping profile
∩ project policy
∩ agent policy
∩ active skill requirements
∩ runtime override
∩ turn-specific policy
```

Skill 只能进一步收紧，不能增加能力。

`ask_host` 进入 `waiting_authorization`，由 Host UI 或业务逻辑异步决定。不得在 Tool callback 内阻塞等待用户确认。

## 10.7 Multi-Tool Call

模型流必须允许同一响应中多个 Tool Call，并允许参数 Delta 按 `call_id` 或 `index` 交错。

Kernel 在模型响应结束或 Provider 明确关闭 Tool Batch 后，得到：

```text
ToolCallBatch [call0, call1, ... callN]
```

Batch 上限由 Turn Budget 控制。

## 10.8 Plan：资源冲突图

Prepared Calls 形成冲突图：

```text
A writes entity:42
B reads  entity:42      A → B
C reads  map:west       可与 A 并行
D writes UI/main-thread 独立主线程队列
```

冲突规则至少考虑：

- 相同 ResourceKey；
- Range 是否重叠；
- read/write/create/delete；
- VersionConstraint；
- serial_group；
- thread_affinity；
- Host 追加的动态约束。

## 10.9 Execute

执行策略：

- 无冲突、允许并行的 Tool 可同时 dispatch；
- Main Thread Tool 只进入 Host pump 队列；
- Worker Tool 由 Host/Spindle 调度；
- 同一 serial_group 顺序执行；
- 不可逆 Tool 默认不自动重试；
- Operation 完成顺序可以不同于模型调用顺序。

事件按实际完成顺序发出，以便 UI 和 Trace 观察；写回 Session 和提供给下一轮模型的 Tool Result 应保持模型原始调用顺序，除非 Provider 协议明确要求其他顺序。

## 10.10 ToolResult

Tool Result 分离模型内容与应用内容：

```zig
pub const ToolResult = struct {
    call_id: ToolCallId,
    status: ToolStatus,
    model_content: BoundedContent,
    app_payload: ?OpaquePayload,
    error: ?ToolError,
    retryable: bool,
    observed_world_revision: WorldRevision,
    side_effect_receipt: ?SideEffectReceipt,
};
```

示例：寻路 Tool 可以给模型返回路径摘要，把完整 Waypoint 数组放入 `app_payload`，避免将大量结构化数据写入模型 Context。

## 10.11 重复调用与循环检测

不应因为某工具本 Turn 已使用过一次，就从后续模型请求中移除。

推荐规则：

- 相同 Tool + 相同 Canonical Args：受 `max_identical_calls` 限制；
- 相同 Tool + 不同 Args：受 `max_calls_per_tool` 限制；
- 全部 Tool：受 `max_tool_calls` 限制；
- 写 Tool：额外受 side-effect policy 限制；
- 可重入性由 Descriptor 声明；
- 检测键包含 Tool ID、Version、Canonical Args 和必要的目标 Revision。

---

# 11. Model Contract V2

## 11.1 Provider-neutral 请求

```zig
pub const ModelRequest = struct {
    request_id: ModelRequestId,
    model: ModelRef,
    messages: []const ModelMessage,
    tools: []const ModelTool,
    tool_choice: ToolChoice,
    response_format: ResponseFormat,
    sampling: SamplingOptions,
    max_output_tokens: u32,
    thinking_budget: ?u32,
    cache_hints: []const CacheHint,
    media: []const MediaRef,
    metadata: RequestMetadata,
};
```

## 11.2 模型能力

```text
streaming
single_tool_call
parallel_tool_calls
structured_output
json_schema_output
tool_choice
prompt_cache
vision_url
vision_inline
native_media_handle
audio
thinking_budget
usage_reporting
cost_reporting
```

Context Pipeline 和 Tool Resolver 必须根据 capability 降级，而不是假定所有模型能力相同。

## 11.3 流事件

```text
start
text_delta
reasoning_delta（可选、默认不持久化明文）
tool_call_start(call_id, index, tool_name)
tool_arguments_delta(call_id, bytes)
tool_call_end(call_id)
usage
finish
error
cancelled
```

多个 Tool Call 的事件可交错，但同一 `call_id` 内部顺序必须有效。

## 11.4 Provider Adapter

Adapter 负责：

- Provider Payload 编码；
- SSE/WebSocket/IPC 解析；
- Provider Role 和 Tool Result 格式映射；
- Prompt Cache Hint；
- Tokenizer；
- Provider Error 分类；
- 原始 Usage 转统一 Usage；
- Media 上传或编码。

Adapter 不得：

- 隐式修改 Tool 权限；
- 隐式重试不可逆请求；
- 修改 Session；
- 直接执行 Tool；
- 绕过 Context Manifest。

## 11.5 Retry Policy

重试放在 Backend 外层统一管理：

```text
transport
rate_limit
provider_overload
timeout_connect
timeout_first_byte
timeout_overall
protocol_error
context_overflow
content_filter
cancelled
```

每次重试都应：

- 消耗预算；
- 使用稳定 request group ID 和新的 attempt ID；
- 写入 Trace；
- 明确是否重新构建 Context；
- 不自动重试已开始执行的不可逆 Tool。

---

# 12. WorldProvider

## 12.1 目标

NAR 不持有世界权威，只请求当前任务所需的不可变快照。

```zig
pub const WorldProviderVTable = struct {
    acquire_snapshot: *const fn (... ) anyerror!WorldSnapshotHandle,
    describe_snapshot: *const fn (... ) anyerror!WorldSnapshotView,
    refresh_snapshot: *const fn (... ) anyerror!WorldSnapshotHandle,
    release_snapshot: *const fn (... ) void,
};
```

## 12.2 WorldSection

```zig
pub const WorldSection = struct {
    id: WorldSectionId,
    name: []const u8,
    schema_id: ?SchemaId,
    revision: WorldRevision,
    trust: ContextTrust,
    sensitivity: Sensitivity,
    content: ContentRef,
};
```

World Section 可以是：

- 文本；
- Canonical JSON；
- 二进制摘要；
- MediaRef；
- Host Opaque Reference，仅供 Tool 使用而不进入模型。

## 12.3 部分快照

Provider 应允许按需求请求 Section：

```text
agent_self
current_goal
nearby_entities
quest_state
inventory_summary
navigation_summary
ui_state
recent_world_events
```

不得默认复制整个 ECS 或场景。

## 12.4 Stale Policy

在模型边界和写 Tool 执行前检查 World Revision。

默认：

```text
只读 Tool stale
  → 可刷新 Snapshot 后重新 Prepare

幂等写 Tool stale
  → 重新 Prepare；由 Policy 决定是否继续

不可逆写 Tool stale
  → 不自动执行，返回 stale 或重新交给模型

Object generation 变化
  → 立即拒绝
```

## 12.5 World Invalidation

Host 可以提交：

```text
snapshot invalidated
section invalidated
object destroyed
generation advanced
scene unloaded
savegame switched
```

Kernel 应在最近安全边界响应。场景卸载或 Savegame 切换通常直接取消相关 Turn 和 Operation。

---

# 13. SessionJournal

## 13.1 Session 不是 Transcript

Session 是 Agent 可恢复语义状态的 append-only journal。聊天消息只是事件的一类。

Session 不存储 Tool 实现、Model 对象、Hook callback 或文件句柄。它只存储稳定引用、版本、Hash 和执行结果。

## 13.2 事件类型

最小事件集：

```text
session_created
configuration_changed
queue_enqueued
queue_consumed
turn_started
turn_finished
turn_interrupted
context_built
model_request_started
model_request_finished
model_request_interrupted
tool_batch_proposed
tool_call_prepared
tool_call_authorized
tool_call_started
tool_call_finished
tool_call_interrupted
operation_started
operation_finished
operation_interrupted
skill_activated
skill_deactivated
working_memory_updated
memory_candidate_created
memory_candidate_committed
memory_candidate_rejected
compaction_started
compaction_committed
branch_created
checkpoint_created
```

Model Text Delta、每帧进度和底层调度细节属于 Trace，不必全部写入 Journal。

## 13.3 SessionEvent

```zig
pub const SessionEvent = struct {
    id: SessionEventId,
    session_id: SessionId,
    branch_id: BranchId,
    parent_id: ?SessionEventId,
    sequence: u64,
    timestamp: Timestamp,
    schema_version: u32,
    event_type: SessionEventType,
    payload_hash: Hash,
    payload: SharedBuffer,
};
```

Store 可额外使用 checksum、segment hash 或 hash chain 防止损坏，但这些不应绑定某一种数据库。

## 13.4 Durable 依赖恢复

恢复时 Host 必须重新提供：

- Model Registry；
- Tool Registry；
- PromptPack；
- SkillPack；
- World Provider；
- Store/Memory Adapter；
- Hook/Policy Handler；
- Authorization Provider；
- Tokenizer 和 Provider Auth。

NAR 比较稳定 ID、Version 和 Hash，根据 Restore Policy 决定：

```text
fail
mark_incompatible
disable_missing
drop_optional
host_migrate
```

## 13.5 Durability Mode

```text
memory_only
buffered_journal
checkpointed
strict_durable
```

- `memory_only`：测试和短生命周期；
- `buffered_journal`：批量写入，不保证每个 API 返回前落盘；
- `checkpointed`：在 Turn/Tool 边界持久化；
- `strict_durable`：接受关键 mutation 前先 durable append。

游戏主线程不得直接执行 `fsync`。严格持久化通过异步 Store Operation 完成，Agent 进入等待状态。

## 13.6 恢复策略

默认保守策略：

```text
未完成 Turn
  → 标记 interrupted，保留队列，回到 idle

未完成 Provider Request
  → 标记 interrupted，不从流中间恢复

未完成 Tool Call
  → 追加 interrupted result；只有 retry-safe/idempotent 才允许重试

未完成不可逆 Tool
  → 检查 SideEffectReceipt；无法确认时交给 Host

未完成 Compaction
  → 无 committed entry 时可重新执行

已提交结果但缺 finish marker
  → 根据稳定 event/call id 补齐 marker
```

## 13.7 Branch 与 Checkpoint

Branch 用于：

- Editor 实验；
- Replay 分叉；
- 测试不同模型或 Prompt；
- 回退到旧决策点。

Checkpoint 用于加速恢复，但 Journal 仍是语义依据。Checkpoint 必须记录覆盖到的 SessionEventId、Reducer Version 和依赖 Hash。

---

# 14. Working Memory 与 Long-term Memory

## 14.1 五类状态必须分离

| 状态 | 用途 | 权威性 | 生命周期 |
|---|---|---|---|
| SessionJournal | 执行与恢复 | 对 Agent 过程权威 | Session/Savegame |
| WorkingMemory | 当前目标、计划、假设、待办 | 临时，可重建 | Turn/Session |
| LongTermMemory | 跨 Turn 的观察和认知 | 可能过期、可能主观 | Profile/Savegame |
| Skill State | 程序性能力实例状态 | 由 Skill Schema 约束 | Skill Instance |
| WorldState | 游戏真实状态 | Host 权威 | World/Scene |

## 14.2 WorkingMemory

建议结构：

```text
current_goal
subgoals
plan_steps
open_questions
assumptions
pending_operations
recent_failures
important_tool_results
active_skill_state_refs
latest_world_revision
```

Working Memory 更新必须是结构化 Patch，并进入 Journal。它可由 Session Reducer 重建，不应只存在于 Prompt 文本。

## 14.3 LongTermMemory Record

```zig
pub const MemoryRecord = struct {
    id: MemoryId,
    namespace: MemoryNamespace,
    subject: ?ObjectRef,
    predicate: []const u8,
    object: MemoryValue,
    epistemic_status: EpistemicStatus,
    source_event_id: SessionEventId,
    observed_world_revision: ?WorldRevision,
    valid_from: ?Timestamp,
    valid_until: ?Timestamp,
    confidence: f32,
    salience: f32,
    visibility: Visibility,
    supersedes: ?MemoryId,
    tombstone: bool,
    content_hash: Hash,
};
```

`EpistemicStatus`：

```text
authoritative
observed
reported
inferred
hypothesis
```

模型推断不得伪装成 Host 权威事实。

## 14.4 Memory 写入

```text
模型或规则生成 MemoryCandidate
  ↓
Schema / Scope / Duplicate / Staleness 检查
  ↓
MemoryWritePolicy
  ├── accept
  ├── modify
  ├── reject
  └── ask_host
  ↓
commit to MemoryStore
```

默认不向模型开放“任意改写长期 Memory”的通用 Tool。

## 14.5 Memory 召回

推荐首版：

```text
namespace scope
→ subject generation
→ visibility
→ TTL / valid range
→ supersede/tombstone
→ tags/predicate
→ recency + salience + confidence
→ deterministic top-k
→ optional model rerank
```

主 Context 只注入小型索引或摘要；详细记录按需加载。不得把全部 Memory 文件或数据库内容自动放入 Prompt。

## 14.6 Memory 与 World 冲突

World 权威数据优先。若 Memory 记录与最新 World Revision 冲突：

- 标记 stale；
- 不作为事实注入；
- 可作为“角色旧认知”注入，但必须保留 epistemic status；
- 由应用决定角色是否应知道最新事实。

---

# 15. Skill Runtime

## 15.1 Skill 定位

Skill 是能力受限、版本化、按需激活的程序性知识包，不是任意脚本目录。

```text
SkillPack
├── manifest
├── prompt sections
├── references/examples
├── assets
├── state schema + migrations
└── optional WASM module
```

## 15.2 SkillManifest

```zig
pub const SkillManifest = struct {
    id: SkillId,
    version: SemVer,
    content_hash: Hash,
    name: []const u8,
    description: []const u8,
    when_to_use: []const u8,

    activation: ActivationPolicy,
    required_tools: []const ToolRef,
    optional_tools: []const ToolRef,
    required_capabilities: CapabilitySet,
    allowed_profiles: ProfileMask,

    prompt_token_budget: u32,
    memory_namespace: ?MemoryNamespace,
    state_schema_version: u32,
    exclusive_groups: []const SkillGroup,
    conflicts: []const SkillId,

    trust: AssetTrust,
    signature: ?Signature,
    wasm_module: ?WasmModuleRef,
};
```

## 15.3 Progressive Disclosure

启动或 Catalog 构建时只向模型暴露：

```text
skill id
name
description
when_to_use
```

完整 Prompt、Reference 和 Asset 只在 Skill 激活后加载。

模型可以建议激活 Skill，但最终激活由 Skill Resolver 和 Policy 决定。

## 15.4 激活方式

```text
host_explicit
rule_match
model_suggested
user_command
auto_for_agent_type
```

激活和停用必须进入 Journal，并记录 Skill Version/Hash。

## 15.5 能力规则

Skill 有效能力：

```text
skill requirements
∩ agent capabilities
∩ project policy
∩ shipping policy
∩ runtime override
```

Skill 永远不能扩大 Agent 权限。

## 15.6 Skill State

Skill Instance State：

- 按 `application/profile/savegame/agent/skill` 命名空间隔离；
- 必须符合状态 Schema；
- 更新通过结构化 Patch；
- 版本升级必须提供 migration 或明确 reset/fail 策略；
- 不直接保存 native pointer、Tool implementation 或 Provider object。

## 15.7 资产格式

开发期：目录 + Markdown/TOML/JSON，支持 Editor 热更新。  
Shipping：预编译 `.narskill`，包含索引、Hash、可选签名和可选 WASM。

Shipping Runtime 默认禁止：

- 任意目录扫描；
- 任意 Shell Script；
- 任意 Native 动态代码加载；
- 未签名 Pack；
- Skill 自行请求文件系统或网络。

---

# 16. Lifecycle Hook

## 16.1 Observer 与 Interceptor 分离

```text
Observer
  只读观察，返回值忽略；用于 Trace、Metrics、UI。

Interceptor / Policy Handler
  参与特定事件语义，返回该事件定义的类型化决策。
```

不提供“万能可变 Runtime Context”。

## 16.2 固定阶段

建议内核只暴露：

```text
before_context
after_context
before_model
model_event_observed
before_tool_prepare
after_tool_prepare
before_tool_execute
after_tool_result
before_compact
memory_candidate
before_turn_commit
turn_end
session_restore
```

工具注册、模型注册、命令注册等属于 Registry，不属于 Hook。

## 16.3 类型化结果

示例：

```text
before_context       → add/remove/replace ContextItem
before_model         → deny / replace safe request metadata
before_tool_execute  → allow / deny / ask_host
memory_candidate     → accept / modify / reject
before_turn_commit   → allow / fail
```

每个事件定义自己的结果，避免通用 `map<string, any>`。

## 16.4 顺序、错误和预算

- Handler 使用稳定 priority 和 registration ID 排序；
- 相同 priority 使用 ID tie-break；
- 每个 Handler 有 deadline 和工作预算；
- Error Policy 明确为 `continue`、`fail_event` 或 `fail_turn`；
- 变换采用不可变输入、新值输出；
- Hook 不能在 callback 中重入同一 Agent；
- C ABI Hook 可返回 pending Operation；
- 所有语义变换写入 Trace，并记录来源。

---

# 17. Compaction

## 17.1 Compaction 目标

Compaction 不是简单删除旧消息，而是生成可验证的 Session 摘要，并保留继续执行所需状态。

## 17.2 Compaction Record

```text
covered_event_start
covered_event_end
covered_hash
summary_prompt_id/version/hash
summary_model_ref
summary_content_hash
preserved_goals
pending_operations
active_skills
important_tool_results
latest_valid_world_revision
created_at
```

## 17.3 不压缩的内容

以下内容不得只依赖自然语言摘要：

- 未完成 Operation ID；
- 未消费 Input Queue ID；
- Tool Call/Receipt；
- Active Skill 和 State Version；
- 当前 Goal 的结构化字段；
- Capability/Policy 版本；
- World Snapshot 引用；
- 恢复所需的稳定 Dependency Ref。

## 17.4 Compaction 后重建

Compaction 完成后，Context Pipeline 重新收集：

- 当前输入；
- 结构化 Working Memory；
- 活跃 Skill；
- 最新 World Snapshot；
- 未完成 Tool/Operation；
- Compact Summary；
- 必要的近期 Session Events。

World Snapshot 不应反复复制到 Session Transcript 中。

---

# 18. Trace、Replay 与 Differential Replay

## 18.1 三层记录

```text
SessionJournal
  可恢复的语义事实

Trace
  完整模型流、Context Manifest、Tool 参数、策略和调度细节

Telemetry
  指标、进度、采样性能数据
```

## 18.2 Trace 必须包含

- Runtime/Profile/Build ID；
- Agent/Turn/Request/Call/Operation ID；
- PromptPack、SkillPack、Tool 和 Model 的版本与 Hash；
- Context Manifest；
- Provider-neutral Model Request；
- Model Stream Event；
- Retry 和 Deadline；
- Tool Prepare/Authorize/Plan/Execute 结果；
- 资源冲突图和完成顺序；
- World Revision；
- Hook 决策；
- Compaction 和 Memory 决策；
- Budget 变化；
- 最终 Outcome。

## 18.3 脱敏

每个 Payload 定义：

```text
record
redact
hash
omit
host_transform
```

敏感内容包括：

- 玩家 PII；
- Auth/Secret；
- 私聊；
- 未发布资产；
- 精确设备信息；
- Reasoning/Thinking 明文；
- 外部 Tool 返回的受限数据。

## 18.4 Replay 模式

```text
strict
  请求和事件必须与 Canonical Trace 精确匹配。

semantic
  允许模型文本 chunking 等无语义差异，但 Tool Call、Result 和 Outcome 必须匹配。

differential
  使用同一 Context/World/Tool 模拟输入比较不同 Model、Prompt 或 Policy。
```

Replay 不得在缺少记录时静默回退到 Live Provider。

## 18.5 确定性要求

- Canonical JSON；
- 稳定排序；
- 可注入时钟；
- 可注入随机源；
- Completion 实际顺序和模型顺序分别记录；
- Context Item 和 Tool Candidate 使用稳定 ID；
- Reducer 版本固定；
- 浮点评分需要明确舍入或改用整数分值。

---

# 19. Native/Game 专项设计

## 19.1 LLM 输出高层 Intent

推荐：

```text
LLM Agent
  ↓ Goal / Intent / Plan
Gameplay Planner / State Tree / GOAP
  ↓
Behavior Tree / Ability / Navigation
  ↓
Movement / Animation / Combat / UI
```

NAR 不应鼓励模型输出逐帧移动、瞄准或物理控制。

## 19.2 Main Thread Tool

```text
Prepare on worker
  ↓
Authorize
  ↓
Enqueue native command
  ↓
Host safe-point pump
  ↓
Execute on main thread
  ↓
Complete Operation
```

`agent.tick()` 不执行主线程 callback，除非宿主明确在主线程调用专用 pump API。

## 19.3 Runtime-level Scheduler

保留单 Agent `tick`，可增加：

```zig
runtime.tickMany(.{
    .max_work_units = 32,
    .max_worker_nanos = 500_000,
    .max_main_thread_jobs = 4,
    .max_main_thread_nanos = 200_000,
});
```

Scheduler 支持：

- Agent priority；
- deadline；
- dormant/active；
- round-robin fairness；
- per-agent quota；
- event coalescing；
- backpressure；
- Host-defined activation signal。

大量 NPC 不应每帧全部调用模型。Agent 由事件、距离、剧情或任务激活。

## 19.4 Savegame Scope

Session、Memory 和 Skill State 至少支持：

```text
application_id
profile_id
save_slot_id
world_id
agent_id
```

切换 Save Slot 或 World 时，必须显式取消、迁移或分离当前 Turn；不得让旧世界的 Operation 在新世界提交。

## 19.5 MediaRef

```zig
pub const MediaRef = struct {
    id: MediaId,
    mime_type: []const u8,
    width: u32,
    height: u32,
    source: union {
        inline_bytes: SharedBuffer,
        url: []const u8,
        host_handle: HostMediaHandle,
    },
    generation: u32,
    sensitivity: Sensitivity,
};
```

Provider Adapter 决定上传、编码、共享内存或本地直接读取。NAR 不假定游戏内纹理一定有 URL。

## 19.6 Perception 与 Agent 分离

Perception 系统负责：

- 截图选择；
- 目标检测；
- OCR；
- 深度/分割；
- 事件聚合；
- 图像压缩；
- 可见性过滤。

NAR 只接收经过预算和权限处理的 MediaRef 或 Perception Summary。

---

# 20. 安全与信任模型

## 20.1 Capability 交集

```text
EffectiveCapability =
  BuildHardLimit
  ∩ ShippingPolicy
  ∩ ProjectPolicy
  ∩ AgentPolicy
  ∩ SkillRequirements
  ∩ RuntimeOverride
  ∩ TurnPolicy
```

默认拒绝，缺失能力不是“提示模型不要调用”，而是执行层不可达。

## 20.2 Prompt Injection 边界

- Tool Result、World、用户、网络和 Memory 默认不可信；
- 不可信内容不得覆盖 Kernel/Host 指令；
- PromptPack Section 有 trust 和 namespace；
- Tool 描述和 Skill 内容也属于供应链输入，必须验证来源；
- 外部 MCP 指令只能作为低信任数据或受限 Skill/Tool metadata；
- 不向模型暴露未授权 Tool 的名称和 Schema；
- 不向模型暴露 Secret，除非 Tool 在 Host 内部使用且结果已脱敏；
- Trace 中记录 Trust 转换和内容来源。

## 20.3 Side-effect Gate

不可逆副作用至少经过：

```text
Schema
→ Object/Generation
→ World Revision
→ Capability
→ Tool Policy
→ Host Authorization（需要时）
→ Resource Plan
→ Idempotency/Receipt
→ Execute
```

## 20.4 Skill 与 Prompt 供应链

Shipping Profile 推荐：

- 只加载打包时列入 Manifest 的资产；
- 校验内容 Hash；
- 可选签名；
- 禁止目录自动发现；
- 禁止任意 Native Extension；
- WASM 只获得显式 Host Import；
- 资产版本进入 Trace 和 Savegame 兼容检查。

## 20.5 WASM

WASM 默认无：

- 文件；
- 网络；
- 系统时钟；
- 随机数；
- 环境变量；
- 进程；
- 任意系统调用。

Host 通过显式 Import 授权。WASM Fuel、Memory、Call Depth 和执行时间必须有上限。

## 20.6 MCP

MCP 只作为外部 Gateway：

```text
NAR Tool Contract
  ↓ Policy Overlay
MCP Gateway Adapter
  ↓ JSON-RPC
External MCP Server
```

内部 ECS、Gameplay 和主线程 Tool 不使用 MCP 作为核心 ABI。

---

# 21. Budget 系统

## 21.1 Turn Budget

```text
wall deadline
work units
context tokens
output tokens
model calls
model retry attempts
tool calls
tool batch size
parallel operations
main-thread jobs
allocation bytes
model result bytes
trace bytes
memory retrieval count
compaction calls
estimated monetary cost
```

## 21.2 Runtime Budget

```text
active agents
active model requests
active operations
queued main-thread jobs
aggregate allocation
aggregate network bytes
aggregate model cost
store backlog
trace backlog
```

## 21.3 Budget Charge 时机

- 在创建资源前预留；
- 完成后结算实际消耗；
- 失败和重试也消耗相应预算；
- Provider 未返回 Usage 时使用估算并标记；
- Tool Schema Token 进入 Context Budget；
- Host callback 不得绕过 Allocation Budget。

## 21.4 预算耗尽策略

```text
reduce optional context
reduce tool catalog
compact
switch model（仅显式 Router Policy）
return partial result
fail turn
```

降级顺序必须配置化并写入 Trace。

---

# 22. 性能与内存

## 22.1 目标

- 单次 `tick` 有界；
- 主线程无网络、磁盘和无界 JSON 解析；
- 模型流和 Tool Result 不无界累积；
- 多 Agent 时避免每轮复制全量 Tool Catalog 和 Session；
- Minimal Profile 不依赖工作线程；
- 注册表变化不阻塞已开始 Turn。

## 22.2 建议实现

- Tool Catalog 使用 immutable generation snapshot；
- Prompt/Skill Pack 使用只读 generation；
- 编译后的 JSON Schema 缓存到 Tool Entry；
- Tool Schema Token Estimate 按 Provider/Tokenizer 缓存；
- Session 使用 append-only segment/page；
- Context Item 内容使用 ref-counted Buffer 或 interned static asset；
- 每 Turn 使用有硬上限、可复用 Arena；
- World Snapshot 支持 Host-owned ref-counted storage；
- 小对象使用 bounded inline storage，超过阈值再分配；
- 大 Tool Result 先摘要或放 `app_payload`；
- Trace Writer 支持异步批量写，但必须有 backpressure。

## 22.3 禁止的隐式成本

- 每次模型调用深拷贝全部 Tool Descriptor；
- 每次 Tool Loop 深拷贝完整 Session；
- 每轮扫描整个长期 Memory；
- 每帧 tick 所有 dormant Agent；
- 在主线程构建大型 JSON；
- 为 Provider 特殊格式污染 Kernel 数据模型。

---

# 23. C ABI 演进

## 23.1 原则

- 现有 ABI v2 保持兼容；
- V2 架构优先在 Zig 内部稳定语义；
- 新语义成熟后统一发布下一个 breaking ABI，不逐个暴露半成品接口；
- 可通过 additive extension struct 提前暴露不破坏语义的能力；
- 所有结构保留 `struct_size`、`api_version` 和 reserved 字段；
- 所有 Handle 为固定宽度整数，零无效；
- 所有 callback 明确 borrowed/owned 规则；
- API 支持 feature query。

## 23.2 建议新增 API 族

```c
nar_status nar_agent_enqueue_input(...);
nar_status nar_agent_tick(...);
nar_status nar_runtime_tick_many(...);
nar_status nar_agent_poll_event(...);

nar_status nar_runtime_set_world_provider(...);
nar_status nar_runtime_set_session_store(...);
nar_status nar_runtime_set_memory_store(...);

nar_status nar_prompt_pack_register(...);
nar_status nar_skill_pack_register(...);

nar_status nar_tool_register_v2(...);
nar_status nar_tool_authorization_complete(...);

nar_status nar_session_restore(...);
nar_status nar_session_checkpoint(...);
```

## 23.3 VTable 规则

- VTable 本身由 Host 持有且地址稳定；
- NAR 只在注册有效期内调用；
- callback 参数默认 borrowed；
- callback 不得重入同一 Runtime/Agent，除非 API 明确标记 reentrant-safe；
- 异步 callback 返回 Operation Handle；
- shutdown 后拒绝新 callback；
- Runtime destroy 是最终所有者，必须使子 Handle 失效。

## 23.4 Event ABI

Event 应区分：

```text
text_delta
turn_state_changed
tool_call_proposed
authorization_required
tool_progress
tool_result
world_stale
budget_warning
turn_completed
turn_failed
turn_cancelled
turn_interrupted
```

Terminal Event 不得静默丢弃。低优先级进度事件可以按明确规则合并。

---

# 24. Build Profile

## 24.1 Minimal

- 无工作线程；
- 无 HTTP；
- Mock/嵌入式 Model；
- 同步 Tool 与确定性 Operation；
- Memory-only Session；
- 预编译 Prompt/Skill Pack；
- In-memory Trace；
- 用于测试、嵌入式、小工具和确定性 Replay。

## 24.2 Runtime

- Worker/Blocking/Network executor；
- OpenAI-compatible 或其他 Provider Adapter；
- Resource Scheduler；
- Main-thread pump；
- Buffered/Checkpointed Session；
- Native Tool；
- 可选长期 Memory。

## 24.3 Editor

- Runtime 全部能力；
- 动态 Prompt/Skill 热更新；
- MCP Gateway；
- WASM；
- 文件系统 Tool（显式 Capability）；
- Debug Hook；
- Differential Replay UI。

## 24.4 Server

- 无游戏主线程假设；
- Durable Session；
- 高并发 Agent Scheduler；
- 远端 Model；
- 服务端 World Provider；
- 结构化 Metrics/Trace Sink。

## 24.5 Shipping Game

- 固定 Tool/Prompt/Skill Manifest；
- 关闭动态目录发现；
- 默认关闭 MCP、任意文件系统和 Native Extension；
- 可选签名资产；
- 严格 Capability；
- 受限 Trace；
- 远端或 Sidecar Model；
- 所有主线程工作受 Frame Budget 限制。

---

# 25. 推荐目录结构

```text
src/
├── kernel/
│   ├── runtime.zig
│   ├── agent.zig
│   ├── turn.zig
│   ├── turn_machine.zig
│   ├── input_queue.zig
│   ├── budget.zig
│   ├── cancellation.zig
│   └── scheduler.zig
│
├── context/
│   ├── item.zig
│   ├── producer.zig
│   ├── pipeline.zig
│   ├── resolver.zig
│   ├── selector.zig
│   ├── budget.zig
│   ├── renderer.zig
│   ├── manifest.zig
│   └── compaction.zig
│
├── prompt/
│   ├── pack.zig
│   ├── section.zig
│   ├── catalog.zig
│   ├── composer.zig
│   └── asset_format.zig
│
├── skill/
│   ├── manifest.zig
│   ├── pack.zig
│   ├── catalog.zig
│   ├── resolver.zig
│   ├── instance.zig
│   └── migration.zig
│
├── tool/
│   ├── descriptor.zig
│   ├── registry.zig
│   ├── resolver.zig
│   ├── prepare.zig
│   ├── authorization.zig
│   ├── planner.zig
│   ├── batch.zig
│   ├── dispatcher.zig
│   └── result.zig
│
├── model/
│   ├── contract.zig
│   ├── capabilities.zig
│   ├── registry.zig
│   ├── router.zig
│   ├── retry.zig
│   ├── tokenizer.zig
│   └── media.zig
│
├── world/
│   ├── provider.zig
│   ├── snapshot.zig
│   ├── section.zig
│   └── stale_policy.zig
│
├── session/
│   ├── event.zig
│   ├── journal.zig
│   ├── reducer.zig
│   ├── branch.zig
│   ├── checkpoint.zig
│   ├── recovery.zig
│   └── store.zig
│
├── memory/
│   ├── working.zig
│   ├── record.zig
│   ├── candidate.zig
│   ├── retrieval.zig
│   ├── write_policy.zig
│   └── store.zig
│
├── lifecycle/
│   ├── event.zig
│   ├── observer.zig
│   ├── interceptor.zig
│   └── registry.zig
│
├── operation/
│   ├── registry.zig
│   ├── resource_plan.zig
│   └── main_thread_queue.zig
│
├── trace/
│   ├── format.zig
│   ├── writer.zig
│   ├── reader.zig
│   ├── replay.zig
│   ├── diff.zig
│   └── redaction.zig
│
├── abi/
│   ├── api.zig
│   ├── handles.zig
│   ├── buffers.zig
│   └── validation.zig
│
└── adapters/
    ├── openai_compatible/
    ├── sqlite/
    ├── wasm/
    └── mcp_gateway/
```

不要求一次性完成目录迁移。首要目标是依赖方向正确：

```text
kernel → contracts
adapters → contracts
contracts 不反向依赖 adapters
```

---

# 26. 测试策略

## 26.1 状态机测试

对每个状态和事件组合测试：

- 正常完成；
- `would_block`；
- Cancel；
- Deadline；
- Mailbox 满；
- Input Queue 满；
- World Invalidated；
- Provider Error；
- Tool Error；
- Store Error；
- Trace Error；
- Shutdown。

## 26.2 Multi-Tool 测试

- 两个只读 Tool 并行；
- 写后读排序；
- 不重叠 Range 并行；
- Main Thread + Worker Tool；
- 参数 Delta 交错；
- Tool Call 重复 ID；
- Tool Batch 超限；
- 实际完成顺序与模型顺序不同；
- 不可逆 Tool 恢复不重试。

## 26.3 Context Golden Test

固定输入下比较：

- ContextItem 列表；
- Selected/Dropped；
- Drop Reason；
- Token；
- Prompt/Skill/Tool Hash；
- Provider-neutral Message；
- Context Manifest。

## 26.4 Prompt/Skill Test

- Replace/Append 顺序；
- Namespace 保护；
- Hash；
- Profile 条件；
- Skill 冲突；
- Skill 不能扩权；
- State Migration；
- Shipping 拒绝未签名/未列入 Manifest 的资产。

## 26.5 Recovery Test

在每个 Durable Boundary 注入崩溃：

- Queue append 前后；
- Turn start 前后；
- Model request start/finish；
- Tool prepare/execute/finish；
- Receipt 写入前后；
- Compaction commit 前后；
- Checkpoint 前后；
- Store 尾部损坏或 partial record。

恢复后检查不丢输入、不重复不可逆副作用、不生成悬空 Handle。

## 26.6 Fuzz

- Provider Stream Parser；
- Interleaved Tool Call Events；
- JSON Schema；
- Canonical JSON；
- Trace Reader；
- Session Event Decoder；
- Prompt/Skill Pack；
- C ABI struct size/version；
- Resource Range overlap；
- Context Budget；
- Unicode 和超长 Payload。

## 26.7 Feature Matrix

每个 PR 必须验证：

```text
minimal debug
minimal release-safe
runtime debug
runtime release-safe
C11 header
C++17 header
replay
sanitizer（平台支持时）
```

---

# 27. 迁移计划

## M0：Contract Split，行为不变

目标：从单体 Agent Loop 抽出接口，但保持现有测试和 ABI 行为。

工作：

- 新建 `AgentKernel`；
- 抽出 `ContextPipeline` 接口，暂由 Legacy Adapter 调用现有 Builder；
- 抽出 `ToolOrchestrator` 接口，暂保持单 Tool；
- 抽出 `SessionJournal` 接口，使用 Memory Adapter；
- Runtime/Agent 不直接构造具体 Builder/Session；
- 增加 Dependency Generation Ref。

验收：

- 现有测试全部通过；
- Trace/Replay 不回退；
- Minimal Profile 无线程；
- C ABI v2 不变。

## M1：Context V2

工作：

- `ContextItem`、Trust、Role、Sensitivity；
- Prompt Section 基础结构；
- mandatory 预留与类别预算；
- Tool Schema 计入 Token；
- Provider Tokenizer 接口；
- 完整 Context Manifest；
- World 默认作为 Data；
- immutable Tool Catalog snapshot。

验收：

- 当前输入和 Tool Result 不被 optional 内容挤出；
- 每个 dropped item 有原因；
- 选择结果确定；
- Manifest 可用于 Differential Replay。

## M2：Multi-Tool 与动态资源

工作：

- Model Stream 支持多 `call_id`；
- ToolCallBatch；
- `Prepare`；
- 动态 ResourceAccess；
- 冲突图；
- 并行/顺序调度；
- ToolResult 双通道；
- 取消“使用一次后隐藏 Tool”。

验收：

- 无冲突 Tool 可并行；
- 冲突 Tool 顺序确定；
- Session 结果保持模型顺序；
- Main Thread Tool 只经 Host pump；
- 重复调用检测仍有效。

## M3：Input Queue 与 WorldProvider

工作：

- steer/follow-up/next-turn；
- World invalidation；
- Partial Snapshot；
- stale policy；
- Runtime `tickMany`；
- Agent activation/fairness。

验收：

- 模型进行中可 steering；
- 场景卸载安全取消；
- stale 写 Tool 不自动执行；
- 多 Agent 不出现单 Agent 饥饿。

## M4：PromptPack 与 SkillPack

工作：

- Section Graph；
- Prompt cache metadata；
- Task-specific Prompt；
- Skill Catalog；
- Progressive Disclosure；
- Skill Activation/State；
- `.narprompt` / `.narskill` 编译工具。

验收：

- Prompt/Skill Version 和 Hash 进入 Trace；
- Skill 不能扩权；
- Shipping 不依赖目录扫描；
- Prompt 差异可独立回放比较。

## M5：Durable Session 与 Memory

工作：

- Append-only Semantic Journal；
- StoreVTable；
- Reducer/Checkpoint；
- Restore Policy；
- Working Memory；
- Memory Candidate/Commit；
- SQLite 参考 Adapter。

验收：

- 任意 durable boundary 崩溃后保守恢复；
- 不自动重试不可逆 Tool；
- Host 缺少依赖时明确失败；
- Memory 与 World 冲突可识别。

## M6：Extension Ecosystem

工作：

- Typed Hook；
- WASM Adapter；
- MCP Gateway；
- Engine Bindings；
- Editor 热更新；
- 更多 Provider。

前置条件：M0–M5 的契约已稳定。MCP、WASM 和多 Agent 高级能力不得反向改变 Kernel 的权限和调度语义。

---

# 28. 推荐 PR 拆分

```text
PR 1  refactor: extract AgentKernel and contracts
PR 2  context: typed ContextItem and full manifest
PR 3  context: reserve-first budget and tokenizer contract
PR 4  model: interleaved multi-tool stream
PR 5  tool: prepare, dynamic resources and ToolCallBatch
PR 6  tool: conflict planner and parallel dispatch
PR 7  kernel: bounded steer/follow-up queues
PR 8  world: provider and stale policy
PR 9  prompt: PromptPack and section composer
PR 10 skill: catalog, activation and state
PR 11 session: semantic journal and reducer
PR 12 session: recovery and checkpoint
PR 13 memory: working memory and candidate pipeline
PR 14 extension: typed hooks
PR 15 adapters: SQLite/WASM/MCP as optional packages
```

每个 PR 必须可以单独构建、测试和回放，避免一次性重写整个 Runtime。

---

# 29. 架构决策

保留原 `arch.md` 的 ADR-001 至 ADR-008，并新增：

## ADR-009：Kernel 与可替换服务分离

Turn 状态机、预算、取消、顺序和恢复边界属于 Kernel；Model、World、Store、Memory 和 Tool 实现属于 Adapter。

## ADR-010：Context 使用类型化 Pipeline

所有模型输入先成为带 trust、role、scope、revision 和 sensitivity 的 ContextItem，再进行选择和渲染。

## ADR-011：Tool 使用 Resolve/Prepare/Authorize/Plan/Execute

动态资源规划必须在副作用前完成；多 Tool Call 由冲突图调度。

## ADR-012：Session 是语义 Journal

Transcript 不是恢复模型。所有已接受的关键 mutation 必须在对应 durability 模式下进入 append-only Journal。

## ADR-013：World、Memory、Session 和 Skill State 分离

World 由 Host 权威管理；Memory 可过期；Session 记录执行；Skill State 由版本化 Schema 管理。

## ADR-014：Skill 不能授予能力

Skill 只能声明需求并进一步收紧权限。

## ADR-015：Host 负责恢复不可序列化依赖

Tool implementation、Provider、Hook、World Provider 和 Auth 不持久化；恢复时由 Host 重新注册，并通过 ID/Version/Hash 校验。

## ADR-016：World Data 不默认拥有 System 权限

动态世界、用户、Tool 和外部内容默认作为低信任数据渲染。

## ADR-017：Hook 必须类型化

Observer 只读；Interceptor 返回事件专属决策；不提供万能可变事件总线。

## ADR-018：MCP 不是内部 Tool ABI

MCP 只通过外部 Gateway Adapter 接入。

## ADR-019：Native 调度语义优先

主线程 safe point、Frame Budget、Object generation、World Revision 和资源冲突优先于 CLI Agent 的便利抽象。

---

# 30. 明确不做的事情

在 V2 核心契约稳定前，不实施：

- 通用 Workflow DSL；
- 自动多 Agent 组织；
- 完整 Vector DB；
- 模型自动永久记忆一切；
- 让 Skill 执行任意 Shell；
- 运行时下载并加载任意 Native 插件；
- 将 MCP Tool 直接注册为无 Policy Overlay 的内部 Tool；
- 让 Hook 获得完整 Runtime 可变引用；
- 将 World Snapshot 长期复制进 Transcript；
- 自动重试未知副作用 Tool；
- 在主线程等待 Provider、Store、用户确认或长 Tool；
- 为了支持某个 Provider 把其私有格式写入 Kernel。

---

# 31. 开放问题

以下问题保留到对应里程碑，用测试和实际集成决定：

1. Context 选择算法首版使用纯规则，还是增加可选小模型 rerank；
2. PromptPack/SkillPack 的签名格式由 NAR 定义还是交给 Host；
3. Tool Result 的 `app_payload` 是否需要统一二进制 Schema Registry；
4. Session Journal 是否内建 Hash Chain，还是只要求 Store 提供完整性；
5. Working Memory Patch 使用 JSON Patch、自定义二进制格式还是 Zig Typed Reducer；
6. `steer` 默认是否取消当前 Provider Request；
7. SideEffectReceipt 的最小统一字段；
8. 跨 Savegame 的 Agent Memory 默认迁移还是隔离；
9. 多 Agent 共用 Model Request Batch 是否属于 Runtime Adapter 而非 Kernel；
10. Prompt Tokenizer 缺失时的保守估算系数；
11. Skill WASM 是否允许直接产生 ContextItem，还是只能调用受限 Host API；
12. C ABI 下一 breaking version 的发布时间点。

这些问题不得阻塞 M0–M2。优先稳定 Kernel、Context 和 Tool 的语义。

---

# 32. 最终目标形态

```text
Game / Native App
│
├── 注册 WorldProvider、Tool、Model、Store、PromptPack、SkillPack
├── 创建 Runtime 和 Agent
├── enqueue input / world invalidation
├── 每帧或事件循环调用 tick / tickMany
├── 在安全点 pump main-thread jobs
├── 轮询 Agent Event
└── 在 Savegame / Shutdown 边界 checkpoint / shutdown

NAR Kernel
│
├── 不拥有游戏世界
├── 不拥有平台权限
├── 不执行隐藏后台循环
├── 不依赖 Node/Python/JVM
├── 不让模型绕过 Tool/Policy
├── 不把 Transcript 当全部状态
└── 提供确定、可取消、可观测、可恢复的 Agent Turn
```

最终判断：

> NAR 的竞争力不在于提供最多的 Agent 功能，而在于把 Agent 执行语义压缩成一个适合嵌入 Native Runtime 的小型、稳定、可验证内核。

V2 应优先完成 `ContextPipeline`、`ToolOrchestrator`、`SessionJournal` 和 `PromptPack + SkillPack`。完成这些基础契约后，Memory、WASM、MCP、更多模型和游戏引擎绑定都可以作为 Adapter 或 Policy 包自然接入，而不会继续扩大 `agent_loop` 的职责。

---

# 33. 参考与吸收边界

本文参考以下项目的公开架构与文档思想：

- [NAR](https://github.com/in-dreaming/nar) 当前 `README.md`、`docs/arch.md` 和核心实现；
- [Pi](https://github.com/earendil-works/pi) 的 Agent Harness、durable session、hook 和 skill 文档；
- [`claude-code-analysis`](https://github.com/liuup/claude-code-analysis) 中关于 Prompt 管理与 Agent Memory 的分析。

使用原则：

- Pi 的实现采用宽松开源许可，可作为实现参考，但仍应保持 NAR 的 native/game 语义；
- `claude-code-analysis` 只作为架构观察资料，不复制其分析对象中的源码、Prompt 原文、私有常量或受限制内容；
- NAR 的实现应基于本文定义的公开契约进行 clean-room 设计；
- 任何第三方代码进入仓库前必须单独确认许可证、版权归属和依赖边界。
