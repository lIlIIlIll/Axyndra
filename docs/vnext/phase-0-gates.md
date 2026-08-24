# Axyndra vNext Phase 0 gates

This document freezes the observable behavior that later vNext phases must
preserve or deliberately replace. It is executable traceability for
`trajectory-fixtures.fixture`, not a claim that every broader release gate has
already passed.

## Semantic boundary

A semantic result becomes Thread truth only through the active Run commit
boundary. An Operation receipt remains durable even when its originating Run
is cancelled, superseded, or no longer eligible to extend the Thread.

Tests assert ordered Items, Run outcomes, approvals, Operation/Receipt state
and replayed Thread state through public package behavior. Internal helper
ordering is not part of the contract.

## Control-flow paths

| Path | Input and durable boundary | Required result |
|---|---|---|
| P001 | Final model response; assistant Item commit | Run completes once |
| P002 | Valid ToolCall; receipt and ToolResult commits | Call-ID-complete replay |
| P003 | Known pre-effect tool failure | Error result without a success claim |
| P004 | Independent tool calls | One receipt per concurrent Operation |
| P005 | Conflicting tool calls | Deterministic serialized waves |
| P006 | Approved side effect | Exact approved Operation executes once |
| P007 | Denied side effect | No executor call or external effect |
| P008 | Model result arrives after cancellation | Trace-only late result |
| P009 | Tool result arrives after cancellation | Receipt persists; no semantic ToolResult |
| P010 | Cooperative cancellation | Owned work joins before terminal state |
| P011 | Worker misses join deadline | Worker is quarantined; no late commit |
| P012 | Context crosses the safe watermark | Deterministic ContextCheckpoint |
| P013 | Candidate cut splits a tool pair | No checkpoint at the unsafe cut |
| P014 | C1: ToolCall exists, Operation absent | Reconcile exactly one Operation |
| P015 | C2: Prepared exists, approval absent | Request approval exactly once |
| P016 | C3: Executing exists and effect is proven absent | Replay only by declared policy |
| P017 | C4: effect may exist, receipt absent | Unknown/RecoveryRequired; no blind retry |
| P018 | C5: receipt exists, Operation unsettled | Settle from receipt without re-execution |
| P019 | C6: Operation settled, ToolResult absent | Append exactly one ToolResult |
| P020 | C7: ToolResult exists, Run not advanced | Advance without duplicate Item |
| P021 | Remote MCP `readOnlyHint=true`, no local trust | Remain approval-governed |
| P022 | Exact local MCP trust tuple | Narrow only that named tool |
| P023 | Matching checkpoint digest/version | Projection equals deterministic rebuild |
| P024 | Incompatible checkpoint digest/version | Rebuild from canonical Items |

## Scenario and test matrix

| Scenario | Paths | Tests | Public assertion |
|---|---|---|---|
| S001 final response | P001 | T001 | Exact Item order and completed replay |
| S002 tool success/failure | P002,P003 | T002 | Receipt/result classification |
| S003 approval decision | P006,P007 | T003 | Execute once or never |
| S004 late model/tool result | P008,P009 | T004,T013 | Zero late semantic commits |
| S005 safe compaction | P012,P013 | T005,T015 | Canonical Items and tool pairs unchanged |
| S006 MCP trust | P021,P022 | T006 | Conservative default and exact override |
| S007 conflict waves | P004,P005 | T007 | Concurrency only for independent effects |
| S008 cancellation join | P010,P011 | T008 | Joined or quarantined owned work |
| S009 crash before effect | P014,P015,P016 | T009,T014 | One deterministic recovery action |
| S010 unknown effect | P017 | T010,T014 | No automatic retry |
| S011 receipt-driven recovery | P018,P019,P020 | T011,T014 | No re-execution or duplicate result |
| S012 checkpoint compatibility | P023,P024 | T012,T015 | Replay matching data; reject stale data |

The minimal gate owns T001-T006, the boundary gate owns T007-T012, and the
strengthened deterministic scheduler, repeated-crash and 100k-Item contracts
own T013-T015. Crash fixtures must cover C1-C7 exactly.

## Input partitions

- Tool calls: none, one, independent, conflicting, duplicate ID, missing or
  oversized result, executor exception.
- Approval: absent, approve, deny, cancelled while waiting, stale decision,
  digest drift and reusable-grant ceiling.
- Cancellation: before/during model, during tool, after effect before receipt,
  uncooperative worker and child Run.
- Identity: active Run/epoch, stale Run/epoch, wrong Turn and duplicate
  sequence.
- Context: below/at/above trigger, unsafe tool boundary, huge schema and output
  reserve exhaustion.
- Recovery: C1-C7, repeated recovery and crash during recovery.

Every state assertion distinguishes semantic mutation from trace-only
observation, receipt durability from ToolResult eligibility, and normal
completion from `RecoveryRequired` or unknown outcome.

## Gate ownership

- `vnext_fixture_gate.py` checks fixture structure, C1-C7 coverage and test-ID
  traceability to this document.
- `vnext_contract_gate.py` executes the focused runtime, storage, lifecycle,
  projection, child-run, skill, mailbox and chaos contracts with the pinned
  daily SDK.
- PR validation runs the focused gate. Implementation and release validation
  run the same preflight before their broader product, packaging and provider
  gates.

Managed-heap, coverage, mutation and real-provider evidence remain
evidence-insufficient until their raw artifacts exist. RSS must not be
reported as managed heap, and a local implementation run must not be reported
as Hosted CI or Real Provider success.
