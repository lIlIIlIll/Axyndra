# Workflow migration: execution and document boundary

This document preserves the migration roadmap and authored validation from the
original schema28 document-foundation checkpoint. Future-tense requirements in
sections 1 and 2 describe that historical checkpoint, not current production APIs.
See [current source state and historical evidence](plugin-first-migration.md) and
[Coding assembly](coding_distribution.md) for the current integration boundary.

The current source uses installed Workflow native Tool/Command contributions for
Todo, Goal, Plan, Task, Hub and Yield business logic. Old static Workflow business
tools and live legacy metadata writers have been retired. Preserved cold
`thread_metadata.todo_payload` / `goal_payload` bytes remain available to explicit
migration and historical inspection; they are not a parallel live fact store.
No dual write is allowed. Source migration does not establish successful current
compilation, installed execution or complete A5/A7 acceptance.

## 1. Controlled document service (historical foundation roadmap)

`plugin_document_intent.cj` defines descriptive, immutable frozen data. The
binding includes actual installed namespace/package/generation/configuration,
Thread/lane/Run/epoch/parent Operation, contribution and implementation/schema
identity. Only the Host constructs it from an actual invocation. Workers may
propose a logical key and value; they may not select another namespace, Thread,
lane, Run, generation, filesystem path or artifact reference.

The execution broker request is exactly `{intent_id}`. It selects one already
frozen intent from the current invocation, never worker-supplied replacement
bytes. `read` freezes revision and exact raw JSON; `compare_exchange` also
freezes the replacement. A null replacement is a revisioned tombstone. Prior
malformed JSON is preserved verbatim; repair cannot silently normalize it.
One parent may contain at most eight distinct keys and intent IDs. Operations
on dependent versions require another canonical preparation.

The new Store branch reuses the existing Direct/Committed canonical source,
ParentIntent audit, full normalized plans, epoch and handoff checks. It also
checks the actual `run_lane_bindings` and source Item's lane, active Turn owner,
and exact document revision/raw bytes. This runs on child admission, execution,
handoff and completed settlement. Reads get the same scope checks as writes.
The parent handoff hashes the entire encoded plan, and the authorization audit
hashes the entire child plan, including package generation and data.

The document executor will return the exact proposed result without mutating
the repository. The existing `settleDerivedOperation` transaction applies the
CAS immediately before inserting the reserved Receipt and updating state.
There is no nested transaction. A Receipt/state SQL failure rolls back the CAS.
Unknown or never-handed Rejected closes an old obligation without changing a
document; neither grants a new execution. Completed requires actual child
handoff and the exact frozen result. Standalone primitive IDs cannot execute
this service. Read children are ReadOnly/NeverReplay; CAS children and their
parents are ExternalMutation/NeverReplay.

Still required before exposing this branch: an operator/manifest document
scope with exact logical keys/read-write rights (absent means deny), private
live invocation/package-generation guard through settlement,
the hidden Tool executor, and the generic native broker adapter. A shape or
plan predicate does not create this guard. Actual installed-package tests must
cover disable/re-enable and cancellation during the service callback.

Preparation must not privately read a database in a pure worker query. The
two-stage path will reuse the existing ContextRead continuation: a Host-owned
read request selects this invocation's authorized document address, a real
ReadOnly Operation produces immutable revision/raw-byte facts, then the worker
computes the proposal from those facts. The resumed preparation freezes the
replacement before approval; hook/algorithm execution is not repeated after
approval. Missing/changed facts reject instead of rereading a new premise.
No fabricated ModelDecision, UserMessage or fresh maintenance budget is used.

Per-document storage stays 8 MiB. Complete normalized plans and framed Receipt
payloads keep the existing independent 8 MiB codec ceiling, checked before
handoff. Inline old+new bytes can reach that ceiling earlier; large-document
artifact/reference transport remains an explicit parity obligation. This
candidate does not claim all repository-sized records fit an inline plan.

## 2. Actual Todo/Goal/Plan tools and commands (historical foundation roadmap)

The Workflow package must gain actual Tool and Command contributions alongside
its provider. Its existing pure policy modules own validation, mutation,
Markdown, descriptions, result formatting, argument routing and role data.
Host adapters expose only generic document read/CAS, ContextRead, approval and
already controlled filesystem proposal/application services.

Retire the business algorithms and static registrations in
`agent_product/src/todo_tool.cj`, `todo_slash.cj`, `goal_runtime.cj`,
`goal_slash.cj`, and `tools.cj` (`TodoTool`, `GoalTool`, `PlanWriteTool`). Switch
`ProductRuntime` getters/setters, Application/TUI/RPC editing and compaction
consumers to the selected installed contribution and the generic documents.
The plugin parses `/todo`, `/goal`, and planning commands; Host command routing
does not retain permanent Workflow-specific dispatch. Canonical plan review,
actual approvals and legal continuation remain Host responsibilities.

All `SqliteSessionMetadataRepository.setTodoPhases/setGoalState` live writers
must be removed together with their consumers. Schema migration retains their
old bytes as archival history, including malformed values. Generic fork/reset
already has explicit same-database document handling in the foundation.

Goal continuation is a separate Host allowance. User-selected budget, actual
Run token usage, explicit pause and restart constraints cannot be supplied or
reset by a document. The Host allowance is bound to canonical Thread/lane and
the actual user control; plugin suggestions only propose whether/how to
continue. Editing `tokensUsed`, `baselineTokens`, `enabled`, or `tokenBudget`
inside a plugin document grants nothing. The previous user-budget stopping
semantics must remain, without a second model loop.

## 3. Task/Hub execution and commands

The installed Workflow native package owns Task, Hub and Yield argument parsing,
business policy, result assembly and command formatting. Its explicit peers,
messages, jobs, cancellation and process service families use the same generic
Host boundary; they do not require the retired default Hub tool. The former
`ProductTaskTool`, `ProductHubTool` and `ProductYieldTool` production classes have
been removed; preserved original contract names remain historical test evidence.

The Host freezes installed provider data and intersects child requests with the
real parent. It keeps actual child Run creation, one cumulative budget and slot
ledger, frozen plans, exact parent/child cancellation, canonical messages,
approval, Operation/Receipt settlement, retained cleanup and journal inspection.
Plugin role or document data may request, but cannot mint, Delegate/PeerMessage
authority. Process observation and mutation remain bounded Host primitives with
their actual source, current-plan, fence and receipt checks.

Tests must keep Committed and Direct roots, one-slot nested calls, parent
cancellation, child Unknown budget retention, resumed approval, and missing
original plugin historical inspection. The native package must actually invoke
the generic services; a provider hidden behind the old Tool wrapper is not the
final migration.

## 4. Distribution and deletion gate

Coding installs the normal independent Workflow package and seeds the existing
operator selection only when absent. Existing disabled/custom records are not
overridden. Static help, management and historical inspection remain available
without Workflow. Actual App/CLI/TUI/RPC scenarios use normal installation and
canonical entry points, not fixture-only bypasses. Original Todo/Goal/Plan and
Task/Hub success, error, capacity and cancellation oracles remain required after
production source retirement. Preserved historical PASS/FAIL results retain their
original source and environment scope. A5 remains incomplete until the current
installed paths and complete acceptance gates actually pass.

## Historical authored validation (original foundation checkpoint)

Four Domain cases cover deep-copy isolation, strict shape/numeric/hash/path
negatives, tombstones/corrupt historical bytes, and exact effect/parent matching.
Three actual SQLite unit cases cover rollback, revision ABA, and callback-side
row replacement. The existing Store contract has 76 authored scenarios across
real Direct/Committed sources and read/CAS modes: scope drift, no handoff,
primitive bypass, stale document at each phase, full-plan generation mutation,
missing proof, wrong result, Receipt insertion rollback and cancellation.
None has been compiled or executed here. They do not stand in for the required
installed Workflow broker and Product tests.
