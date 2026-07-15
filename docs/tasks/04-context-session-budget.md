# 04 - Context Builder、Memory Session 与预算系统

## 目的

为每个 Turn 构造有界、可解释的模型输入，并保存最小会话历史，确保成本和循环均有硬上限。

## 依赖

- 01 基础类型。
- 03 Tool 描述符，供 Tool Resolver 选择模型可见工具。

## 实现方案

1. 定义 AgentDefinition 的 system/static context、模型要求、允许工具、默认预算和 context strategy；定义 immutable WorldSnapshot `{revision, captured_at, sections}`，payload 由宿主管理或复制规则明确。
2. 实现 MemorySession，保存规范化 message/tool call/tool result/turn outcome；支持 append、snapshot view、clear/deinit，不做数据库持久化或长期记忆。
3. Context Builder 按 setup 优先级合并 system、static、world、recent history、当前 input/tool result；输出 ModelRequest 和 ContextManifest（来源、大小、被裁剪原因）。
4. Token 预算首版可使用保守 UTF-8 byte estimator，但接口允许 Provider estimator；不得把 byte 数宣传为精确 token。
5. Tool Resolver 基于 allowlist、capability、profile、descriptor 标签和最大工具数确定性筛选；安全约束先于相关性。
6. TurnBudget 实现 wall time、model calls、tool calls、context/output tokens、cost micros、trace bytes 的 checked accounting。零值语义明确；计数溢出视为超限。
7. 循环检测 key 为规范化 tool name + canonical JSON arguments；阈值可配置且有硬上限。

## 必测细节

- 裁剪永不删除 system 安全消息与当前工具结果；不足以容纳硬内容时返回 budget_exceeded。
- snapshot/session 原始 buffer 释放后，已声明 owned 的 context 仍有效；borrowed 路径不越界。
- 所有预算边界 exact limit / limit+1 / overflow。
- Tool Resolver 输出稳定且不泄露未授权工具。
- canonical JSON 对 key 顺序不敏感，对数组顺序敏感。

## 完成校验

```powershell
zig fmt src tests
zig build test --summary all
zig build test-all
git diff --check
```
