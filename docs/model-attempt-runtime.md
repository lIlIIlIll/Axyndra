# Model Attempt Runtime

## Purpose

Model generation and external operation execution have independent durability
boundaries. Provider stream content is provisional until the provider emits a
terminal protocol fact, the adapter validates the entire decision, and the
decision is durably stored. External side-effect uncertainty begins only after
the durable execution handoff.

## Safety gates

```text
Provider stream (provisional)
        |
        v
Provider terminal evidence
        |
        v
Validated durable ModelDecision
        |
        v
Atomic canonical projection
        |
        v
Canonical ToolCall (execution eligible)
        |
        v
Durable execution handoff
        |
        v
External side effect
```

Provider transport completion, provider message terminal, and Agent decision
validity are separate facts. `UsageCompleted` is accounting metadata and is
not required for decision validity.

## Durable identity

```text
SemanticModelRequestId
`-- ModelAttemptId
    `-- ModelDecisionId
        |-- DecisionBlockId
        `-- ScopedToolCallId
            `-- OperationId (bound by a unique source relation)
```

`ModelDecisionId` identifies one decision instance. It is never derived from
`content_hash` or `replay_hash`. Equal content produced by two attempts remains
two decisions. Decision block IDs and scoped tool-call IDs are assigned during
the first successful assembly and never reconstructed by reparsing provider
payloads.

`content_hash` covers ordered normalized semantic blocks. `replay_hash` also
covers replay-required opaque provider state and terminal evidence. Usage is
stored and finalized separately, so late accounting cannot change either
fingerprint.

## Provider terminal facts

The provider adapter vocabulary is:

- `StreamStarted`
- `ContentBlockStarted`
- semantic content deltas
- `ContentBlockCompleted`
- `MessageTerminalObserved`
- `UsageDelta` and `UsageCompleted`
- `ProviderError`
- `StreamTransportClosed`

The persisted `TerminalEvidence` records protocol, terminal event kind, raw
stop reason, whether a message terminal and stream EOF were observed, and the
adapter version. These are facts. `CompletionDisposition`, `DecisionOutcome`,
and validator version are interpretations that may be revalidated later.

Accepted completion dispositions are `Complete` and `ToolUse`. Output limits,
filtering, unknown stop reasons, and protocol-incomplete streams cannot become
durable validated decisions. A refusal is an outcome, not an incomplete
terminal: a complete refusal may be canonical.

## Atomicity and recovery

A decision and all stable decision blocks are inserted in one SQLite
transaction. Canonical projection is a separate idempotent transaction, but it
must bind every item in one batch to every block of one validated decision.
The projection transaction inserts canonical items, inserts their stable
decision bindings, and marks the decision canonical together.

Operation preparation may only consume a committed canonical ToolCall. The
`(decision_id, scoped_tool_call_id)` operation binding is unique, so concurrent
recovery cannot create two operations for one decision call.

Recovery is selected from durable state:

```text
no durable Decision       -> retry model with explicit AttemptPolicy
Decision not canonical    -> reproject the same Decision
canonical call no op      -> prepare idempotently
prepared no handoff       -> resume execution
handoff no receipt        -> reconcile unknown outcome
receipt no ToolResult     -> finalize from receipt
```

Failed attempts and their provisional UI output never enter the canonical
thread. UI streams are attempt-scoped and must support an aborted-attempt
signal.

## Invariants

1. Streaming observation is not a durable model decision.
2. A model decision used for execution is durable first.
3. A durable model decision is never regenerated during recovery.
4. Canonical projection from a durable decision is idempotent.
5. Operation preparation from a canonical ToolCall is idempotent.
6. Execution is not safely retryable after durable handoff unless the tool has
   explicit idempotency or reconciliation semantics.
7. Failed model attempts never enter the canonical transcript.
8. Retry policy changes are explicit, durable, and auditable.
9. A completed provider content block is not a complete decision.
10. Decision validation requires a provider-confirmed terminal boundary and an
    accepted completion disposition.
11. All ToolCalls belonging to one decision become canonical atomically.
12. Replay-required opaque state is immutable decision artifact data and part
    of the replay-integrity fingerprint; it is not reconstructed from
    normalized content.
13. RecoveryV1 uses one Core-owned monotonic idle clock. Meaningful reasoning,
    text, or tool progress renews it; there is no whole-attempt soft/hard
    deadline and production recovery requests do not synthesize a transport
    hard timeout.
14. Provisional provider content cannot enter Operation Runtime. Preparation
    is permitted only from atomically committed canonical ToolCalls belonging
    to a validated durable decision.
15. All provisional model output is scoped to exactly one `AttemptId`.
16. Provisional model output is never canonical state and may be discarded
    without affecting correctness recovery.
17. Attempt terminalization or supersession prevents later stream events from
    mutating its active provisional projection.
18. A committed canonical Decision supersedes the provisional projection of
    its source Attempt by identity, not by content comparison.
19. Lifecycle/audit retention is independent from high-frequency stream
    telemetry retention.
20. Loss or pruning of stream telemetry cannot prevent reconstruction of the
    canonical transcript or correctness state.
21. Telemetry persistence failure cannot invalidate an already durable
    ModelDecision or canonical projection.

Usage remains separate accounting metadata and is excluded from decision
identity and integrity fingerprints. Provider terminal, transport completion,
and Agent validity remain distinct facts.

## Online attempt recovery

`AgentCore` owns one process-local monotonic `AttemptDeadlineContext` for each
wire attempt. RecoveryV1 evaluates only stream idleness. Wall-clock values in
`model_attempts` remain audit timestamps and run-level resource deadlines;
they are never converted into a whole-attempt reasoning deadline. The legacy
soft/hard fields remain decode-compatible but RecoveryV1 persists them as
zero. Direct adapter callers may still set a transport timeout, while Core
recovery requests leave it disabled.

Meaningful progress is normalized model content: non-empty reasoning, text,
and tool-argument deltas, tool-call start, content-block completion, and
provider terminal evidence. Heartbeats, empty frames, usage-only events,
metadata, and transport EOF do not renew the meaningful-progress clock.

Automatic turn retry is bounded to two Attempts. Stream-idle failure retries
the exact effective thinking, tool choice, and output policy. A retry gets a
new `AttemptId`, links its parent, and keeps the same
`SemanticModelRequestId`. Immediately before a retry, Core re-reads durable
Decision state; an existing Decision is projected instead of regenerated.

Before any provider side effect, Core atomically persists the normalized
request/policy Attempt row, the `model.attempt_policy_applied` event, and a
running-model continuation, then claims dispatch with a second durable CAS.
After process restart, a Prepared Attempt is dispatched exactly once. An A1
whose dispatch was already claimed may create only one linked A2 and records a
possible-duplicate audit fact; a dispatched A2 is never expanded into A3.
Persisted capability snapshots validate their own canonical fingerprints and
are never compared with the live model catalog. Existing resolved attempts are
reused verbatim rather than re-resolved.

## Attempt-scoped UI and telemetry

Provider deltas are live, Attempt-scoped provisional observations. They update
the UI `AttemptProjection` immediately and are separately chunked in the
bounded stream-telemetry retention class. Attempt/Decision lifecycle facts use
an independent low-frequency lifecycle class. Neither class is a correctness
source.

Reconnect begins from canonical ThreadItems, then identifies the current
durable streaming Attempt and applies only an available telemetry tail. A
cursor inside a pruned or aggregated sequence span is reported as
`resyncRequired`; consumers must not infer missing assistant content.
`DecisionCommitted` supersedes the source Attempt projection through stable
Attempt/Decision identity, while failed, cancelled, aborted, and committed
Attempts reject late provider deltas.

## Current implementation slice

Schema version 9, terminal vocabulary, strict stream terminal validation,
durable Attempt/Decision storage, stable block identity, separate usage, and
atomic canonical binding are implemented. Production `AgentCore` persists an
auditable resolved request policy and restart checkpoint before the provider
request, validates terminal
evidence, computes separate semantic and replay-integrity fingerprints,
persists the complete Decision, and projects it atomically. Operation
preparation consumes only an attested `CommittedToolCallRef`; the SQLite source
binding makes repeated preparation idempotent.

Core-owned idle recovery, typed attempt failures, meaningful progress,
same-policy retry, frozen capability/policy resolution, and durable pre-HTTP
dispatch boundaries are implemented. Attempt-scoped provisional UI,
identity-based supersession, late-event rejection, cursor-gap resync, and
independent aggregated telemetry retention are implemented. Adaptive policy,
richer failed-attempt presentation, and provider fallback remain later slices.
