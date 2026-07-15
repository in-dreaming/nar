# 10 - 稳定 C ABI、Buffer 所有权与 C Smoke Test

## 目的

暴露首版可实际嵌入的 C API，使 C/C++/其他语言可管理 Runtime、Agent、Tool、Turn、事件和取消，而不泄露 Zig ABI。

## 依赖

- 06 Runtime/Agent Loop。
- 07 Operation/Executor。
- 09 Replay mode。

## 实现方案

1. `include/nar.h` 只含 C11 兼容 fixed-width 类型、opaque/generational uint64 handles、显式 enum 数值、version/size 字段和 `extern "C"` guard。
2. 提供 API version 查询、runtime create/destroy、tool register/unregister、agent create/destroy、submit、tick、main-thread pump、poll event、cancel、buffer release；名称以现有架构 API 为准并保持一致。
3. 所有输入 struct 首字段为 `struct_size`（及必要 version），允许未来 minor 扩展；小于必要尺寸返回 invalid_argument，较大尺寸忽略未知尾部。
4. 跨 ABI payload 使用 `nar_buffer {data,size,release,userdata}` 或 caller buffer 两阶段查询。任何路径不得 Zig 分配 C free，callback buffer 生命周期写入头文件。
5. C Tool callback 接收受限 invocation context、JSON args buffer、result sink、userdata；sink 只能完成一次，可返回 pending operation。Callback 不获得内部对象地址。
6. ABI 边界捕获 Zig error 并转 ErrorCode；绝不 panic/异常跨边界。线程安全和允许调用线程写入 header 文档。
7. 实现真正 C smoke executable：注册 query/action tool，Mock model 驱动完整 turn，poll final event；另测 cancel、无效/stale handle、buffer release。
8. C++ 编译检查验证 header 兼容。导出符号列表/动态库构建检查确保无意外 Zig API 作为公共 ABI。

## 必测细节

- null+zero 与 null+nonzero、超大 size、未知 enum、重复 destroy/release。
- callback userdata 生命周期；Runtime destroy 后不再回调。
- 32/64 位字段固定，不在公共结构使用 `usize`、bool、Zig enum/layout。
- `test-cabi` 替换任务 00 的 bootstrap placeholder。

## 完成校验

```powershell
zig fmt src tests examples
zig build test-cabi --summary all
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime
zig build test-all
git diff --check
```
