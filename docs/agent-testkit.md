# axyndra-agent-testkit architecture

## Purpose

`axyndra_agent_testkit` is the public testing companion for `agent_sdk`. It provides
small deterministic controls and a pure extension contract harness. It is not a
production host, an Agent embedding facade, or a way to acquire execution
authority.

Its stable source surface is frozen alongside the SDK as described in
[compatibility.md](compatibility.md); experimental fault helpers are outside
the stable consumer promise.

The repository also keeps `agent_testkit` as an internal package for Agent,
ToolPipeline, persistence, recovery, and benchmark contracts. Separating the two
prevents an external extension test from pulling the whole product or gaining
access to internal authority ports.

```text
yjson ─> yjson_support ─┐
                       ├─> agent_sdk ─> axyndra_agent_testkit ─> external extension tests
                       └────────────────────────────────────────────────────────────

agent_domain / agent_ports / tool_runtime ─> agent_testkit ─> omp contracts

production packages ─X─> either testkit
```

## Public deterministic primitives

Stable:

- `ManualClock`: explicit `nowMillis`, `advance`, `setMillis`, and SDK deadline
  construction without reading wall-clock time.
- `SequenceIds`: deterministic opaque fixture strings. It does not construct
  Run, Operation, Receipt, or other authority-bearing objects.
- `ManualCancellation`: an idempotent SDK invocation cancellation controller.
- `ExtensionContractHarness`: validates a real `agent_sdk.Extension`, looks up a
  tool, runs SDK validation/preparation, and decodes a supplied host result.
- `PreparedExtensionCase`: read-only observation of the definition, normalized
  invocation, and untrusted `OperationIntent`.
- `requireSdkOk`, `assertCapabilityRequested`, and
  `assertCapabilityNotRequested`: focused assertions with useful error context.

Experimental:

- `FaultRule` and `FaultPlan`: deterministic named occurrence faults. The plan
  returns a boolean; the caller must return a real production error domain.

Internal (`agent_testkit`):

- `ScriptedModelPort`, `RecordingModelEvents`, `ScriptedToolExecutor`;
- `ScriptedCapabilityPolicy`, invoked by the real ToolPipeline policy seam;
- deterministic Agent IDs/clock;
- in-memory Run/Operation repositories and recording Audit port that implement
  production ports and enforce replay/binding semantics;
- repository faults and benchmark statistics.

Protocol-specific scripted MCP/LSP/DAP/provider fixtures stay with their
libraries or adapters. Product assembly, SQLite, TUI, Task/Hub, and detailed
recovery fixtures remain product-specific.

## Extension example

```text
let harness = ExtensionContractHarness(MyExtension())
let prepared = requireSdkOk(harness.prepare("my_tool", input))
assertCapabilityRequested(prepared.definition, "workspace.write")
```

This proves schema, normalization, capability declaration, intent preparation,
and result decoding. It deliberately does not execute the intent. Side-effect
security tests use the internal host adapter and the real ToolPipeline:

```text
extension intent
  -> ToolPipeline
  -> capability / policy / approval
  -> trusted executor
  -> receipt / audit
```

A denied policy or approval is asserted with the recording executor/host call
count. An extension return value is never treated as an authoritative receipt.

## Fault and recovery testing

`FaultPlan` supports named, deterministic `fail-on-N` and `repeat-after-N`
behavior. It does not inject test-only exceptions into production code. Internal
recovery and chaos contracts combine it with production ports and
`ScriptedModelPort`; persistent recovery still runs through the real recovery
implementation. Process-level crash tests and SQLite contracts remain separate
integration evidence.

## Determinism and evidence limits

Public unit/contract fixtures use no random source, external network, executable,
or unnecessary sleep. Process and transport integration tests may still require
real time and remain in their dedicated gates.

A scripted model test does not prove a real provider works. A scripted protocol
peer does not prove clangd, a debugger, or SSH integration works. Deterministic
fixtures complement the release and external integration gates; they do not
replace them.

## Authority boundary

The public Testkit cannot grant approval, construct prepared operations, forge
receipts, mutate production audit/history, mutate Run persistence, or call a
trusted executor. Internal fakes implement production ports and are called by the
normal pipeline. No production package may depend on either Testkit package; the
architecture checker enforces both directions.
