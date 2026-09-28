# ADR 0002: Derived-call admission and operation state

- Status: Accepted
- Date: 2026-09-25

## Context

The public `ProductVnextControl.executeReadOnlyToolProgram` accepts source and starts a synthetic Program Run.
`ProductProgramSubOperationExecutor` accepts raw `ToolCall` values and writes a synthetic Thread `tool_call` Item for each child.
The executor then calls `ToolPipeline.prepare` and `ThreadRuntime.resolveOperation`.
The resolver writes a child `tool_result` Item. These child Items have no validated, canonically committed `run_program` root.
Programmatic tool calling (PTC) must use prepared-only execution and the canonical Operation and Receipt store.
It must retain child evidence without inventing model Decisions or user-visible tool-call turns.

## Decision

1. **Require one canonical root.** Start a Tool Program only from a validated, durable, canonically committed `run_program` ToolCall represented by `CommittedToolCallRef`.
   Prepare the root Operation through `AgentCore` and `ToolPipeline.prepareCommitted`.
   Resolve required approval before handoff. Compare the stored plan with the current tool identity and enforce the current capability ceiling.
   The Program Runtime must not create a `ModelDecision` or `CommittedToolCallRef`.
   Remove the raw-source `executeReadOnlyToolProgram` and former Program-suboperation preparation route in one clean cutover. Trusted SDK/CLI/MCP control roots use `prepareTrustedControlOperation` only after committing their own canonical direct-origin ToolCall Item; derived Program calls use host admission and `prepareDerivedOperation` exclusively.
   Do not keep an execution fallback.

2. **Admit every derived call through the host.** Treat each `DerivedToolCallRequest` as untrusted input, not as an executable `ToolCall`.
   Mint a host-only `ProgramExecutionAdmission` from the root Operation.
   Bind it to the root ToolCall Item, Run, turn, epoch, immutable Program identity, and root `ToolInvocationContext.capabilities` value.
   Intersect that ceiling with the host read-only allowlist. Never fill defaults or accept permissions from Program arguments.
   Validate each request against the current descriptor and schema.
   Normalize the call, check its plan against the frozen root ceiling, and persist the derived Operation before handoff.
   Only a prepared derived invocation may reach an executor.
   The Program cannot choose an Operation ID, parent, Run, capability, network policy, or executor.
   Reject shell and write tools, arbitrary network, nested Programs, and model or provider APIs.

3. **Store identity with the canonical Operation.** Give each request an opaque `request_key` scoped to its parent.
   The key supports retries but grants no authority.
   In the accepting transaction, the host assigns the next per-parent call sequence and one child Operation ID.
   It computes a digest from the canonical tool name, arguments, schema, and implementation identity.
   Persist a `derived_operation_admissions` row keyed by child `operation_id`.
   Store `parent_operation_id`, `call_sequence`, `request_key`, and `request_digest` in that row.
   Enforce uniqueness for `(parent_operation_id, request_key)` and `(parent_operation_id, call_sequence)`. The child Operation ID is the stable identity.
   Keep Operation state and Receipts in the existing canonical tables.
   For a derived Operation, `operations.tool_call_item_id` and its effect record point to the actual root `run_program` Item.
   Never create a child Thread Item.
   `decision_operations` continues to bind validated root Decision calls only.
   Require each derived parent to be the active canonical root for the same Run and root Item.
   Reject nested derived parents.
   Insert the derived Operation, immutable effect record, and admission in one SQLite transaction before handoff.
   A repeated parent and request key with the same digest resolves to the existing Operation or Receipt state, including an in-progress state.
   Never start a second executor for that duplicate.
   A different digest for the same parent and request key is a conflict.
   The admission row stores identity only. It is not a second state or Receipt ledger.

4. **Keep child settlement out of conversation history.** Extend the existing `AgentStore` settlement boundary with a derived-result variant.
   In one transaction, record the child Receipt and terminal Operation state.
   Do not insert a Thread `tool_call` or `tool_result` Item for a derived Operation.
   Do not advance the root Run or Thread revision.
   Keep the reserved child result-item ID in the immutable effect record.
   Never materialize that ID as a Thread Item.
   Let the root Operation emit one canonical ToolResult with a bounded aggregate, error, or result references.
   Link child Receipts through parent identity for inspection and recovery.
   Keep parent and child terminal states separate. A successful child never marks the root complete.

5. **Share policy, scheduling, and approval.** Require every child to pass normal ToolPipeline descriptor and schema checks.
   Give each child a frozen normalized plan.
   Allow only read-only host tools. Give the Program process no ambient network authority.
   Before handoff, compare the frozen plan with the current descriptor, schema, and implementation.
   Enforce the live capability ceiling. Approval cannot add permissions.
   A denial cannot trigger a retry with new permissions.
   Have the parent yield its exclusive scheduling slot before it awaits a child.
   Hold no coordinator lock or database transaction during child execution.
   Children use the shared scheduler and parent Run budget.
   Set `ToolProgramLimits.maxParallelCalls` to 1 initially.
   This lets the root progress under a one-slot scheduler.
   Resume an approval-waiting child only in the same live Program Runtime, after rechecking the frozen plan.
   Approval denial, expiry, cancellation, timeout, or Draining marks the child terminal and stops the Program.
   A policy denial never reaches executor handoff.
   No child remains Prepared indefinitely.

6. **Preserve recovery evidence without restoring the VM.** Never restore Program memory or stack after process loss.
   If a child has not reached handoff, terminalize it without execution.
   If it reached handoff but has no Receipt, record `OperationOutcome.Unknown`.
   Apply the existing recovery policy without blind replay.
   Keep completed child Receipts if the root later fails.
   Do not resume an old Program Runtime or reuse its child identity.
   Another attempt requires an explicit new root ToolCall and new Operations.

## Migration and failure cases

Add the derived-admission relation and uniqueness constraints in a versioned SQLite migration.
Do not rewrite canonical roots or `decision_operations`.
Keep existing Program rows without a validated root binding as legacy evidence.
Do not infer parent links from item IDs, Run IDs, or provenance.
Never resume or replay those rows.
Root lookup, recovery, and execution must distinguish a canonical root from a derived Operation.
Reject legacy rows as execution authority.

Fail closed when any of these conditions holds:

- The root Decision is provisional or uncommitted, or its Run, turn, or epoch is stale.
- The parent differs from the canonical root, or the Program attempts a nested derived call.
- A request key is reused with a different digest, or persistence fails before handoff.
- The tool is outside the read-only allowlist, or its frozen identity changes.
- The live capability ceiling no longer permits the plan.
- Approval is denied, or Run cancellation, timeout, or Draining interrupts execution.
- A child crosses handoff but has no Receipt after recovery.
  Record Unknown. Do not report success or replay the child blindly.

Contract tests must prove that duplicate messages do not duplicate execution.
They must prove that derived Operations add no Thread ToolCall or ToolResult Items.
They must prove that a successful root commits one result.
A one-slot scheduler test must prove that the root yields its slot and does not deadlock while awaiting a child.

## Consequences

- Internal tool work has durable parent and child Operation evidence.
  It does not invent assistant Decisions or pollute canonical conversation history.
- Synthetic Thread ToolCalls are rejected because they fabricate model history.
- A separate child execution ledger is rejected because it duplicates Operation and Receipt authority.
- The direct Program API and synthetic child-call path must be removed.
  No raw-call compatibility shim remains.
- Historical synthetic Program Items remain visible as history.
  They cannot prove a committed root or authorize replay.