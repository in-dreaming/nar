# 08 - OpenAI-compatible HTTP/SSE Backend

## 目的

实现首个 live model backend，支持 Chat Completions 风格流式文本和工具调用，同时保持网络实现可替换且可取消。

## 依赖

- 02 Model interface。
- 06 Agent Loop。
- 07 异步/取消/Executor。
- fund HTTP、SSE、JSON 公开能力；必须先阅读其 API 和测试。

## 实现方案

1. 配置 base URL、model、认证 header provider、额外安全 allowlist、timeouts；密钥只在请求时借用，不写 Trace/错误/Debug 输出。
2. 编码 OpenAI-compatible messages、tools、tool_choice、stream=true；拒绝无法表达的 NAR capability，而非静默丢弃。
3. 使用 fund HTTP/SSE adapter 异步请求。解析任意 chunk 边界、CRLF、多 data 行、comment、`[DONE]`，并映射为统一 ModelEvent。
4. 聚合同一 tool call index/id 的 name 与 arguments delta；检测 index 冲突、finish 前未完成、无效 JSON envelope、HTTP 非成功状态和超大 event。
5. 取消关闭/中止底层请求并最终产生 cancelled；timeout、DNS/TLS/HTTP/protocol 分别映射稳定错误。
6. Backpressure：Agent 未消费时不得无界缓存；达到上限暂停读取或明确失败。
7. 添加本地 loopback fixture server，脚本/测试产生分块 SSE、工具调用、错误响应、延迟与断连；测试不得访问公网。
8. minimal profile 不编译 backend 或 HTTP 实现；runtime profile 导出注册 helper。

## 安全细节

- 默认仅允许 http://127.0.0.1/localhost 和显式 https origin；重定向不得绕过 allowlist。
- 响应 body、header、event、tool args 均有硬上限。
- 错误文本脱敏 Authorization/API key。

## 完成校验

```powershell
zig fmt src tests
zig build test-integration --summary all
zig build check -Dprofile=minimal
zig build check -Dprofile=runtime
zig build test-all
git diff --check
```
