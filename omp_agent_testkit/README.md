# omp-agent-testkit

面向 `agent_sdk` consumer 的最小、确定性测试包。它只依赖 `agent_sdk` 与
`json4cj`，不包含 Agent 产品装配、ToolPipeline executor、持久化或恢复权限。

稳定面包括 `ManualClock`、`SequenceIds`、`ManualCancellation`、
`ExtensionContractHarness` 与 capability assertions。`FaultPlan` 当前为实验性原语。

完整边界和示例见 [`docs/agent-testkit.md`](../docs/agent-testkit.md)。
