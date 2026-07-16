# 08 - Spindle 驱动的异步 Operation、主线程 Pump 与资源调度

## 目的

让长工具以 Operation 进入 spindle compute/blocking/pump executor，并把资源访问无损映射到 spindle Resource Graph。不得再创建 standalone executor。

## 依赖

- 07 的 ExecutionServices、spindle Host 和新 Runtime ownership。
- spindle 公开 Task/Executor/Task Graph/Resource Graph API。

## 实现方案

1. Operation Registry 使用 generational OperationId；状态 pending、queued、running、completed、failed、cancelled、timed_out，terminal 单向且恰好一次。
2. Operation 持有 spindle Task、NAR cancellation reason/token、owned completion payload、deadline 和资源映射。late/double completion 返回明确错误并释放 payload。
3. Tool callback 的 pending 结果使 Agent 进入 waiting_operation；completion 转为 tool result 并恢复 building_context。Agent cancel/timeout 同时取消 NAR token、spindle Task 和尚未开始的 pump work。
4. affinity 路由固定：query/CPU -> compute；明确 blocking I/O -> blocking；main thread -> pump。任何 callback 不得在错误 executor 上执行。
5. 实现宿主 `pumpMainThread(max_jobs, max_nanos)`，只通过 spindle 公开 executor facade/help boundary 驱动 caller-thread work。pump 不隐式发生在 Agent tick。
6. 把 Tool ResourceAccess 映射为 spindle ResourceKey/Range/AccessMode/VersionConstraint。多个可并行 tool call 构造成 ResourceTaskGraph：只读无冲突可并行，write hazard 有序；不支持的范围明确失败。
7. 单个无资源操作可直接提交 executor；有资源或并行批次必须走 Resource Graph，禁止自研 lock map。
8. Trace 记录 queued/start/complete/cancel/timeout、executor route、resource keys、spindle task terminal 和 shutdown rejection。
9. Shutdown：NAR 先停止接收、取消 operation，再调用 host 的 spindle staged shutdown；报告 outstanding operation/pump/executor 信息。

## 测试矩阵

- compute/blocking/pump completed/error/pending；main-thread callback 线程 id 等于 pump caller。
- cancel-complete、timeout-complete、shutdown-complete 竞态唯一 terminal。
- queue full/backpressure、stale OperationId、double complete、callback error、allocator failure。
- VirtualClock 帧/timeout 预算，不使用 sleep。
- 并行只读实际重叠；读写/写写 hazard 有序；exact revision 不匹配 callback 次数为零。
- finite spindle shutdown 取消 pending pump，deinit 后无 outstanding task。

## 完成校验

```powershell
zig fmt src tests adapters
zig build test --summary all
zig build test-integration --summary all
zig build test-feature-matrix
zig build test-all
git diff --check
```
