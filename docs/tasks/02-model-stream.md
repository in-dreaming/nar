# 02 - Model 抽象、流式事件、Registry/Router 与 Mock Backend

## 目的

建立与 Provider 无关、可取消、可流式消费的模型契约，并以 Mock Backend 提供完全确定性的测试基础。

## 依赖

- 01 的错误、ID、取消和事件所有权规则。

## 实现方案

1. 定义 ModelDescriptor、能力位（streaming/tool_calling/vision/json_mode）、请求消息/内容块、Tool schema view、usage、finish reason。
2. 定义 backend vtable/interface：start 返回 request handle；poll/drain 产生统一 ModelEvent；cancel 幂等；release 释放请求。不得要求 backend 回调 Agent Core。
3. ModelEvent 覆盖 start、text_delta、tool_call_start/arguments_delta/tool_call_end、usage、finish、error；强制每请求恰好一个 terminal。
4. Registry 使用稳定 model/provider ID，拒绝重复名和失效 descriptor。Router 按显式 model、所需能力、优先级和允许列表确定性选择；无匹配返回 model_unavailable。
5. MockStep 支持文本、工具调用、usage、可控 pending tick、错误和 finish。Mock 只按 poll 次数推进，不用墙钟 sleep。
6. 参数和事件跨 poll 生命周期必须清晰；Agent 持久保存时显式复制。
7. 对 tool arguments chunk 只保证字节顺序，完整 JSON 留给 tool schema 阶段验证。

## 测试矩阵

- 单次文本完成、多 chunk UTF-8 边界、多工具调用、arguments 分块。
- cancel before start / during pending / after terminal。
- backend 重复 terminal、terminal 后事件、usage overflow、无 capability 匹配均被拒绝。
- Router 在相同输入下选择稳定，显式禁用模型不回退。
- Mock deinit 不泄漏未消费 payload。

## 完成校验

```powershell
zig fmt src tests
zig build test --summary all
zig build test-all
git diff --check
```
