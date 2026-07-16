# 12 - 首版端到端验收、示例与发布检查

## 目的

聚合 spindle 驱动的首版能力，验证真实 Zig/C 嵌入、profile 裁剪、异步/取消/Replay 与安全边界，不新增产品范围。

## 依赖

- 09 OpenAI-compatible、10 Replay、11 C ABI。

## 实现方案

1. `examples/minimal_agent` 使用无线程 minimal Host + Mock，完成 query -> sync action -> final。
2. `examples/runtime_agent` 创建地址稳定 spindle Host，完成 query -> async move（compute）-> main-thread confirmation（pump）-> final；展示 staged shutdown。
3. `examples/c_api` 与真实 header 一致，完成 async/pump 场景并释放全部 handle/buffer。
4. 集成 fixture：成功 async move；角色死亡时 waiting_operation cancel；pump deadline；resource graph 并行只读和写 hazard；shutdown active task。
5. 成功/取消 trace 在 fresh Replay Runtime 复现，live model/tool/HTTP/spindle callback 调用为零。
6. 本地 OpenAI fixture 完成 streaming text+tool，不需要公网/key。
7. `test-feature-matrix` 用编译与符号证据验证：minimal 无 thread/task/resource/HTTP/workflow；runtime 有 task/resource/HTTP，但无 ECS/workflow/SQLite/archive。
8. README/docs 补齐快速开始、模块图、Host ownership、线程模型、pump、取消、C ABI、profile、安全默认、Trace schema、spindle feature 和已知限制。
9. release check 聚合 fmt、测试、feature matrix、C/C++ header、示例、公开 API 文档、TODO/FIXME、gitlink 与 submodule clean。不设置未经基准验证的性能阈值。

## 验收场景

- 成功：query -> async move -> pump tool -> final；AgentEvent/Trace/Session/resource order 一致。
- 取消：waiting_operation 时 owner destroyed，NAR token、spindle Task、Turn 唯一 cancelled；late completion 拒绝。
- 安全：capability、schema、stale ObjectRef/WorldRevision/resource constraint 均在 callback 前拒绝。
- 预算：model/tool/wall/trace/pump 任一超限唯一 terminal。
- Shutdown：finite deadline report 可观察，最终 deinit 无 worker/task/operation/pump outstanding。
- Replay：离线结果一致，live 调用为零。
- C ABI：runtime/minimal consumer 均通过并释放所有资源。

## 完成校验

```powershell
zig fmt --check build.zig src tests examples adapters
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime
zig build test
zig build test-integration
zig build test-cabi
zig build test-feature-matrix
zig build test-all
git diff --check
rg -n "TODO|FIXME" src tests examples adapters include
git status --short deps/fund deps/spindle
```

`rg` 无匹配时退出码 1 是期望结果。全部命令和示例通过后才可提交。
