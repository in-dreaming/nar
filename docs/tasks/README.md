# NAR 任务索引

实现 agent 先读 `setup.md`，再只执行脚本分配的单个编号任务。任务必须按编号顺序提交；提交主题固定为 `<task-id> done`。

任务 00-10 不依赖 spindle 未完成的 durable workflow。任务 11 仅使用 spindle 已公开的 executor/task/resource 能力，任务 12 做全局验收。
