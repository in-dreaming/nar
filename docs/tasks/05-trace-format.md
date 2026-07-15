# 05 - Trace 事件、Append-only Writer/Reader 与内存 Sink

## 目的

建立首版稳定 Trace 格式，完整记录 Turn 决策链，并可在损坏或截断输入上安全失败。

## 依赖

- 01 的稳定 ID、ErrorCode 与事件所有权。
- 可复用 fund trace/buffer/hash 的公开能力，但 NAR schema 归 NAR 所有。

## 实现方案

1. 定义 TraceHeader：magic、major/minor、flags、session/runtime id、固定 little-endian；record 定义 type、schema version、sequence、payload length、checksum。
2. TraceEvent 覆盖 turn start/context manifest/model request/model event/tool validation/tool call/tool result/operation transition/budget/terminal。敏感字段支持 redact/hash/omit 策略并记录策略结果。
3. Writer 支持 MemorySink 与 caller-provided Sink；append 先编码完整 record 再提交，失败不产生看似有效的半 record。
4. Reader 增量解析，限制最大 record/payload，检测 bad magic/version/length/checksum/sequence/truncation；允许 minor 版本跳过已知可跳过 record，major 不兼容失败。
5. 建立 canonical payload 编码。可使用稳定 JSON 作为首版 payload，但 envelope 必须是二进制且 key 顺序规范；浮点/整数表示稳定。
6. TraceBudget 在写前检查，超限生成唯一 terminal/budget 结果时保留诊断所需最小记录。
7. 添加 golden fixture 和 round-trip 测试；fixture 变更必须显式说明 schema bump。

## 必测细节

- 每个 record 边界截断、checksum 位翻转、超大长度、未知 type、乱序 sequence。
- Sink 写失败传播 storage_error，Writer 可安全 deinit。
- 敏感 tool args 不出现在原始字节。
- 不持久化指针、usize、native endian enum ordinal。

## 完成校验

```powershell
zig fmt src tests
zig build test --summary all
zig build test-integration --summary all
zig build test-all
git diff --check
```
