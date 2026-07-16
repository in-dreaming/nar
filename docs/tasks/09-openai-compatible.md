# 09 - OpenAI-compatible HTTP/SSE Backend

## 目的

实现 runtime profile 的 live model backend，使用 fund HTTP/SSE/JSON 与任务 07 注入的 `std.Io`，通过 spindle 调度阻塞边界和取消，不创建独立网络线程池。

## 依赖

- 02 Model interface、06 Agent Loop、08 Operation/execution。
- fund HTTP/SSE/JSON 公开 API。
- ExecutionServices 中与 spindle Host 同生命周期的 `std.Io`。

## 实现方案

1. 配置 base URL、model、认证 header provider、origin allowlist、connect/first-byte/overall timeout 和响应上限。密钥只在请求时借用，不进入 Trace、错误或日志。
2. 编码 OpenAI-compatible messages/tools/tool_choice/stream=true；无法表达的 NAR capability 明确拒绝。
3. 网络请求使用 fund HTTP adapter 和 host `std.Io`。CPU parsing 可在 compute，必要的阻塞桥只提交 spindle blocking executor；不得启动 NAR 自有线程。
4. SSE 解析任意 chunk 边界、CRLF、多 data 行、comment、`[DONE]`；聚合同一 tool call index/id 的 name/arguments delta，映射统一 ModelEvent。
5. 取消同时终止底层 I/O Operation 与 spindle task；最终只产生 cancelled。timeout、DNS/TLS/HTTP/protocol 分别映射稳定错误。
6. Backpressure 有硬上限；可暂停读取或明确失败，禁止无界缓存。
7. 本地 loopback fixture 覆盖 chunk、工具调用、错误、延迟、断连、重定向和 oversized response；测试不得访问公网或使用真实 key。
8. minimal profile 不编译 HTTP backend/fund curl symbols；runtime profile 导出注册 helper。

## 安全细节

- 默认只允许 loopback HTTP 和显式 HTTPS origin；每次重定向重验 allowlist。
- header/body/SSE event/tool arguments 均有硬上限。
- Authorization、API key 和敏感响应字段在所有错误路径脱敏。

## 完成校验

```powershell
zig fmt src tests
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime
zig build test-integration --summary all
zig build test-feature-matrix
zig build test-all
git diff --check
```
