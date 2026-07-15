# 01 - 基础领域类型、句柄、取消与事件邮箱

## 目的

定义所有后续模块共享的稳定错误、ID/Handle、生命周期、取消、事件和有界邮箱语义，优先适配 fund 的公开基础能力。

## 依赖

- 00 工程骨架。
- 阅读 `deps/fund/foundation/src/foundation.zig` 及相关公开模块，不得导入其私有文件。

## 实现方案

1. 定义稳定 `ErrorCode` 与 Zig error 映射，覆盖 setup 列出的错误分类，并提供 retryable/model-visible/security-sensitive 元数据查询。
2. 定义强类型 RuntimeId、AgentId、TurnId、ToolId、OperationId、ObjectRef `{id,generation}`、WorldRevision。零值无效，序列化使用固定宽度。
3. 实现或封装 generational registry，检测 stale/double free；slot 重用必须递增 generation，溢出不得产生有效旧句柄。
4. 复用 fund CancellationSource/Token（若公开契约满足）；否则只写 NAR adapter，不复制另一个不兼容取消体系。取消幂等、跨线程可见、支持 reason。
5. 定义统一 `AgentEvent` tagged union、优先级、sequence、turn id、timestamp；事件 payload 明确 owned/borrowed 语义。
6. 实现有界 pull mailbox。terminal/high priority 不丢失；text delta 可在相邻且同 turn 时合并；容量不足返回 backpressure 或驱动合并，禁止静默覆盖。
7. 所有公开类型从 foundation/core 公共入口导出并写 API 文档。

## 必测细节

- generation 重用后旧句柄失败；零值、最大 id、generation 溢出。
- 多线程 cancel 只发生一次状态迁移，token 最终可见。
- mailbox FIFO、sequence 单调、delta 合并、terminal 保留、满队列错误。
- payload deinit 在消费、丢弃、mailbox deinit 三条路径恰好一次。
- ErrorCode 的数值显式固定，后续新增只能追加。

## 完成校验

```powershell
zig fmt src tests
zig build test --summary all
zig build test-all
git diff --check
```

代码审查确认 NAR 内没有第二套底层 allocator/executor/cancellation 实现与 fund 重复。
