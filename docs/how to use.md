NAR 真正有价值的地方，不是“又一个聊天 Agent 框架”，而是：

> **把大模型能力以内嵌、可控、可调度、可持久化的方式，放进 native 应用运行时。**

这会让它和 Pi、Claude Code、LangGraph、Mastra 这类“外部 Agent 框架”形成明显区别。

## 一、最核心的用途：给 native 应用加一个 Agent Runtime

典型对象包括：

* 游戏
* 游戏引擎和编辑器
* DCC 工具
* CAD、工业软件
* 桌面应用
* 嵌入式设备
* 机器人
* 仿真系统
* 数字人
* 本地 AI 工具

这些应用往往有共同需求：

* 已经有自己的主循环、线程模型和对象系统
* 不能把控制权交给 Python/Node 事件循环
* 需要严格限制 Agent 能做什么
* 要访问 native 世界状态
* 要控制主线程副作用
* 要支持暂停、恢复、存档、回放
* 要兼容云模型和本地模型
* 不能接受 Agent 任意读文件、执行 shell、访问网络

NAR 可以成为这类应用内部的统一智能运行时。

---

# 二、游戏里的用途

这是 NAR 最有潜力的方向。

## 1. NPC 高层决策

不是让 LLM 每帧控制角色，而是让它负责较低频的高层意图：

```text
世界状态
  ↓
NAR Agent
  ↓
目标 / 计划 / 意图
  ↓
行为树、GOAP、状态机、ECS 系统执行
```

例如：

* NPC 决定是否相信玩家
* 商人调整交易态度
* 队友判断当前任务优先级
* 敌人根据长期遭遇改变策略
* 城镇居民传播消息
* 阵营角色形成动态关系

NAR 管：

* 对话历史
* 工作记忆
* 长期记忆
* 技能选择
* 工具调用
* 上下文裁剪
* 模型切换

游戏系统仍然管：

* 移动
* 战斗
* 动画
* 数值
* 权威世界状态

这可以避免“LLM 直接操纵游戏导致不可控”。

---

## 2. 动态剧情和任务系统

传统任务系统通常是预设状态图。

NAR 可以用于：

* 根据世界状态生成任务变体
* 动态补全支线
* 根据玩家历史调整任务目标
* 生成符合阵营关系的事件
* 对任务失败进行合理续写
* 让剧情在有限约束下重新规划

关键不是完全自由生成，而是：

```text
Narrative Agent
  → 提议剧情节点
  → 调用受限剧情工具
  → 游戏规则验证
  → 写入正式任务状态
```

例如工具只能是：

* `create_objective`
* `bind_existing_npc`
* `set_dialogue_topic`
* `schedule_world_event`
* `award_existing_item`
* `change_faction_relation`

而不是任意修改游戏世界。

---

## 3. 动态对话系统

NAR 很适合做“有记忆、有工具、有世界认知”的对话运行时。

相比普通对话 SDK，它可以：

* 从游戏世界读取角色状态
* 检索角色长期记忆
* 激活职业、阵营、剧情 Skill
* 调用查询工具
* 根据世界 revision 判断信息是否过期
* 将关键事件写入角色记忆
* 将模型输出转成结构化行为

一次对话结果不仅是文本，还可以是：

```json
{
  "speech": "我昨晚确实见过那辆马车。",
  "emotion": "nervous",
  "intent": "conceal_information",
  "look_target": "player",
  "memory_candidates": [],
  "gameplay_actions": [
    {
      "type": "reveal_clue",
      "clue_id": "wagon_seen_at_gate"
    }
  ]
}
```

---

## 4. 游戏内 Companion Agent

例如玩家有一个长期陪伴的 AI 队友：

* 记得玩家习惯
* 理解当前任务
* 帮助解释机制
* 提醒资源风险
* 帮忙规划路线
* 在玩家授权后执行低风险操作
* 根据角色设定保持人格一致

这种 Agent 既不是简单 NPC，也不是外挂式聊天机器人，而是游戏系统的一部分。

---

## 5. Gameplay Agent / 自动测试 Agent

这是 NAR 非常现实的用途。

Agent 可以通过受限工具：

* 获取场景状态
* 查询 UI
* 模拟输入
* 执行任务
* 读取日志
* 判断是否卡住
* 记录异常
* 生成复现路径

NAR 的优势在于它可以直接嵌入游戏 runtime，而不是完全依赖外部视觉控制。

可以形成分层：

```text
高层 Agent
  ├─ 理解测试目标
  ├─ 规划步骤
  ├─ 判断异常
  └─ 生成报告

确定性工具层
  ├─ UI 查询
  ├─ 实体查询
  ├─ 导航
  ├─ 输入模拟
  ├─ 状态校验
  └─ 日志采集
```

这比纯 computer-use 更快、更稳定、更容易定位问题。

---

## 6. 游戏内 GM / 导演系统

NAR 可以充当受限的“AI Dungeon Master”：

* 动态调节遭遇
* 根据玩家状态推荐事件
* 控制节奏
* 生成合适的支线机会
* 调整任务提示强度
* 发现玩家卡关
* 主动插入教学或补给

但它不能直接改数值，必须通过导演工具：

```text
propose_encounter
request_loot_drop
schedule_hint
adjust_spawn_budget
select_story_event
```

实际执行由游戏规则系统裁决。

---

## 7. 玩家创作和 Mod Agent

NAR 可以内嵌到游戏编辑器或 UGC 系统：

* 玩家自然语言描述任务
* Agent 生成任务图
* 生成有限范围脚本
* 搜索已有资产
* 配置 NPC 行为
* 生成关卡逻辑
* 检查引用和规则错误

Skill 可以对应不同创作领域：

* Quest Design Skill
* Combat Encounter Skill
* Dialogue Skill
* Level Dressing Skill
* UI Skill
* Economy Balance Skill

这种场景尤其适合 NAR 的 Skill、Tool、Memory、PromptPack 体系。

---

# 三、游戏引擎和编辑器里的用途

## 1. 编辑器内建 Copilot

和外部 Codex 不同，NAR 可以理解编辑器当前状态：

* 当前选中对象
* 当前场景
* 当前资源
* 当前 Inspector
* 当前 Timeline
* 当前 Shader Graph
* 当前错误和性能数据

Agent 可以调用编辑器工具：

* 创建实体
* 修改组件
* 搜索资源
* 批量重命名
* 生成材质
* 建立状态机
* 修改任务图
* 运行验证
* 生成预览

这将成为真正意义上的“引擎原生 Agent”。

---

## 2. 资产处理 Agent

例如：

* 检查纹理尺寸和格式
* 自动配置导入参数
* 查找重复资产
* 生成 LOD
* 判断压缩策略
* 检查动画绑定
* 修复命名规范
* 生成资产依赖报告
* 调用 DCC 或外部流水线

Agent 负责决策，底层 asset pipeline 负责确定性执行。

---

## 3. 性能分析 Agent

你现在做的 Profiler Agent 就可以以 NAR 为运行时。

它可以：

* 持续接收 profiler 数据
* 检测热点
* 调用符号、SVN、代码索引工具
* 建立调查计划
* 保存工作记忆
* 多轮归因
* 输出结构化报告
* 等待更多数据后继续调查

这类 Agent 的特点是：

* 生命周期长
* 工具很多
* 需要持久化
* 需要可恢复
* 需要可审计
* 不适合简单一次性 LLM 调用

非常符合 NAR。

---

## 4. 构建和发布 Agent

嵌入构建工具或 Launcher：

* 分析构建失败
* 判断缺失依赖
* 选择增量构建策略
* 检查平台配置
* 对比包体差异
* 生成发布说明
* 验证产物
* 处理低风险修复

NAR 可以作为构建系统内部的智能控制面，而不是另起一个外部服务。

---

## 5. Debug Agent

运行时或编辑器中：

* 收集 crash context
* 检索符号
* 查询对象状态
* 分析最近事件
* 复现关键操作
* 检查 invariant
* 生成可能原因
* 推荐验证步骤

甚至可以在开发版本中提供：

```text
暂停游戏
→ Agent 检查当前世界
→ 调用调试工具
→ 形成诊断
→ 开发者继续追问
```

---

# 四、通用 native 软件里的用途

## 1. 软件内嵌帮助 Agent

相比传统帮助文档，NAR 可以理解当前应用状态。

例如 CAD：

* 当前选中了哪个实体
* 当前约束为什么失败
* 哪个参数冲突
* 应该调用哪个命令
* 能否自动执行修复

例如视频编辑器：

* 当前时间线
* 当前素材
* 当前导出配置
* 当前错误
* 当前色彩空间

这类 Agent 不只是“回答问题”，而是能安全操作应用。

---

## 2. 工作流自动化

Native 应用里通常有很多固定但复杂的流程。

NAR 可以把它们变成：

```text
用户自然语言目标
  ↓
Agent 选择 Skill
  ↓
规划工具调用
  ↓
Host 审批关键副作用
  ↓
执行并验证
```

例如：

* 批量导出多个格式
* 整理工程资源
* 清理错误引用
* 批量生成配置
* 自动跑一组检查
* 收集结果并生成报告

---

## 3. 本地隐私 Agent

因为 NAR 可嵌入本地应用并接本地模型，所以适合：

* 医疗终端
* 工业软件
* 企业桌面工具
* 离线应用
* 军工或保密环境
* 无法访问公网的设备

其重点是：

* 本地模型
* 本地 memory
* 严格能力限制
* 无隐式网络权限
* 可追踪工具调用
* 可完全关闭外部 provider

---

# 五、机器人和仿真用途

## 1. 机器人高层任务规划

NAR 可以运行在机器人 native runtime 中：

* 理解用户任务
* 读取传感器摘要
* 选择 Skill
* 调用导航、抓取、识别工具
* 遇到失败后重新规划
* 保持任务状态
* 请求人工确认

LLM 不直接驱动电机，只输出高层动作。

```text
NAR
  → navigate_to(room_a)
  → inspect(table)
  → pick(object_12)
  → return_to(user)
```

底层实时控制仍由机器人系统负责。

---

## 2. 数字孪生和工业仿真

Agent 可以：

* 查询仿真对象
* 分析异常
* 调整实验参数
* 生成实验计划
* 比较结果
* 形成报告
* 记住历史实验

NAR 的 deterministic host、trace 和 replay 在这里很有价值。

---

# 六、端侧 Agent Runtime

NAR 还可以成为“端侧 Agent 的通用内核”。

例如部署到：

* Windows/macOS 应用
* 手机 App
* 掌机
* 游戏主机
* AR/VR
* 智能设备
* 车机

它向上提供统一 Agent API，向下适配：

* 云端大模型
* 本地小模型
* 本地 VLM
* 混合模型路由
* 宿主工具
* 本地数据库
* WASM Skill

其价值类似：

```text
SQLite 之于嵌入式数据库
Lua 之于嵌入式脚本
NAR 之于嵌入式 Agent
```

这是比较有潜力的长期定位。

---

# 七、NAR 还可以成为 Agent 能力的统一中间层

很多 native 应用未来会同时接入：

* OpenAI
* Anthropic
* Gemini
* 本地模型
* 公司内部模型
* MCP
* 自定义工具
* Memory 服务
* RAG
* 多模态能力

如果每个应用各自实现，最后会非常混乱。

NAR 可以统一这些概念：

```text
Model
Tool
Skill
Prompt
Memory
Context
Session
Policy
Trace
Replay
Host Operation
```

这样应用本身不需要绑定某个模型 SDK 或 Agent 框架。

---

# 八、不同复杂度的产品形态

NAR 不应该只有一种使用模式。

## Level 0：一次性智能调用

```text
输入 + 世界上下文 → 结构化输出
```

适合：

* 文本生成
* 解释
* 分类
* 推荐
* 简单决策

---

## Level 1：带工具的单轮 Agent

```text
输入 → 模型 → 工具 → 模型 → 输出
```

适合：

* 查询当前世界
* 执行简单编辑器操作
* 获取诊断信息

---

## Level 2：有状态 Agent

```text
Session + Working Memory + Skills + Tools
```

适合：

* 长期 NPC
* Companion
* Profiler Agent
* Debug Agent
* 自动测试 Agent

---

## Level 3：持久化 Agent

```text
Journal + Savegame + Long-term Memory + Recovery
```

适合：

* 长期角色
* 跨游戏会话陪伴者
* 长周期调查 Agent
* 桌面工作流 Agent

---

## Level 4：多 Agent Runtime

```text
多个 Agent + 调度 + 共享世界 + 消息
```

适合：

* 城镇 NPC 群体
* 游戏导演 + NPC + 任务 Agent
* 大型自动化工作流
* 多角色仿真

但这应该是后续能力，而不是 NAR 初期核心。

---

# 九、最值得优先验证的几个应用

从 NAR 当前阶段看，我认为最适合做样板的不是普通 Chat，而是这四个。

## 1. 游戏内 NPC Agent

验证：

* 世界上下文
* memory
* skill
* tool
* world revision
* save/load
* 主线程操作

它最能体现 native embedding 差异。

## 2. Gameplay 测试 Agent

验证：

* 工具编排
* 多模态
* 长任务
* 状态恢复
* trace
* 失败重试
* 报告生成

商业价值也比较直接。

## 3. 引擎编辑器 Copilot

验证：

* Host Tool API
* 用户授权
* 动态 Skill
* 编辑器状态注入
* 可撤销副作用

最容易形成真实开发体验。

## 4. Profiler 调查 Agent

验证：

* 长生命周期
* 多工具
* 工作记忆
* 上下文压缩
* session journal
* 可审计输出

并且你已经有现成项目可接。

---

# 十、NAR 最不应该做什么

这些方向容易让它失焦：

* 不要变成另一个 Claude Code CLI
* 不要把 shell/file/network 当默认能力
* 不要自己做完整 RAG 平台
* 不要自己做模型推理引擎
* 不要自己做工作流 SaaS
* 不要让 LLM 接管每帧游戏逻辑
* 不要把所有 Agent 都塞进一个万能抽象
* 不要把 MCP 当核心内部协议
* 不要把 native app 变成 Agent 框架的附属品

正确关系应当是：

> **应用是主人，NAR 是被嵌入的智能执行内核。**

---

# 十一、可以形成的产品定位

可以考虑几种表达。

### 技术定位

> NAR is an embeddable agent runtime for native applications.

### 面向游戏

> A native AI runtime for games, engines, NPCs, tools, and autonomous testing.

### 更完整的定位

> NAR enables native applications to run stateful, tool-using AI agents under explicit host control, with deterministic scheduling, capability isolation, persistence, and replay.

中文可以概括为：

> **NAR 是面向游戏和 native 应用的可嵌入 Agent Runtime，负责模型、工具、技能、上下文、记忆和会话执行，但不夺取宿主对线程、世界状态和副作用的控制权。**

---

# 十二、我认为最有想象力的终局

NAR 最终可能不是一个“Agent 框架”，而是 native 软件中的一个新运行时层：

```text
应用逻辑层
Gameplay / Editor / Robot / CAD
          │
Agent Runtime Layer
NAR
          │
Model / Skill / Memory / Tool / Policy
          │
Native Host / OS / Engine
```

未来一个游戏里可能同时存在：

* NPC Agent
* Narrative Agent
* Director Agent
* Testing Agent
* Debug Agent
* Player Companion
* Editor Agent

它们共享同一套 NAR Runtime，但拥有不同：

* Skill
* Tool capability
* Memory scope
* Model policy
* Scheduling priority
* Persistence policy

这会比“每个功能单独接一个 LLM SDK”更接近真正可维护的 AI-native engine。
