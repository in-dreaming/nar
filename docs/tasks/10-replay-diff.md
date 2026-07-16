# 10 - Trace 驱动的确定性 Replay 与差异比较

## 目的

离线复现同步/异步 Agent Turn，保证 Replay 不调用 live model、tool、HTTP 或 spindle executor callback，并定位行为差异。

## 依赖

- 05 Trace 格式、06 Agent Loop、08 Operation/spindle task transitions、09 完整 model event 行为。

## 实现方案

1. ReplaySession 按 turn/model call/tool call/operation sequence 建索引，加载时校验 schema、连续 sequence 和 terminal 完整性。
2. Replay ModelBackend 按记录 poll/event 顺序产生事件；Replay Tool/Operation 验证 name/version/call id/canonical args/resource access/revision 后返回记录结果。
3. Runtime replay mode 在类型/配置层禁止 live backend、callback、HTTP 和 ExecutionServices.submit。缺 record 不回退在线。
4. spindle 调度事实作为 Trace 输入重现：executor route、queued/start/terminal、resource ordering、cancel winner；Replay 不实际创建 spindle Task。
5. Diff 比较 ContextManifest、ModelEvent、Tool/Operation、budget、terminal、resource order。输出首个 divergence 的 sequence/path/expected/actual，遵守 redaction。
6. strict 模式要求 event/poll/task transition 一致；semantic 模式允许 text delta 分块不同但拼接、usage、调用、resource ordering 和 terminal 一致。
7. golden trace：成功 async move、waiting_operation cancel、OpenAI fixture tool call。record -> fresh replay -> event/session/outcome 相等。

## 必测细节

- live model/tool/HTTP/executor callback 设置为调用即失败，计数始终为零。
- 缺失、额外、重排、参数/resource/version 差异、截断、checksum/schema 不兼容。
- complete/cancel/timeout 竞态按记录唯一重现。
- Diff 不泄露 redacted 内容。

## 完成校验

```powershell
zig fmt src tests
zig build test --summary all
zig build test-integration --summary all
zig build test-all
git diff --check
```
