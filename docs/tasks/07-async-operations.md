# 07 - 异步 Operation、Executor、主线程工具与帧预算

## 目的

让长工具和模型等待不阻塞调用线程，并明确 worker、main-thread pump、取消、超时和 shutdown 语义。

## 依赖

- 06 可运行 Agent Loop。
- fund executor/cancellation/clock 的公开能力。

## 实现方案

1. Operation Registry 使用 generational OperationId；状态 pending/running/completed/failed/cancelled/timed_out，terminal 单向且恰好一次。
2. 定义 Operation completion sink/interface，支持跨线程提交 owned result；late/double completion 被拒绝并正确释放 payload。
3. Tool dispatcher 对 async result 使 Agent 进入 waiting_operation；完成后生成 tool result 并恢复 loop。Agent cancel/timeout 传播 operation token。
4. 定义 Executor interface（submit worker、enqueue main thread、pump main thread、shutdown），实现 standalone adapter，优先包装 fund executor，不复制线程池。
5. MainThread tool 只能由宿主显式 `pumpMainThread(max_jobs, max_nanos)` 执行；worker poll 不得冒充主线程。记录 enqueue/start/end trace。
6. FrameBudget 限制每 pump job 数和耗时；Clock 可注入以确定性测试。高优先级不绕过硬预算。
7. ResourceAccess 列表随 job 传给 adapter，但 core 不自行构图。standalone 串行执行也必须保持同一冲突契约。
8. Shutdown graceful：拒绝新任务、取消 pending、请求 running 协作取消、等待/泵送至明确 deadline；不强杀线程。Runtime deinit 不留下 callback。

## 测试矩阵

- sync/main-thread/worker async 各路径；pending 多 tick 后完成。
- cancel 与 complete 竞争、timeout 与 complete 竞争，只有一个 terminal。
- stale OperationId、double complete、callback failure、queue full、shutdown active。
- 主线程 callback 记录 thread id，证明只在 pump 调用线程执行。
- 可控 Clock 验证帧预算，不使用 sleep。

## 完成校验

```powershell
zig fmt src tests adapters
zig build test --summary all
zig build test-integration --summary all
zig build test-all
git diff --check
```
