# 11 - 稳定 C ABI 与 Owned Runtime Host

## 目的

暴露可实际嵌入的 C API，并在 C wrapper 内安全拥有 `std.Io.Threaded`、spindle aggregate Runtime、NAR Runtime、Agent/Tool/Operation handles。

## 依赖

- 07 Runtime Host ownership、08 Operation/Pump、10 Replay。

## 实现方案

1. `include/nar.h` 使用 C11 fixed-width 类型、opaque uint64 handle、显式 enum 数值、version/struct_size 和 `extern "C"`。禁止 Zig layout、bool、usize、error union 泄露。
2. C `nar_runtime_create` 为 runtime profile 分配地址稳定 Owner，依次初始化 `std.Io.Threaded`、spindle Runtime、NAR Runtime；minimal 创建无线程 Host。任一步失败严格逆序释放。
3. `nar_runtime_destroy` 先拒绝新工作，按 monotonic deadline shutdown NAR/spindle，再销毁 NAR、spindle、Io。超时通过 report/error 返回，但最终 destroy 仍不得遗留线程。
4. API：version、runtime create/shutdown/destroy、tool register/unregister、agent create/destroy、submit/tick/pump_main_thread/poll/cancel、operation complete/fail/cancel、buffer release、replay runtime create。
5. 输入 struct 首字段 `struct_size`，必要时加 version；小于必需尺寸拒绝，大于尺寸忽略未知尾部。profile 和 worker/queue/observability 配置映射 spindle Config，并有硬上限。
6. Buffer 使用 `nar_buffer {data,size,release,userdata}` 或 caller-buffer 两阶段查询。任何路径不得 Zig 分配 C free。
7. C Tool callback 仅获得受限 context、JSON args、result sink、userdata；sink 完成一次，可返回 pending Operation。Main-thread callback 只在 C caller 调用 pump 时执行。
8. ABI 捕获全部 Zig error/panic boundary，转稳定 ErrorCode。Spindle SubmitError/ShutdownReport 映射为 NAR error/report，不泄露内部地址。
9. 真实 C smoke：runtime profile 创建 Owner，注册 sync/async/main-thread tools，驱动成功和取消；C++ header 编译；minimal smoke 证明无线程路径。
10. 导出符号检查确保只有声明的 `nar_*` 公共符号，无意外 Zig/spindle API。

## 必测细节

- null+zero/null+nonzero、未知 enum、struct size、重复 destroy/release、stale handle。
- callback userdata 生命周期和 destroy 后零回调。
- pump thread affinity、shutdown active operation、late completion。
- init fault/allocator failure 覆盖 Io/spindle/NAR 各阶段。
- 32/64 位 ABI 字段和 C/C++ header。

## 完成校验

```powershell
zig fmt src tests examples
zig build test-cabi --summary all
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime
zig build test-feature-matrix
zig build test-all
git diff --check
```
