# Native Game Agent Runtime

## 面向 Zig/C 游戏引擎的原生 Agent Runtime 完整架构设计

**文档状态：** 架构设计稿
**目标语言：** Zig + C ABI
**目标平台：** Windows / Linux / macOS，后续支持 Android / iOS / Console
**核心定位：** 可嵌入游戏 Runtime、Editor、自动化测试程序和独立服务器的轻量原生 Agent 执行框架

---

# 1. 背景

当前主流 Agent 框架大多面向：

* Coding Agent；
* Web 服务；
* Python/TypeScript 应用；
* 企业工作流；
* 浏览器和桌面自动化；
* 长生命周期后台服务。

典型框架如 Pi、LangGraph、Mastra、Claude Agent SDK 等，通常默认：

* 运行时可以依赖 Node.js 或 Python；
* 工具可以直接访问文件系统、Shell 和网络；
* Agent 延迟以秒为单位；
* 运行环境拥有较宽松的内存和线程资源；
* Agent 与宿主程序之间主要通过文本、JSON 或 RPC 交互；
* Agent 崩溃通常不会直接影响实时渲染或游戏逻辑。

这些假设并不适用于游戏 Runtime。

游戏 Runtime 中的 Agent 需要处理：

* 严格的线程亲和性；
* 游戏对象生命周期；
* 每帧时间预算；
* 高频世界状态变化；
* 网络波动；
* 游戏暂停、关卡切换与对象卸载；
* 可回放、可复现和自动化测试；
* 发布版本的安全权限；
* 本地模型与远端模型混合；
* 多个平台和多种硬件；
* 与 ECS、行为树、Task Graph、资源系统、UI 系统等原生模块协作。

因此，本项目不应被定义为“将 Pi 移植到 Zig”，而应被定义为：

> 构建一个面向实时交互软件的 Native Agent Runtime，吸收 Pi 的模型抽象、Agent Loop、工具调用、状态管理和事件流能力，并针对游戏引擎重新设计调度、权限、上下文、对象访问和回放机制。

Pi 当前明确拆分为统一多模型接口 `pi-ai`、负责工具调用与状态管理的 `pi-agent-core`，以及上层 Coding Agent；这种分层方式值得参考，但 Pi 本身没有内建的细粒度文件、进程、网络权限隔离，官方建议通过容器或沙箱提供安全边界，这与游戏 Runtime 所需的进程内能力隔离并不相同。

---

# 2. 项目定位

## 2.1 一句话定义

Native Game Agent Runtime 是一套：

> 以 Zig 实现、通过稳定 C ABI 暴露、支持流式模型调用、结构化工具执行、异步任务、权限控制、上下文构建、状态持久化和确定性回放的原生 Agent Harness。

本文暂以 **NAR：Native Agent Runtime** 作为项目代号。

---

## 2.2 NAR 不是什么

NAR 不是：

* NPC 行为树替代品；
* ECS 框架；
* Gameplay Framework；
* 大模型推理引擎；
* Workflow 编排平台；
* MCP Server 集合；
* 脚本语言；
* 游戏服务器框架；
* 完整 Coding Agent；
* 独立的游戏 AI 产品。

NAR 负责的是：

> 将模型、上下文、工具、策略和游戏 Runtime 安全地组织为一个可执行 Agent。

---

## 2.3 NAR 的适用场景

### 游戏内智能角色

* 智能 NPC；
* AI 队友；
* 战术指挥；
* 动态剧情角色；
* 游戏教学助手；
* 玩家陪伴角色；
* 自然语言任务交互；
* 动态难度控制。

### Gameplay Agent

* 自动玩游戏；
* 根据技能描述完成目标；
* UI 操作；
* 游戏画面理解；
* Bug 发现；
* 卡关检测；
* 性能路径自动探索；
* 自动回归测试。

### Runtime 调试 Agent

* 查询游戏对象；
* 查询 ECS 状态；
* 分析日志；
* 分析内存；
* 分析 Profiler；
* 检查卡死状态；
* 定位资源异常；
* 自动生成诊断报告。

### Editor Agent

* 场景编辑；
* 资产查找；
* 自动摆放；
* 参数调节；
* 蓝图或状态机生成；
* 测试关卡创建；
* 调用构建、SVN、Profiler 等外部工具。

### 游戏运维 Agent

* 服务器状态诊断；
* 玩家异常行为分析；
* 配置检查；
* 自动化事件执行；
* 灰度验证；
* 线上问题取证。

---

# 3. 设计目标

## 3.1 核心目标

NAR 应满足：

1. **原生嵌入**

   可以作为静态库或动态库嵌入游戏 Runtime，不需要 Node.js、Python 或 JVM。

2. **Zig 实现，C ABI 优先**

   内部主要使用 Zig，对外暴露稳定 C ABI，使 C、C++、Rust、C#、Unity、Unreal 和其他语言能够接入。

3. **模型无关**

   支持 OpenAI-compatible、Anthropic、Gemini、本地 llama.cpp、自有推理服务和 Mock Backend。

4. **工具无关**

   Agent Core 不依赖 ECS、UI、导航、动画、背包或特定游戏系统。

5. **异步优先**

   网络、模型、工具执行和持久化不阻塞主线程。

6. **可取消**

   所有 Agent Turn、模型请求、工具调用和长操作必须具备取消语义。

7. **可回放**

   Agent 的模型输入、模型输出、工具调用和工具结果可以记录、重放和对比。

8. **安全可控**

   工具具有能力声明、权限校验、参数校验、资源预算和状态约束。

9. **实时系统友好**

   允许设置 CPU、内存、主线程、Token、工具调用和模型成本预算。

10. **可裁剪**

    发布版本可以关闭：

    * MCP；
    * 文件系统；
    * 本地模型；
    * WASM 扩展；
    * 调试工具；
    * 长期记忆；
    * 多 Agent。

---

## 3.2 非目标

MVP 阶段不追求：

* 通用 Workflow DSL；
* 图形化工作流编辑器；
* 完整 RAG 平台；
* 完整向量数据库；
* 大规模分布式 Agent 调度；
* Agent 市场；
* 自动生成并加载 Native 代码；
* 让 LLM 逐帧控制角色；
* 在所有移动设备上运行大语言模型；
* 与所有模型 Provider 完全兼容。

---

# 4. 设计原则

## 4.1 LLM 不进入高频控制环

LLM 适合：

* 目标选择；
* 高层计划；
* 语义理解；
* 情境判断；
* 任务分解；
* 异常诊断；
* 自然语言交互。

LLM 不适合：

* 每帧寻路；
* 每帧转向；
* 动画混合；
* 碰撞响应；
* 连续瞄准；
* 高频技能判定；
* 实时物理控制。

推荐分层：

```text
LLM Agent
    │
    │ 低频决策：数百毫秒至数秒
    ▼
Goal / Intent / Plan
    │
    ▼
Gameplay Planner / State Tree / GOAP
    │
    ▼
Behavior Tree / Ability / Navigation
    │
    │ 高频确定性执行
    ▼
Movement / Animation / Combat / UI
```

LLM 应输出：

```json
{
  "goal": "保护玩家并撤退到最近掩体",
  "priority": "high",
  "constraints": [
    "与玩家距离不得超过15米",
    "生命低于20%时优先治疗"
  ]
}
```

而不是输出：

```text
向左走0.2米；
转身3度；
等待一帧；
再次向左走。
```

---

## 4.2 Agent 只能看到能力，不能看到裸实现

模型不能直接访问：

* 裸指针；
* ECS 内部 Archetype；
* 任意函数地址；
* C++ RTTI 对象；
* 任意反射函数；
* 任意脚本环境；
* 游戏进程完整内存；
* 任意文件系统路径。

模型只能调用经过注册的 Tool。

---

## 4.3 Agent Core 不拥有世界状态

Agent Runtime 不应复制或接管游戏世界。

世界状态属于：

* ECS；
* Object System；
* Gameplay System；
* Scene；
* Server State；
* UI Tree；
* Inventory；
* Quest；
* Navigation。

NAR 只获取当前任务所需的快照或稳定句柄。

---

## 4.4 所有长操作必须显式异步

以下操作不能表现成同步函数：

* 移动到目标；
* 加载关卡；
* 下载资源；
* 等待 UI；
* 等待动画；
* 等待服务器响应；
* 启动游戏；
* 执行自动测试；
* 等待构建；
* 模型推理。

它们必须返回异步操作句柄。

---

## 4.5 所有执行必须可观测

每个 Agent Turn 都应能够回答：

* 为什么被唤醒；
* 使用了什么上下文；
* 调用了哪个模型；
* 消耗了多少 Token；
* 选择了什么工具；
* 工具参数是什么；
* 工具是否被权限系统拒绝；
* 工具执行耗时；
* 世界版本是否变化；
* 最终为什么停止。

---

# 5. 现有方案调研与判断

## 5.1 Pi

Pi 当前将项目拆分为：

* 多 Provider 模型抽象；
* Agent Core；
* Coding Agent；
* TUI。

Agent Core 提供工具调用和状态管理；其整体结构适合作为 NAR 的概念参考。

可借鉴：

* 模型层与 Agent 层分离；
* 流式事件；
* 工具调用循环；
* Session；
* 上层 Agent 与底层 Harness 分离；
* Provider 适配器；
* Agent 状态管理。

不应直接复用：

* TypeScript Runtime；
* Node.js 包系统；
* Coding Tool；
* Shell；
* 文件系统默认权限；
* CLI Session 语义；
* 面向聊天消息的全部上下文模型。

---

## 5.2 Zig 原生 Agent 项目

截至 2026 年 7 月，已经出现少量 Zig Agent Runtime 项目。

### ZSeven-W/agent

该项目使用 Zig 实现多轮 Agent、流式事件、工具执行、Provider VTable、C ABI、NAPI、Agent Team、上下文裁剪和取消机制。它说明“Zig 原生 Agent Core + C ABI”在工程上完全可行。该项目当前规模较小，GitHub 页面显示仅有少量社区采用，尚不足以直接作为商用游戏 Runtime 的基础。

它值得参考的内容包括：

* Provider VTable；
* Tool VTable；
* Pull-based Event Iterator；
* C ABI；
* 原子取消；
* 外部工具结果回传；
* DAG Message；
* Context Strategy。

### KrillClaw

KrillClaw 是一个面向嵌入式和边缘设备的 Zig Agent Runtime，提供 HTTP、SSE、工具调用、上下文管理、KV、MCP 和硬件工具等能力。其项目重点是小体积与零依赖，而不是复杂游戏引擎集成；它使用 BSL 1.1，而非完全宽松许可证，因此不宜不经评估直接作为商业游戏引擎核心依赖。

它证明了：

* Agent Loop 本身可以非常小；
* Zig 标准库足以实现 HTTP、SSE、JSON 和工具循环；
* Agent Runtime 不需要数百 MB 的 Runtime；
* 嵌入式 Profile 与桌面 Profile 可以使用编译期裁剪。

### 总体判断

目前已有 Zig 项目可以作为原型参考，但仍缺少同时满足以下条件的成熟框架：

```text
Zig/C ABI
+ 游戏对象生命周期
+ 主线程工具
+ Resource Task Graph
+ World Snapshot
+ 发布版权限
+ Trace/Replay
+ Gameplay Intent
+ 多模态感知
+ 跨平台游戏 Runtime
```

因此推荐：

> 参考现有实现，但核心架构自行掌控。

---

## 5.3 llama.cpp

llama.cpp 提供原生 C/C++ 推理能力以及独立 HTTP Server。其 Server 支持 OpenAI 风格接口，并已提供多种模型的函数调用格式支持。

推荐两种接入模式：

### In-process

```text
Game Runtime
    │
    ▼
NAR llama.cpp Backend
    │
    ▼
llama.cpp C API
```

优点：

* 无 IPC；
* 低额外延迟；
* 部署简单；
* 可共享模型实例；
* 适合工具程序和离线测试。

缺点：

* 推理崩溃可能影响游戏；
* 与渲染争抢 GPU；
* 增加进程内存；
* 升级模型较困难；
* 移动端包体压力大。

### Sidecar

```text
Game Runtime
    │ HTTP / IPC
    ▼
llama-server
    │
    ▼
Local Model
```

优点：

* 故障隔离；
* 模型独立更新；
* 更容易限制 GPU；
* 可以多个游戏进程共享；
* 开发和生产配置统一。

建议：

* Editor：优先 Sidecar；
* PC 测试 Agent：Sidecar；
* 独立工具：In-process 可选；
* 正式游戏 Runtime：远端或 Sidecar；
* 移动端：远端优先。

---

## 5.4 WebAssembly Runtime

WAMR 提供 C API 和宿主 Native API 注册能力，定位是轻量、可嵌入和可配置的 WebAssembly Runtime。

Wasmtime 提供完整 C/C++ Embedding API，并支持标准 WebAssembly API 和自身扩展 API。

推荐：

| 场景            | Runtime              |
| ------------- | -------------------- |
| 游戏 Runtime    | WAMR                 |
| Editor        | Wasmtime 或 WAMR      |
| Agent Server  | Wasmtime             |
| 极小移动端 Profile | WAMR Interpreter/AOT |
| 不可信扩展         | WASM 沙箱              |
| 核心引擎工具        | Native Tool          |

---

## 5.5 MCP

MCP 是基于 Host、Client、Server 的外部上下文和工具接入协议，协议基于 JSON-RPC，并面向有状态会话。

MCP 适合：

* SVN；
* Git；
* 构建服务；
* Jira；
* 文档；
* Profiler 数据；
* 机器农场；
* 云服务；
* 外部数据库。

MCP 不适合直接作为内部 ECS 或 Gameplay Tool ABI：

* JSON 序列化没有必要；
* 动态工具发现增加上下文；
* 对象生命周期难表达；
* 主线程亲和性难表达；
* 高频调用成本高；
* 权限边界不够贴近游戏系统。

推荐：

```text
NAR
├── Native Tool Registry
├── WASM Tool Registry
└── MCP Gateway
      └── External MCP Servers
```

---

# 6. 总体架构

```text
┌───────────────────────────────────────────────────────────────┐
│                       Game / Editor                           │
│                                                               │
│  NPC Agent  Gameplay Agent  Debug Agent  Editor Agent         │
│                                                               │
│  ECS  UI  Navigation  Ability  Quest  Asset  Profiler         │
└───────────────────────────────┬───────────────────────────────┘
                                │ Zig API / C ABI
┌───────────────────────────────▼───────────────────────────────┐
│                    Native Agent Runtime                       │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ Agent Facade / Agent Instance                           │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                               │
│  Agent Loop        Scheduler           Event Mailbox          │
│  Context Builder   Tool Dispatcher     Policy Engine          │
│  Session Store     Trace & Replay      Budget Manager         │
│  Memory            Model Router        Capability System      │
│                                                               │
├───────────────────┬───────────────────┬───────────────────────┤
│ Model Backends    │ Tool Backends     │ Extension Backends    │
│                   │                   │                       │
│ OpenAI-compatible │ Native Tools      │ WAMR                  │
│ Anthropic         │ Engine Adapters   │ Wasmtime              │
│ Gemini            │ Remote Tools      │ Native Plugin         │
│ llama.cpp         │ MCP Gateway       │ Script Adapter        │
│ Mock / Replay     │                   │                       │
└───────────────────┴───────────────────┴───────────────────────┘
```

---

# 7. 架构分层

## 7.1 Foundation Layer

提供与 Agent 无关的基础能力：

* Allocator；
* String；
* Buffer；
* JSON；
* HTTP；
* SSE；
* URI；
* Time；
* UUID；
* Hash；
* Thread；
* Mutex；
* Atomic；
* Channel；
* Future；
* Cancellation；
* File；
* Logging。

这层可以复用引擎已有基础设施，也可以提供默认实现。

要求：

* NAR Core 不直接依赖某个 Job System；
* 通过 Adapter 对接引擎线程池；
* 独立测试时可使用自带简单 Executor。

---

## 7.2 Model Layer

负责：

* 模型能力描述；
* 请求构建；
* Provider 协议；
* 流式事件；
* Tool Calling；
* Structured Output；
* Token Usage；
* 重试；
* 限流；
* 取消。

不负责：

* Agent Loop；
* Tool 执行；
* Context 决策；
* Gameplay 状态。

---

## 7.3 Agent Core Layer

负责：

* Agent 状态机；
* 多轮模型调用；
* 工具调用循环；
* 终止条件；
* 错误恢复；
* 事件发出；
* Session 更新；
* Turn 生命周期。

---

## 7.4 Tool Runtime Layer

负责：

* Tool 注册；
* Tool Schema；
* 参数验证；
* Capability；
* 权限；
* Thread Affinity；
* 资源访问声明；
* 调用调度；
* 异步结果；
* Tool Trace。

---

## 7.5 Context and Memory Layer

负责：

* Prompt 组成；
* World Snapshot；
* Conversation；
* Working Memory；
* Long-term Memory；
* Context 压缩；
* Tool 选择；
* Token 预算。

---

## 7.6 Session and Trace Layer

负责：

* Session；
* Turn；
* Message；
* Event；
* Tool Call；
* 模型请求；
* 模型响应；
* Record；
* Replay；
* Branch；
* Diff。

---

## 7.7 Integration Layer

包括：

* ECS Adapter；
* UI Adapter；
* Navigation Adapter；
* Task Graph Adapter；
* Resource Graph Adapter；
* Profiler Adapter；
* Asset Adapter；
* Network Adapter；
* MCP Adapter；
* WASM Adapter。

---

# 8. 核心对象模型

## 8.1 Runtime

```zig
pub const AgentRuntime = struct {
    allocator: Allocator,
    executor: Executor,
    model_registry: ModelRegistry,
    tool_registry: ToolRegistry,
    policy_registry: PolicyRegistry,
    session_store: SessionStore,
    trace_sink: TraceSink,
    clock: Clock,
};
```

Runtime 是全局设施容器。

职责：

* 创建 Agent；
* 管理共享 Backend；
* 管理工具；
* 管理模型连接；
* 管理全局预算；
* 统一调度；
* 关闭与排空。

---

## 8.2 Agent Definition

Agent Definition 是不可变配置。

```zig
pub const AgentDefinition = struct {
    name: []const u8,
    system_prompt: []const u8,
    model_policy: ModelPolicy,
    tool_filter: ToolFilter,
    context_strategy: ContextStrategyId,
    memory_policy: MemoryPolicy,
    execution_policy: ExecutionPolicy,
    security_policy: PolicyId,
};
```

Agent Definition 可作为：

* 资产；
* 配置文件；
* WASM Manifest；
* 服务器下发配置；
* Editor 中的 Agent Template。

---

## 8.3 Agent Instance

```zig
pub const AgentInstance = struct {
    id: AgentId,
    definition: *const AgentDefinition,
    session_id: SessionId,
    state: AgentState,
    mailbox: EventMailbox,
    active_turn: ?TurnHandle,
    cancellation: CancellationSource,
    user_data: ?*anyopaque,
};
```

Agent Instance 表示运行中的具体 Agent。

---

## 8.4 Agent State

```zig
pub const AgentState = enum {
    idle,
    queued,
    building_context,
    waiting_model,
    processing_model_output,
    waiting_tool,
    suspended,
    completed,
    failed,
    cancelling,
    cancelled,
};
```

状态转换：

```text
Idle
  │ Event
  ▼
Queued
  ▼
BuildingContext
  ▼
WaitingModel
  ▼
ProcessingModelOutput
  ├────────────── No Tool ──────────────► Completed
  │
  ▼
WaitingTool
  │
  ├── Tool Result ──────────────────────► BuildingContext
  ├── Suspend ──────────────────────────► Suspended
  ├── Failure ──────────────────────────► Failed / Recovery
  └── Cancel ───────────────────────────► Cancelled
```

---

# 9. Agent Loop

## 9.1 标准循环

```text
1. 接收触发事件
2. 创建 Turn
3. 构造 Context
4. 选择 Model
5. 发起模型请求
6. 接收流式事件
7. 解析 Tool Call
8. 校验工具权限和参数
9. 调度 Tool
10. 收集 Tool Result
11. 更新 Session
12. 判断是否继续
13. 输出最终结果
14. 提交 Trace
```

---

## 9.2 伪代码

```zig
fn runTurn(agent: *AgentInstance, trigger: AgentEvent) !void {
    var turn = try Turn.begin(agent, trigger);
    defer turn.finish();

    while (true) {
        try turn.budget.check();

        const context = try buildContext(agent, &turn);

        const model = try runtime.model_router.select(
            agent.definition.model_policy,
            context.requirements,
        );

        var stream = try model.start(context.request, turn.cancel_token);
        defer stream.deinit();

        var assistant = AssistantResponse.init(turn.arena);

        while (try stream.next()) |event| {
            try turn.emitModelEvent(event);
            try assistant.consume(event);
            try turn.budget.consume(event);
        }

        if (assistant.tool_calls.len == 0) {
            try turn.complete(assistant.output);
            return;
        }

        const results = try dispatchToolCalls(
            agent,
            &turn,
            assistant.tool_calls,
        );

        try turn.appendToolResults(results);

        if (turn.should_stop) {
            return;
        }
    }
}
```

---

## 9.3 终止条件

必须支持：

* 模型返回完成；
* 用户取消；
* Agent 被销毁；
* 世界卸载；
* Session 关闭；
* 超时；
* 最大 Turn 次数；
* 最大模型调用数；
* 最大工具调用数；
* 最大 Token；
* 最大成本；
* 最大错误数；
* 检测到重复循环；
* Tool 返回不可恢复错误；
* 权限拒绝；
* 上层 Gameplay 系统终止任务。

---

## 9.4 循环检测

Agent 可能重复调用同一工具。

建议计算：

```text
LoopKey =
    hash(
        tool_name,
        normalized_arguments,
        relevant_world_revision,
        recent_tool_results
    )
```

检测规则：

* 同一 Tool + Arguments 连续出现 N 次；
* 相同错误连续出现；
* Context 没有新增信息；
* 模型输出语义重复；
* Tool 没有改变世界版本；
* Token 消耗快速增长。

处理策略：

1. 首次重复：向模型注入警告；
2. 再次重复：要求重新规划；
3. 达到阈值：停止 Turn；
4. 写入 `agent_loop_detected` Trace。

---

# 10. Model Abstraction

## 10.1 模型能力

```zig
pub const ModelCapabilities = packed struct {
    text: bool,
    image_input: bool,
    audio_input: bool,
    tool_calling: bool,
    parallel_tool_calling: bool,
    structured_output: bool,
    reasoning_tokens: bool,
    prompt_cache: bool,
    streaming: bool,
};
```

---

## 10.2 Model Descriptor

```zig
pub const ModelDescriptor = struct {
    id: ModelId,
    provider: ProviderId,
    model_name: []const u8,
    capabilities: ModelCapabilities,
    max_context_tokens: u32,
    max_output_tokens: u32,
    cost: ModelCost,
    latency_class: LatencyClass,
};
```

---

## 10.3 Provider VTable

```zig
pub const ModelBackendVTable = struct {
    get_capabilities: *const fn (
        backend: *anyopaque,
    ) ModelCapabilities,

    start_request: *const fn (
        backend: *anyopaque,
        request: *const ModelRequest,
        sink: *const ModelEventSink,
        cancel: CancellationToken,
    ) ModelRequestHandle,

    cancel_request: *const fn (
        backend: *anyopaque,
        handle: ModelRequestHandle,
    ) void,

    destroy: *const fn (
        backend: *anyopaque,
    ) void,
};
```

---

## 10.4 内部统一事件

```zig
pub const ModelEvent = union(enum) {
    response_begin: ResponseBegin,
    text_delta: TextDelta,
    reasoning_delta: ReasoningDelta,
    tool_call_begin: ToolCallBegin,
    tool_argument_delta: ToolArgumentDelta,
    tool_call_end: ToolCallEnd,
    usage: Usage,
    response_end: ResponseEnd,
    error_event: ModelError,
};
```

Agent Core 不解析 Provider 原始 SSE。

各 Provider Adapter 负责将：

* OpenAI SSE；
* Anthropic Events；
* Gemini Stream；
* llama.cpp Stream；

转换成内部统一事件。

---

## 10.5 Model Router

Model Router 根据：

* 是否需要图片；
* 是否需要 Tool Calling；
* 延迟等级；
* 成本预算；
* 隐私要求；
* 网络状态；
* 模型可用性；
* 任务难度；

选择模型。

```zig
pub const ModelPolicy = union(enum) {
    fixed: ModelId,
    ordered_fallback: []const ModelId,
    capability_route: CapabilityRoute,
    custom: CustomModelRouter,
};
```

示例：

```text
简单 UI 操作：
    本地 3B VLM

复杂剧情：
    远端高能力模型

网络不可用：
    本地规则模型或小模型

自动化回放：
    Replay Backend
```

---

# 11. Tool Runtime

## 11.1 Tool Descriptor

```zig
pub const ToolDescriptor = struct {
    id: ToolId,
    namespace: []const u8,
    name: []const u8,
    description: []const u8,

    input_schema: SchemaRef,
    output_schema: SchemaRef,

    flags: ToolFlags,
    capability_requirements: CapabilitySet,
    resource_access: ResourceAccessSet,
    thread_affinity: ThreadAffinity,

    timeout_ms: u32,
    max_result_bytes: u32,
    version: ToolVersion,
};
```

---

## 11.2 Tool Flags

```zig
pub const ToolFlags = packed struct {
    read_only: bool,
    idempotent: bool,
    cancellable: bool,
    async_tool: bool,
    deterministic: bool,
    replayable: bool,
    requires_confirmation: bool,
    hidden_from_model: bool,
    development_only: bool,
};
```

---

## 11.3 Tool 调用接口

```zig
pub const ToolInvokeFn = *const fn (
    context: *ToolContext,
    args: JsonValue,
    completion: ToolCompletionSink,
) ToolInvokeResult;
```

返回值：

```zig
pub const ToolInvokeResult = union(enum) {
    completed: ToolResult,
    pending: ToolOperationHandle,
    rejected: ToolRejection,
    failed: ToolError,
};
```

---

## 11.4 Tool 类型

### Query Tool

只读工具：

* 查询附近实体；
* 查询任务；
* 查询背包；
* 查询 UI；
* 查询性能指标；
* 查询日志。

特点：

* 通常可并行；
* 可以缓存；
* 风险较低；
* 可以声明 Snapshot Revision。

### Command Tool

写工具：

* 移动；
* 使用技能；
* 点击 UI；
* 修改状态；
* 执行调试命令。

特点：

* 默认串行；
* 必须权限校验；
* 可能需要主线程；
* 必须返回世界版本变化。

### Async Tool

长任务：

* 移动到目标；
* 等待动画；
* 运行测试；
* 加载场景；
* 下载资源。

返回 Operation Handle。

### Transaction Tool

多步骤高层操作：

* 购买物品；
* 创建测试场景；
* 批量修改对象；
* 启动完整自动化流程。

事务 Tool 内部自行保证：

* 原子性；
* 补偿；
* 幂等；
* 状态校验。

模型不应自行组合大量低级写工具完成敏感事务。

---

# 12. 游戏对象访问模型

## 12.1 禁止裸指针

工具结果不能包含：

```c
GameObject*
Entity*
Component*
void*
```

应使用稳定句柄：

```zig
pub const ObjectRef = struct {
    world_id: u32,
    object_id: u64,
    generation: u32,
    type_id: u32,
};
```

---

## 12.2 每次访问重新验证

验证：

* World 是否存在；
* Object 是否存在；
* Generation 是否匹配；
* 类型是否匹配；
* Agent 是否有权限；
* 当前阶段是否允许操作；
* 距离、阵营等业务约束是否满足。

---

## 12.3 World Revision

动态世界需要版本号：

```zig
pub const WorldRevision = u64;
```

每个 Tool Result 可包含：

```json
{
  "world_revision_before": 18321,
  "world_revision_after": 18323,
  "stale": false
}
```

模型请求期间世界可能改变。

工具可声明：

```text
requires_revision = 18321
```

若当前版本不一致：

* 自动重新查询；
* 返回 `stale_world_state`；
* 或由业务策略决定是否继续。

---

# 13. Context 架构

## 13.1 Context 组成

```text
Context
├── System Contract
├── Agent Identity
├── Game Rules
├── Current Goal
├── World Snapshot
├── Working Memory
├── Relevant Episodic Memory
├── Recent Conversation
├── Recent Tool Results
└── Available Tool Schemas
```

---

## 13.2 Static Context

包括：

* 角色设定；
* 游戏规则；
* Tool 使用约束；
* 输出格式；
* 安全规则；
* 世界观基础信息。

Static Context 应：

* 可缓存；
* 可哈希；
* 可版本化；
* 尽量不在每轮重复序列化；
* 利用 Provider Prompt Cache。

---

## 13.3 World Snapshot

World Snapshot 是当前任务所需的动态视图。

```zig
pub const WorldSnapshot = struct {
    revision: WorldRevision,
    timestamp: GameTime,
    sections: []SnapshotSection,
};
```

示例：

```json
{
  "revision": 18321,
  "player": {
    "health": 35,
    "position": [10.0, 2.0, 31.0],
    "status": ["poisoned"]
  },
  "current_goal": "到达安全区域",
  "nearby_entities": [
    {
      "id": "enemy:293",
      "distance": 7.2,
      "visible": true
    }
  ],
  "navigation": {
    "has_path": true,
    "estimated_time": 5.3
  }
}
```

World Snapshot 不应无限追加到对话历史。

每轮根据策略重新生成。

---

## 13.4 Working Memory

存储当前任务中的：

* 子目标；
* 已知事实；
* 假设；
* 失败原因；
* 待完成操作；
* 最近计划；
* 用户约束。

```zig
pub const WorkingMemory = struct {
    goal: ?Goal,
    facts: []Fact,
    pending_operations: []OperationRef,
    plan: []PlanStep,
    scratch: []MemoryItem,
};
```

---

## 13.5 Episodic Memory

长期事件：

```zig
pub const MemoryRecord = struct {
    id: MemoryId,
    subject: ValueRef,
    predicate: SymbolId,
    object: Value,
    timestamp: GameTime,
    confidence: f32,
    importance: f32,
    source: MemorySource,
    expiry: ?GameTime,
};
```

例如：

```text
玩家曾救过 NPC A
玩家拒绝加入阵营 B
玩家偏好远程武器
该路线此前发生过伏击
```

---

## 13.6 Context Strategy

```zig
pub const ContextStrategyVTable = struct {
    estimate: *const fn (...) TokenEstimate,
    build: *const fn (...) ContextBuildResult,
    compact: *const fn (...) CompactResult,
};
```

可以提供：

* ChatContextStrategy；
* GameplayContextStrategy；
* DebugContextStrategy；
* VisionAgentContextStrategy；
* MinimalEmbeddedContextStrategy。

---

# 14. Tool Selection 与工具数量控制

当系统存在数百个工具时，不能把所有 Schema 都放入 Prompt。

建议分三层：

```text
Tool Domain
    ▼
Tool Group
    ▼
Concrete Tool
```

例如：

```text
gameplay
├── navigation
│   ├── query_path
│   ├── move_to
│   └── stop_movement
├── inventory
│   ├── list_items
│   ├── use_item
│   └── craft_item
└── combat
    ├── query_abilities
    ├── select_target
    └── execute_ability
```

Tool Resolver 根据：

* Agent 类型；
* 当前 Goal；
* 当前 Game State；
* Capability；
* 工具标签；
* 规则；
* 可选语义检索；

选出本轮工具。

MVP 建议优先规则路由，不要一开始引入向量检索。

---

# 15. 调度与线程模型

## 15.1 线程分类

### Game Main Thread

执行：

* 只能在主线程访问的对象；
* Gameplay Command；
* UI 操作；
* Scene 修改；
* 某些 ECS 写入；
* Actor 生命周期操作。

### Agent Worker

执行：

* Prompt 构造；
* JSON 解析；
* SSE；
* 网络；
* Memory Query；
* 只读计算；
* 模型结果解析；
* Trace 序列化。

### IO Worker

执行：

* HTTP；
* 文件；
* SQLite；
* Trace；
* 外部 RPC。

### Inference Worker

执行：

* llama.cpp；
* Embedding；
* VLM；
* 本地推理。

---

## 15.2 Main Thread Tool

工具声明：

```zig
thread_affinity = .game_main_thread
```

Agent Worker 不直接执行，而是提交 Command：

```text
Agent Worker
    │
    ▼
Main Thread Command Queue
    │
    ▼
Game Tick
    │ execute
    ▼
Completion Queue
    │
    ▼
Agent Worker
```

---

## 15.3 帧预算

每帧允许 NAR 在主线程使用：

```zig
pub const FrameBudget = struct {
    max_main_thread_us: u32,
    max_tool_count: u16,
    max_commands: u16,
};
```

若预算耗尽：

* 剩余 Tool 延迟到下一帧；
* Agent 保持 `waiting_tool`；
* 不阻塞游戏帧。

---

## 15.4 与 Job System 解耦

定义抽象 Executor：

```zig
pub const ExecutorVTable = struct {
    submit: *const fn (
        executor: *anyopaque,
        job: JobFn,
        userdata: *anyopaque,
        priority: JobPriority,
    ) JobHandle,

    cancel: *const fn (... ) void,
    wait: *const fn (... ) WaitResult,
};
```

提供：

* Standalone ThreadPool Adapter；
* Engine Job System Adapter；
* Single-thread Test Adapter；
* Immediate Executor。

---

# 16. Resource-Based Task Graph 接入

工具声明读写资源：

```zig
pub const ResourceAccess = struct {
    resource_id: ResourceId,
    mode: AccessMode,
};

pub const AccessMode = enum {
    read,
    write,
    exclusive,
};
```

示例：

```text
query_inventory:
    read Inventory

query_health:
    read CharacterState

use_item:
    write Inventory
    write CharacterState

move_to:
    write NavigationState
    read WorldCollision
```

调度规则：

* 只读工具可并行；
* 读写冲突需排序；
* 写写冲突默认串行；
* 主线程写入进入主线程图；
* 长期异步 Tool 只在开始和提交阶段占资源；
* 等待外部事件时不持有资源锁。

重要原则：

> Agent Runtime 只生成资源访问描述，不自行实现引擎级资源锁。

---

# 17. Event 与 Mailbox

## 17.1 Agent Event

```zig
pub const AgentEvent = union(enum) {
    user_message: UserMessage,
    world_event: WorldEvent,
    tool_completed: ToolCompletion,
    operation_progress: OperationProgress,
    timer: TimerEvent,
    model_event: ModelEvent,
    cancel: CancelEvent,
    system_event: SystemEvent,
};
```

---

## 17.2 Event 优先级

```zig
pub const EventPriority = enum {
    critical,
    high,
    normal,
    low,
    background,
};
```

例如：

* 玩家直接消息：High；
* 战斗开始：High；
* 生命危险：Critical；
* 环境观察：Low；
* 定期记忆整理：Background。

---

## 17.3 合并与去抖

高频事件不能直接触发模型。

例如：

```text
EnemyPositionChanged 每帧发生
```

应合并为：

```text
NearbyThreatsUpdated
```

策略：

* Last-value；
* 时间窗口合并；
* Set 合并；
* Count 聚合；
* Threshold；
* Debounce；
* Cooldown。

---

# 18. 异步 Tool 与 Operation

## 18.1 Operation State

```zig
pub const OperationState = enum {
    created,
    running,
    waiting,
    completed,
    failed,
    cancelling,
    cancelled,
};
```

---

## 18.2 Operation Handle

```zig
pub const OperationHandle = struct {
    id: OperationId,
    generation: u32,
};
```

---

## 18.3 示例：移动到目标

模型调用：

```json
{
  "name": "move_to",
  "arguments": {
    "target": {
      "type": "position",
      "value": [10, 0, 20]
    },
    "acceptance_radius": 1.0
  }
}
```

立即返回：

```json
{
  "status": "pending",
  "operation_id": "op-9812"
}
```

完成后 Mailbox 收到：

```json
{
  "event": "tool_completed",
  "operation_id": "op-9812",
  "result": {
    "status": "success",
    "travel_time": 4.8
  }
}
```

Agent 可以选择：

* 等待完成；
* 同时执行其他查询；
* 被新的高优先级事件打断；
* 取消移动。

---

# 19. Cancellation

取消必须贯穿：

```text
Agent
  └── Turn
       ├── Model Request
       ├── Tool Call
       ├── Operation
       └── Child Task
```

父 Token 取消时传播给子任务。

```zig
pub const CancellationToken = struct {
    state: *AtomicCancellationState,

    pub fn isCancelled(self: CancellationToken) bool;
    pub fn register(self: CancellationToken, callback: CancelFn) CancelRegistration;
};
```

取消场景：

* 玩家关闭对话；
* 角色死亡；
* 关卡卸载；
* 游戏退出；
* 任务完成；
* 服务器断开；
* Agent 被替换；
* 上层 Gameplay System 接管。

---

# 20. Capability 与安全策略

## 20.1 Capability

```zig
pub const Capability = enum {
    world_read,
    world_write,
    movement_command,
    combat_command,
    inventory_read,
    inventory_write,
    quest_read,
    quest_write,
    ui_read,
    ui_control,
    debug_read,
    debug_write,
    profiler_read,
    filesystem_read,
    filesystem_write,
    process_spawn,
    external_network,
    local_model,
    mcp_access,
};
```

---

## 20.2 Policy

```zig
pub const AgentPolicy = struct {
    capabilities: CapabilitySet,
    allowed_tools: ToolPatternSet,
    denied_tools: ToolPatternSet,

    max_turns: u16,
    max_model_calls: u16,
    max_tool_calls: u16,
    max_parallel_tools: u16,

    max_context_tokens: u32,
    max_output_tokens: u32,
    max_wall_time_ms: u32,
    max_cost_usd_micros: u64,

    allow_external_network: bool,
    require_confirmation_for_writes: bool,
};
```

---

## 20.3 Tool 执行校验链

```text
1. Tool 是否存在
2. Tool Version 是否匹配
3. Agent 是否可见该 Tool
4. Capability 是否满足
5. 输入 Schema 是否通过
6. 参数范围是否有效
7. 对象引用是否有效
8. World Revision 是否可接受
9. 当前 Game State 是否允许
10. Budget 是否足够
11. 是否需要玩家确认
12. 调度到正确线程
```

---

## 20.4 开发版与发布版

### Development Profile

允许：

* Debug Read；
* Profiler；
* 开发文件系统；
* MCP；
* 自动测试；
* Console；
* Trace 全量记录。

### Shipping Profile

默认禁止：

* Shell；
* 任意文件；
* 任意网络；
* Native 动态插件；
* 未签名 WASM；
* Debug Write；
* Console；
* 未注册 MCP；
* 任意代码执行。

---

# 21. Prompt Injection 防护

游戏 Agent 可能从以下位置读到不可信文本：

* 玩家输入；
* 聊天；
* UI；
* 外部文档；
* Mod；
* MCP Server；
* 网页；
* 服务器下发内容。

必须区分：

```text
Trusted Instructions
Trusted Game State
Untrusted Content
Tool Output
User Content
```

Context 中使用明确边界：

```xml
<trusted_game_rules>
...
</trusted_game_rules>

<untrusted_player_text>
...
</untrusted_player_text>
```

但文本边界并不足够。

真正的安全边界必须来自：

* Capability；
* Tool Allowlist；
* 参数校验；
* 输出过滤；
* 预算；
* 线程和对象校验；
* 用户确认；
* 沙箱。

---

# 22. Trace 与 Replay

## 22.1 Trace 目标

支持：

* Bug 复现；
* Agent 行为审计；
* 模型升级回归；
* Tool 行为回归；
* 自动测试；
* 成本分析；
* 性能分析；
* 安全审计。

---

## 22.2 Trace Event

```zig
pub const TraceEvent = union(enum) {
    agent_created,
    turn_started,
    context_built,
    model_request_started,
    model_event,
    model_request_finished,
    tool_call_received,
    tool_call_validated,
    tool_call_started,
    tool_call_finished,
    operation_progress,
    budget_changed,
    turn_finished,
    agent_cancelled,
    error_event,
};
```

---

## 22.3 每个 Turn 记录

```text
Agent Definition Version
Agent ID
Session ID
Turn ID
Trigger Event
World Revision
Model ID
Model Version
Model Parameters
Prompt Hash
完整或脱敏后的 Prompt
模型流式输出
Tool Calls
Tool Arguments
Tool Results
Tool Timings
Token Usage
Cost
Cancellation
Final Outcome
```

---

## 22.4 三种执行模式

### Live

正常调用模型和工具。

### Record

正常执行并记录所有输入输出。

### Replay

不调用真实模型，根据 Trace 返回历史模型事件。

工具可以选择：

* 重放历史结果；
* 重新执行并比较；
* 只验证参数；
* 使用 Mock。

---

## 22.5 Differential Replay

用于模型升级：

```text
同一个 Recorded Context
       ├── Model A
       ├── Model B
       └── Model C
```

比较：

* Tool 选择；
* 参数；
* 成功率；
* 步数；
* Token；
* 延迟；
* 最终结果；
* 安全违规。

---

# 23. Session 模型

## 23.1 数据结构

```text
Session
├── Session Metadata
├── Agent Definition Version
├── Turn 1
│   ├── Trigger
│   ├── Context
│   ├── Model Response
│   └── Tool Results
├── Turn 2
└── Memory Updates
```

---

## 23.2 分支

调试时支持：

```text
Turn 1
  └── Turn 2
       ├── Turn 3A：原始模型
       └── Turn 3B：替换模型
```

分支适合：

* Undo；
* What-if；
* 模型对比；
* 修改 Prompt 后重试；
* Tool Result 替换。

MVP 可先使用线性 Session，后续增加 DAG。

---

# 24. 持久化

## 24.1 MVP

* MemorySessionStore；
* Binary Trace；
* JSON Debug Export。

## 24.2 正式版本

* SQLite Session Store；
* Append-only Trace；
* 独立 Blob；
* 压缩；
* 可选加密。

---

## 24.3 存储接口

```zig
pub const SessionStoreVTable = struct {
    create_session: *const fn (...) SessionId,
    append_event: *const fn (...) !void,
    load_session: *const fn (...) !SessionData,
    branch_session: *const fn (...) !SessionId,
    close_session: *const fn (...) !void,
};
```

Agent Core 不绑定 SQLite。

---

# 25. 多模态

## 25.1 输入来源

* 游戏最终画面；
* 指定 Render Target；
* UI Layer；
* Depth；
* Segmentation；
* Object ID Buffer；
* Mini-map；
* 音频；
* 游戏结构化状态。

---

## 25.2 不建议只给最终截图

Gameplay Agent 最好同时获得：

```text
视觉图像
+ UI 结构
+ 可交互区域
+ 当前输入焦点
+ 游戏状态摘要
+ 最近操作结果
```

这样可以降低：

* OCR 错误；
* UI 元素定位误差；
* 图标误识别；
* 模型 Token；
* 截图频率。

---

## 25.3 Perception 与 Agent Loop 分离

```text
Frame Capture
    ▼
Perception Pipeline
    ├── UI Detector
    ├── OCR
    ├── Object Detector
    ├── VLM
    └── Game Instrumentation
    ▼
Perception Snapshot
    ▼
Agent Context
```

Perception 可以：

* 高频本地运行；
* 只在变化时通知 Agent；
* 对结果进行跟踪；
* 输出稳定对象 ID。

---

# 26. Extension 系统

## 26.1 Native Extension

适合：

* 内置引擎工具；
* 高性能查询；
* 项目核心功能；
* 可信插件。

C API：

```c
typedef struct nar_tool_desc nar_tool_desc;
typedef struct nar_tool_context nar_tool_context;
typedef struct nar_tool_result_sink nar_tool_result_sink;

typedef void (*nar_tool_invoke_fn)(
    nar_tool_context* context,
    const char* json_args,
    size_t json_args_len,
    nar_tool_result_sink* sink,
    void* userdata
);

nar_tool_handle nar_register_tool(
    nar_runtime* runtime,
    const nar_tool_desc* desc,
    nar_tool_invoke_fn invoke,
    void* userdata
);
```

---

## 26.2 WASM Extension

适合：

* 项目 Skill；
* Mod；
* 自动测试脚本；
* 热更新；
* 不可信第三方扩展；
* 游戏规则插件。

WASM 默认无：

* 文件；
* 网络；
* 时钟；
* 随机数；
* 系统调用。

所需能力由 Host 显式导入。

---

## 26.3 WASM ABI

推荐使用 Handle + Linear Memory：

```c
uint32_t nar_tool_init(uint32_t host_api_version);

uint32_t nar_tool_invoke(
    uint32_t context_handle,
    uint32_t args_ptr,
    uint32_t args_len
);

void nar_tool_cancel(uint64_t operation_id);
```

---

# 27. MCP Gateway

## 27.1 定位

MCP 只用于外部系统。

```text
Agent Tool Call
    ▼
MCP Gateway Tool Adapter
    ▼
MCP Client
    ▼
MCP Server
```

---

## 27.2 首期范围

只实现：

* initialize；
* tools/list；
* tools/call；
* notifications；
* stdio；
* Streamable HTTP。

不建议首期实现：

* Sampling；
* Roots；
  -复杂 Resource；
  -完整 OAuth；
  -动态 Server 市场。

---

## 27.3 MCP Tool 导入

导入时转换：

```text
MCP Tool Schema
    ▼
NAR Tool Descriptor
    ▼
Local Capability Overlay
```

即使 MCP Server 声明某工具，NAR 仍然需要本地 Policy。

---

# 28. C ABI 设计

## 28.1 目标

* 稳定；
* 无 Zig 类型泄露；
* 无异常；
* 无跨 ABI 分配；
* 支持版本协商；
* 支持异步；
* 支持动态库。

---

## 28.2 Handle 模式

```c
typedef uint64_t nar_runtime_handle;
typedef uint64_t nar_agent_handle;
typedef uint64_t nar_turn_handle;
typedef uint64_t nar_tool_handle;
typedef uint64_t nar_operation_handle;
```

---

## 28.3 内存规则

所有跨 ABI Buffer 使用：

```c
typedef struct nar_buffer {
    const uint8_t* data;
    size_t size;
    void (*release)(void* userdata, const uint8_t* data, size_t size);
    void* userdata;
} nar_buffer;
```

不允许：

* Zig 分配、C 释放；
* C 分配、Zig 默认释放；
* 返回临时 Slice；
* 暴露内部 ArrayList。

---

## 28.4 API Version

```c
typedef struct nar_api_version {
    uint16_t major;
    uint16_t minor;
    uint16_t patch;
} nar_api_version;
```

Major 不兼容，Minor 向后兼容。

---

# 29. 错误模型

```zig
pub const AgentErrorCode = enum(u32) {
    ok,
    invalid_argument,
    invalid_state,
    cancelled,
    timeout,
    budget_exceeded,
    model_unavailable,
    model_protocol_error,
    tool_not_found,
    tool_schema_error,
    tool_permission_denied,
    stale_object,
    stale_world_revision,
    operation_failed,
    storage_error,
    network_error,
    internal_error,
};
```

错误必须区分：

* 可重试；
* 不可重试；
* 模型可见；
* 仅开发者可见；
* 安全敏感；
* 用户可见。

---

# 30. 预算系统

## 30.1 Turn Budget

```zig
pub const TurnBudget = struct {
    max_wall_time_ms: u32,
    max_model_calls: u16,
    max_tool_calls: u16,
    max_context_tokens: u32,
    max_output_tokens: u32,
    max_cost_micros: u64,
    max_trace_bytes: u32,
};
```

---

## 30.2 Runtime Budget

限制：

* 全局并发 Agent；
* 全局并发模型请求；
* 每个 Provider QPS；
* 本地 GPU 推理并发；
* 每帧主线程 Tool；
* 总内存；
* Trace IO。

---

## 30.3 优先级

```text
Critical Gameplay Agent
Gameplay Agent
Player Conversation
Debug Agent
Background Memory
Offline Evaluation
```

低优先级任务可以：

* 延迟；
* 降级模型；
* 取消；
* 使用更小上下文；
* 使用缓存结果。

---

# 31. 性能设计

## 31.1 目标

Agent Core 自身应做到：

* Idle Agent 近乎零 CPU；
* 不活跃 Agent 不轮询；
* 流式解析低分配；
* 单 Turn 使用 Arena；
* 工具 Schema 预编译；
* Context 支持增量构建；
* Trace 支持异步批量写入。

---

## 31.2 内存分配

建议：

```text
Runtime Allocator
├── Persistent Registry Arena
├── Agent Lifetime Allocator
├── Turn Arena
├── Stream Buffer Pool
└── Trace Buffer Pool
```

Turn 结束后整体释放 Turn Arena。

---

## 31.3 JSON

建议内部采用：

* Token/Slice View；
* Lazy Parse；
* Schema 编译；
* Streaming Builder；
* 避免构造多份 DOM。

对 Tool 参数：

* 小参数：DOM；
* 大参数：SAX/Streaming；
* 二进制：Blob Handle，不放 Base64。

---

## 31.4 图片

模型输入图片不应复制多次。

使用：

```zig
pub const MediaRef = union(enum) {
    cpu_buffer: SharedBufferHandle,
    gpu_texture: TextureHandle,
    file_blob: BlobHandle,
    remote_uri: Uri,
};
```

由 Model Backend 决定如何编码和上传。

---

# 32. 可观测性

## 32.1 Metrics

* Agent Turn 数；
* 成功率；
* 平均 Tool 数；
* 模型延迟；
* 首 Token 延迟；
* Token；
* 成本；
* Tool 错误率；
* 权限拒绝；
* 取消率；
* Loop 检测次数；
* Context 大小；
* Memory 命中率。

---

## 32.2 不强制绑定 OpenTelemetry

NAR 应定义轻量 Sink：

```zig
pub const MetricsSinkVTable = struct {
    counter: *const fn (... ) void,
    gauge: *const fn (... ) void,
    histogram: *const fn (... ) void,
};
```

提供可选 Adapter：

* Noop；
* Log；
* Prometheus；
* OpenTelemetry；
* 引擎 Profiler；
* 自研监控。

核心不依赖数据库，也不依赖 OTel SDK。

---

# 33. 配置系统

```zig
pub const RuntimeConfig = struct {
    profile: BuildProfile,
    max_agents: u32,
    max_concurrent_model_requests: u32,
    default_turn_budget: TurnBudget,
    trace_config: TraceConfig,
    security_config: SecurityConfig,
};
```

配置来源：

* Build Option；
* 本地 Config；
* 项目 Asset；
* 服务器下发；
* Editor Override；
* 命令行。

优先级：

```text
Build Hard Limit
    >
Shipping Security Policy
    >
Project Config
    >
Agent Definition
    >
Runtime Override
```

低层限制不能被高层配置放宽。

---

# 34. 推荐目录结构

```text
nar/
├── build.zig
├── build.zig.zon
├── include/
│   └── nar.h
├── src/
│   ├── nar.zig
│   ├── foundation/
│   │   ├── allocator.zig
│   │   ├── buffer.zig
│   │   ├── cancellation.zig
│   │   ├── executor.zig
│   │   ├── json.zig
│   │   └── stream.zig
│   ├── core/
│   │   ├── runtime.zig
│   │   ├── agent.zig
│   │   ├── turn.zig
│   │   ├── loop.zig
│   │   ├── event.zig
│   │   ├── mailbox.zig
│   │   └── budget.zig
│   ├── model/
│   │   ├── model.zig
│   │   ├── registry.zig
│   │   ├── router.zig
│   │   ├── request.zig
│   │   ├── event.zig
│   │   └── backends/
│   │       ├── openai_compatible.zig
│   │       ├── anthropic.zig
│   │       ├── gemini.zig
│   │       ├── llama_cpp.zig
│   │       ├── replay.zig
│   │       └── mock.zig
│   ├── tool/
│   │   ├── descriptor.zig
│   │   ├── registry.zig
│   │   ├── schema.zig
│   │   ├── dispatcher.zig
│   │   ├── operation.zig
│   │   ├── resource_access.zig
│   │   └── policy.zig
│   ├── context/
│   │   ├── context.zig
│   │   ├── builder.zig
│   │   ├── snapshot.zig
│   │   ├── working_memory.zig
│   │   ├── compact.zig
│   │   └── tool_resolver.zig
│   ├── memory/
│   │   ├── memory.zig
│   │   ├── store.zig
│   │   ├── retrieval.zig
│   │   └── summarizer.zig
│   ├── session/
│   │   ├── session.zig
│   │   ├── store.zig
│   │   ├── branch.zig
│   │   └── sqlite_store.zig
│   ├── trace/
│   │   ├── event.zig
│   │   ├── writer.zig
│   │   ├── reader.zig
│   │   ├── replay.zig
│   │   └── diff.zig
│   ├── extension/
│   │   ├── native.zig
│   │   ├── wasm.zig
│   │   ├── wamr.zig
│   │   └── manifest.zig
│   ├── protocol/
│   │   ├── mcp.zig
│   │   ├── json_rpc.zig
│   │   └── remote_agent.zig
│   └── cabi/
│       ├── runtime.zig
│       ├── agent.zig
│       ├── tool.zig
│       └── buffer.zig
├── adapters/
│   ├── standalone_executor/
│   ├── task_graph/
│   ├── resource_task_graph/
│   ├── llama_cpp/
│   ├── wamr/
│   └── sqlite/
├── examples/
│   ├── minimal_agent/
│   ├── npc_agent/
│   ├── gameplay_agent/
│   ├── debug_agent/
│   ├── replay/
│   └── c_api/
└── tests/
    ├── unit/
    ├── integration/
    ├── protocol/
    ├── replay/
    ├── fuzz/
    └── stress/
```

---

# 35. Build Profile

## Minimal

包含：

* Agent Loop；
* OpenAI-compatible；
* Tool；
* Cancellation；
* 内存 Session。

不包含：

* SQLite；
* WASM；
* MCP；
* llama.cpp；
* Memory；
* 多模态。

## Runtime

包含：

* Agent Loop；
* 多 Provider；
* Tool Runtime；
* Trace；
* Replay；
* Capability；
* Engine Executor Adapter。

## Editor

增加：

* MCP；
* WASM；
* SQLite；
* 完整 Trace；
* 调试 API；
* Session Branch；
* 多 Agent。

## Server

增加：

* 远程 Agent；
* 多租户；
* 调度；
* 批量模型调用；
* 分布式 Trace。

---

# 36. 测试策略

## 36.1 单元测试

* Agent 状态机；
* Tool Schema；
* Permission；
* Budget；
* Context 裁剪；
* SSE；
* JSON；
* Cancellation；
* Loop 检测；
* Object Generation。

## 36.2 Mock Model

```zig
pub const MockStep = union(enum) {
    text: []const u8,
    tool_call: MockToolCall,
    error_event: ModelError,
    delay_ms: u32,
};
```

允许完全确定性测试。

## 36.3 Mock Tool

* 成功；
* 失败；
* 超时；
* Pending；
* 不可取消；
* Revision 冲突；
* 权限拒绝。

## 36.4 Replay Test

每次修改 Agent Core 后重放历史 Session，检查：

* 事件序列；
* Tool 参数；
* 最终状态；
* Trace Schema；
* 错误行为。

## 36.5 Fuzz

重点：

* SSE Chunk；
* JSON；
* Tool Arguments；
* MCP；
* Trace Reader；
* C ABI Buffer；
* Cancellation Race。

---

# 37. MVP 计划

## Phase 0：Foundation

目标：

* 项目骨架；
* Allocator；
* Event；
* Cancellation；
* Executor；
* JSON；
* C ABI；
* Mock。

交付：

```text
nar_runtime_create
nar_runtime_destroy
nar_agent_create
nar_agent_submit
nar_agent_poll_event
nar_agent_cancel
```

---

## Phase 1：最小 Agent Loop

支持：

* 单 Agent；
* OpenAI-compatible；
* Streaming；
* Tool Calling；
* 同步 Tool；
* Memory Session；
* Token/Turn Budget；
* Mock Model。

验收：

> Agent 查询玩家状态，然后调用一个动作工具，最后返回完成结果。

---

## Phase 2：Runtime Integration

支持：

* Worker Executor；
* Main Thread Tool；
* Async Tool；
* Operation；
* Capability；
* World Revision；
* Stable ObjectRef；
* Trace；
* Replay。

验收：

> Agent 发起移动，等待导航完成，在角色死亡时能够取消。

---

## Phase 3：Gameplay Agent

支持：

* World Snapshot；
* Screenshot；
* UI Tree；
* Perception Snapshot；
* Tool Resolver；
* Gameplay Intent；
* 多模型路由；
* Agent 调试面板。

验收：

> Agent 能在测试游戏中完成“打开背包、使用药品、关闭 UI”的任务，并生成完整 Trace。

---

## Phase 4：Extensions

支持：

* WAMR；
* WASM Tool；
* Manifest；
* 签名；
* MCP Gateway；
* SQLite Session；
* Session Branch。

---

## Phase 5：高级能力

支持：

* 多 Agent；
* Agent-to-Agent；
* Batch Inference；
* 长期 Memory；
* 远程 Agent Server；
* 多设备协同；
* 自动评估；
* 模型 A/B。

---

# 38. MVP 不应实现的内容

为了避免项目失控，第一阶段明确不做：

* 多 Agent Team；
* Agent 自己生成 Tool；
* 动态 Native 代码；
* 完整 MCP；
* Vector DB；
* 自动长期记忆；
* 复杂 Workflow；
* 分布式运行；
* 全平台本地 VLM；
* NPC 全自主生活模拟；
* LLM 逐帧控制；
* Agent Market。

---

# 39. 风险分析

## 39.1 模型延迟

风险：

* 云端请求数秒；
* 网络抖动；
* Tool Loop 放大延迟。

应对：

* 高低频分层；
* 本地小模型；
* Prompt Cache；
* 并行只读 Tool；
* Context 压缩；
* 预取；
* 超时与降级。

---

## 39.2 模型成本

应对：

* Budget；
* 模型路由；
* Tool Resolver；
* 小模型处理简单任务；
* 事件合并；
* Session 摘要；
* 缓存；
* Loop 检测。

---

## 39.3 不确定性

应对：

* LLM 只输出高层 Intent；
* 关键行为走确定性系统；
* 写 Tool 权限；
* 参数边界；
* 用户确认；
* Replay；
* Mock 测试。

---

## 39.4 安全

应对：

* Capability；
* 无裸指针；
* Shipping Profile；
* WASM；
* MCP Allowlist；
* Tool Version；
* 签名；
* 审计。

---

## 39.5 架构膨胀

最大风险是把：

* Agent；
* Workflow；
* Task Graph；
* ECS；
* Memory；
* MCP；
* Model Server；

全部耦合为一个系统。

应坚持：

```text
Agent Runtime 负责“决策循环”
Task Graph 负责“任务执行”
ECS 负责“世界状态”
Gameplay Framework 负责“确定性行为”
Model Server 负责“推理”
MCP 负责“外部工具互操作”
```

---

# 40. 最终技术选型

| 模块           | 推荐                                       |
| ------------ | ---------------------------------------- |
| 核心语言         | Zig                                      |
| 公共接口         | C ABI                                    |
| Agent Loop   | 自研                                       |
| Provider     | 自研薄 Adapter                              |
| HTTP/SSE     | Zig 原生或可替换 Adapter                       |
| Tool Schema  | JSON Schema 子集                           |
| 执行调度         | Executor 抽象                              |
| 引擎调度         | Job System Adapter                       |
| 并行冲突         | Resource Task Graph Adapter              |
| 本地模型         | llama.cpp                                |
| 本地模型默认部署     | Sidecar                                  |
| WASM Runtime | WAMR                                     |
| Editor WASM  | Wasmtime 可选                              |
| Session      | Memory + SQLite Adapter                  |
| Trace        | 自定义 Append-only Binary                   |
| MCP          | 外部 Gateway，不作为内部 ABI                     |
| Metrics      | 轻量 Sink，可选接 OTel                         |
| Context      | World Snapshot + Working Memory          |
| 对象引用         | ID + Generation                          |
| 高层行为         | Intent / Goal                            |
| 高频行为         | BT / State Tree / GOAP / Gameplay System |

---

# 41. 核心架构决策汇总

## ADR-001：自研 Agent Core

不直接嵌入 Pi 或其他 Node/Python Agent Runtime。

原因：

* 线程模型不匹配；
* 游戏对象模型不匹配；
* 权限模型不匹配；
* 部署和包体不匹配；
* 需要 C ABI；
* 需要 Replay。

---

## ADR-002：LLM 只做低频决策

高频执行交给确定性游戏系统。

---

## ADR-003：内部 Tool 使用 Native ABI

MCP 仅作为外部 Gateway。

---

## ADR-004：工具必须声明资源访问

允许接入 Resource Task Graph，但 Agent Core 不依赖具体图实现。

---

## ADR-005：所有动态对象使用 Stable Handle

禁止 Tool 暴露裸指针。

---

## ADR-006：Trace/Replay 是基础能力

不是后期调试插件。

---

## ADR-007：Native + WASM 双扩展体系

核心工具 Native，自定义与不可信扩展 WASM。

---

## ADR-008：模型 Backend 与 Agent Core 分离

模型可以是：

* 云端；
* Sidecar；
* In-process；
* Mock；
* Replay；
* 规则系统。

---

# 42. 项目最终形态

NAR 最终应成为引擎中的 Agent Kernel：

```text
Native Agent Runtime
├── Agent Core
├── Model Abstraction
├── Tool Runtime
├── Context Builder
├── World Snapshot
├── Memory
├── Policy
├── Budget
├── Scheduler
├── Trace & Replay
├── Native Extension
├── WASM Extension
├── MCP Gateway
└── C ABI
```

它可以同时支撑：

```text
NPC Agent
Gameplay Test Agent
Profiler Agent
Runtime Debug Agent
Editor Agent
Machine Farm Agent
Build Agent
Automation Agent
```

这些 Agent 共享：

* Agent Loop；
* Provider；
* Tool Runtime；
* Session；
* Trace；
* Permission；
* Scheduling。

但不共享：

* 具体 Tool；
* 具体 Workflow；
* 具体 Memory；
* 具体 Gameplay 逻辑；
* 具体 Prompt。

---

# 43. 最终结论

该项目具备明确价值，尤其适合你的整体技术路线：

* Zig/C 游戏 Runtime；
* Gameplay Agent；
* 自动 Profiler Agent；
* 机器农场；
* SVN 和构建工具；
* Agentic 游戏研发平台；
* Runtime 热更新；
* Resource-Based Task Graph。

现有 Zig Agent 项目已经证明原生、轻量和 C ABI Agent Runtime 是可行的，但当前项目普遍缺少游戏引擎所需的：

* World Revision；
* Stable ObjectRef；
* 主线程 Tool；
* 帧预算；
* Resource Access；
* Gameplay Intent；
* Trace/Replay；
* Shipping 权限。

因此推荐实施路线不是“寻找一个成熟库直接使用”，而是：

> 参考 Pi、ZSeven-W/agent、KrillClaw、llama.cpp、WAMR 和 MCP 的成熟思想，构建一套小型、可裁剪、可测试、面向游戏 Runtime 的原生 Agent Kernel。

第一版应严格控制在：

```text
Agent Loop
+ OpenAI-compatible
+ Tool Registry
+ Async Operation
+ Cancellation
+ Capability
+ Trace/Replay
+ C ABI
```

只要这部分稳定，后续 NPC、Gameplay Agent、Profiler Agent、Editor Agent 和机器农场都可以建立在同一套基础设施上。
