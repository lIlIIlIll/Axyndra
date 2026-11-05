# Plan execution reliability

> Integration in progress: the current integration preview is based on
> `1866d4c1557558b2a3df70b2b256428a74651959`. The validation results below
> describe the earlier implementation on `364bcec9`; they do not validate this
> new integration. All affected requirements must pass again before complete acceptance.
> Current integration results are recorded separately below. Schema v29 preserves
> the new base's v25-v28 migrations and adds plan state.

This record tracks the approved seven-part reliability change. Operation receipts
remain the execution facts. Step decisions reference those facts without
replacing authorization, cancellation, or recovery checks.

## Requirements and evidence

Overall completion is **not fully complete**. The matrix records current focused
verification; full integration acceptance remains open. Earlier-base evidence is
retained in its separate evidence section. The user selected the reviewed yjson
tag; object verification
confirmed that both lock representations identify the same source. No requirement
was removed.

| ID | Requirement | Required | Observable acceptance | Implementation and product entry | Verification and actual result | Applicable revision | Status | Remaining gap |
|---|---|---|---|---|---|---|---|---|
| PE-1 | Enforce approved steps, budgets and fallback | Yes | Known dependency failure selects the approved CDN alternative; independent source work and Node tests continue; stale evidence, exhausted budgets and unknown effects prevent completion | `agent_domain/src/plan_execution.cj`, `agent_store/src/plan_execution_store.cj`, `agent_core/src/plan_supervision.cj`, plan review and approval in `agent_product/src/application.cj` | Actual seven-process plan contract 95 PASS; Thread Runtime Integration contract in 91 PASS | Integrated source manifests for attempts 85, 95, 97 and 98; see exact source identities below | Implemented; partial verification | Full Product/App unit acceptance and the original implementation gate remain open |
| PE-2 | Separate command, tool and task failure | Yes | Trusted status distinguishes target start, exit 124, runtime timeout and incomplete receipts without parsing target stdout; unsafe effects require recovery | `agent_product/src/command_probe.cj`, process adapters, `libs/process4cj/native/process4cj_native.c`, canonical error fields in `tool_runtime` | Actual CommandProbe 98: 16/16 PASS; native probe 88: 6/6 PASS; unknown-effect and process scenarios 95 PASS | Integrated source manifests for attempts 85, 95, 97 and 98; see exact source identities below | Implemented; partial verification | Full Product units crashed; the independent baseline Pi/Native derived bridge fails contract 96 |
| PE-3 | Diagnose gateway initialization | Yes | Helper missing/invalid, launch failure, early exit and readiness timeout carry typed stages and bounded redacted diagnostics; no host fallback | `agent_product/src/network_gateway.cj`, process isolation acquisition | Actual CommandProbe 98: gateway typed diagnostics, launch/deadline cleanup and receipt tests PASS | Integrated source manifests for attempts 85, 95, 97 and 98; see exact source identities below | Implemented; partial verification | Original full integration gate remains open; no live external gateway/provider claim |
| PE-4 | Trace network authorization | Yes | Requested mode, authorization and applied isolation remain tied to the canonical Operation; failed network paths cannot grant HostNetwork | Existing approval/Operation chain, controlled probe admission, native sandbox and explicit descriptor passing | Actual authorization, controlled scope and network tests 98 PASS; Native refusal and process scope scenarios 95 PASS | Integrated source manifests for attempts 85, 95, 97 and 98; see exact source identities below | Implemented; partial verification | Original full integration acceptance remains open |
| PE-5 | Check plan consistency and executable assumptions | Yes | Invalid structures are rejected; review advisories identify units/lifecycle risks; actual executable fixture tests verify nonzero turns, group laws, integer units and generation cancellation | Contract parser, plan review advisories, normal admitted executable verification | Actual context/advisory suite 97 PASS; canonical hash/edit/confirmation suite 85 PASS; actual Node fixtures in 95 PASS | Integrated source manifests for attempts 85, 95, 97 and 98; see exact source identities below | Implemented; partial verification | Advisories are bounded checks, not arbitrary mathematical proof; full integration gate remains open |
| PE-6 | Select context by approved task scope | Yes | Undeclared repository instructions are excluded; symlink paths cannot widen scope; request tool subsets preserve the frozen full catalog | Scoped prompt/manifest selection, `TaskContextScope`, per-request tool view, read-only plan revision | Actual task-context suite 97: 7/7 PASS; Host suite 82: 268/268 PASS; plan tool suite 97: 6/6 PASS | Integrated source manifests for attempts 85, 95, 97 and 98; see exact source identities below | Implemented; partial verification | Full Product/App unit and original integration gate acceptance remain open |
| PE-7 | Explain progress, retries and blockers | Yes | Durable inspection exposes decisions, remaining attempts, recovery state and receipt references after restart, while redacting arguments and paths | Durable step projection, continuation facts, typed and rendered `/inspect` | Actual approved-plan contract 95 PASS; Store 256-case run 71 and durable contracts 60 retained with source identities | Integrated source manifests for attempts 85, 95, 97 and 98; see exact source identities below | Implemented; partial verification | Full integration gate remains open; diagnostic Store runtime 60 exceeded the original 180-second limit |

## Execution boundaries

- Attempts count controlled action dispatches, including shared child work. They
  do not count unobservable requests inside a remote service.
- Supervised shell tools cannot obtain networking. Network probes require an
  approved command specification and normal capability and approval checks.
- Tools without a trusted execution contract fail closed. A tool name or a
  model-supplied step ID does not establish trust.
- Historical conversations are retained. A text-only plan cannot enter the new
  supervised execution flow; record and review a structured contract first.
- A Run ending does not prove plan completion. Required evidence must be current;
  pending actions or unknown effects prevent sealing, including optional work.
- Child tasks share budgets and immutable delegated action subsets. Supervised
  tasks and shell processes finish their owned work before reporting completion.

## Current integration evidence

The integration starts at `1866d4c1557558b2a3df70b2b256428a74651959`.
The original working tree remains unchanged. Filenames below are relative to
private `<integration-evidence>`. Each runner records the actual transitive source
hashes before and after execution. Focused checks and the original gate are
reported separately. No timeout, permission, quota or assertion has been relaxed.

| Check | Actual result | Evidence and limits |
| --- | --- | --- |
| Product approved-plan flow | PASS, all seven separate real processes joined | `contracts-product-final-69-summary.json`, `contract-product_contract-product-final-69.log`; includes dependency fallback, real source writes and Node tests, budgets, unknown effects, revision, controlled processes, Native refusal and request custody |
| Child continuation | PASS, complete contract | `contracts-thread-review-66-summary.json`; positive child work and strict depth fault use separate real processes |
| Six complete unit packages | PASS, no skipped cases | `units-final-units-59-summary.json`: Tool 64, Core 46, fixture 8, Runtime 31, Domain 178 and Store 256 |
| Actual Task distinct-wait copying barrier | PASS, 1 selected case | `units-host-custody-54-summary.json`; the raw outer reader survives the internal projection callback and must prevent premature return |
| Actual temporary-directory ownership and cleanup | PASS, 3 selected cases | `units-host-temp-55-summary.json`; uses the same unchanged Host dependency closure as the preceding barrier run |
| Session mapping presence | PASS, 2 actual SQLite cases | `units-presence-57-summary.json`; also included in the full 256-case Store run. Existing or damaged mappings cannot enter the no-payer compatibility branch |
| Core, Tool, SQLite and Store contracts | PASS, complete contracts | `contracts-final-contracts-60-summary.json`; Store ran for 183.77 seconds under the diagnostic runner. This exceeds the original gate's 180-second limit and is not original-gate acceptance |
| Native process probe | PASS, 6/6 | `native-probe.log`, `native-source-evidence-final.json`; native source is unchanged |
| Host task context, Product context and command probes | PASS, selected checks | `units-real-final-focused-summary.json`, `units-real-host-task-scope-final.log`; these precede the final review-session change. Final full Product unit acceptance remains pending |
| Workflow protocol | PASS, 172/172 in one full run | `workflow-protocol-38-summary.json`; earlier two 8 MiB deadline failures and their unmodified-base reproduction remain recorded. The pass does not establish a performance fix |
| Application and minimal builds | Both build commands exit 0; final application rebuild pending | `build-final-62-summary.json`; only the resolver lock changed during the application build. The subsequent three-file review-session fix requires another application build |
| Static checks and unit inventory | PASS, 555 unit files in 29 packages | `static-final-65-summary.json` records docs, pin, helper and inventory checks. Its last library command used a nonexistent shell filename; the actual `python3 scripts/check_library_boundaries.py` then passed for 10 libraries |
| Original implementation gate, installed SDK 1.1.3 | FAIL; 24 of 29 unit packages passed | `actual-gate-sts113-71/summary.json`; unchanged source `fb259a445f51ee4dbd7bb66f389455862788edb3da1c5ff68ede37f59d67649f`. Native 6/6 and bundled protocol checks passed. Unit failures prevented later application and contract stages |
| Canonical hash, 3 MiB review and frozen View confirmation | PASS, 4/4 selected cases | `target-product-case-green-85/summary.json`; unchanged source `893274fbf877199b301ab27c3a0d87d44d0519dd846be17fccabe9d1d894ee9a`. Actual complete save, forged confirmation, stale/disabled/malformed event refusal, repeated physical-payment return and full-output hash equivalence, including changed pins |
| App unit package | FAIL; 39 passed, 1 GC-thread SIGSEGV, none skipped | `target-app-units-86/summary.json`; same unchanged source as attempt 85. The queued-input failure case passed; the other plan-review case physically crashed in the installed SDK runtime |
| Same-binary App crash diagnostic | 5/5 selected runs passed; intermittent crash remains unresolved | `target-app-gc-87/summary.json`, `runs.json` and retained `agent_app`. Frozen binary SHA-256 `d425e4b59e25dae6d82825b527b98b3a782953ad9655ff89c83aa04fd5c44cd6`; source unchanged. No rebuild, SDK change or flag change. No core was available; these reruns do not establish a runtime fix |
| RPC original isolated package | PASS, 34/34 | `target-isolated-units-81/summary.json`; unchanged source `b676ddea9044baec9b8c1fe04eb57349cb452bed57e1dbb3b621a4032c286416` |
| Host original isolated package | PASS, 268/268 within the original module budget | `target-isolated-units-82/summary.json`; same unchanged source as RPC. Includes Task scope, Native read-view ownership and distinct-wait return barrier |
| ModelAdapters unit package | PASS, 43/43 | `target-isolated-units-84/summary.json`; same unchanged source as RPC. Attempt 83 used an incorrect private-runner module name and ran no tests; it is not product-failure evidence |

The strict child test reaches the actual depth-1 refusal with two immutable
grants, no child Run or active binding, and no leaf effect. The existing runtime
has already handed off the derived Operation and has no trusted no-effect
receipt, so it correctly retains Unknown and RecoveryRequired. The test checks
the exact unsettled close error, retained payment and history, unchanged receipts
and no replay across repeated close. It does not manufacture a terminal receipt
or a consumer acknowledgement. The positive case still requires normal return.
The separate production depth guard also passed its depth-4 and depth-5 cases.
Five-level real Native execution remains unproved.

Normal cases require the actual new transient Catalog consumers to return.
Historical Task descriptions and the original workflow configuration aliases
remain readable and paid. The conservative Native Shell fault has separate
checks, described below. Global bank totals are not a proof that a specific
Catalog allocation returned.

Earlier failed attempts are retained in their numbered logs. In particular,
Product attempts 56 through 68 exposed fixture setup, receipt-codec and review
visibility problems. Attempt 69 supersedes those Product results. The real
review fix passes the actual session through all three App entry points;
no-session and foreign-session requests still cannot pin the thread-specific
tool, and the actual internal lifecycle control remains excluded.

Attempt 71 exposed mixed build-cache inputs: Host and RPC correctly rejected an
old compiled-input symlink, and ModelAdapters referenced an obsolete zero-argument
symbol while current Domain defined its new signature. The complete old build
tree was preserved; a physical empty build directory replaced it. The freshness
checker and production API were not weakened. The Product fixture also attempted
a legacy cache output outside the isolated writable paths; the private validation
wrapper now redirects those outputs to its own disk-backed child. This changes
no repository source or application permission.

Attempt 80 preserves the original App assertions and adds bounded stage/code
diagnostics. Both failures are `stage=save`, `view.source_changed`; initial plan
creation opens the actual View. It confirms a mismatch between the frozen prose
hash and the normalized saved plan, rather than a tool-discovery failure.

Subsequent SDK 1.1.3 runs exposed a real plan-review allocation regression. Prose
copies and contract JSON now use separate cost recipes. Temporary review work
uses an independent frame in the same original Catalog bank, with the original
floor and aggregate limits; its physical slot returns only after the whole
builder returns. Published output remains paid. Attempt 79 verified that narrow
lifetime but still failed confirmation under repeated public document copies.
The subsequent internal current-identity path revalidates the same contract,
source and tool pins while hashing canonical segments without publishing another
full Raw copy. Its advisory filter actually uses a bounded byte array rather
than the native match-position arrays of repeated `String.replace` calls; the
public review path remains unchanged. User edits are normalized and frozen
before confirmation, then current and candidate identities are rechecked before
the shared append path. Attempt 85 passes the four actual Product regressions.
No pending-field limit, acknowledgement, source contract or original assertion
was relaxed.

Attempts 73 and 74 did not produce a behavioral RED: compilation timed out or was
interrupted. Attempt 75 was also interrupted; the cause of those interruptions
is unknown. Attempt 76 reached an actual test compile error on SDK 1.1.3; the
unsupported collection convenience call was replaced by explicit iteration,
retaining the schema assertions. These attempts are diagnosis, not acceptance.
Product and Child results from attempts 69 and 66 predate the later review
allocation and confirmation changes and require affected-path revalidation.

## Final integrated-source validation and remaining blockers

The latest behavioral runs use installed SDK 1.1.3. Source manifests identify
uncommitted inputs separately from base HEAD. No SDK, compiler flag, runtime
library, test limit, approval or resource quota was changed.

| Requirement or delivery check | Actual result | Evidence and remaining gap |
| --- | --- | --- |
| PE-1/PE-2/PE-4/PE-7 actual approved-plan execution | PASS, all seven independent processes joined | `target-plan-contract-95/summary.json`: dependency fallback, actual source/Node verification, hard budget drain, unknown effects, revision control, scoped processes, Native refusal and request custody. Source `8a5ab514220c118685ba0c0e0933466eef525d8d54b6f2f9e160d808296d47fe` was unchanged |
| PE-2/PE-3/PE-4 CommandProbe | PASS, 16/16 selected cases | `target-product-case-98/summary.json`: actual authorization, package-manager configuration, target exit versus timeout, forged frame refusal, gateway stages/cleanup and controlled process/network scope. Source `84a514a48b90cb6e6a10ba5a88bc95cab2c2dc1f3b42042403304920b0c3e9cd` unchanged |
| PE-5/PE-6 task context | PASS, 7/7 selected cases | `target-product-scopes-97/ProductTaskContextScopeTests/summary.json`: actual context scope, symlinks, frozen tool schemas and advisory limits; same unchanged source as attempt 98 |
| Installed plan-tool product entry | PASS, 6/6 selected cases | `target-product-scopes-97/InstalledPlanToolTests/summary.json`: actual installed Native tool, canonical receipt, no document authority, restricted capabilities and profile drift refusal |
| Review edit, confirmation and allocation | PASS, 4/4 selected cases | Attempt 85 described above. Production review/App source has not changed since that run; later changes affect only the independent Product Thread test fixture and this record |
| Normal application build | PASS | `target-post-units-90/summary.json` records a later packaging refusal, after `cjpm build success`. Actual host SHA-256 `72daaba769efd68a9467d32aef8c9b0ebe1370eaed80014cb2a00be73c411cc0` |
| Relocatable coding candidate, architecture and initial vNext checks | Candidate and architecture PASS; vNext incomplete | `target-post-units-91/summary.json`, `evidence/candidate-path.txt` and `evidence/vnext-contract-summary.json`. Core, ModelAdapters, Tool, Thread Runtime and Thread Runtime Integration contracts passed before the Product Thread failure |
| Candidate setup and clean environment | PASS | `target-candidate-blackboxes-short-93/stages.json`; same actual candidate and unchanged source. Private short paths are backed by this task's disk directory; real user state stays read-only |
| Candidate provider profiles, entry modes and ACP | FAIL under their original timeouts | Same attempt 93: profile 5 seconds, entry invocation 10 seconds and ACP frame/shutdown deadlines. No deadline was increased. Earlier attempt 92 had long socket paths and read-only default user state; the short private-path rerun resolves those setup errors but still times out |
| Original implementation gate | FAIL before main unit execution | `actual-gate-sts113-88/summary.json`: the independently rebuilt latest-context Memory fixture exceeded the original 900-second outer preparation limit. Its inner 138-case log later reports no assertion failures, but preparation did not finish with its required protocol evidence. This is not a passing fixture or full gate |
| Full Product unit package | FAIL; 25 passed, 1 physical child crash, 1042 unrun | `target-product-case-89/summary.json`: `actualCoreCompletedCheckpointAndRewindCannotAccumulateEmptyExecutionCells173b` crashed in the SDK GC thread. The App crash and unchanged-binary diagnostic remain recorded above. Their present root cause is unconfirmed |
| Full Product Thread contract | FAIL; not accepted | `target-product-thread-contract-96/summary.json`: real exec service fails `operation.derived_parent_invalid`; no child admission is manufactured |

Attempt 97 first exhausted the original Product compilation limit for the
CommandProbe selection; it did not run those cases. The later context and plan
tool selections completed compilation and execution. Attempt 98 then ran all
16 original CommandProbe cases. The initial timeout remains recorded; this is
not a claim that compilation performance was fixed.

The Product Thread fixture initially combined a global signature verifier with
unsigned ordinary Native dependencies. The corrected fixture keeps all 226
original assertions: independent signed-package validation, actual approval,
process execution, one Receipt and disable checks run in a complete separate
verifier-configured Product lifecycle. Ordinary unsigned scenarios retain their
existing default policy. Acquisition and direct signature rejection cases remain
unchanged. No production verifier or trust guarantee was relaxed.

That correction exposes a separate baseline bridge gap. The formal Pi exec route
selects the actual Native readonly contribution, but the durable derived-pair
predicate still recognizes the retired `bash_readonly`/host-only shape. Native
readonly-to-Host ancestry also requires a typed root proof absent from an
ordinary Pi root. Comparing immutable base `1866d4c1` confirms these predicates
and the relevant routing sources predate this integration; no baseline-binary
matrix was run. A safe fix needs an explicit bridge proof covering both edges,
using the real frozen Native target, pins, same-Run snapshot and capability
intersection. A string replacement or fabricated epoch/Receipt cannot satisfy
that contract. This additional architecture work requires a scope decision.

Attempt 94 selected Product Thread rather than `product_contract`; it reproduced
the original activation refusal and produced no plan-execution evidence. The
corrected actual target in attempt 95 passes all seven plan scenarios. Both
records are retained.

Overall status remains **not fully complete**. This record accompanies a local
integration checkpoint; it does not establish acceptance. No push, PR, release
or Issue closure is part of this checkpoint. Full Product/App acceptance, original Memory fixture
preparation, the durable Pi/Native bridge and timed packaged entry points remain
open. Later release/performance gates were not reached and are not passing by
inference. The focused passes above neither repair the GC crashes nor replace
those missing acceptance results.

## Earlier-base validation record

Earlier evidence is retained in the private `<earlier-evidence>` directory.
Paths in this section are relative to that directory. The final source identity is recorded in
`final-source-manifest.json`; the base commit is
`364bcec9cea1648cf0419e255ab6fadbc51ec65b` plus the uncommitted working tree.
Existing changes from another session were preserved. No commit, push, PR or
release was performed.

Builds use the frozen installed Linux x86_64 SDK, compiler
`1.3.0-alpha.20261028001050 (cjnative)` through `scripts/pinned_cangjie`.
`sdk-version-final.log` records its identity. No SDK was built.

| Command or scenario | Result | Evidence |
|---|---|---|
| `bash scripts/implementation_gate.sh` | FAIL at existing dependency pin gate; native 6/6, all 19 unit packages (308/308), application build and relocatable candidate creation passed before that failure | `implementation-gate-final.log`, `implementation-gate-final/unit-tests/summary.json`, `implementation-gate-final/candidate-path.txt` |
| Product contract executable, full scope | PASS, including actual process lifecycle, approval restoration, child authority and archive/reset | `integration-product_contract-view-21.log` |
| Product contract with `AXYNDRA_PRODUCT_CONTRACT_SCOPE=plan-execution` | PASS, including actual narrow-root BashTool, real Node tests, CDN fallback fixture, unknown mutation, plan revision, inspection and sealed completion | `integration-product_contract-view-21-plan-execution.log` |
| Product continuation and SQLite Run contracts | PASS, including nested inline supervised children, shared attempts and both approved continuation binding transitions | `integration-view-21-summary.json`, `integration-sqlite_run_repository_contract-view-20.log` |
| Focused domain, store, core, tool and vNext contracts | PASS; latest result supersedes failed intermediate attempts | `focused-view-13-summary.json`, `integration-view-16-summary.json`, `integration-view-18-summary.json`, `integration-view-19-summary.json`, `integration-view-22-summary.json`, `integration-view-23-summary.json` |
| Packaged candidate setup, clean environment, provider profiles, entry modes and ACP blackboxes | PASS, using the candidate built by the final gate | `final-blackbox-summary.json` |
| Tracked artifact, documentation and workspace graph checks | PASS before the dependency failure | `implementation-gate-final.log` |

Support contracts ran from a temporary coherent validation view: each copied test
used the current root lock and live workspace package sources. Original root and
support locks were not rewritten. These results do **not** constitute a pass of
the original pinned gate. Summary files retain intermediate failures; use the
latest per-contract successful log, not an aggregate claim that every attempt
passed.

Three integration defects were fixed and verified: bulk preparation denial now
settles every unstarted canonical Operation; continuation bindings preserve and
compare trusted plan-review/context facts; archive/reset removes plan references
after taking the archive and before deleting underlying threads. The reset
regression verifies retained archive history, cleared active tables and continued
product use.

Two incorrect test assumptions were corrected without relaxing production
limits. The positive checkpoint fixture allowed only 12,000 tokens for fixed
tools costing 12,040; it now provides bounded room for those tools and a retained
checkpoint while preserving negative budget cases. The npm loopback fixture
published its readiness filename before its port content was complete; it now
atomically publishes the completed file. The product Thread Runtime contract
then passed (`integration-view-23-summary.json`).

Earlier failed pinned-directory procfs access and npm configuration checks were
implementation failures. Explicit descriptor passing and controlled npm
configuration fixed them; final native/product checks above supersede those
failed intermediate results.

## Scope return and retained legacy metadata

The installed workflow package mounts ordinary document tools as well as the
new plan tool. Its original Host contract conservatively retains document
configuration aliases after resource closure. Those aliases keep their original
Registry payment. This implementation preserves that contract.

The six normal Product scenarios check the new lifetimes separately: actual
request and transient consumer frames must return, and Catalog publication, Host/Core source
frames, pending metadata and active executions must be empty with no raw Catalog
export. A retained Catalog must identify its actual original legacy-alias
refusal and still hold that producer's payment. A generic `retire=false` or a
completed Run is insufficient. Historical Task headers retain their own payment
while ordinary callers can still read them.

Plan review carries the actual Application session into its paid tool-identity
projection. The optional SDK `sessionId` argument defaults to the original global
view; it does not expose tools scoped to another session. Host-only and control
tools remain excluded. Reviewing a visible implementation does not grant that
implementation a trusted supervised execution contract.

The Native Shell refusal is a separate conservative fault case. Before any
supervised model request, its real service startup already uses the original
public Catalog publication APIs. Looking up its generic, unclosed resolver also
retains the original conservative DATA guard. The test consumes the actual paid
failure caller and requires a canonical `tool.hook_denied` rejection whose
complete typed message is
`preparation read did not complete: plan.tool_contract_required`. It also checks
a non-running Run, zero execution handoffs, no file effect and an incomplete
plan. Resource close must succeed while Catalog DATA stays unretired and
aggregate Native DATA charges remain positive. Startup totals include OS and
transient owners that should return at close, so the final amount may decrease.
A positive aggregate does not identify an individual surviving allocation or
prove that all source aliases returned. Normal return and workflow-alias checks
remain separate.

An earlier regression incorrectly required the whole Catalog and Native bank
to return despite those original aliases. The corrected checks retain the real
scope and caller-acknowledgement assertions. The seven new Product scenarios use
separate real process lifetimes, each with its unchanged original quota. Both
output readers join, and the process is waited and closed. No bank is reset to
run the next scenario. The seven-process Product checks pass in attempt 69.
The child checks pass in attempt 66.

## Dependency identity and remaining validation

The user selected the integration base's reviewed yjson object
`c91859feb77aeba392a1fad0f99d731df66be831`. Git object inspection established that
this is the annotated tag `0.1.0`, whose target is commit
`54b4965dee0f0b96710cbc678ec5ec9a126b055c`. The tag object's content hash was checked
before accepting that relationship. These identifiers do not represent different
source versions. The initial diagnosis of a dependency-version conflict was
incorrect; `reviewed-dependency-object-proof.json` retains the corrected evidence.

Tracked locks use format 0 with the peeled yjson commit. Each package keeps its
own dependency graph. The workspace root lock includes yjson, yjson_macros and
llm4cj. The pin gate accepts only the reviewed tag object or its peeled commit in
format 0. Format 1 requires the complete source URL, the original tag query and
the peeled commit. Changed URLs, queries, tags and unknown lock versions fail.
The llm4cj reviewed commit remains unchanged. No dependency upgrade was made.

A minimal consumer called `JsonNode.parse` and checked its integer result using
the same source, URL/tag manifest and initial format-0 peeled lock on both SDKs:

| Installed toolchain | Compile and run | Lock after build |
| --- | --- | --- |
| Cangjie compiler and cjpm 1.1.3 | PASS, both exit 0 and print `YJSON_PARSE_OK` | Format 0, byte-for-byte unchanged |
| Compiler 1.3.0-alpha.20261028001050 and cjpm 1.3.0-alpha.08 | PASS, both exit 0 and print `YJSON_PARSE_OK` | Automatically migrated to format 1 with the same peeled source |

`reviewed-lock-sdk-matrix-96w24k1m/summary.json` records toolchain binary hashes,
source and manifest hashes, command exit codes and both lock snapshots. Each
build used a separate private cache checked out from the reviewed Git objects.
No compiled dependency artifacts were copied, and the shared cache was mounted
read-only. The format-1 resolver removed the unused macro entry for this build.
This matrix proves the minimal consumer and lock transition. The focused unit
and contract runs above also use the clean reviewed dependency sources. The
original implementation gate remains pending. Ten dependency
pin helper tests and the actual pin gate pass after the lock update.

The Product and child focused contracts pass. The final application rebuild and
original implementation gate remain required. The full workflow protocol passed
once without changing its original deadlines; earlier deadline failures remain
part of the evidence rather than accepted environment exceptions.
No hosted CI, live model provider, browser/CDN loading, cross-platform or release
verification is claimed. The deterministic timeout/CDN fixture proves task
fallback behavior, not external network availability or a production cube app.

Overall task status: **not fully complete** until final build and original-gate
acceptance complete. No unmet requirement has been moved out of scope.

## Upgrade and recovery

Back up the state database and referenced artifact blobs before upgrading.
Migration v29 preserves migrations v25-v28, retains historical records and binds new approved contracts
independently of conversation context. Historical text-only plans require a new
structured review; they do not acquire execution authority from import or replay.
Unknown effects require recovery, not automatic retries.

To roll back, stop the product and restore the matching executable, native
libraries, database and blob backup together. Do not run an older executable
against a v29 database or a newer active contract. An explicit archive/reset
preserves the archived plan history and then clears its active references.

The deterministic fixture adapter now exposes `lastRequest` as a read-only property.
Closed scalar observation uses `withLastRequest159`; raw exports retain their own
paid snapshots. Repository callers do not assign to the former public field.

Final commit preparation removes one extra trailing empty line from each of
`plan_supervision.cj`, `run_inspection.cj` and `operation_parent_intent204.cj`.
No executable token or dependency-lock byte changes. The behavioral results
above remain tied to their recorded inputs; tests were not rerun for this
whitespace-only cleanup and record update.

## GC, timeout and readonly bridge follow-up

The approved follow-up raises the minimum SDK to compiler
`1.3.0-alpha.20261104001050`, CJPM `1.3.0-alpha.09` and its matching stdx.
This is a support migration, not a claim that SDK 1.1.3 was repaired.
Runtime startup deadlines, permission boundaries, canonical evidence and
144 MiB aggregate accounting remain acceptance requirements.

| ID | Required observable result | Implementation and evidence | Status | Remaining work |
| --- | --- | --- | --- | --- |
| GF1 | Rebuilt pinned toolchain has no observed GC crash in repeated cases and complete Product/App runs | Verified official archives; fresh Product and App artifacts still crash in GC | Deferred by operator; not accepted | Official SDK stays fixed. GC repair and crash-free acceptance remain incomplete |
| GF2 | Complete Memory fixture fits composed budgets; cancellation reaps nested sessions | 138/138 Native units, 40/40 protocol cases, 1010.16 s; four process-budget regressions | Accepted for this fixture | Full workspace/release acceptance is separate |
| GF3 | Control requests respond before unrelated plugins start; model Runs freeze the full required ready Catalog | Owner readiness coordinator and actual preparation before model/command execution | Partial; metadata startup and physical retirement accepted | Model preparation, provider, read and ACP acceptance remains incomplete |
| GF4 | Real Pi and Native roots execute the exact readonly plugin and Host ReadView through a canonical three-node tree | Four independent real entries pass; 11 selection-field corruptions reject; four Direct Native fault/budget cases pass | Focused and compound contracts accepted; full lifecycle partial | Disable, cancellation and restart matrix remains unverified |
| GF5 | Final candidate, full original gates and latest-commit CI agree | Final production build and fresh nine-plugin Coding package pass; Store 256/256, App 38/40 | Not accepted | Original blackboxes and GC acceptance fail; complete Product/release gates and hosted CI are not green |

### Follow-up implementation checkpoint

GF1 now uses SHA-256-verified official SDK and stdx archives. The SDK check
accepts the independent pinned compiler and CJPM versions and rejects SDK
1.1.3 by default. The first real application build on the new SDK passed.
Its result predates the final readiness integration tests and is not final
acceptance. All 116 tracked locks retain their original dependency entry
sets in format 1, including the root llm4cj and macro closure.

GF2 now composes the Memory build/unit/protocol execution budgets
(900/900/240 seconds) plus a 60-second metadata allowance. The dedicated
watcher bounds physical cleanup separately. Four real-process budget tests,
41 existing watcher regressions, seven SDK-check tests, three verified
archive tests and two canonical-target tests pass. Timeout records retain
their pre-cleanup survivor evidence even after the final reaping witness
confirms physical cleanup; timeout is still FAIL. The full Memory fixture
has not yet been rerun.

GF3 and GF4 have partial implementations. The existing Owner now defers
execution assembly, and model preparation joins its complete real mounts.
A failed parallel mount joins every started Future before returning. The
Host readonly-exec bridge has a default-closed port and Store ancestry
checks using the actual ordinary root handoff and canonical audit. New
Product readiness scenarios and real bridge execution remain unverified.
Overall status remains **not fully complete**.

### Current real-run results

The complete fresh Memory latest-context package passes on the fixed SDK:
138/138 Native unit cases and 40/40 protocol cases, with no skips. Total
fixture time is 1010.16 seconds. Each child retained its original execution
cap, and the composed parent completed with no remaining or unknown
processes. This closes the observed single-900-second parent-budget defect;
it does not complete unrelated Product or release acceptance.

Test compilation needs the same `--export-for-test` dependency profile.
Bounded test-profile stages completed for Runtime (238.89 s), Tool (104.97 s),
Store (356.89 s), Core (122.45 s) and Host (557.22 s). An ordinary production
build is not interchangeable with this preparation. Existing unit artifacts
are preserved before target unit recompilation: the SDK's incremental
command otherwise retained a stale executable after a test-only edit.
The gate now resolves its actual target through `pinned_cangjie`, rebuilds
target unit metadata, retains -O2 and gives preparation zero unit-test credit.
The expanded Python gate regressions pass 27/27.

The current Product corpus contains 1073 cases. Its fresh target unit
compilation passes. Of five new readiness cases, three pass (concurrent
waiters share real preparation, close-before-start, stable preparation
failure). Two crash in the fixed SDK collector (cancelled-waiter then
preparation, and first-model initial context). The actual executable SHA-256
is `f440a56d2572dbf3d6860ce5341e18f2971a7568929141fc46cd1e302285eb41`.
GDB catches SIGSEGV before the handler, through GcPhaseEnum, GCTib field
visitation and stack-root scanning. Official SDK metadata identifies
runtime commit `95054a86164a`; the four IsStackAddr-to-CheckAndPush branches
remain in that source. This is not yet proof of the exact invalid slot, and
no SDK/runtime repair is claimed. The operator explicitly declined runtime builds and requires retaining the
official SDK. GC therefore remains incomplete; no compiler or runtime was built.

The complete Coding package builds with nine freshly compiled plugins.
Initial blackboxes needed short private temporary paths to avoid Unix
socket length and implicit-home write failures. With those corrected,
clean-environment functional assertions pass; its long-lived Owner is a
separate process-custody observation. Provider and entry execution report
Owner peer disconnection, and ACP gets through initialization but fails
during prompt execution. These remain failures pending diagnosis; no
timeout, GC, lifecycle or release acceptance is inferred from packaging.

The implementation checkpoints are `a521970e` (verified toolchain),
`35c61b10` (Memory budgets), `ce936dea` (current unit artifacts), `ddde3140`
(readonly bridge) and `95f4ee16` (Owner preparation). The last includes only
indentation after the recorded final normal build. Validation boundaries
remain as stated below. PR stays Draft and the overall task remains
**not fully complete**.


### Latest fixed-SDK delivery evidence

The operator decision keeps the official November 4 SDK and leaves GC
unresolved. It does not waive GC acceptance or authorize SDK source builds.
The final production sources build at the original -O2 configuration through
Store (472.03 s), Core (102.19 s), Host (564.93 s), Product (563.92 s) and App
(363.42 s), each within its existing 900-second cap. The preceding cold App
build timed out at 900 seconds; its cleanup completed and the failure remains
recorded. A fresh Coding candidate, including nine independently rebuilt
plugins, completes packaging in 648.63 seconds without remaining processes.
Its executable SHA-256 is
`4cb9bd38479c3c25e79135aaf9acf4490c0597db2752b298d2cc6017b97f1ef7`.

The readonly bridge now revalidates an existing admission using only its
exact persisted Operation/parent/request identity. This observation cannot
mint a new child or bypass the original Source, current epoch, handoff,
capability intersection or immutable audit. New admissions still require
the actual Host selection guard. History loading checks first-level bridge
selection as well as nested ancestry; it never recreates execution authority.

Independent real-process contracts pass for Pi and Native model roots and
both Direct roots. Each checks three actual Operations, host-minted child
calls, reserved Receipts and read-only/denied-network plans. Corrupting each
of 11 Host selection fields rejects both Native-child and worker historical
reads; restoring the original audit restores readability. Direct Native
also passes independent two-call, one-call, missing-file and spent-root
budget cases. The missing-file case retains three actual Receipts and a
failed Run. Tests now compare the stored request digest with the frozen
plan's actual binding digest, and compare the exact registered executor
version; the former assumptions of 64 bytes and an `:instance:` substring
were incorrect. A parent may return a structured child failure successfully;
the budget test still requires a failed Run and no unbudgeted worker handoff.

These independent cases do not prove continuous-call retirement. The
original compound entry remains available and still exhausts the shared
capacity. No quota, floor, SUM accounting, permission or retirement guard was
relaxed. Test-only explicit result consumption uses the existing release
API; that alone did not resolve compound retention. Further lifecycle and
compound acceptance therefore remains open.

The current Store test artifact passes all 256 cases, with no skips. The
App artifact runs all 40 cases: 38 pass and two plan-review cases crash with
exit 11. The final readiness test artifact contains 1074 Product cases;
its six selected readiness cases produce three passes and three GC crashes,
with 1068 filter exclusions. The thrown-preparation case confirms one cached
failure and a joinable close. The Product/App test artifacts precede only
the later cleanup of unreturned secondary parallel-mount errors; they are
not represented as complete final-source test acceptance. The final normal
production build includes that cleanup. Exact artifact hashes and process
receipts are retained in the evidence bundle.

The final candidate preserves the original blackbox deadlines. Setup passes.
Clean-environment functional assertions pass, but the process supervisor
finds a long-lived Owner, so the combined result fails. Provider profiles
report `owner.peer_disconnected`; `read` exceeds its original 10 seconds;
ACP initializes but times out during prompt execution and reports an invalid
Owner frame on shutdown. These are actual failures. A bounded GDB process-
tree diagnostic did not establish their root cause and is not acceptance
proof; they are not automatically attributed to GC.

The test gate prepares eight existing dependency stages, including RPC,
without unit-test credit, and preserves prior test executables and metadata
before fresh compilation. Other selected members resolve their package name
from the manifest, including nested library paths. The target resolver has
three passing tests; gate preparation/freshness has 28 passing Python tests.
The final affected Python regression group passes 100/100. Dependency,
documentation, library/plugin boundaries and test inventory checks pass.
All 116 lock files retain their complete reviewed dependency graphs after
build-generated pruning is removed.

Private evidence names below are relative to the retained evidence bundle;
no local machine path is part of this repository record:

- `bridge-pins-cases.json`, `bridge-case-results.json`: real entry and fault cases.
- `readiness-product-final/tests-sequential.log`: six readiness cases.
- `current-corpus-results.json`: Store and App artifact hashes and outcomes.
- `final-production-*.log.process.json`: bounded final production stages.
- `candidate-final-build.json`, `candidate-final-blackboxes.json`: final package and original blackboxes.
- `memory-latest-fixture.process.json`: complete Memory fixture and physical cleanup.

The PR remains Draft. Overall conclusion: **not fully complete**. No Issue
closure, release readiness, complete Product run, repeated crash-free run,
full cancellation/restart matrix or hosted-CI success is claimed.


### Non-GC continuation: preparation custody and early Owner probes

The operator defers GC repair and requests completion of the remaining work.
This decision does not mark a crash as passed or identify every timeout as GC.
The official SDK, dependency pins, original execution deadlines, 144 MiB
aggregate, 16 MiB reservation floors, 32-slot ceiling and SUM accounting stay fixed.

GF4 now passes the original compound entries in one process. Read-view
preparation previously returned transport-backed proposal data without retiring
its payload. Each selected preparation retained two message reservations.
The actual mounted descriptor now supplies an owned canonical-data producer.
Core and the existing Direct/Host consumer prepay independent copies before
the original transport is retired. Unknown producers remain registered and paid.
This protocol grants no Source, permission, child admission or replay authority.

The final contract executable SHA-256 is
`67aac90ca6b9322a14c613de063df2092bdbff2e73b3e20e2d7935cf1ffcffe1`.
Its build takes 636.86 seconds. The Direct Native compound takes 4.71 seconds;
the four-root compound takes 16.20 seconds. Both pass all original assertions
and physical process checks. The Direct Native entry includes successful
execution, two-call and one-call rejection, missing-file failure and an already
spent budget. The four-root entry covers Pi, Native and both Direct variants.
The three actual Operations, their reserved Receipts and all eleven selection
field corruption checks remain required. Before the fix, the missing-file case
produced only two Receipts after `extension.payload_capacity`. Its post-close
shared charge was 117,440,512 bytes. The first repaired run returns that charge
to 16,777,216 bytes. Raw Registry copies still retain their own payment.

GF3 also fixes a separate startup defect. The listener accepted early ping
requests before `configuration180` was bound by background Product assembly.
Constructing the physical peer then failed, leaving its original slot held.
The worker now installs the same trusted configuration before listening.
Frontend execution still joins actual Product assembly. Lifetime observation
joins transient handshakes and preserves other authenticated frontends and
real persistent services. Shutdown errors retain their structured cause and
bounded retirement phase instead of only the generic carrier message.

The clean-environment test now runs all original functional assertions inside
the existing strict process watcher. The inner command still has its original
20-second deadline. Forced reaping or an unknown process identity fails the
test. The old candidate fails this regression; the repaired candidate passes
three consecutive runs with no survivors, forced cleanup or unknown identities.
The current host candidate SHA-256 is
`e5c206ce24aae22d5c894e3d841edbf055c520f500b03250ccf0193576a0ddc3`.
It uses the nine byte-verified plugins from the successful fresh Coding build.
This host-only repackaging is not a new complete distribution-build claim.

Final production Product and App builds take 239.07 and 268.10 seconds.
The preceding complete Tool, Core, Host, Product and App build also passes.
A full Coding build passes in 877.59 seconds; an earlier attempt received
SIGTERM without a complete receipt and remains recorded as interrupted.
A minimal fixed-SDK probe confirms that a completed `Future<Unit>.tryGet()`
returns `Some`. No SDK component was built or modified.

The current entry-mode test still fails during execution after its metadata
cases. ACP prompt and provider-profile tests also fail. These are not accepted
or automatically attributed to GC. Complete current-source unit, lifecycle,
distribution, performance and hosted-CI acceptance remains open. GitHub Actions
is enabled, but the pushed starting head has no run records. The PR stays Draft.

Private evidence files for this checkpoint are `bridge-final.json`,
`direct-native-final.log`, `compound-final.log`, `clean-env-regression.json`,
`clean-env-evidence/`, `owner-ready-builds.json` and `owner-ready.json`.
The existing Epic matrix remains the full requirement inventory.
Implementation checkpoints are `36ef29cf` (preparation custody) and
`e109c9a8` (early Owner probes and physical-retirement regression).


The current affected Python regression group passes 100/100. Its compiler
identity probe now sends both native-library and network-bridge output to the
probe's own directory. `pinned_cangjie` copies the explicitly selected bridge
instead of trying to rewrite the checkout during the probe. The normal output
path is unchanged. The complete architecture gate passes, including 15 internal
checks, all 61 plugin-package boundaries, all ten reusable-library boundaries,
the current dependency graph and the retirement inventory. The inventory now
records the already present native readonly bridge as a name-marker candidate,
without treating that name as evidence of an obsolete compatibility layer.
The probe isolation checkpoint is `163804e1`.
