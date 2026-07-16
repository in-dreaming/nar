# 07 - Spindle Runtime 基线迁移（破坏性）

## 目的

把 spindle 从可选编译检查提升为 NAR 的统一调度/时钟/运行时基础，删除旧 standalone/`-Dspindle` 决策，并破坏性调整已完成 00-06 的 Runtime ownership。此任务只迁移基础，不实现异步 Operation。

## 依赖

- 已完成任务 00-06。
- `deps/spindle` main 基线至少为 `2a1f5e074fcc4c63a61e4b7437c288a2db9bb24b`。
- 必须完整阅读 spindle `README.md`、`src/root.zig`、`runtime/root.zig`、executor/task/resource roots、runtime integration tests；禁止导入私有实现文件。

## 实现方案

1. 更新 `build.zig.zon` gitlink/依赖和 `build.zig`：删除 `-Dspindle`；spindle 为所有 profile 的依赖。显式传递完整 feature set：
   - minimal：task_graph=false、resource_graph=false、ecs=false、workflow=false、所有 workflow 后端/归档=false；
   - runtime：task_graph=true、resource_graph=true、ecs=false、workflow=false、所有 workflow 后端/归档=false。
2. 新增 `test-feature-matrix`。编译并检查 minimal/runtime 两个独立 NAR module，断言 `spindle.runtime.Features` 与预期一致，并用符号/产物检查证明 SQLite/archive 未链接。
3. 定义 NAR `ExecutionServices`（名称可按代码惯例调整），至少借用：spindle Clock、compute Executor、blocking Executor、pump Executor、observability EventSink、必要的 `std.Io`。每个借用的生命周期和线程安全写入文档。
4. 重构 `core.Runtime.init`，要求显式 services；删除 `RuntimeConfig.now_ns` function pointer 和内部 SystemClock。所有预算、事件、Trace 时间读取 spindle clock。
5. 在 `adapters/spindle` 实现 `Host`：runtime profile 下拥有地址稳定的 `std.Io.Threaded` 与 `spindle.runtime.Runtime`，提供 services，执行 `shutdown(deadline)` 并最后逆序 deinit。若 Zig 调用方传入外部 `std.Io`，另提供 borrowed host，但所有权不可含糊。
6. minimal 提供不启动线程的 Test/Minimal Host，使用 spindle VirtualClock、Inline/Deterministic executor 和 caller-driven pump。不得维护 NAR 自研线程池或 executor vtable。
7. 将 NAR 对外取消与 spindle Task state 的桥接边界写清楚。此任务可保留 fund 带 reason cancellation，但删除任何重复的 NAR executor cancellation 类型。
8. 更新 00-06 的测试构造：显式创建 host/services；使用 spindle VirtualClock，禁止墙钟 sleep。同步 Agent Loop 语义应保持，允许公开 init 签名破坏。
9. README 更新新的 profile、host ownership、shutdown 顺序和 feature 边界。不添加旧 API shim。

## 细节

- spindle aggregate Runtime 返回地址相关 executor facade；Host 和 Runtime 必须地址稳定，禁止 init 后移动导致 facade context 悬空。
- NAR Runtime 必须先于 spindle Runtime 销毁；`shutdown` 后拒绝新 Agent/Turn。
- workflow 已完成但固定关闭。不得因 spindle 默认 workflow=true 而意外编译它。
- `spindle.runtime.Runtime.pumpExecutor().helpUntil` 可用于 caller-thread pump boundary；若需要精确 max_jobs/time API，封装公开 `Executor.helpUntil`，不得引用内部 PumpExecutor 字段。
- 删除 `adapters/standalone_executor` 或旧 README 中的 standalone 产品承诺。

## 测试

- minimal 无线程创建，VirtualClock 推进决定 timeout。
- runtime host 创建、services 使用、无任务 shutdown、重复 shutdown/deinit。
- init fault/allocator failure 逆序释放。
- finite deadline shutdown report 可观察；deinit 最终收敛。
- NAR Agent 在迁移前后的 Mock 成功/取消/协议错误语义通过现有测试。
- feature matrix 明确验证 task/resource/workflow/ECS/SQLite/archive 值。

## 完成校验

```powershell
zig fmt build.zig src tests adapters examples
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime
zig build test-feature-matrix --summary all
zig build test --summary all
zig build test-integration --summary all
zig build test-all
git diff --check
git status --short deps/fund deps/spindle
```
