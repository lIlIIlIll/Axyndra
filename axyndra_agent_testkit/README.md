# axyndra-agent-testkit

Version 3.0.0 is the public deterministic testing companion for Native plugin
data handlers. It depends only on `agent_sdk`, yjson and the JSON seam.

`NativePluginContractHarness` validates a contribution and invokes the actual
pure handler. `PreparedNativePluginCase` is untrusted fixture data, not Kernel
Prepared, approval, Source, or execution authority. `ManualClock`, `SequenceIds`,
`ManualCancellation` and capability assertions remain available. `FaultPlan`
and `FaultRule` remain experimental.

The real public source consumer is `support_tests/testkit_consumer`. Complete
cooperative v2 harness oracles are retained separately in test-only Support
packages and cannot become a production dependency.

See [agent-testkit](../docs/agent-testkit.md) and
[compatibility](../docs/compatibility.md).
