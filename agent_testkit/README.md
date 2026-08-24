# agent_testkit (internal)

Axyndra 内部 Agent / ToolPipeline / persistence / recovery contracts 使用的确定性
测试适配层。第三方 SDK consumer 应依赖 `axyndra_agent_testkit`，而不是此 package。

内部能力包括：

- `ScriptedModelPort`：文本/tool/usage 事件、重复 delta、截断流、错误与挂起取消；
- `ScriptedToolExecutor`：结果、call-bound error、delay 和取消竞态；
- 内存 Conversation/Run/Operation repositories 与 recording audit；
- 精确到第 N 次操作的 repository fault；
- `DeterministicIds`、`ManualClock`；
- `ScriptedCapabilityPolicy`，只通过正式 `CapabilityPolicy` port 返回决策；
- TTFT、generation、context/tool/render/resume、RSS 的 P50/P95/P99 聚合。

这些 doubles 可以模拟 host 决策，但不能构造 `PreparedOperation`、伪造 Receipt，
也不能绕过 ToolPipeline。不可测指标使用 `None`，不会伪造为 0。执行 contract 时应直接检查生成的二进制
退出码；部分 cjpm 版本可能吞掉子进程异常，`course check` 和 release gate 已遵守
这一边界。
