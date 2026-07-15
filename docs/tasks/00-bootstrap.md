# 00 - 工程骨架、依赖接线与构建契约

## 目的

建立 Zig 0.16 NAR 工程、模块边界、feature 裁剪和统一验证入口。此任务不实现 Agent 行为。

## 依赖

无。子模块应已位于 `deps/fund` 与 `deps/spindle`；初始化缺失时执行 `git submodule update --init --recursive`，不得修改其内容。

## 实现方案

1. 创建 `build.zig`、`build.zig.zon`，声明包 `nar`、minimum Zig 0.16.0，并把 `deps/fund/foundation` 作为本地依赖。spindle 必须为 `-Dspindle=true` 才解析的 lazy/local dependency。
2. 建立 `src/nar.zig` 和 setup 中的模块目录/聚合入口。只创建当前任务需要的最小可编译入口，禁止为未来功能放空实现。
3. 提供 `-Dprofile=minimal|runtime`（默认 runtime）和 `-Dspindle=false`。非法 profile、minimal+spindle 明确配置失败。
4. 构建静态库 `nar`；runtime profile 另可构建 shared library，但不要让 C ABI 空壳冒充实现。
5. 创建最小外部 Zig consumer 编译检查，证明只能通过 `@import("nar")` 访问公开 API。
6. 建立 test 聚合入口与 `check`、`test`、`test-integration`、`test-cabi`、`test-all` step。早期无 C API 时 `test-cabi` 可以运行一个明确标记 bootstrap 的构建检查，但任务 10 必须替换成真实 C smoke test。
7. 更新 README：定位、Zig 版本、submodule 初始化、构建命令、首版范围和非目标。

## 细节与约束

- 不把 fund/spindle 源码复制到 NAR。
- 检查关闭 spindle 时编译图中没有 spindle import。
- 模块命名避免与 Zig 标准库冲突。
- Windows/Linux/macOS 条件代码使用编译期 target 分派。
- 构建脚本不得访问网络下载未声明内容。

## 测试

- 外部 consumer 只能导入公开入口并成功编译。
- minimal、runtime、runtime+spindle 三种合法组合编译。
- minimal+spindle 以清晰配置错误失败。

## 完成校验

```powershell
zig fmt --check build.zig src tests examples adapters
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime
zig build check -Dprofile=runtime -Dspindle=true
zig build test-all
git diff --check
```

检查 `git status --short deps/fund deps/spindle` 无子模块内部修改。
