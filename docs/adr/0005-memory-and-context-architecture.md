# ADR 0005: Portable Memory and Context Architecture

- **Status:** Proposed — review required; no implementation is implied
- **Date:** 2026-10-19
- **Scope:** Context planning, memory governance, compaction, activation, portability, erasure and evaluation
- **Related:** [#39](https://github.com/lIlIIlIll/Axyndra/issues/39), [#45](https://github.com/lIlIIlIll/Axyndra/issues/45), [#46](https://github.com/lIlIIlIll/Axyndra/issues/46), [#48](https://github.com/lIlIIlIll/Axyndra/issues/48); [#44](https://github.com/lIlIIlIll/Axyndra/issues/44) for the model Attempt/retry boundary
- **Implementation baseline:** main@4d88fa6072f7176a6d236a1cb39b33529d5b609d; [draft PR #49](https://github.com/lIlIIlIll/Axyndra/pull/49) at e53b9f6545f6f154088c466e8af0f6e248a1cced
- **Numbering:** ADR 0004 is already proposed by draft PR #49; reserve 0005 for this independent decision.

## Context

Axyndra already has a canonical Thread/Run/Attempt/Decision/Operation/Receipt pipeline, ContextProjector, ContextCheckpoint, ModelContextManifest, versioned model-lane/tool snapshots and Memory v3 semantics. Draft PR #49 moves Memory, Compaction, Skills and ModelProvider business implementations into independently installed plugins. In that draft:

- agent_runtime/src/context_projection.cj checks projector version, lane protocol and canonical source digest before reusing a ContextCheckpoint. A protocol change can therefore discard a semantically useful summary and require reconstructing a longer history.
- agent_runtime/src/context_manifest.cj already seals the thread revision, checkpoint, Memory references, prompt contributions, tool snapshot and token budget. A second manifest or context revision system would duplicate authority.
- plugins/memory/src/native_memory_tools.cj maps both delete and forget to a tombstoning operation; plugins/memory/src/native_journal_business.cj appends a Deleted revision. This is **logical invalidation, not physical erasure**.
- The generic plugin document path has thread/lane-scoped authorization, while logical Memory scope includes user/workspace/global. Cross-thread knowledge sharing must be established through an explicitly authorized namespace, not inferred from a scope label.
- The independent Memory/Compaction policies and paged/fragmented transport are work in progress. PR #49 remains Draft, and its authored tests are not proof of end-to-end acceptance.

Axyndra needs long-lived sessions and Subagents that can compact history, recover and change model/provider without losing goals, constraints, evidence or already accepted execution obligations. Provider-native opaque reasoning items, cache state and tool wire formats are not universally portable. Saving every external environment is neither feasible nor required for safe continuation.

This ADR defines a **follow-up semantic architecture**. It does not claim #39 or #45–#48 are complete, and it must not expand the scope of PR #49 by silently replacing its unfinished plugin migration.

## Decision summary

1. **The session belongs to the trusted Runtime, not a model provider.** Portable continuation means semantic and execution continuity; not identical internal reasoning, prompt-cache reuse or deterministic model reruns.
2. **Keep one canonical fact and context authority.** Existing Thread/Run/Attempt/Operation/Receipt, #39 context events/revisions and ContextCompiler/ModelContextManifest stay authoritative. A Context Planner proposes the next context selection; it never publishes or rewrites canonical facts itself.
3. **Use a Hybrid Context Planner.** Incremental event/index maintenance can lag; immediately before an LLM request the planner freezes a source snapshot, reconciles deltas, enforces required information, retrieves/ranks/compacts candidates and presents a bounded plan to the existing compiler/host validator.
4. **Model Memory as versioned, evidence-linked knowledge units.** Fact-based is the logical model; document and graph views are optional, rebuildable projections. Knowledge kinds include facts, decisions, constraints, preferences, procedures and hypotheses; epistemic status is separate.
5. **Use dual-path memory proposals with unified governance.** An Agent can request a memory write; Runtime extractors can generate proposals. Neither writes authoritative knowledge without Memory governance and host-controlled storage/authorization.
6. **Support event-driven activation as hints.** Memory events may nominate knowledge for the next Context Plan; they cannot interrupt execution, grant permission, manufacture a tool call or create an independent Agent loop.
7. **Separate invalidation from erasure.** Versioned replacement, expiry and tombstones preserve audit semantics. True forgetting is a host-controlled deletion workflow with a visibility barrier and propagation to controllable source/payload/index/checkpoint/cache derivatives.
8. **Fence external dispatch after context sealing.** A frozen manifest/Attempt records the permission and erasure generation and the provenance of outbound content, but sealing is **not** continuing authority to transmit it. The trusted host must recheck the live barrier at each external dispatch, including requests that waited in a queue, and stop stale sends before egress.
9. **Evaluate independently.** Deterministic invariants are CI gates; semantic fidelity, cross-model task continuity and token/latency trade-offs use reproducible fixtures and separate evaluation, not self-scoring by the compactor.

## Ownership and dependency boundaries

| Existing issue | Sole implementation/authority owner | This ADR adds; explicitly **not** a duplicate |
| --- | --- | --- |
| [#39](https://github.com/lIlIIlIll/Axyndra/issues/39) | Append-only ContextUpdate, immutable context revision, per-branch/lane visibility, frozen Attempt input, native tool/Skill update support and legal commit cuts | Selection and retrieval **before** the existing revision/Attempt boundary; no second context-event log, ToolSetSnapshot, dynamic-tool API or cacheEpoch owner |
| [#45](https://github.com/lIlIIlIll/Axyndra/issues/45) A0/A1/A5/A6 (PR #49) | Plugin protocol, ContextProvider/ResourceProvider, independently installed Memory/Compaction/ModelProvider business implementations, isolated worker and broker, generic persistence, the trusted execution/approval/checkpoint boundary | Unified planner policy contract, knowledge governance semantics and portability guarantees **after** the underlying plugin contributions work; no parallel plugin manager, Store, model loop or rewrite of migration work |
| [#46](https://github.com/lIlIIlIll/Axyndra/issues/46) | Typed services, observer/transform/guard event contribution, bounded event ordering/reentrancy and controlled cross-plugin calls | Consume its observer mechanism for activation; no new hook bus, cross-plugin service router or privileged Memory listener |
| [#48](https://github.com/lIlIIlIll/Axyndra/issues/48) | End-to-end capability ownership matrix, removable-first-party-plugin tests, distribution/product acceptance | Memory/Context-specific semantics and regression cases; reference its F11–F17 and F21–F22 rather than marking their migration complete |
| [#44](https://github.com/lIlIIlIll/Axyndra/issues/44) | Model retry, fallback and Attempt/usage accounting | Context planning/compaction auxiliary model calls use the same host-owned budget and Attempt path; never retry behind a provider plugin |

Where the earlier #45 issue text conflicts with the later explicit breaking-change decisions in #46/#48, the **new runtime correctness invariants remain mandatory**, but legacy SDK/manifest/old persisted-format compatibility and old ecosystem shims are not required. Unsupported old data must be refused before destructive writes and kept intact. Update conflicting tracking text within its owning issue, not by implementing two contracts.

The proposed four conceptual responsibilities are **not four mandatory processes or packages**:

| Responsibility | Trusted host owns | Plugin/policy owns |
| --- | --- | --- |
| Runtime Context Coordinator | Canonical history/revision; authorization/trust, legal cut, snapshots, immutable Attempt binding, final validation/commit and host-mediated dispatch-time revocation/erasure fencing | None of these authorities |
| Context Planner | Planning entry point, effective access scope, required constraints, snapshot coherence, budget ceiling, selection validation and manifest handoff | Context sources, retrieval/ranking/allocation/compaction proposals and optional semantic planning algorithms |
| Memory Manager | Generic versioned namespaced persistence, CAS/visibility, access and retention/deletion authority, transaction/audit boundary | Knowledge schema/interpretation, extraction, deduplication/semantic conflict and memory activation proposals |
| Evaluation | Stable canonical evidence/metrics APIs and test fixtures with privacy limits | Replaceable evaluators and algorithms; no authority to mutate production state or certify their own output |

A business plugin may own multiple policies or use host-controlled generic document/artifact storage. No new privileged Memory database or direct plugin access to Core SQLite tables is introduced. Minimal with Memory disabled still starts, manages plugins and inspects canonical history.

## Canonical events, projections and checkpoints

- Preserve the original user/assistant/tool events and durable operation/receipt facts using existing canonical ownership. Event payloads and provider-native blocks can be referenced through separately governed artifacts; store stable IDs, provenance and controlled references rather than forcing everything into a text-only role/message model.
- A **context projection** is replaceable, model-specific input; it is not the fact source. The manifest continues to bind input content, source revisions, exact visible tool definitions, selected contributions, model capability profile, output reserve and budget. Its committed provenance must also bind the permission/erasure visibility generation used at materialization so a delayed dispatch can detect revocation without editing frozen input.
- A **context checkpoint** is a compact semantic projection bound to a canonical source range/digest and an explicit projection format. It is not the recovery journal of pending external effects. Execution restoration stays with existing durable Run/Operation/Receipt mechanisms.
- Distinguish (a) portable semantic summary and verified task state, (b) optional provider-native opaque continuation/cached items and (c) model-specific rendered request layout. A change of provider must be able to rebuild (c) from (a) if target capabilities permit; (b) is neither required nor assumed transferable.
- Do not remove source-digest/legal-cut/tool-pair verification. Split compatibility by **semantic representation version** and **wire/protocol layout**, rather than weakening the current source binding. Provider-incompatible native state stays preserved for history but is omitted from portable input.
- Existing Checkpoint/Manifest stores, #39 revision and cacheEpoch and #44 Attempt counting are reused. No global forkable mutable ContextPlan database is needed. Decision traces and retrieval indexes are derived, scoped caches.
- Recover by **reconciling accepted obligations and uncertain effects, validating current environment, rebuilding portable context, then replanning**. Planned but unaccepted future actions are advisory; accepted pending operations cannot be silently dropped or retried when their external outcome is unknown.
- Forks share authorized immutable historical prefixes, but not mutable planner state, plugin process state, activation queues or granted authority. Previously accepted external effects are not reversed by forking.

A model switch is **not** a session fork or an automatic compaction. It only causes new capability/budget validation and a portable or native context projection at the next legal boundary. A target that cannot represent mandatory content or a required modality must return an explicit incompatibility rather than a success-shaped lossy drop.

## Hybrid Context Planner

The host-owned coordinator invokes the planner at a legal pre-Attempt boundary; the planner never edits an in-flight/claimed Attempt. Planning follows:

1. Freeze branch/lane event cursor and context revision, relevant knowledge revision, permission/erasure generation, content/resource witnesses, selected provider/model capability snapshot, plugin generation and finite budgets.
2. Build **Required** items from authoritative intent, active user constraints, unfinished canonical obligations and applicable protocol invariants. Classify other eligible facts as **Retrievable** (must remain locatable) or **Optional**.
3. Collect candidates from canonical history, knowledge, approved Context/Resource providers, indexed artifacts and optional event activation hints. Structured queries serve IDs, revisions, obligations and scopes; keyword/vector/semantic matching is a pluggable choice, not a universal requirement.
4. Respect an **index watermark** per authorized source/scope. Include or directly process the unindexed delta up to the frozen cursor. Missing/updating indexes cannot cause the latest mandatory facts to disappear.
5. Deduplicate by stable identity and source revision; rank by task relevance, information gain, credibility, recency, applicability, diversity and token/latency cost. Avoid treating semantic similarity as permission or factual verification.
6. Select/compact under a separately bounded planning budget (retrieval rounds, candidate count, auxiliary-model tokens, time and final prompt tokens). Compaction returns a source-linked transform proposal, not an overwrite of original events.
7. Recheck source revisions, policy scope, revocation/erasure barriers, provider compatibility and final token accounting before the existing ContextCompiler seals the ModelContextManifest. Bind the checked permission/erasure generation and outbound source lineage to its immutable provenance/Attempt binding; sealing alone does **not** authorize a later outbound dispatch. If Required content cannot fit in any valid supported representation, fail explicitly; never silently drop it.

Optional failures can be diagnosed and omitted only when the configured policy and Required invariants permit. A configured mandatory policy's absence is an explicit error; no hidden Host algorithm replaces a selected plugin. Auxiliary LLM calls go through a real counted host Attempt and cancellation path, not direct plugin HTTP.

Minimal logical interfaces (illustrative; not prescribed SDK signatures):

~~~text
PlanRequest {
  thread_lane, event_cursor, context_revision, capability_snapshot,
  effective_access_scope, requirements, input_token_budget, planning_budget
}
ContextCandidate {
  stable_ref, source_revision, source_range, trust, applicability,
  evidence_refs, content_or_artifact_ref, estimated_cost
}
ContextPlan {
  selected_refs, transformations, omissions_with_reasons,
  frozen_source_revisions, estimated_tokens, decision_trace_ref
}
~~~

The final input is still the **existing canonical ModelContextManifest**, never a new ContextPlan authority. A plan's selection trace is a bounded diagnostic projection; it cannot by itself approve access or prove provider cache hits.

### Dispatch-time visibility fence (host-owned)

A manifest can be valid when sealed but stale when the outbound model or plugin request is **actually dispatched**. This is a separate time-of-check/time-of-use boundary, not another context revision authority:

1. Freeze the permission/erasure visibility generation and the references or lineage required to identify outbound content in the sealed manifest and the canonical Attempt/dispatch binding. Do not accept plugin-provided generations as authority; a model retry keeps its frozen semantic input, but must still pass the **current** access/erasure check before any new dispatch.
2. Route each egress of content derived from a planned context through the **existing trusted host-controlled dispatch/transport admission**: model-provider HTTP body/upload (including auxiliary compaction/embedding requests), plugin IPC or resource delivery, and retries/resumes. A queued request does not inherit perpetual authorization from a previously valid manifest or claimed Attempt.
3. Immediately before the first externally visible byte or frame, compare the pinned generation and affected source lineage against the current permissions and erasure barrier. Synchronize egress admission with barrier publication so a revocation committed first cannot race with a later transport enqueue/write. Any transport queue must discard still-unsent frames that become stale; do not treat a one-time check at planning, materialization, Attempt claim or queue insertion as sufficient.
4. For chunked or streaming outbound content, validate at each subsequently issued frame/transport write or use a host-controlled, equivalently fenced channel. Revocation closes/cancels subsequent egress, including queued chunks. This must not hold a database transaction or an unbounded lock across network I/O, and must reuse #45 broker, cancellation, IPC and #44 Attempt accounting rather than introducing a second dispatch mechanism.
5. On stale generation or withdrawn resource access, **send nothing further**, release untransmitted buffers/leases, record the real Attempt/operation cancellation or blocked state, and replan only at a legal new Attempt boundary. Do not mutate the original immutable request, silently continue via a different provider, or retry a potentially effective operation. The host must not assume revocation can retract bytes already admitted to the transport/remote peer **before** the barrier took effect; those external-copy limits remain explicitly observable and documented.

P1 (#53) adds the binding and universal pre-dispatch validation seam using existing permission/revocation state. P4 (#56) adds the full erasure barrier, lineage-wide invalidation and race/recovery tests. This contract applies even while P4 storage deletion remains unimplemented: queued data must not leak after ordinary permission revocation.

## Versioned knowledge, ingestion and activation

A Knowledge Unit is a bounded logical record, not necessarily a (subject, predicate, object) triple. Minimum semantics:

~~~text
KnowledgeUnit {
  id, revision, kind, statement, optional_structured_payload,
  scope, applicability, epistemic_status, lifecycle,
  evidence_refs, related_revision_refs, source_generation
}
KnowledgeProposal {
  origin: agent | runtime | explicit_user,
  operation: create | revise | invalidate | propose_erasure,
  candidate, evidence_refs, expected_revision, requested_scope
}
ActivationHint {
  trigger_event_ref, knowledge_id_and_revision, branch_lane,
  match_reason, relevance_not_confidence, valid_until, dedupe_key
}
~~~

- Kind may express fact, constraint, decision, hypothesis, procedure or preference. Epistemic status (observed/asserted/inferred) and validation evidence are distinct; repetition or compression never upgrades an inference into a verified fact.
- Task/branch/session/user/project/agent scope and resource/version applicability are distinct. Shared project/user knowledge requires **explicit host-authorized cross-thread namespace and access checks**. Existing thread-scoped plugin document rights cannot be treated as an implicit sharing grant.
- The Memory policy proposes structured writes and conflict/merge outcomes. Governance checks origin, scope, access, evidence, duplicate/contradictory revisions, lifecycle and CAS before the host-controlled storage mutation. User-explicit controls have their own provenance; plugin content cannot masquerade as an operator rule.
- The knowledge core is **fact-based**. Bundles/documents, full-text/embedding and relation/graph indexes are optional derived views with repairable watermarks; no graph DB is required in the first implementation. Updating a decision must not discard its reason and related evidence.
- A typed, bounded observer may match TaskStarted/ToolFailed/ProjectChanged/CapabilityChanged etc. against active knowledge and enqueue ActivationHints. Activation is only candidate nomination for the **next** Context Plan. It cannot change the current Attempt, interrupt a running operation, promote untrusted text to system policy or autonomously execute tools.
- Hints require scope/version/expiry checks, event+knowledge-version deduplication, cooldown, batching and finite semantic-match cost. Hints themselves must not trigger another identical activation. Forked agents have separate queues; removal/erasure suppresses hints in all affected scopes.
- Runtime extraction is event-triggered/phase-batched, not a required second LLM call on every message. Keep temporary plans and low-confidence guesses out of durable shared memory unless explicitly proposed and governed.

## Invalidation, true erasure and provenance

Three operations must have different externally documented semantics:

- **Invalidate / supersede / expire:** append a new revision or relation; retain permitted original historical evidence for audit and historical validity.
- **Revoke:** deny future authorized use (including cached/indexed use) under the current permission generation; separate authorization from whether content is physically present.
- **Forget / erase:** authorized deletion of selected original content and controllable derivatives. A MemoryStatus.Deleted tombstone by itself does **not** satisfy this contract.

A host-owned erasure coordinator implements: authorize and scope target → install a visibility/deletion barrier **before** new reads and derivations → compute lineage reachability → purge or conservatively invalidate affected blobs, knowledge units, embeddings, summaries, checkpoints, caches, indexes, forks and activation queues → rebuild permitted derivatives → verify and retain only non-reconstructive receipts.

Lineage refers to source IDs, revision, transformation version and downstream artifact references. When exact selective subtraction is impossible, invalidate the entire derivative and rebuild from surviving sources. **An output/commit-time check alone is insufficient:** queued model/plugin requests may already contain materialized sensitive bytes. Apply the dispatch-time visibility fence above before any newly issued external frame and recheck in-flight streams at subsequent egress boundaries, in addition to checking derivation/output/commit. Restores and reindexing must reapply the barrier (**no resurrection**). If a minimum redacted event marker is retained, it must not leak deleted content through metadata, hashes, human-readable reason or references.

Backups, exports, remote providers and physical erasure have separate retention/feasibility guarantees. Never promise instant deletion of immutable backups or previously transmitted remote-provider material; state the enforceable boundary and available provider-specific deletion procedure. The feature is incomplete until those limits are documented and tested.

Before the true-erasure feature ships, the existing Memory tool's forget alias must be described as tombstoning/invalidation or changed to reject unsupported true-erasure requests; do not claim content erasure on the strength of a Deleted status.

## Independent evaluation and observability

Evaluation is a test/diagnostic consumer, not a production mutation authority or another Agent loop.

- **Hard CI assertions:** no missing Required constraints, no fabricated/duplicated pending Operation, canonical call/result validity, permission and lane isolation, legal-cut/source digest, pre-dispatch erasure/revocation generation validation with zero newly issued bytes after barrier publication, no deleted-data resurrection, frozen Attempt/tool version and explicit incompatible-model rejection.
- **Ground-truth semantic fixtures:** fact/evidence recall and precision, decisions-vs-hypotheses classification, model-switch task continuity, summary drift across repeated compaction and key resource applicability.
- **Comparative task metrics:** task completion and recovery quality versus baseline, input/output/auxiliary token use, cache observations only when provider reports them, P50/P95 planner latency, activation usefulness, index lag and storage costs.
- Deterministic fixtures/recorded provider events run in normal CI; real-provider evaluations are sampled separately with disclosed model/version/date/budget and statistical tolerance. No self-evaluation by the same summarizer as the only quality proof.
- A ContextDecisionTrace records included/omitted references, reasons, transform provenance, model capability/selection, budgets and version/watermark diagnostics. Logs must honor scope, secret redaction and erasure rules; a trace is not a raw unbounded prompt archive.

At minimum exercise: Claude→GPT→Claude after compaction; legal resume with unknown external side effect; cross-thread project retrieval without privilege leak; index watermark lag; simultaneous fork activation and knowledge correction; plugin deactivation during planning; permission revocation before materialization **and after manifest seal but before queued external dispatch**; erasure during a chunked plugin/model outbound stream; erase→restore/reindex/fork without resurrection; incompatible modality; and Required content over the target window. Stubbed model tests cannot substitute for the real process/SQLite/plugin boundaries when those are part of the claim.

## Phased follow-up work (outside #45 migration scope)

| Phase | Deliverable | Prerequisites / overlap rule |
| --- | --- | --- |
| **[P1 #53](https://github.com/lIlIIlIll/Axyndra/issues/53) — Portable Context Planner and model handoff** | Unified selection/constraint/retrieval contract, permission/revocation-generation binding and pre-dispatch fence, decision trace, provider-neutral semantic checkpoint projection and model-switch acceptance | Reuse #39 revisions + existing ContextCompiler/Manifest; integrate #45 A5/A6 contribution contracts after their necessary interfaces stabilize. No new context authority or migration of existing Compaction business code |
| **[P2 #54](https://github.com/lIlIIlIll/Axyndra/issues/54) — Knowledge units and governed memory** | Evidence-linked versioned Knowledge Unit, Agent + Runtime proposals, CAS/validity/conflict, cross-thread sharing with host authorization; document/graph projections optional | P1 source/reference contract, #45 Memory plugin and storage boundary. No second canonical Thread store, vector DB requirement or duplicate plugin manager |
| **[P3 #55](https://github.com/lIlIIlIll/Axyndra/issues/55) — Hybrid indexing and event activation** | Per-scope watermarks, incremental-delta reconciliation, bounded active retrieval and activation hints, cooldown/deduplication | P1 planner + P2 knowledge; reuse #46 typed event observer and #39 legal context update. No autonomous listener that reruns the Agent |
| **[P4 #56](https://github.com/lIlIIlIll/Axyndra/issues/56) — Erasure and independent evaluation** | Host-controlled deletion propagation/barriers, pre-dispatch erasure fencing + no-resurrection/race matrix; deterministic/semantic/cross-model evaluation suite | Needs P1 selection/provenance and P2 lineage; P3 integration cases may land after P3. Keep deletion metadata/refs in P1/P2 from the start. No expectation of deleting remote model state or reproducing nondeterministic LLM internals |

Each phase has a separate issue with detailed acceptance criteria and evidence requirements. P1/P2/P3/P4 are **new behavior**, not a redefinition of the already tracked #45 A5 plugin relocation, #46 contribution ABI or #48 product-level plugin ownership. Where a dependency is not yet merged, implement against a stable reviewed contract or defer integration without marking acceptance complete.

## Rollout and failure policy

- This ADR is **proposed**. No code functionality is certified by the design document, and it does not turn #45, #39 or PR #49 complete.
- Start with interfaces and deterministic tests, then use the installed Memory/Compaction policies from the completed migration. Keep one source of canonical execution facts and one legal context update path.
- New plugin/SDK/persistence contracts may break old incompatible formats as allowed by #46/#48. Preserve user data by explicit rejection before destructive writes; never silently reinitialize a store.
- Optional projection/index loss must be recoverable from still-authorized sources. If a required plugin, required source, permission or valid model capability is unavailable, report a typed block/failure rather than fabricating context.
- Security/permissions, dispatch-time generation fencing, disposal, cancellation and unknown side-effect reconciliation are host-owned at all phases. No sealed manifest, frozen Attempt or plugin buffer bypasses later revocation.

## Rejected alternatives

1. **Replace the canonical transcript with a rolling model summary:** loses evidence, pending calls and recoverability; compounds semantic drift.
2. **Make checkpoints exact snapshots of every provider/process/external resource:** imposes infeasible restore/reproduction guarantees and couples sessions to one provider.
3. **Let Memory or a planner plugin commit final prompts, run tools or own the Thread DB:** violates #39 and the single-host authority in #45/#46.
4. **Run a fully autonomous nested planning Agent for every event:** adds hidden model attempts, latency and recursion, breaking budget/accounting invariants.
5. **Require a vector store/knowledge graph from day one:** duplicates indexes and couples semantics to one retrieval implementation.
6. **Treat Deleted tombstones as physical forgetting:** allows old payloads and derived indexes to resurrect data.

## Consequences

Positive: sessions are model-portable at the semantic/operation level; compaction is source-linked and replaceable; shared knowledge is inspectable, governed and testable; and first-party Memory remains removable without removing host authority.

Costs: scope-aware reference/lineage metadata, delta/index-watermark reconciliation, portable checkpoint compatibility checks and real deletion/quality fixtures require careful implementation. Those costs are deliberately staged outside the unfinished plugin-first migration.
