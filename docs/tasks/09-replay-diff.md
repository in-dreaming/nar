# 09 - 确定性 Replay Backend、Tool Replay 与差异比较

## 目的

使用 Trace 离线复现 Agent Turn，保证 Replay 不触碰 live model/tool，并能定位行为差异。

## 依赖

- 05 Trace reader/writer。
- 06 Agent Loop。
- 07 Operation 状态与异步事件。

## 实现方案

1. ReplaySession 从 trace 构建按 turn/model call/tool call/operation sequence 索引，加载时校验完整性和 schema 兼容。
2. Replay ModelBackend 实现与 live 相同接口，按记录的 poll/event 顺序产生事件；取消语义仍走正常状态机。
3. Replay Tool dispatcher 验证 name/version/call id/canonical args/resource/revision 后返回记录结果或 operation transitions。任何不匹配立即 replay_mismatch（映射稳定内部错误并携带安全诊断）。
4. Runtime replay mode 在类型层或配置层阻止注册/调用 live backend 和 callback；缺 record 不允许 fallback。
5. Diff 比较 context manifest、model events、tool calls/results、budget、terminal；输出第一个 divergence 的 sequence/path/expected/actual，敏感字段遵守 redaction。
6. 支持严格模式（事件/poll 边界全部一致）和语义模式（允许 text delta 分块不同但拼接、usage、调用和 terminal 一致）。
7. golden trace 由任务 06 场景生成并固定；live record -> fresh Runtime replay -> event/session/final outcome 相等。

## 必测细节

- 用计数器/失败 callback 证明 replay 中 live model/tool 调用次数为零。
- 缺失、额外、重排、参数差异、schema major 不兼容、截断 trace。
- 异步 operation complete/cancel race 按记录唯一重现。
- Diff 输出不泄露已 redacted 内容。

## 完成校验

```powershell
zig fmt src tests
zig build test --summary all
zig build test-integration --summary all
zig build test-all
git diff --check
```
