# 03 - Tool Registry、Schema、Capability/Policy 与对象校验

## 目的

建立模型唯一可见的能力边界，使工具在 dispatch 前经过完整、确定性的安全校验。

## 依赖

- 01 的 ID、ObjectRef、WorldRevision、错误和取消。
- fund 的 JSON/schema 能力；先检查公开 API，再决定薄封装范围。

## 实现方案

1. ToolDescriptor 包含规范化 name、description、version、JSON Schema 子集、flags、thread affinity、required capabilities、resource access、revision policy 和 profile mask。
2. 实现 Schema 编译与验证的首版子集：object、array、string、integer、number、boolean、null、required、properties、additionalProperties、enum、min/max、长度。拒绝未知 schema keyword，避免误以为已校验。
3. Tool Registry 编译 schema 后注册，名称采用明确 ASCII 规则，重复 name/version 明确失败，注销使旧 handle stale。
4. CapabilitySet 和 Policy 采用默认拒绝；实现 build hard limit > shipping policy > project/agent > runtime override 的交集语义，任何上层不能放宽。
5. HostValidator interface 在调用前验证 ObjectRef generation 与 WorldRevision。Tool 参数中的对象字段由 descriptor 显式声明，不能启发式扫描 JSON。
6. Dispatcher 按 setup 固定顺序校验，且只在全部通过后调用 callback。错误结果对模型可见时必须脱敏，不泄露 capability 列表或内部地址。
7. Tool callback 返回 completed JSON、pending OperationId 或 typed error；Operation 实现在任务 07，当前只定义契约并允许 completed/error。
8. 资源访问声明至少支持 stable resource key + read/write；核心保存声明但不调度 graph。

## 必测细节

- 恶意/深层/重复 key/类型错误 JSON；schema 上限避免递归或内存耗尽。
- 未授权 callback 调用次数为零；schema 错误、stale object、revision 冲突同理。
- policy 层级只能收紧；shipping 禁用 debug tool。
- unregister/re-register 后旧 ToolId 失败。
- callback panic 不作为正常错误机制；所有结果释放恰好一次。

## 完成校验

```powershell
zig fmt src tests
zig build test --summary all
zig build test-all
git diff --check
```
