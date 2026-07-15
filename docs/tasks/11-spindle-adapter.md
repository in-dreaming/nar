# 11 - Spindle Executor/Task Graph/Resource Access 可选适配

## 目的

在不污染 NAR core 的前提下，将 worker/main-thread job 和资源访问声明接到 spindle 已公开的稳定能力，同时保留 standalone executor。

## 依赖

- 07 Executor/Operation/ResourceAccess。
- 10 C ABI（确认 adapter 不改变 ABI）。
- `deps/spindle` main 当前公开入口。Workflow 尾部能力不是依赖。

## 实现方案

1. 只阅读 `deps/spindle/src/root.zig` 公开导出及 executor/task_graph/resource_graph 文档和测试；不得导入私有文件，不得修改 submodule。
2. 在 `adapters/spindle` 实现 NAR Executor interface：worker job 提交到合适 executor；main-thread job 仍由宿主显式 pump，不能偷偷起线程。
3. 将 NAR stable resource key + read/write 映射为 spindle 支持的 whole-resource/page access。无法无损表达的 range 返回明确 unsupported，不扩大为 whole write。
4. 生命周期：adapter 不拥有外部 spindle Runtime 时只借用；拥有模式则成对 init/deinit。shutdown 遵守 NAR 协作取消和收敛语义。
5. `-Dspindle=true` 才解析 adapter/submodule module；关闭时二进制和编译图不含 spindle 符号。
6. 集成测试提交并行只读与冲突读写工具，验证只读可并发、写 hazard 有序、结果回到 Agent Loop；取消/shutdown 不留下任务。
7. 若当前 spindle 某高级接口不存在，只实现已存在且可验证的 executor/task graph 映射，并对 unsupported resource mode 返回错误。不得依赖 workflow，不得创建空适配器或修改 spindle 来凑接口。

## 必测细节

- standalone 与 spindle 对同一 Mock 场景产生相同语义结果。
- callback thread/main-thread affinity 正确。
- conflict 排序、取消竞态、queue rejection、adapter deinit active。
- `-Dspindle=false` 编译最小 profile；`true` 构建并运行专项集成测试。

## 完成校验

```powershell
zig fmt src tests adapters
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime -Dspindle=false
zig build check -Dprofile=runtime -Dspindle=true
zig build test-integration -Dspindle=true --summary all
zig build test-all
git diff --check
git status --short deps/spindle
```
