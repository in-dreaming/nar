# 12 - 首版 Runtime 端到端验收、示例与发布检查

## 目的

聚合首版能力，验证真实嵌入路径、失败路径、裁剪和文档，不新增架构范围。

## 依赖

- 08 OpenAI-compatible。
- 09 Replay。
- 10 C ABI。
- 11 spindle adapter。

## 实现方案

1. 完成 Zig `examples/minimal_agent`：Mock model 查询玩家状态、发起异步移动、等待完成、输出 final；演示事件 pull、取消和完整 deinit。
2. 完成 `examples/c_api`，与真实 `include/nar.h` 一致并纳入 check。
3. 建立 runtime integration fixture：Agent 发起 `move_to` pending operation，宿主多帧 pump；角色死亡事件触发 cancel；另一场景成功完成并生成 trace。
4. 对成功 trace 在全新 Runtime 中 replay，live model/tool callback 设置为调用即失败；比较 event/session/outcome。
5. 使用本地 OpenAI fixture 完成一轮文本+tool streaming；不需要真实 API key/公网。
6. 验证 minimal/runtime/runtime+spindle 构建裁剪。提供可检查的编译或符号证据，minimal 不含 HTTP/trace-file/spindle。
7. 补齐 README 和 `docs/`：快速开始、模块图、线程模型、所有权、C ABI、profile、安全默认值、Trace schema/version、已知限制。
8. 增加 release check：格式、测试、C/C++ header、示例、公开 API 文档、禁止 TODO/FIXME、子模块 clean。不要设置未经基准验证的性能阈值。

## 验收场景

- 成功：query -> async move -> operation complete -> final，事件/Trace/Session 一致。
- 取消：waiting_operation 时角色死亡，operation 和 turn 均 cancelled，late complete 被拒绝。
- 安全：无 capability、stale ObjectRef、stale WorldRevision 均在 callback 前拒绝。
- 预算：tool/model/wall/trace 任一超限产生唯一 terminal。
- Replay：离线结果一致，live 调用为零。
- C ABI：C consumer 完成成功场景并释放所有 buffer/handle。

## 完成校验

```powershell
zig fmt --check build.zig src tests examples adapters
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime
zig build check -Dprofile=runtime -Dspindle=true
zig build test
zig build test-integration
zig build test-cabi
zig build test-all
git diff --check
rg -n "TODO|FIXME" src tests examples adapters include
git status --short deps/fund deps/spindle
```

`rg` 无匹配时退出码 1 是期望结果。所有命令通过且示例实际运行后才可提交。
