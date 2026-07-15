# 06 - Runtime、Agent/Turn 状态机与最小 Agent Loop

## 目的

把 Model、Context、Tool、Session、Budget 和 Trace 组装为单 Agent 的确定性执行循环，完成首个架构验收场景。

## 依赖

- 02 Model stream/Mock。
- 03 Tool Runtime。
- 04 Context/Session/Budget。
- 05 Trace。

## 实现方案

1. Runtime 拥有 model/tool registry、agent registry、operation 预留接口、配置和可选 sinks；创建失败必须逆序释放。
2. AgentInstance 持有 definition、session、mailbox 和当前 turn。一次只允许一个 active turn；submit 在 terminal 后创建新 TurnId。
3. 实现 setup 固定状态机。每次 `tick/poll` 做有界工作，不阻塞、不递归跑完整循环；可配置每 tick 最大事件/步骤。
4. 标准循环：submit -> build context -> start model -> consume stream -> 若 final text 则 terminal；若 tool call 则组装/验证/dispatch -> 将结果加入 session/context -> 下一次 model call。
5. tool arguments 只在 tool_call_end 后解析。缺失 end、无效 JSON、重复 call id、finish 与未完成 tool call 冲突均为 model_protocol_error。
6. 每个状态转换发 AgentEvent 与 TraceEvent；事件顺序稳定，terminal 恰好一次。Mailbox 背压时 tick 返回 would_block，不丢 terminal。
7. cancel 在所有非 terminal 状态传播给 model/tool token；同步 callback 已运行完则阻止下一步。deinit active runtime 先协作取消并收敛。
8. budget、loop detector、tool error policy 在真实循环接线。禁止无界 tool/model 次数。

## 集成场景

Mock model 第一次要求 `query_player`，Tool 返回状态；第二次要求 `move_to`，Tool 完成；第三次输出完成文本。断言 session、event、trace、调用参数和 terminal reason 全部一致。

## 测试矩阵

- 纯文本、单/多 tool call、多轮调用、tool error 可返回模型、硬失败策略。
- 每个 active 状态取消；model/tool/budget/loop/mailbox 错误。
- runtime/agent/turn stale handle、重复 submit、terminal 后 poll。
- allocator failure 注入覆盖创建和循环关键分配点。

## 完成校验

```powershell
zig fmt src tests examples
zig build test --summary all
zig build test-integration --summary all
zig build test-all
git diff --check
```
