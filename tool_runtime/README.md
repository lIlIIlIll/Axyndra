# tool_runtime

Every model-visible tool call passes through one pipeline:

`catalog -> argument validator -> capability policy -> approval -> operation
state -> executor -> receipt -> audit`

Executors cannot ask the user for approval and clients cannot invoke executors
directly.

The public execution boundary is split into three phases:

1. `prepare` resolves and validates the call, evaluates policy, and persists a
   `PreparedToolInvocation` without executing it.
2. `authorize` records an approval decision without executing it.
3. `executePrepared` runs an already-authorized invocation and replays its
   receipt on retries.

This split lets a batch coordinator prepare every call and finish every
approval before any executor starts. `invoke` and `decide` remain convenient
single-call compositions of the same phases.

`ToolConcurrencyProfile` defaults to `Exclusive`. A `Shared` profile declares
typed read/write claims by namespace and exact/tree scope. Conflict checks use
canonical path components, so `/workspace/pkg` contains
`/workspace/pkg/file.cj` but not `/workspace/pkg2/file.cj`. A side-effecting
shared tool is rejected at registration unless it declares a write claim.

Unknown tools, invalid arguments, and known executor failures are returned as
error `ToolResult` values with the original call ID. Persistence, invariant,
budget, and recovery failures remain runtime errors. Executors stream typed
stdout/stderr/artifact/summary chunks through `ToolInvocationContext.outputSink`.

Approval requests bind the tool name, canonical argument value, capability and
resource to a stable hash. The operation repository retains the exact original
`ToolCall`; `decide` rechecks its digest before execution. Deterministic risk
flags and permanent denials run before an optional AI reviewer and cannot be
overridden by it.
