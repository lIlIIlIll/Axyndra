# Public Native testkit

`axyndra_agent_testkit` 3.0.0 tests Native plugin data handlers independently of
Product. It exposes deterministic clock, ID and cancellation controls plus
`NativePluginContractHarness`, `PreparedNativePluginCase`, `requireSdkOk`, and
capability declaration assertions. FaultPlan/FaultRule remain experimental.

```text
let harness = NativePluginContractHarness(MyNativePlugin())
let prepared = requireSdkOk(harness.prepare("echo", input, callId: "fixture"))
assertCapabilityNotRequested(prepared.definition, "workspace.write")
let output = requireSdkOk(harness.invoke(prepared))
```

The harness calls the handler's genuine validate/invoke functions, observes
cancellation and deadline expiration, and returns the complete business output.
Its fixture does not contain an OperationIntent, Host executor, Kernel Source,
Prepared operation, receipt, approval, or persistence authority.

The supported consumers are `support_tests/sdk_fixture_extension` and
`support_tests/testkit_consumer`. The former also has a separate Native executable
wrapper using the existing provider wire loop. Unit invocation is not evidence
of real process/Root/policy acceptance; those require fresh integration runs.

The internal `agent_testkit` remains a separate repository test facility for
real Core/ToolPipeline/persistence/recovery contracts. Neither testkit grants
production authority. All original v2 cooperative SDK/Host/runtime/harness
oracles remain runnable under explicit `support_tests/legacy_*` packages; the
default Product and Minimal dependency graphs must exclude them.

Version 3 baselines preserve future stable source changes under the standard
major-version diff policy. Historical v2 baselines stay unchanged. Native wire
compatibility still uses the actual AGENT_SDK_VERSION 2.1.0.
