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
| GF4 | Real Pi and Native roots execute the exact readonly plugin and Host ReadView through a canonical three-node tree | Four independent real entries pass; 11 selection-field corruptions reject; four Direct Native fault/budget cases pass | Focused, compound and 22 lifecycle cases accepted | Complete Product, distribution and release acceptance remains open |
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


## Non-GC verification checkpoint, 2026-11-06

The official SDK and stdx stay fixed at the preceding checkpoint. No SDK
component was built or modified. GC repair is deferred, not accepted. Existing
execution deadlines, permission checks, 144 MiB bank, 16 MiB floors, 32 slots
and SUM accounting remain unchanged.

The fresh default-target unit gate compiles all eight bounded dependency
stages and completes fourteen package preparers. It then fails during the
latest-context Memory preparer: its serial Native run reaches 122 of 138 cases
before the original 900-second stage deadline. No workspace unit case receives
credit from that failed gate. The ordinary Memory preparer already uses two
isolated workers. `e230ed06` applies that same runner to latest-context without
removing a case or changing a deadline. Its complete 138 Native and 40 protocol
cases then pass; the observed full preparation takes 701.72 seconds.

A scoped continuation verifies the existing prepared package hashes, finishes
the three remaining preparers and runs every workspace package. Together with
the Process4cj fix below, 27 of 29 packages pass 1,388 cases. This continuation
is not a passing canonical full unit gate. App passes 38 of 40; its other two
cases have explicit GC crash stacks. Product's canonical isolated runner stops
at a GC error after ten passes. A separate diagnostic executes its unchanged
1,074-case binary in independent processes: 478 pass, 540 report SIGSEGV and
56 fail without SIGSEGV. A SIGSEGV alone is not proof of an SDK GC defect.

Process4cj's five timeouts are independent of GC. A retained minimal probe
passes ordinary O0/O2 compilation and test-only O0, but times out in test-only
O2. Its delegate getter and wait method contain nonreturning loops. Preserving
the delegate type with a generic fixture avoids that compilation result.
`9fac0812` rebuilds and passes all 43 original cases at O2, with no assertion or
deadline change. `e7d69019` also fixes eight Product fixture setup failures:
temporary directories follow TMPDIR and version updates reuse their directory.
Two large-history oracles now use the API's correct units: 8 MiB logical bytes
still prepay the original 64 MiB physical copy budget. They reach execution and
then crash; their large-content assertions remain unaccepted. The targeted
56-case rerun passes nine and fails 47; one additional pass has no established
fix and is not counted among the eight repaired setups.

The model-resource failures expose a separate test migration gap. Old Product
claims do not satisfy the Host's internal installed-provider seal. The Host
check stays strict. The old positive fixtures must move to the actual installed
path; they are not reclassified as GC or passed by admitting compatibility
claims.

GF4's new formal runner, `scripts/readonly_bridge_lifecycle_gate.py`, passes all
24 entries: 22 lifecycle cases and both original compound entries. The final
contract executable SHA-256 is `f416da825df75378f5e4a1dee6eae8a7a7c54601a45e253d972248a178a01d0a`.
Pi, Native and both Direct entries cover disabled selection, withdrawn service
grants, cancellation and revocation after actual worker handoff, and reopening
a completed journal without replay before a distinct new root. Direct entries
also cover an already-cancelled caller. Cancellation and revocation retain
three actual Operations and all three original reserved Receipts. Every case
passes physical observation without survivors, forced reaping or unknown
identities. Physical exit does not acknowledge DATA. The Direct serialization
scratch returns from its complete helper before payload release.

The runner is connected to the existing focused gate. Focused and release
entry points now prepare the Native Workspace, Program and readonly Shell
packages their standalone contracts require; a child unit-gate environment
cannot provide these variables to its parent. Standalone readonly Shell also
passes all nine original Cangjie unit cases. These results do not claim that
the complete focused or release gate has passed.

Provider-profile setup now imports and enables the real package through the
CLI, uses its returned content digest and writes explicit operator grants.
The original two keys, two profiles and five-second invocation deadlines stay
required. The local blackbox passes twice, and again through the shared
operator helper. Its binary is the full App supplied explicitly to an
unbundled diagnostic recipe; this is actual App/Host proof, not acceptance of
the lean `agent_minimal` component or the complete Minimal distribution.
The Coding attempt fails during import; its retained core reports GC field
enumeration on a scheduler worker. A widened, traced wait is diagnostic only
and never substitutes for the original deadline.

Real-provider smoke uses the same explicit installed grants. Its two proposed
DeepSeek normal-output calls were rejected by automatic approval review before
execution because the external prompt and credential use lacked explicit
payload-and-destination approval. No workaround or live call was performed.
The existing full PR matrix, genuine distribution builds, remaining Product
contracts, original baseline measurements and hosted pinned CI remain open.
PR #49 stays Draft.

Evidence for this checkpoint is retained under `<evidence>`:
`acceptance-units/summary.json`, `acceptance-continuation/summary.json`,
`process-generic-final/summary.json`, `product-all-direct-cases/summary.json`,
`product-targeted-final/summary.json`, `bridge-formal-final/summary.json`,
`readonly-units.json`, `profile-original-gate.json` and
`profile-shared-gate.json`. The bridge summary contains source and fixture
hashes as well as every actual command and process receipt. Current logical
checkpoints are `e230ed06`, `9fac0812`, `e7d69019`, `1d780f7d` and `9aa5d7cb`.
No production API or database migration is introduced by these test and
fixture follow-ups. Reverting them restores the preceding test/gate behavior.


### Actual Minimal, distribution and baseline follow-up

This follow-up uses the same official SDK and stdx hashes above. No SDK
component was built. GC repair remains deferred. The production HTTP change is
`ed9b4dd3`; subsequent commits through `a22a0913` change fixtures and gates.

The genuine `agent_minimal` build and portable package pass all ten actual CLI
contracts. Its installed model path also passes ten contracts against a local
HTTP peer, including Chat Completions, Responses and Messages, canonical
Decisions, unknown usage, missing secrets, cancellation and partial responses.
The model contract now deliberately uses a long installed-package path.
The preceding binary fails before HTTP with curl error 100. The repaired
binary passes the same contract without tracing or longer deadlines.
The fixed HTTP launcher uses literal `/usr/bin/env HOME=/tmp /usr/bin/curl`.
Package code cannot choose this executable or assignment. The original
sandbox, network policy, CA bundle, credentials and resource limits remain.
No database or public API migration is required. Reverting this change restores
the preceding curl invocation and its observed long-HOME failure.

The separate Minimal source-closure gate also passes. It materializes 19
packages without Product, optional business packages or compiled caches, then
builds a fresh executable and runs Registry 36, History 4 and nine original CLI
blackboxes. The gate initially exposed a missing `ci_toolchain.env` input.
`a22a0913` includes and hashes that input. The closure executable hash is
`929549fe83213cf80023b84069c8b2eb21fba522be96425f6a1aabd8fe9c73d6`.
This gate does not by itself prove a portable distribution or external models.

`c2d074a1` prepares the real MCP Server sibling alongside the Client. Both
independent packages build and pass all 51 Client and 20 Server protocol cases.
The server manifest, binary, libraries and licenses are checked against their
actual packaged provenance. A missing sibling can no longer be replaced by a
fabricated package. The subsequent actual Full17 Product case crashes, so its
Product-level acceptance remains open.

The final App binary, `90cf58506537f342faf5f3e33acbe8e0da51b63ad085ea86bdc679a344c17dc2`,
produces fresh Coding nine-package and Full seventeen-package distributions.
Both pass setup and clean-environment checks. Both provider-profile imports
crash. Full's entry-mode attempt also crashes. Their three retained cores show
`GCTib.ForEachBitmapWord` and `Mutator.GcPhaseEnum`; a disconnect alone is not
used as that evidence. Coding's read entry separately reports missing operator
configuration. `e0f84051` fixes ACP's use of the developer's default home and
prevents its cleanup assertion from masking the first protocol failure.
The isolated rerun reaches prompt handling, then loses the Owner connection.
ACP and entry-mode acceptance remain failed.

The immutable original baseline is `4d88fa6072f7176a6d236a1cb39b33529d5b609d`.
Its unmodified lock-v0 build fails dependency resolution with this SDK.
A separate audited build copy converts lock serialization to v1 with the same
reviewed dependency commits; all Cangjie source bytes remain unchanged. This
adapted baseline builds with the same fixed SDK and clang15. It passes 100 cold
starts and 40 TUI runs, with p50 263.7 ms and p95 263.8 ms. Final Coding passes
100 cold starts. Its original TUI gate fails at run one with exit 1, despite
rendering 14 frames. No 40-run candidate p95 or baseline comparison is accepted.
The headless TUI returns before the Screen retirement used by the native path;
that lifecycle gap is still under investigation, not waived as GC.

`1290a9f8` supplies required shared batch context, uses a valid zero-child
budget for pre-admission refusal and makes the negative yield payload satisfy
its public schema. It preserves the original wave, count, cancellation and
Receipt assertions. Schema-valid business errors and the original
schema-invalid inputs are covered separately. The latter passes with 1,075
tests enumerated and one selected case: each rejected call retains its unique
canonical failure Operation and Receipt, with no execution handoff or child.
Seven other selected Product cases crash. Compilation is not their acceptance.
`eeffd4a8` also preserves old test artifacts across mount boundaries: exclusive
copy and both SHA checks precede removal of the original. Its two new Python
regressions pass; failed copies leave the original intact.

Private evidence under `<evidence>` includes `minimal-model-long-before.json`,
`minimal-model-long-after.json`, `minimal-http-fixed.json`,
`minimal-closure-final/summary.json`, `mcp-pair-current/package-validation/summary.json`,
`distributions-final.json`, `distribution-core-evidence.json`,
`workflow-mcp-current2/summary.json`, `workflow-schema-current/summary.json`,
`baseline-cjpm1-bridge.json`, `baseline-cjpm1-build.json`,
`performance-final.json` and `acp-isolated-current.json`.
The original full unit, focused, release and hosted pinned CI requirements
remain open at that checkpoint. The later authorized two-call smoke and its
failures are recorded below; authorization is no longer pending.

Current Python regressions pass 102/102. The full architecture gate passes,
including documentation, dependency pins, library boundaries and the 39-package
inventory. Minimal source materialization separately passes all 16 Python
cases. Evidence is `static-gates-final-checkpoint.json` and its named logs.
These static results do not replace failed Product or release contracts.


### Actual headless performance retirement

The noncapturing performance path now has a concrete producer lifetime. The
vendored overlay adds `AppTestRunner.runOwned`: it charges the actual prior
Terminal and TestBackend buffers through the original provider before drawing.
It closes the real command, asynchronous-task and Terminal helpers before
returning internal retirement witnesses. These witnesses never acknowledge
physical output or retained screenshots. Capturing options are rejected by
this entry; the original capturing runner remains available unchanged.

The product binds a private headless producer to the exact Screen and actual
`DirectStdOutDisplayOutput`. The complete performance helper returns before
its stdout witness and Screen-copy receipt can be created. The receipt also
requires real asynchronous, Window and Terminal retirement and backend-reader
quiescence. The native retirement guard is preserved. No native-frame marker,
extra budget pool, Source, permission or physical-exit acknowledgement is used.
Other headless capture modes still need their own complete custody path.

All 549 vendored Core tests and all 98 TUI tests pass without skips. The new
four Core cases cover actual buffer invoices, refusal before draw, primary
render failure during cleanup and capture rejection. Production App build
passes with executable hash
`2cea8e7d036e3ac33cabc334227182fca9a57bc3376c87f8425037460c774ec7`.
The newly rebuilt Coding nine-plugin package has executable hash
`96e8651ea8ac81977ce3c110b672dba549ad2df90b37881ddeb01822d960b0df`.
Its setup, clean-environment checks, 100 `--version` cold starts and all 40
original TUI journeys pass. TUI p50 is 413.8 ms and p95 is 413.9 ms under the
unchanged 500 ms gate and 15-second sample deadline. The earlier same-SDK
baseline p95 is 263.8 ms; the observed candidate increase is 150.1 ms, about
57 percent. These samples do not replace the required activation, hot IPC,
output-load, memory and cancellation performance matrix.

Evidence is `headless-core-second-probe.json`, `headless-core-full.json`,
`tui-headless-units.json`, `app-headless-current.json`,
`headless-actual-app-diagnostic.json` and `headless-coding-final.json` under
`<evidence>`. The unbundled diagnostic is separate from the final Coding gate.
All final process observations report no survivors, forced reaping or unknown
identities. The upstream cjtui identity remains unchanged; the intentional
local overlay and API checksum record the new entry and four tests. No database
migration is introduced. Reverting this change restores the prior headless
performance failure; original native and capturing APIs keep their contracts.


### Hosted CI, Workspace output and Product Registry bridge follow-up

The manually dispatched pinned PR gate at `951e6bd6` failed because an old
status entry named a generated target directory as source authority. `682585e9`
corrects that reference without weakening the documentation gate; its 19
regressions pass. The next hosted run exposed an installer-test isolation bug:
the fake SDK installer inherited the real `GITHUB_ENV` and `GITHUB_PATH`, so
subsequent steps selected an already-deleted fake SDK. `c9621d55` gives each
fixture private output files. Its new regression fails before the fix and all
four tests pass afterwards, including exact fixture exports and unchanged
parent output files. The next hosted run passes static checks and clean
compilation, then fails the actual AST product contract. It is not a green CI
result; later unit and release stages remain unrun.

`d6cd56e9` fixes single-file Workspace grep output by retaining filenames in
ripgrep line mode. The strengthened existing regression fails against the old
real package and the independently rebuilt package passes all 43 worker and
nine payload tests. CLI tests now import and enable the actual package, select
its real digest and write explicit readonly operator grants. Issue #48 section
0.6 permits replacing old interface tests with corresponding current contracts:
case/count/skip and a real 1,100-line fixture prove the fixed 1,000-line page
and remaining 100 lines. Actual read, count, paging and path-escape assertions
pass under the original ten-second invocation limits. The isolated test
workspace excludes unrelated build artifacts; production resource limits are
unchanged. This is a fixed-App diagnostic with a real installed package, not
Minimal or complete Coding acceptance. The complete diagnostic reaches the
missing search-plugin capability and fails there.

Coding9 and Full17 are rebuilt at `d6cd56e9`; both pass setup and clean-
environment checks. Both use packaged App hash
`96e8651ea8ac81977ce3c110b672dba549ad2df90b37881ddeb01822d960b0df`.
These packages predate the Product Registry bridge change below and must not
be credited as final artifacts for that later production change. A core from
the current Coding import failure matches this executable and contains
`GCTib::ForEachBitmapWord`; that GC path remains explicitly deferred.

The user subsequently authorized exactly one normal Agent call per official
DeepSeek endpoint. Recovery retries were disabled and each database records
one ModelAttempt. Neither call passes: Completions returns
`http.exchange_outcome_unknown`; Messages returns `model.plugin_failure`.
Neither returns its marker. This proves neither model availability nor an
external root cause. No further request was made. These calls used the fixed
current App with only the actual provider installed; they are not complete
Coding/Full or extended tool/approval/cancel smoke evidence.

Local reproduction of the hosted AST failure reveals
`plugin.registry_package_worker_unsupported` behind the plugin's generic
invalid-JSON error. Product's `LocalProcessPort` omitted the existing
`HostRegistryPackageProcessPort` interface. At `65039c03` the adapter delegates its
Registry-aware readonly entry directly to the same native owner. The original
launch fence, readonly sandbox, denied network and canonical Derived/Receipt
path remain authoritative. No seal, source, permission or second owner is
introduced. A separate actual refusal contract is added to the focused gate
without removing the original complete command.

The current product contract binary
`00142f63c032f3aee24a6f50b7d816a8b98d6d79b01f3ab035b13fa1023b48d9`
builds within the original 900-second cap and passes Registry launch refusal,
AST query and AST edit contracts. Query covers structural matches, pagination
and escape refusal. Edit covers actual proposal, approval/reject/cancel,
concurrent conflict, recovery and final write. The old stale-plan assertion
mistook the final explanatory reply's success for a successful write. Its
replacement requires the canonical failed ToolResult, precise conflict,
`no_effect`, zero applied items, one failed Receipt and unchanged concurrent
bytes. The normal approved replacement remains asserted. The complete Product
unit compilation times out twice at the unchanged 900-second cap; no selected
unit case receives acceptance credit. The added refusal unit case and the
complete unit/focused/release suites still require validation.

Private evidence under `<evidence>`: `workspace-grep-current/package-validation/summary.json`,
`entry-read-current-v6.json`, `entry-full-current.json`,
`distributions-grep-final.json`, `real-two-authorized-result.json`,
`real-two-authorized-v2-process.json`, `ast-current-contract.json`,
`registry-worker-canonical3.json` and both
`registry-worker-adapter-current*/product-build.log.process.json` files.
The private local syscall trace diagnoses only the AST refusal and is not
publication evidence. The bridge changes no database schema or plugin protocol;
rollback restores the prior refusal rather than granting an alternative path.

The Registry bridge checkpoint also passes 103 Python regressions and the full
architecture gate on the current source. These are static/script results,
not substitutes for the two timed-out Product unit builds. Evidence is
`static-gates-registry-worker.json`.


## Product workflow follow-up on the fixed official SDK

The PR remains incomplete and Draft. GC is deferred by the user; the remaining
non-GC failures below are not waived. This follow-up uses the same official
SDK archive SHA-256 `3128c819ee9f580ff065c457ef1d38b4be2a08ae0f8da6fbf596d9d315f04a5a`
and unchanged stdx archive. No compiler, runtime or SDK source build was run.

The completed hosted run `42156582071` at `cc2fd7e0` passed static checks and
clean compilation, then failed the aggregate Product contract during AST
approval. Its actual failure was `application.owned_failure_pending` with the
shared bank at `8:134847312`. Four earlier, independent broker Products retained
legacy Raw metadata on that same process bank. The focused gate now runs
Registry refusal, acquisition, AST query, AST edit and Core/recovery as separate
actual process lifetimes. Its existing 24-case bridge gate still requires both
original compound broker entries and every lifecycle case. The no-argument
aggregate entry remains available and its earlier failure remains recorded.
No process exit acknowledges DATA; no bank is reset or enlarged. New runner
regressions require every case group and fail immediately when a case fails.

The Core fixture now imports and enables the actual Native Compaction package
with an immutable digest and explicit operator policy and canonical-data grants.
It first requires `policy.not_configured` without that configuration, then
requires the original checkpoint and resumed projection. The isolated-host
fixture reuses the package directory created by actual public imports.

Actual Program execution exposed a production mismatch: readonly delegation
resolved effects from the pre-canonical display arguments, which made the
read-view effect resolver reject the valid child as
`readonly_delegation.target_changed`. Commit `d5e546a0` resolves the descriptor
from the already validated frozen child arguments. The original effect,
package, schema, version, capability, Derived Source and Receipt checks remain.
The fixture now compares each derived request digest to its exact stored plan
`bindingDigest`, including the transactional cancellation observer. It no
longer assumes that every such digest has 64 characters.

Commit `60295229` adds a scalar request-prefix observation. The Product fixture
uses existing paid tool/system observations and the actual invocation count
instead of exporting a complete Raw `lastRequest` for boolean checks.
The public Raw getter keeps its original conservative retention behavior.
All nine fixture custody tests pass, including empty history/block/text,
late-access revocation and exact original-bank return. The Product fixture
changes and stack-frame extractions are in `d52c1769`. The extracted durable
readback and compound broker bodies remain byte-for-byte unchanged; all
original assertions, order and quotas remain. Both Direct restart cases failed
with `StackOverflowError` before the broker extraction and pass afterward.
No SDK stack setting was changed.

Contract binary at the earlier `d52c1769` checkpoint, SHA-256:
`cdfc933fded078e97bfd68bf62615ba9a9cc15fae648e022f23925622537f781`.
It passes Registry refusal, acquisition, AST query and complete AST edit, and
all 24 original readonly bridge cases. The normal Python entry passes all
105 regressions and the complete architecture gate. An extra enclosing process
watcher caused three watcher-owning Python tests to fail; that diagnostic run
is retained separately and is not counted as a pass. These static results and
focused contracts do not establish full Product, hosted CI or release acceptance.

At that earlier checkpoint, the complete Core/recovery case fails in the
second matched Program sample. The actual first PTC sample has seven Operations and seven Receipts;
its native comparison has six of each. The later worker records
`read_view.output_capacity`, followed by a failed Workspace result and the
unchanged completed-Run unsettled-Operation guard. Temporary observations
confirmed that the actual input-attachment ACK arrived and its original charge
closed. Those observations were removed exactly. The remaining retaining owner
is not established, and the shared budget and settlement guard are unchanged.
Input attachments, all three matched samples, and the original negative and
recovery assertions remain required. Downstream assertions not reached by this
failure remain unverified.

The earlier actual O2 Product and App builds at `65039c03` also completed;
App SHA-256 is `8a864848af2736de49a7ca587729841599e9a0cbd3abe76b25a557fea065d7bf`.
They predate this readonly-delegation fix. The third full Product unit build
still timed out at the original 900-second cap. Current final App, distribution,
full unit, focused and release acceptance remain open.

During validation, tracked checkout files, SDK members and dependency cache
contents disappeared. Their cause is unknown. Recovery preserved all WIP hashes,
restored only missing tracked paths from `cc2fd7e0`, restored missing SDK members
from the verified original archive, and reconstructed dependency caches from
local committed objects at the same pinned revisions. No local dirt, new
revision or SDK source build was used. The restored SDK produces a distinct
canonical target identity; current results identify their actual binaries.
Earlier build failures caused by missing files remain failure evidence.

Private evidence under `<evidence>`: `product-followup-source-identity.json`,
`product-followup2-independent.json`, `readonly-bridge-product-followup2/summary.json`,
`fixture-observation-units-current.json`, `static-gates-product-followup-direct.json`,
`static-gates-product-followup.json`, `product-workflow-settlement-diagnostic.json`,
`product-input-attachment-diagnostic.json`, `product-readback-extraction-proof.json`,
`product-broker-frame-extraction-proof.json`, `product-broker-frame-current.json`,
`app-registry-current-v4.json`, `product-release-current.json`,
`registry-worker-adapter-current3/product-build.log.process.json`, and the private
checkout, official-SDK and dependency-cache recovery manifests. Raw diagnostics
are not publication artifacts. This follow-up adds no database or plugin
protocol migration and grants no new execution permission.


### Owned readonly metadata follow-up

The current non-GC work is still incomplete. Commits `0d37ff64` and
`94a80da6` return the actual temporary active-Run and Registry views after
complete scalar helpers finish. Their selected tests pass one case each;
four existing Registry ownership regressions also pass. Commit `88266ba5`
reuses the actual installed Program binding and closes temporary Registry
lookups. Its 100 binding observations and 100 Registry lookups preserve the
live logical ledger. File-plan scenarios reuse the installed package rather
than importing its namespace twice. No assertions or scenarios are removed.

Commit `3102df0b` omits the unused catalog from the process-control cancellation
projection. Run identity, epoch, capabilities, budget and cancellation remain
unchanged; actual invocation preparation still uses its original context and
Source. Its selected lifecycle test passes and proves that the original
catalog payment can close while the process-control projection remains live.

Commit `a7892be0` copies the actual snapshot ID into independently paid DATA
rather than exporting the full immutable schema graph. Delegation checks the
original thread, installed generation, fingerprint, version and schema. Its
owned canonicalizer copies the complete result before returning the producer
frame. Validation consumes a closed Boolean comparison; exported dynamic
errors and uncertain consumers keep their original payments. The legacy Raw
result retains its copied ID. No generated ID, new bank, Source, authorization
or acknowledgement is introduced. Existing metadata-escape guards are unchanged.

Three snapshot-ID tests, four canonical-comparison tests and the process-control
test pass on the pinned official SDK. The initial custom-node test expected a
Boolean for an unsupported JsonNode and failed. The corrected assertion requires
the original exception and continued payment. An incremental run reused the old
test executable; only the subsequent actual rebuild receives current credit.
Private evidence is `snapshot-identity-units-current.json`,
`canonical-comparison-units-current3.json` and
`process-control-projection-units-current3.json` under `<evidence>`.

The current standalone contract executable has SHA-256
`f0c3844a11d43177a477258e172c32cf39c891bf21ce71fbe2547c4ddc6d8648`.
It builds in 412.2 seconds under the unchanged 900-second limit, passes all
four independent Registry/acquisition/AST contracts and all 24 original
readonly bridge scenarios. It also passes all three original matched PTC and
Native samples, with seven Operations/Receipts per PTC sample and six per
Native sample. The complete Core/recovery command still fails at the first
file-plan input attachment with `input_attachment.capacity`. That is a non-GC
failure. File-plan and later recovery acceptance remain open.

Read-only debugger observations reconcile all 5,493 observed live-ledger
checks with the actual original bank. They identify retained preparation and
Catalog DATA; they do not establish a complete ownership fix or a passing
contract. No budget, peak-refund rule, timeout, sample count, Source or settlement
guard is changed. Evidence is `product-owned-catalog-identity-current.json`,
`product-catalog-identity-followup.json`,
`readonly-bridge-catalog-identity-followup/summary.json` and
`workflow-file-plan-live-leases-owned-identity.json`. Full Product units,
current O2 App/packages, positive installed-Host Model-resource fixtures,
capturing headless/performance coverage and the full required gates remain
open. The two authorized real-provider attempts remain failed; no extra call
is authorized by these results. GC repair remains explicitly deferred.

These changes add DATA lifecycle APIs without changing existing signatures,
plugin wire fields or database schema. Reverting them restores the earlier
retention behavior; it grants no alternate execution path. Earlier artifacts
remain historical evidence and do not validate the current production code.


### Resolver invocation and current remaining failures

The Pipeline previously treated registration selection as a Raw callback
export. A read-only presence query therefore retained its entire Catalog DATA
source even though neither resolver ran. The correction places the existing
conservative check at actual Raw canonical and preparation-read invocations.
The owned path still requires same-bank validation, complete independent
copying and real producer/consumer-frame return. No `coreMetadataResolverClosed204`
flag is enabled. Raw errors, callbacks, unsupported nodes and unknown failures
retain their existing debt.

The new four-case public Pipeline DATA fixture fails two cases before the fix
and passes all four afterward. It does not create a Core Run, Source, execution
or Receipt. Both actual Raw callback controls remain retained. The current
complete Tool Runtime suite passes 72/72 without skips. The full inventory adds
all five new test files from this continuation and removes none. Evidence is
`resolver-invocation-before3.json`, `resolver-invocation-after.json` and
`tool-runtime-full-current.json` under `<evidence>`.

The matched workflows now use the existing owned AgentClient start entry to
provide the actual Core frame return. Their Raw request DATA remains owned by
the caller. Pending failure carriers are not flattened or acknowledged. A
separate contextual ApplicationSession API experiment did not improve capacity
and was withdrawn; no new submission API is shipped.

The final product run passes all three original matched samples and the four
independent contracts. The first valid file plan now stages its attachment,
but its actual Workspace read child fails with `read_view.output_capacity`.
The parent returns the original partial failure. Full Core/recovery remains
FAIL; subsequent file-plan and recovery assertions are unverified. Evidence is
`product-resolver-owned-final.json` and its actual Store diagnostics. No quota,
settlement condition, timeout or assertion is relaxed.

The same final bridge run passes 23/24. `direct-pi-disable-handoff` again fails
while withdrawing the installed generation. Earlier current 24/24 evidence is
retained separately and does not erase this failure. The fixture now reports
the static Registry refusal code before closing the actual error. Five bounded
subsequent diagnostic runs pass without reproducing the failure. They do not
establish stable acceptance or identify its cause. Evidence is
`readonly-bridge-resolver-owned-final/summary.json` and
`product-resolver-disable-diagnostic.json`. This remains a non-GC open item.


### Closed checkpoint protocol lookup

A further read-only trace finds `projectContext` marking the actual lane's
protocol as historical before calling the open checkpoint repository. The new
optional `ContextCheckpointProtocolRead159` port receives only an exact Boolean
matcher. The Runtime closes that matcher after the complete repository helper
returns. A retained matcher cannot read text or perform late comparisons.
SqliteContextCheckpointStore selects a database-owned protocol string and
uses the existing exact load, canonical-prefix digest and boundary checks.
The original repository API and historical payment remain for compatibility.
No Source, quota or execution acknowledgement is added.

All 37 Runtime and 257 Store tests pass without skips. New cases cover exact
and mismatched protocols, expired matchers after success and exception, the
original Raw retention behavior, a real SQLite selected checkpoint with UTF8
and embedded zero, and unchanged rejection after prefix-digest corruption.
Evidence is `checkpoint-protocol-runtime-full.json`,
`checkpoint-protocol-store-full.json` and their selected-case build logs.
The current product binary SHA-256 is `b0ec5bfdad762cda65c12fb435e8785348988db383f41a7781ff07f6e8b8cfc9`. It passes all four independent contracts and all 24 original
readonly bridge cases. The earlier 23/24 withdrawal failure remains an open
intermittent concern; a single passing rerun does not establish its cause or
stable resolution. Evidence is `product-checkpoint-protocol-current.json` and
`readonly-bridge-checkpoint-protocol-current/summary.json`.

The complete Core/recovery case still fails at the first file-plan read child
with `read_view.output_capacity`. The three matched samples pass; later
file-plan assertions remain unverified. Read-only ledger checks at the prior
checkpoint reconcile 5,796/5,796 and report no unknown Catalog-callback holds.
Their large `reserveSnapshotCatalogData159` group includes actual tool-set
snapshots and must not be mislabeled as only Core Catalog source loans.
Root-context and other lane consumers still require a complete lifetime audit.
No Core-context retirement change is included in this checkpoint.

### File preview authority and current lifetime boundary

The current non-GC work remains **not fully complete**. GC is deferred by the
user. The following evidence does not replace the open full Product, App,
performance, release, provider, and hosted-CI requirements.

| Evidence | Required behavior and implementation | Actual verification | Status and remaining gap |
| --- | --- | --- | --- |
| E993 | Private Core root Context DATA remains held until its entire producer helper and original task witnesses return. Existing pending consumers and ACK debts still prevent collection. | `preview-followup-units-current.json`: Core 47/47 PASS. Actual file-plan execution now passes its original first read and preview. | Partial. The change covers start without an open initial-context preparer. Resume, approval and other concrete Context consumers still need lifetime closure. Errors and unknown callbacks remain paid. |
| E994 | Operator-granted previews use their exact `readonly-delegation` child key in Pipeline and Store routing. The existing transaction still checks the actual frozen parent, complete edge, capability ceiling, handoff and reserved Receipt. The registered preview now declares `neverReplay`, matching the existing Domain predicate. | `product-file-plan-owned-canonical-current.json`: actual ungranted preview is refused without a preview Operation or file; the granted preview has the original completed child Receipt and exact parent/source/proposal identity. | Focused behavior PASS. Complete Core remains FAIL later in the same process. No authorization or replay guard was relaxed. |
| E995 | A file changed during review must be rejected before recording approval. `ToolApprovalTargetValidator` opts the actual file-plan executor into the descriptor's existing canonicalizer. Both application and recovery producers use `ToolCanonicalArgumentsOwner204` on the original Registry bank. | Actual Core file-plan scenario passes one-time approval, three exact writes, rejection of session-wide approval, stale-target refusal with pending review retained, and recovery. `product-preview-ast-approval-current.json` passes the independent AST edit contract, including no stale apply Receipt and successful cancellation. | Focused behavior PASS. Existing public function signatures and DB/wire formats are unchanged. Stale approval now returns `application_plan.precondition_conflict` with review pending instead of consuming approval and reporting a later failed write result. Callers must cancel or refresh that review. |
| E996 | Nested Native service execution must fit the existing stack. Process-error translation runs only on the error path and no longer occupies the normal `invoke` frame. Error ordering and cancellation precedence remain unchanged. | Original binary reproduces `StackOverflowError` twice. `workflow-stackframes-current.log` records a 121,920-byte active span. The changed actual Core passes that site. Extension 100/100 PASS in `preview-followup-extension-fixture-current.json`. | Focused regression PASS. This does not prove every nested-depth or performance scenario. No SDK build, stack-limit increase or workload reduction was used. |
| E997 | Both Host preparation and Program completed-error adapters preserve the actual child refusal. The Native fixture decodes persisted Receipt detail using the existing Store codec. | `program-preview-error-red.json`: the old package fails two new error-code assertions. `program-preview-error-package-validation/summary.json`: all 28 packaged protocol cases PASS, including those assertions, without skips. Actual Core preserves path refusal and rejects the original UTF-8 path bound. | PASS for these adapters and protocol cases. Protocol packets do not prove Store authority; the actual Product evidence in E994 supplies that boundary. |
| E998 | All affected package unit cases remain inventoried and execute. | Tool Runtime 72/72, Store 257/257 and Core 47/47 PASS in `preview-followup-units-current.json`. The original isolated Host entry passes 272/272 in `preview-followup-canonical-host-current/agent_host_runtime.isolation.json`. Extension passes 100/100 with its required fixture root. Total: 748 PASS, no skips. | PASS for these packages. The initial noncanonical Host shared-process run and Extension missing-fixture run remain failure evidence; they are not counted as passing. Product/App are not included in these totals. |
| E999 | All original bridge lifecycle cases and independent contracts must pass on final artifacts. | `product-preview-final-independent.json`: Registry refusal, acquisition and AST query pass; its old AST stale-review oracle fails and is corrected in E995. `readonly-bridge-preview-final-independent/summary.json`: 23/24 PASS, Pi disable-handoff fails with `thread.durable_commit_failed`. | FAIL. The earlier Direct Pi withdrawal failure remains an intermittent concern. No claim of stable bridge closure or final product acceptance. |
| E1000 | Consecutive real Runs must release only DATA whose concrete consumers returned. | Complete Core in `product-file-plan-owned-canonical-current.json` reaches the stale-proposal negative, then fails before dispatch with `input_attachment.capacity`. Read-only `workflow-preview-owned-scope-hold.log` identifies Raw metadata getters in actual Native Host and file-plan executors invoking `PreparedMetadataOwner204.holdUnknown204`. | FAIL. Add actual metadata consumers through complete private helpers, asynchronous broker and result ACK lifetimes. Preserve unknown Raw exports, shared high-water accounting, original quotas and all Source checks. |

The final standalone AST product artifact is
`3e30166e6c7a305c180ec71e12a2b12856f6a80c9df9d71ad8436412382558f5`.
`product-preview-canonical-refusal-current.json` verifies this final build: AST
edit PASS and complete Core FAIL at the same later attachment capacity boundary.
The preceding independent/bridge artifact is identified separately in its JSON.
The final producer also handles exact recorded pre-copy refusal through the
existing owner protocol. Unknown copy failures remain paid. This narrow failure
change is not a new complete bridge acceptance.
The five package results apply to the production changes before that test-only
edit. Official SDK and StdX identities remain unchanged.

Generated root, Program and standalone Product locks were preserved with exact
bytes, differences and hashes in `preview-followup-lock-preservation`, then
restored to the approved lock contents after the related builds completed.
No dependency upgrade or DB migration is introduced. Rollback can revert this
follow-up without rewriting historical Operations or stored artifacts.

The E993-E1000 production and fixture changes are committed in `dc5657e9`.
The current Python regression suite passes 105 cases. Full architecture,
documentation, dependency-pin and test-source inventory checks also pass in
`static-gates-preview-final.json` and `preview-followup-final-inventory/summary.json`.
These static results do not close the failing actual Core or bridge requirements.


## Non-GC pipe, cancellation and fixture follow-up

This checkpoint continues the approved non-GC work. It does not close PR #49.
The official SDK and StdX remain pinned; no SDK component was built. The only
two authorized external provider calls remain failed, and no further external
provider call was made. Evidence below uses the existing private evidence root.

| Evidence | Requirement, implementation and observed evidence | Status and remaining gap |
| --- | --- | --- |
| E1001 | The three concrete file-plan executors borrow the original Prepared metadata in private helpers. Their successful result retains the original metadata consumer until the canonical payload lease returns. Errors, unknown consumers and legacy Raw exports retain their prior debt. `product-file-plan-result-metadata-current.json` passes AST edit but fails complete Core at the later attachment-capacity boundary. Read-only `workflow-file-plan-result-metadata-scopes.log` observes zero Product Raw exports, compared with the former 14. The final Product unit binary passes all three existing file-plan service guards in `nongc-pipe-file-plan-direct-final/summary.json`. | PARTIAL. This fixes these concrete consumers only. Native Host/Broker Raw exports, Core resume/approval/initial-context lifetimes and complete consecutive Runs remain open. The standalone evidence predates the pipe change and is not final artifact acceptance. |
| E1002 | The lifecycle fixture now prints the actual Registry mutation refusal code before closing its owned error, and retains the Core error message. The safe standalone rebuild passes Pi and Direct Pi disable-handoff; ten alternating independent diagnostic runs also pass in `product-pi-withdraw-bounded-diagnostic.json`. The unsafe generic read-view metadata experiment was withdrawn because open ProcessPort and inspector interfaces can retain DATA beyond physical cleanup. | NOT CLOSED. Ten passes do not establish a fix for the earlier intermittent withdrawal failures. No generic metadata ACK or Raw-getter exemption was shipped. |
| E1003 | The fresh 1,076-case Product inventory reruns 56 prior non-GC failures independently in `product-nongc-current-audit/classification.json`: 12 PASS, 23 crashes with Runtime GC frames, one other physical crash, and 20 non-GC failures. | Diagnostic snapshot only. Excluded cases receive no pass credit; a signal alone is not a GC diagnosis. Later fixes below supersede individual failures, not the entire snapshot. |
| E1004 | Real one-page pipes expose a write-path bug: `POLLOUT` can be absent although a small nonblocking write fits the partial page. Both new regressions fail before the fix: `partial-pipe-page-red/unit.log` and `partial-pipe-page-borrowed-red-current/unit.log`. Both writers now attempt the nonblocking syscall first and wait only on no progress. Guarded writes retain the original per-syscall admission lease, recheck revocation before waiting, and hold no lease across the wait. The original assertions, deadlines and byte limits are unchanged. `partial-pipe-page-green/unit.log` passes all 45 Process4cj tests at the original O2 profile. | PASS for the two pipe regressions and the complete Process4cj suite. This is a process-library fix, not an SDK/runtime change. |
| E1005 | Operation-only channel cancellation now carries `process.channel_cancelled`, preserves an earlier parent cause, and does not cancel the caller Run. The HTTP test formatter compares the canonical primary error once rather than counting its repeated structured detail. Optional service `max_instances` accepts 1..32 and freezes the minimum of service/plugin ceilings. `product-partial-pipe-page-current/summary.json` passes all 34 selected Product channel-service, raw-channel, HTTP and lifecycle-configuration tests, including the former cross-Thread blocked-write failure. `nongc-pipe-canonical-packages/summary.json` passes all 272 isolated Host and 100 Extension tests without skips. | PASS for these actual paths and package suites. The new quota boundary rejects 0, 33 and text values; a larger service value cannot raise the plugin ceiling. No Source, authorization, replay or unknown-outcome guard was relaxed. |
| E1006 | The historical connection fixture declares the actual Codex root schema and still preserves malformed historical connection bytes without launching them; its original assertions pass. Memory fixtures now distinguish installation from Host policy selection, and use the installed Native ranking path for explicit CRUD. The Skills fixture creates the settings root passed to the actual distribution recipe. The Pi queue test checks a unique caller cancellation reason and independent second token. The installed DAP smaller-quota scenario is also retained. | PARTIAL / UNVERIFIED. These five fixture cases reached Runtime `CheckAndPush` crashes in `product-nongc-fixes-current/summary.json` and are not passes. Those crash logs precede the pipe follow-up. GC remains deferred; no claim is made that the final artifact accepts these cases. |
| E1007 | At `37ecd51d`, nine model-resource positive fixtures still used compatibility claims that cannot satisfy the internal installed-provider seal. E1008 records their source migration; runtime acceptance remains open. | OPEN. Do not admit compatibility claims or replace actual resource ownership with fixture DTOs. Stable full bridge, complete Core, current release artifacts, performance matrix and the other earlier mandatory gates also remain open. |

The code checkpoints are `e136bc5a` (pipe writes), `53b5f15b` (channel
cancellation), `e93e6999` (service ceilings), `0d2a0622` (fixtures and diagnostics)
and `a68a4ce3` (concrete file-plan metadata consumers). All current package
results above apply to these source contents. Later commit metadata does not
change the tested code. The latest Product unit executable SHA-256 is
`3c83e266950ce92d41a06b88d3cc77e5aa6d634ae3423012450e3dcc2c559525`.

After other member gates ran, CJPM's last-member manifest returned zero Product
cases with `--skip-build`. That is not a pass. The executable still matched the
SHA from the 34-case run; the three file-plan guards therefore ran directly
through the pinned SDK wrapper. Their parser verifies the actual package,
suite, exact case, complete 1,077-case inventory and single execution count.
This is focused binary evidence, not a completed canonical Product gate.

`nongc-pipe-lock-preservation` retains exact generated lock bytes, differences
and hashes before restoring only this batch's root and standalone Product locks
to their approved contents. No dependency version or DB schema changed. The
service quota field is optional; its absence keeps the previous plugin ceiling.
Reverting the source changes requires no stored-data migration. PR #49 remains
Draft and the complete delivery remains **incomplete**.


`static-gates-nongc-pipe-final.json` passes all 105 Python regressions and the
complete original architecture entry, including documentation, boundaries,
dependency pins and package checks. `nongc-pipe-final-inventory/summary.json`
passes source inventory only. Neither result substitutes for runtime acceptance.


## Installed model-resource fixture migration

E1008 updates E1007's implementation gap. Commit `ebaddf93` changes tests only.
The production Host verifier and its internal installed-provider seal are
unchanged. The fixture composes the real installed local-HTTP package, original
Host model port, Core, Store and process launcher. Its native observer forwards
policy checks, transcript loans and the exact original Returned/Held envelope;
it does not construct a claim, Dispatch, replacement debt or return credential.

| Evidence | Required behavior and implementation | Actual verification | State and remaining gap |
| --- | --- | --- | --- |
| E1008 | All nine existing resource cases use the actual installed Host path. Preserve raw refusals; model timeout 0/3,600,001; the original 64 MiB zero-timeout input allowance; exact 17,825,792-byte input and N+1 refusal; typed-owner isolation; actual Run/package cancellation; safe-cut refusal; ordinary background-task independence; one Attempt under pending cleanup; and no cleanup ACK from cancellation alone. `installed_model_resource_fixture204_test.cj` contains the shared real composition and observable assertions. | The complete final Product test profile compiles under the unchanged SDK/O2 and original 900-second cap. `installed-model-resource-reviewed-compilation/summary.json` enumerates all 1,077 cases and reports `COMPILED_NOT_ACCEPTED`, with no runtime pass credit. | Implemented but runtime-unverified. GC remains deferred; none of these nine cases is accepted. |

Source reverse review uses ten control-flow paths, nine semantic scenarios and
nine existing test IDs in private `model-resource-reverse-review.md`; its
structural validator passes. The review restored repeated channel-close
idempotence and the zero-Operation assertion inside the live dispatch callback,
not merely after the Run. Original case names, loop variants, deadlines and
input limits remain. The old fake-provider worker count of zero is replaced by
one actual installed worker, one Attempt and zero HTTP/decisions for failed or
cancelled requests. Cleanup failure is observed on the original factory's
Runtime task and canonical recovery state, including when physical exit has
already occurred; no fixture-generated ACK substitutes for that state.

`installed-model-resource-first-composed-current/summary.json` and
`installed-model-resource-remaining-slot-current/summary.json` retain the full
Product runs: all nine cases crash in Runtime GC frames. A separate focused
artifact extracts the same nine case bodies and required helper declarations,
records their source hashes, links the original production archives and keeps
the same SDK/O2, real Host/Store/native boundaries and budgets. It also fails all
nine cases: eight show CheckAndPush/GcPhaseEnum and one shows the GC bitmap walk
in `installed-model-focused-linked-current/classification.json`. This focused
artifact proves no passing behavior and does not replace the full Product gate.
Those runtime logs precede the final quota/assertion restoration; the final
source was compiled and enumerated, not rerun into the unchanged GC blocker.

The final full Product test executable SHA-256 is
`03855dd30471ff24263f1bf6dc462f296f2562925a4d891563f0c762d02918fb`.
`model-resource-migration-lock-preservation` retains generated root lock bytes,
diff and hashes before restoration to the approved dependency pins. Complete
Core, stable bridge, current release artifacts, performance and other mandatory
requirements remain open. No further external provider call was made.


The 105 Python regressions and complete architecture/documentation/dependency
entry pass in `static-gates-model-resource-final.json`. The source inventory
first rejected the missing new helper-file registration; the migration commit
now adds exactly that file and removes none. Registered inventory passes in
`model-resource-final-registered-inventory/summary.json`, and all 30 related
runner regressions pass with the original scripts module path. These are
structural checks, not runtime acceptance for E1008.


## Current distribution and Core Context follow-up

Overall acceptance remains incomplete. GC stays deferred. No additional
external provider call was made, and the two authorized calls remain failed.

| Evidence | Current behavior and verification | Status and remaining gap |
|---|---|---|
| E1009 | At `737d9127`, a fresh O2 App and independent Product contract compile. The first package attempt fails because its old engine path no longer exists; `current-product-artifacts/summary.json` remains FAIL. A separate rerun uses the existing ripgrep 15.2.0 cache after verifying all four asset hashes against the unchanged reviewed lock. `current-product-artifacts-pinned/summary.json` records Full 17 and Coding 9 packaging, both setup blackboxes and both clean-environment package checks passing. | PASS for these artifacts and entry checks. The original failed attempt is retained. This is not full release acceptance; the later Core change requires a fresh final App. |
| E1010 | The same fresh standalone contract passes AST edit and all 24 formal readonly bridge cases in `current-product-artifacts-pinned/readonly-bridge/summary.json`. The full Core/recovery entry still fails at the stale-precondition scenario with `input_attachment.capacity`. | Bridge and AST PASS for the named artifact; complete Core FAIL. This does not turn earlier intermittent failures into a proven general fix. |
| E1011 | Core model resume, approval preflight and approval resume now retain their actual private Context producer in the existing control. The same original pending-consumer and real task-return witnesses govern collection; errors and unknown producers remain paid. `core-context-resume-typed-current/summary.json` passes all 49 Core tests, including two real shared-snapshot lifetime cases. The standalone Product rebuild succeeds, but full Core/recovery still fails at the same capacity boundary. | PARTIAL. Context lifetime coverage is extended; E1000 is not closed. The open initial-context preparer and Native Host/Broker Raw metadata consumers still need complete consumer proof. No budget, Source, permission or unknown-outcome guard changed. |
| E1012 | The original current-source Product test build reaches its 900-second cap in `product-eight-task-current/build.json`. The existing dependency staging path builds Host and then Product within their separate unchanged 900-second caps. `product-eight-task-staged-current/summary.json` inventories all 1,077 Product cases and executes the original eight-task/sixteen-Operation case once. It crashes in `gc-main-thread` at Runtime `CheckAndPush`. | GC-blocked, not PASS. This classifies the formerly unexplained physical crash on the new artifact; no workload or assertion was reduced. The other 1,076 inventory cases receive no runtime credit from this run. |

Read-only diagnostics at `737d9127` retain actual Raw metadata export call
stacks in `current737-prepared-metadata-diagnostic.log`. The shared Native
allocation ledger in `current737-bank-diagnostic.log` reconciles all 7,099
observations without an unknown identity. These are diagnostic facts, not DATA
return acknowledgements. The later Context scopes do not establish that all
Raw consumers have returned.

`current-product-lock-preservation` and `core-context-lock-preservation` keep
all generated lock bytes, hashes and diffs before guarded restoration of the
approved pins. The Core source hashes and exact executable hashes are in the
named build summaries. SDK/runtime sources and binaries remain unchanged.
Complete Core, final App/release, performance, remaining Product requirements
and supported-platform CI remain open. Refs #45.

The Context implementation and its tests are committed in `f7ea5c45`. The
49-case Core evidence applies to the same source bytes. The 105 Python
regressions and full original architecture entry pass in
`static-gates-core-context-final.json`, including documentation, dependency
pins, package inventory and library boundaries. Those checks do not change
the failing full Core or deferred GC verdicts.


## Owner failure transport and current distribution closure

This follow-up starts at `f28abba9` and uses the same pinned official SDK.
The source and executable hashes are recorded in each named evidence summary;
the subsequent commits preserve these tested source bytes. GC remains deferred.
No additional external provider request or SDK build was made.

| Evidence | Requirement, implementation and actual result | Status and remaining gap |
| --- | --- | --- |
| E1013 | The authenticated Owner can return its complete broker failure envelope after accepting a frontend. ACP previously replaced it with `owner.acp_frame_invalid`; CLI/RPC printed an unexpected-frame message. Both readers now use the strict existing eight-field broker error decoder through `decodeProductOwnerFrontendFailure180`. The original raw/DOM frame remains paid through the complete error consumer; a failed checked write retains it. `owner-error-final-current/summary.json` records successful Product/App compilation and all three new transport tests. The actual Coding ACP rerun in `owner-error-profiles-current/summary.json` preserves `owner.acp_frontend_close_pending`. | Error preservation PASS. The original server close failure remains open; decoding is no Source or cleanup acknowledgement. Full App has 43 cases: 41 PASS and two Runtime `CheckAndPush` GC errors, with zero skipped cases. |
| E1014 | The fixture operator now inspects the actual package before using its installation. It reuses Coding/Full bootstrap only when one real user-scope record matches the inspected identity and full package-tree digest, explicitly enables it and rechecks that same record. Four Python regressions cover absent, exact installed, changed-content and foreign-scope cases. Actual inspected-package fixtures pass the former duplicate-namespace point. | Fixture setup corrected. Coding provider profiles still time out at the original five-second limit. The same App with an empty diagnostic distribution passes both local HTTP profiles, but that package is not genuine Minimal. No production Registry rule or grant was relaxed. |
| E1015 | Current Coding packaging succeeds. Its original entry-mode gate still fails, most recently when a real operator list loses its Owner peer. A separate actual `launch --print` returns approval-required status 3. Explicit `never` on a fresh empty workspace rejects the required canonical initial-context read; a separate `trusted` probe still loses the peer. `owner-error-final-current/summary.json` and `launch-approval-contract-current/summary.json` retain those outcomes. | FAIL, not a successful authorized product path. No broad trusted mode, longer deadline or skipped assertion was added to the acceptance fixture. |
| E1016 | `current-distribution-closure-bounded/summary.json` rebuilds the genuine isolated Minimal source closure: 19 packages, 40 Registry/History unit cases and nine original offline CLI checks PASS. Its fresh portable Minimal package then passes all ten real Host contracts and all ten installed-model contracts, including Chat Completions, Responses, Messages, restart, missing credentials, partial replies and cancellation against local HTTP fixtures. | PASS for the named final Minimal artifact, not for external provider availability. Source closure and portable packaging remain distinct evidence. The packaged Minimal SHA-256 is `e5feb880bacb8b950d4954757adab8e80ec42eb0076cb9929ed907e353355021`. |
| E1017 | The same batch builds the current Full seventeen-package distribution from the newly compiled App. Full setup and clean-environment package checks PASS. A fresh standalone Product build passes AST edit and all 24 cases in the original formal readonly bridge gate. | PASS for these current artifacts and bridge cases. Complete Core/recovery still has the separately recorded capacity failure; this batch does not rerun or close it. |
| E1018 | At `f28abba9`, the original 100 cold-start samples and all 40 noncapturing TUI journeys pass, with candidate P50/P95 413.8/413.9 ms. The original seven plugin performance records also pass after using a verified short disk-backed home. Capturing golden still exits 1 after its first semantic marker and leaves an owned Broker for bounded cleanup. | PARTIAL. `current-app-f28-gates/summary.json` and `f28-short-home-gates/summary.json` retain both failed and passing stages. These samples are not the full activation, concurrency, output-load, memory and cancellation comparison, or final-source golden acceptance. |

The strict decoder and fixture changes add no database migration. Reverting
those changes restores the earlier error presentation and unconditional fixture
import. It does not resolve any underlying Owner, Core or GC failure. Existing
permissions, message bounds, timeouts and physical process witnesses are intact.

All 13 generated tracked dependency locks from this batch were saved with
original/generated bytes, hashes and diffs in `owner-error-lock-preservation`.
Guarded restoration checked the exact approved HEAD bytes before writing them
back. The approved dependency pins are unchanged.

Read-only broker diagnostics record only fixed source error codes and function
names. A debugger run that allowed a startup shell selected an ambient runtime
and is excluded from pinned-SDK evidence. With startup shells disabled, a
separate run observes a GC crash in the packaged runtime; another observes
`acp.workers_pending` and the original close failure. Neither debugger result
is product acceptance or proof that every disconnect is GC.

The remaining required work includes complete Core consumer retirement,
authorized Coding model/ACP/entry success, capturing TUI retirement, the full
performance matrix and all remaining Product/release and hosted CI gates.
The two previously authorized external calls remain failed. The PR is Draft
and the overall task is not complete.

The final static run in `static-gates-owner-error-final.json` passes all 109
Python regressions and the original architecture, documentation, dependency,
package inventory and plugin-boundary gates. This does not replace any failed
runtime gate above.


## Input attachment capacity classification

| Evidence | Requirement, implementation and actual result | Status and remaining gap |
| --- | --- | --- |
| E1019 | An actual Native shared-bank refusal was returned through the permission-denied resource helper. `HostToolInputAttachmentOwner.acquire` now catches `LogicalJsonPayloadError` separately and returns `BudgetExceeded` with the unchanged `input_attachment.capacity` code. Both original retry/fallback flags stay false. Two real-bank tests prepare a readonly call through the actual Pipeline, then exhaust the initial floor or the existing 64 MiB growth invoice. They verify precise attempt refunds and restoration of their own pressure leases. Both fail the kind assertion before the fix in `attachment-budget-pipeline-red/summary.json` and pass after it in `attachment-budget-green/summary.json`. The original complete Host isolation gate passes **274/274**, without skips, in `attachment-budget-host-full/summary.json`. | Classification regression PASS. No quota, alternate bank, Source construction, admission, cleanup witness or retry right changed. This does not fix the retained-consumer capacity deficit. |

A fresh standalone Product build succeeds with this Host source. The original
complete Core/recovery contract still fails at the same stale-precondition
scenario. Its actual ToolResult now contains `error.kind = budget_exceeded`
and `error.code = input_attachment.capacity`; it is no longer mislabeled as a
policy refusal. `attachment-budget-core-current/typed-budget-readback.json`
checks that exact nested JSON. The original summary's first probe searched the
legacy `error_kind` shape and is retained with its false observation; the raw
failing contract output is unchanged. Complete Core remains FAIL.

The first new-test compile attempt is retained separately in
`attachment-budget-red/summary.json`. The corrected test uses the real
Pipeline and existing Runtime/SQLite fixture rather than constructing a
nonpublic Prepared invocation. Both tracked generated locks from the final
builds are saved and restored against their exact approved HEAD bytes in
`attachment-budget-lock-preservation`.

No public API, database schema or dependency pin changes. Reverting this fix
restores the old permission-denied classification; no data migration is needed.
The earlier distribution evidence names the artifacts built before this
error-branch change. It remains evidence for those artifacts and does not
claim final release validation of a newer App. E1013-E1018's open Core,
Coding/ACP/TUI, performance, Product and release requirements remain open.

After these runtime gates, only the pressure-test comment was corrected to
name its existing canonical Runtime fixture. Executable test and production
source are unchanged from the recorded successful Host build.

`static-gates-attachment-budget-final.json` also passes all 109 Python
regressions and the original architecture, documentation, dependency and
inventory gates for this source.


## Current Core numeric accounting boundary

E1020 records a read-only check of the exact E1019 standalone executable in
`core-bank-numeric-current/summary.json`. Constructor disassembly verifies the
fields read by the debugger, and debugger startup shells are disabled. At the
last input-attachment growth, the existing bank has capacity 150,994,944 bytes
(144 MiB), charged bytes 101,021,296 and a requested growth of 50,331,648 bytes.
The total exceeds that unchanged capacity by 358,000 bytes. This identifies
the actual refusal; it grants no return witness or permission to raise quotas.
The protocol reference and attachment comment now describe the existing
144 MiB product quota. Historical 128 MiB saturation evidence stays unchanged.

The separate fixed-buffer origin trace does not reconcile its 104 tracked
entries with the actual bank count of 25. Its `validation.json` explicitly
marks it `INVALID_AS_LIVE_LEDGER`. Those groups are not proof of outstanding
owners or leaks and must not drive a refund or lifecycle change. The numeric
capacity check is independent of that incomplete acquire/close trace.

These are diagnostic observations, not a passing Core contract. The existing
E1019 raw failure and all open requirements remain. Only documentation and a
source comment change after the tested E1019 production code.


## Native JSON codecs and complete Product case diagnosis

E1021 retains the unsuccessful read-view DATA experiment in
`readview-input-experiment-preserved/disposition.json`. The fresh Core contract
still fails at the original stale-precondition attachment refusal. Its numeric
charge does not decrease. All experimental adapter APIs and source changes are
withdrawn. No cleanup observation becomes a DATA acknowledgment.

E1022 qualifies every original Product test identity on the preserved unit
executable `83409b853a851fcdb2da7aec1d6d83557f6173d3e8715b8a40f5d0e78ce9d137`
from `b5787b62`. `product-full-readback-current.json` records 1,077 independent
cases: 489 pass, 581 have collector or runtime GC signatures, two crash without
a proved GC classification, and five fail by assertion or exception. Every
case has closed physical custody. These are individual original cases with
unchanged limits. The formal gate stops at case 11 and does not pass. The first
900-second compilation timeout and a later 509-second cached compilation both
remain recorded. A missing Shell fixture variable and a rejected zero-case
diagnostic are retained separately, with no Product acceptance credit.

E1023 fixes a deterministic codec mismatch. `encodeAgentValue` produces JSON;
`decodeStoredValue` reads the internal tagged Store format. The selected Shell
frontend and four Shell/Eval bridge copies now use bounded JSON parsing, with
the original duplicate-key rejection, depth, argument and observation limits.
`native-json-final-current/summary.json` passes a real public Product contract
on executable `fd3109ebcd5738d462fe31b988f906f2e2b018e1ed72bf3a496a28b48ac30309`. It installs and starts the
Native package, tests the direct missing-timeout frontend and explicit seconds
and milliseconds, preserves caller arguments and UTF-8 output, rejects the exact
original invalid or over-profile timeout codes before any Operation, and checks
one startup plus three root/child pairs: seven completed canonical Receipts.
The new entry is `AXYNDRA_PRODUCT_CONTRACT_SCOPE=native-json-frontend` in the
existing `support_tests/product_contract` executable. This is local real-process
proof, without an external provider or a final App release build.

E1024 corrects original fixture premises. The three context-update paths use
the installed Native Workspace read rather than the removed bare name. They
require one actual ordinary root and its exact read-view child on the same Run.
The queued Pi cancellation fixture waits for the actual abort signal instead
of racing its first result against a 500-millisecond completion delay. Task
schema checks cover both exported single/batch branches and the original
one-through-eight bound. No original test identity, permission, assertion goal
or production deadline is removed. Fresh Product test compilation passes in
787 seconds. Of ten affected unit cases, one passes and nine fail with explicit
GC stacks in `shell-json-context-regressions-current/summary.json`. Their
behavioral acceptance remains incomplete.

E1025 preserves the broader Native baseline failures. After the Task schema
correction, `eval-runtime-config` passes its earlier Python execution,
persistence, cell-timeout and post-timeout assertions, then fails at reset with
`tool.not_found`. The actual original Python service reports `released` and
`cleanup_acknowledged=true` after the separate cancellation fixture. This is an
observation, not a proved cause or authority to restart it automatically. See
`native-baseline-status-diagnostic-current/summary.json`. The full Core,
unknown crashes, 63 MiB oracle allocation, Native resource-bound startup,
Coding/ACP, captured TUI, performance comparison and final release requirements
remain open. GC work stays deferred by the user.

The final static batch passes all 109 Python regressions and the original
architecture, documentation, dependency and inventory gates. The architecture
gate also passes with the new regression source staged (2,956 tracked paths).
See `static-gates-native-json-final.json` and
`architecture-native-json-tracked.json`. These checks do not replace the open
Product, performance or release acceptance.


## Passive Registry contention and remaining Eval startup failure

E1026 fixes an observed permanent withdrawal of an idle Native service during
an independent Product's Registry write. `PluginRegistryExecutionPin.current()`
returns `plugin.registry_busy` while a real writer holds its fence. That result
does not revoke the pin. The service monitor previously interpreted every
unsuccessful check as revocation. A separate process-lease monitor did the same.
Temporary probes identify both paths and are withdrawn from the final source.

The generation, endpoint and manager now distinguish that exact busy result
for passive observation. The lease monitor also defers its passive recheck on
that result. Both monitors retain their original polling intervals and finite
lease deadlines. All other errors, physical closure, cancellation, expiration
and actual Registry revocation still withdraw the service. `isClosing()`,
`available()`, publication and effect admission retain their strict checks.
No busy result grants permission or authorizes an invocation.

`AXYNDRA_PRODUCT_CONTRACT_SCOPE=eval-registry-contention` exercises actual
installed packages through public Product and Application paths. It preserves
an original Python service's state across an independent package installation,
activation and accepted-cell cancellation. It then resets the original service
with exactly one startup Operation. A real Registry disable rejects the next
cell before another child Receipt. The disabled record view is closed.
`eval-monitor-regression-red-current/summary.json` fails the preservation
assertion with the original production monitors. The same contract passes on
the corrected monitors in `eval-monitor-owned-disable-current/summary.json`.
The latter executable is `79d67cedd2dc64b384d1b80047b54c8dd7066dd38ab985deacc8d5c17c72aee0`.
The original complete Host isolation gate also passes **274/274**, without
skips, in `eval-monitor-host-full-current/summary.json`.

E1027 bounds test setup's actual Registry mutation retries at 16 attempts with
10-millisecond pauses. Only `plugin.registry_busy` qualifies: that writer-fence
refusal precedes materialization and publication. Each refused owned error is
closed. Other errors fail immediately. Startup, cells, accepted effects and
Unknown results are never retried. Original service limits, capability checks,
assertions and case deadlines stay unchanged. This prevents read-fence
contention from becoming an unrelated fixture-construction failure.

E1028 keeps the broader Eval acceptance open. The original flow now passes its
Python reset and reaches JavaScript startup, which returns
`plugin.lifecycle_start_unknown`. The separate `eval-languages` scope runs the
same original language assertions to isolate this boundary. Both scopes fail
in `eval-monitor-fixture-fenced-current/summary.json`; neither is a passing
whole-flow gate. The contention-only final rerun does not replace them.

The actual sandboxed Bun process terminates with `SIGABRT`, as recorded in
`eval-languages-fenced-physical-current`. A standalone replay of the same
sandbox and original 512 MiB address-space, eight-process, file and CPU limits
reproduces that exit with stdin held open. It emits READY, then aborts after
about one second. Immediate EOF incorrectly appears healthy and is not
persistent-service evidence. `eval-js-allocation-probe-current` records failed
memory mappings (`ENOMEM`) and a final thread creation (`EAGAIN`) before the
abort. Bun `--smol` and the tested GC worker options do not resolve it. None of
those options is retained in source or operator configuration. This is a Bun
process failure, not evidence of a Cangjie GC crash. No resource limit is raised
to turn it into a pass.

| Requirement | Final status in this follow-up | Remaining evidence |
| --- | --- | --- |
| Preserve idle services across transient Registry writer contention | Acceptance passed for the real regression and full Host gate | Full Product acceptance remains separate |
| Keep actual revocation, cancellation and effect admission strict | Real disable and independent cancellation assertions pass | No new authority or recovery bypass introduced |
| Complete the original Native Eval baseline | Partial; Python reset advances, JavaScript startup fails | Compatible persistent interpreter execution under the original limits, then remaining language assertions |
| Complete all non-GC PR requirements | Incomplete | Existing Core capacity, unknown crashes, oracle allocation, resource-bound startup, Coding, ACP, TUI, performance and final release gaps |

The user-deferred Cangjie GC work remains incomplete. No SDK component, Native
C launcher, quota, Source, seal, receipt authority or DATA acknowledgment changes
in this follow-up.

The follow-up code is committed as `20cc39b0`. Exact source hashes in both the
final real regression and full Host reports match that commit, as checked in
`eval-monitor-source-readback-current.json`. The 109 original Python regressions
and the architecture gate pass in `static-gates-eval-monitor-final.json`, with
2,957 tracked paths. Its documentation, dependency, inventory and boundary
checks pass. These checks do not replace the open broader acceptance gates.


## Current O2 Coding artifact and Owner crash evidence

E1029 rebuilds the App from `ca726b3d`. The first whole-App compilation hits
its unchanged 900-second cap in `monitor-coding-entry-current/summary.json` and
remains a failure. The existing dependency-staging path then compiles Product
in 833 seconds and App in 320 seconds, each within its own original 900-second
cap. `monitor-coding-staged-current/summary.json` records successful O2 App
compilation and actual nine-package Coding assembly. The source executable is
`7180ef5939b5aa1abc942e8c58e0fa1300fdfab25741ad24eee3c16d51aa7146`, and the
packaged executable is
`26a9764c468b1aef33d7e827f3dbf0f2401bbe3d005a66fc498bc5b17d6f3523`.

The original blackboxes still fail: the local HTTP profile exceeds its
five-second invocation limit, ACP does not return its expected frame and retains
`owner.acp_frontend_close_pending`, and CLI read exceeds ten seconds. All actual
process custody closes. No deadline, fixture assertion or permission changes.
`monitor-coding-lock-preservation` retains the nine generated lock files before
restoring the approved pins. This artifact does not pass complete Coding or
final release acceptance.

A separate diagnostic repeats the original operator setup and readonly command
on that exact package. Its first long-path attempt rejects the Unix socket
length and receives no acceptance credit. The short-path attempt in
`coding-read-short-physical-current` reaches an actual Owner `SIGSEGV` followed
by `owner.peer_disconnected`. Metadata for that exact executable and process
shows `gc-main-thread`, `GCTib::ForEachBitmapWord` and `Mutator::GcPhaseEnum`.
`owner-core-classification.json` records metadata-only inspection. Core memory
and credentials are not read. This identifies a GC failure for that diagnostic,
not a cause for every earlier timeout. The user's GC deferral remains in force.


## Narrow initial preparation input

E1030 adds the optional `InitialContextPreparationInputPort159` composition
interface. Its input contains only Thread and Run identity, epoch, immutable
context projection and cancellation. It contains no ModelLane, Catalog/tool
snapshot, Source or invocation grant. The existing open preparation interface
and constructor parameters remain available. Core still gives an old port its
independently paid active snapshot.

Product's concrete initial preparer uses the narrower input. Its single,
multiple, document, window and journal preparation paths retain the same
identity/projection data instead of the whole active ModelLane. Existing
non-initial context-read helpers keep their old signatures and project into the
same narrow implementation. Product builds a powerless preparation Context for
its pure selection helpers. Actual reads continue through the original Core,
policy, approval, Operation, capability and Store paths.

This avoids allocating a full active-snapshot fork that the preparer does not
need. It does not attest that every open continuation returned its DATA. The
proposed automatic Core Context retirement is withdrawn; all original
conservative Context payments remain. No generic closed flag, receipt, cleanup
observation or input-interface type becomes a retirement witness. The exact
scope and withdrawn proposal are recorded in
`initial-context-input159-source/disposition.json`.

`initial-context-input-conservative-core-current/summary.json` passes all
**49/49** original Core tests without skips. The actual Product contract in
`initial-context-input-sequence-conservative-current/summary.json` uses the real
installed Native Workspace Catalog and Skills provider. Metadata and selected
body each require their own canonical approval and distinct Operation. Before
body approval, one actual read Receipt exists and no model Attempt exists.
Afterward exactly one Run, two completed read Receipts, one safe cut and one
model Attempt carry the exact immutable instructions. Changed configuration
rejects the first pending read before a completed Receipt or model Attempt.
The public entry is `AXYNDRA_PRODUCT_CONTRACT_SCOPE=initial-context-input` in
`support_tests/product_contract`.

The initial provider-only diagnostic entered the historical unowned fixture
observation path. Its borrowed last-request observer could not prove model
content. Those failed attempts remain recorded. The final test adds the real
ordinary Native Catalog so it exercises the funded snapshot boundary. It keeps
the complete positive and changed-configuration assertions. Source readback in
`initial-context-input-product-source-readback.json` verifies every tested file;
the only later difference is an exact explanatory comment in Core.

The original continuous Core/recovery build succeeds in 605 seconds, but its
execution still fails at the stale-precondition scenario with
`input_attachment.capacity`. `initial-context-input-complete-core-current`
retains the failure. The nested error has `kind=budget_exceeded`; the diagnostic
runner's old `error_kind` probe was false and is preserved alongside the exact
JSON readback in `typed-error-readback.json`. No assertion is lowered and no
quota changes. The full capacity, other Raw consumer retirement, final App,
release and performance requirements remain open. The current O2 artifact in
E1029 precedes this additive input change and is not final-source release proof.


The narrow-input code and regression are committed as `0c1bbfdd`. Exact Core
and continuous-contract source hashes match that commit in
`initial-context-input-commit-readback.json`. The real two-stage Product
executable is
`1c1a558d79fc78e78e9e91f45ca057ab36238dd0880614f31d87a8378b29a753`.
`static-gates-initial-context-input-final.json` passes all 109 original Python
regressions and the full architecture, documentation, dependency, inventory and
boundary gates with 2,958 tracked paths. Existing open preparers and persisted
schemas are unchanged; no database migration or plugin wire-protocol upgrade
is required. Roll back this whole coherent input commit if needed. None of
these results closes the original complete Core or final release requirements.


### Explicit Bun startup under the original service limits

E1031 changes the support frontend's explicitly authored Bun backend argv to
`--eval` with a `pathToFileURL` import of the installed JavaScript runner. The
standalone interpreter checker uses the same launch. This is an operator-profile
correction, not an Eval-specific Host dispatcher or command rewrite. The
installed Native endpoint and runner bytes, public tool schema, service
configuration, approval, Root/Source, Receipt, quotas and deadlines are unchanged.
The public example is in `plugins/eval/README.md`.

`eval-bun-runner-regression-final/summary.json` retains a failing file-launch
control under the same 512 MiB address-space, eight-process, 64-FD, file-size and
CPU limits. Inline import passes the real persistent wait, state/reset,
async/error recovery and timeout/retirement assertions, including an installed
module path containing spaces, quotes, Unicode and a fragment character. The
complete current runner suite executes 30 tests: 23 pass and seven Julia tests
are skipped because Julia is unavailable. The initial new async assertion used
an expression without returning from the runner's existing async wrapper; the
corrected test explicitly returns its awaited value. No runner semantics change.

`eval-bun-import-product-final/summary.json` records a fresh fixed-SDK build and
three uninstrumented public Product contracts: `eval-registry-contention`,
`eval-languages`, and the original complete `eval-runtime-config`. All pass with
the original assertions and limits. The complete contract takes 59 seconds.
Its executable SHA-256 is
`7f3c65c48cde992a8029aa4022373ec04b892afe392be6193ebea551d9f21c38`.
`eval-bun-import-source-readback.json` matches all tested source files; the only
subsequent code-file difference is an explanatory comment.
`static-gates-eval-bun-import-final.json` passes the 109 Python regressions and
full architecture, documentation, dependency, inventory and boundary gates.
Earlier Unknown failures
remain in `eval-bun-import-product-current` and the physical diagnostic. A
capacity-constructor probe observes no capacity exception in its run; it is not
an allocation ledger. A later diagnostic build passes the complete contract and
three additional independent fixtures. Temporary Host diagnostics are restored
byte-for-byte before the final build. These results do not establish a cause for
every earlier intermittent Unknown, or complete the wider performance matrix.

The unrelated readonly canonical-metadata closed-marker experiment is withdrawn:
the original complete Core still fails `input_attachment.capacity`. Its source
and failure remain in `readonly-canonical-metadata-source` and
`readonly-canonical-metadata-core-current`. The read-only growth stacks preserve
real budget observations without claiming an identity ledger or a safe refund.
No quota is raised and no Raw consumer is acknowledged by a generic flag.

Existing lifecycle grants keep their exact argv. To adopt or roll back the Bun
launch, update the explicit operator profile and start a fresh service through
the ordinary approval path; do not replay an Unknown cell. GC remains deferred.
The 63 MiB Memory oracle OOM, complete continuous Core, final App/release and
remaining performance/blackbox requirements are still incomplete.


### Relocated Minimal uses its public CLI

E1032 corrects the shared clean-environment check for Minimal. The original
check passes App-only `--fixture --print /help` arguments to every distribution;
the real Minimal executable rejects them with `minimal.option_invalid`.
Minimal now uses its documented `--help` entry and must expose both plugin
management and canonical tool invocation. Coding and Full keep their original
fixture help entry. The 20-second command deadline, isolated runtime PATH,
relocation, provenance hashes, credential-free environment and actual process
custody checks remain unchanged.

`current-clean-environment-regression/summary.json` passes the actual relocated
Minimal, Coding and Full packages. The failing Minimal control is retained in
`current-release-artifacts/minimal-clean.log`; it is a test-entry error, not a
reason to add fixture options to the production Minimal CLI. The original
Minimal empty/offline matrix also passes all six actual cases in
`current-release-artifacts/minimal-empty-offline.log`.

The current uninstrumented App rebuild has SHA-256
`0306a939bff8d46fe6b634acdcf0774418218bf1f732d0c29114b272e227093b`,
identical to the earlier clean build at `0766ca0`. Minimal's source executable is
`73a17be083c507f87a96f659e8e7e938bff72b3cbd136cdf05efc16957ed06b2`
and its relocated executable is
`93c2472466ef4b11a9a8f9bdaa4c7f02c550aebbe9edcb0dd79219933bae31a5`.
The named Coding and Full host executable is
`c9e5f6b7d835943b8ba211798b41ef8f66a555a669a6cf12aa977e57150c9ae2`.
These are entry and artifact checks, not complete Core, model, TUI, performance
or release acceptance. No production API, persisted schema or migration changes.


### Standalone Workflow keeps release optimization

E1033 fixes the independently packaged Workflow dependency build. Root workspace
builds apply `-O2` to dependencies, but the standalone Workflow manifest did not
inherit that override. Its retained build history records yjson's declared
`-O0`. The actual Full endpoint fails two of the original 172 protocol tests at
`document.data_timeout`: one complete 8 MiB document and two complete 4 MiB
continuation slots. The original five-second query deadline and exact samples
are retained in `current-native-protocols/workflow.log`.

`workflow-large-original-phases/summary.json` repeats each unchanged case three
times. Uploads consume 3.9–4.4 seconds and computation another 0.6–0.7 seconds;
one repeat fails and five finish near the limit. The temporary numeric-only
probe in `workflow-large-internal` observes parsing and hexadecimal append costs.
Both instrumented files are restored byte-for-byte before the final build.
These measurements locate costs; they do not isolate yjson as the only cause.

Workflow now declares the same package-level `override-compile-option = "-O2"`
already used by the MCP plugin and host workspace. No business algorithm,
dependency pin, deadline, payload, quota or Source contract changes.
`workflow-actual-compiler-options/summary.json` retains the actual verbose
compiler commands: all eight dependency/entry commands end their optimization
flag sequence with `-O2`; yjson's earlier declared `-O0` remains visible before
the override. The initial log selector expected an absolute compiler path and
found no commands. Its failed audit is retained; offline qualification reads
the actual PATH-based `cjc` commands without rerunning or changing compilation.

`workflow-release-regression/summary.json` passes the original complete
**172/172** protocol cases. All six repeated original large cases pass in
0.59–0.76 seconds with the same five-second deadline. The independent packaged
Workflow executable is
`1a647a27d2b6df01441946c8e2c9f17ef0412495d8494ad5851076c4727a7a6a`.
This is a controlled build-configuration comparison, not a complete Product
performance matrix or a claim about every startup timeout.

`current-release-workflow-integration/summary.json` records fresh actual Coding
(nine plugins) and Full (17 plugins) assembly. Both pass their original
clean-environment, operator setup and complete 172-case Workflow checks. Both
contain that exact tested Workflow executable. The other 15 checked Full
endpoints match the exact binary hashes of their **429 passing protocol cases**
in `current-native-protocols/summary.json`. Together these establish 601 protocol
cases across 16 endpoints; they do not replace the separate Memory application
or Host/Core authority requirements. The original two Workflow failures remain
in the earlier report. App bytes remain those recorded in E1032.

No database migration or protocol change is required. Existing installations
keep their exact old package and grants. Adopt or roll back the coherent
Workflow package through the ordinary plugin update and operator binding/
approval paths; never treat the changed content digest as preserving an old
Source grant. Complete Core capacity, deferred GC, unknown failures, capturing
TUI, broader performance and complete release acceptance remain open.

The coherent Workflow change is committed as `a90c3c8d`; the Minimal check is
`0a7b7336`. `current-release-static/static-gates-release-final.json` passes all
109 original Python regressions and the complete architecture gate, including
documentation, dependency pins, package inventory and library/UI boundaries.
`release-source-readback.json` binds the tested build manifest and clean-entry
check to these commits. Later changes in this checkpoint are documentation only.


### Current fixed-SDK crash boundaries

E1034 records current physical evidence without expanding the user's GC scope.
The official November 4 SDK and StdX are restored from the same approved archive
hashes after the earlier temporary source/SDK trees became incomplete. The cause
of that external loss is unknown. An independent checkout restores exact
`0766ca0`; the original user worktree is not reset or overwritten. No SDK,
runtime, compiler, standard library or StdX component is built or patched.

`memory-current-compatible-staged/summary.json` completes all six normal O2
dependency/Product compilations within each original 900-second cap. The current
full Product unit executable is
`5cd59e4a81b5ca1607d39da4e38d380c407febde2aae71a10637a6ac28cec351`.
The original 63 MiB Memory case then fails with an explicit
`gc-main-thread`/`CheckAndPush` SIGSEGV before its historical oracle OOM can be
assessed. `memory-final-classification.json` preserves both conclusions: this
attempt is GC-blocked; the earlier `OutOfMemoryError` remains unresolved and is
not waived. Original sample bytes, heap, assertions, oracle and case deadlines
are unchanged.

`current-coding-physical/owner-core-metadata-classification.json` identifies
collector frames in the two actual current-package Owner crashes observed
while setting up the profile and CLI entry tests. ACP's readonly durable
snapshot has zero Runs, model Attempts and Operations before its original
five-second timeout. A separate parent-debugger diagnostic in
`acp-owner-parent-stack` observes SIGSEGV in `GCTib::ForEachBitmapWord` while the
actual Owner loads installed state, with only packaged fixed-runtime libraries
loaded. It captures no arguments, locals or core memory. The earlier debugger
attempt used its extra startup shell and loaded an ambient SDK; that attempt is
excluded from fixed-runtime causal evidence. The corrected diagnostic disables
that startup shell. It is not a passing timing test and does not prove that
every historical ACP timeout has the same cause.

The current GC-bound attempts stay incomplete under the user's deferral. The
separate complete Core `input_attachment.capacity` failure and unclassified
historical failures remain distinct; no GC observation releases a DATA payment,
changes a quota or supplies a consumer acknowledgment. PR #49 remains Draft.


### Reconciled current Core accounting remains diagnostic evidence

E1035 records `core-stable-ledger/validation.json`. A temporary numeric probe
uses lock-protected physical allocation IDs and the existing derived lease IDs
at the actual mutation sites. All **167,294** recorded counter and lease SUM/
count checks reconcile. The four instrumented source files are restored
byte-for-byte, with their hashes in `core-stable-ledger/source/manifest.json`.
No probe code enters the release build.

At the refusal, the actual Native bank has capacity 150,994,944 bytes, charged
101,022,976 bytes, and requested growth 50,331,648 bytes. Growth would exceed
the limit by 359,680 bytes. Its Registry root costs 67,263,744 bytes with 482
live leases whose invoices sum to 62,488,944 bytes. Two other logical groups
each cost 16,777,216 bytes. There are 25 fixed groups totaling 204,800 bytes.
Of the tagged Prepared metadata children, 43 remain live with total invoices
of 12,080,944 bytes. These are accounting observations, not proof that any
consumer returned or that any payment may safely retire.

The earlier fixed-buffer trace with 104 tracked entries versus an actual count
of 25 remains `INVALID_AS_LIVE_LEDGER`. This new trace does not validate those
old records or replace the original capacity failure. It does not authorize
larger quotas, guessed acknowledgments or refunds. Original three matched
PTC/Native samples, deadlines and Source contracts remain unchanged.


### Public HTTP configuration retires its temporary descriptor copy

E1036 corrects the public owned-descriptor overload of
`loadHostPluginHttpConfiguration` in
`agent_host_runtime/src/registry_metadata_copy.cj`. It now uses the existing
private `hostReadonlyConfiguration159` frame. The concrete loader compares the
Registry arguments with a separately parsed operator document; the returned
configuration uses that document's name and package digest. It exports no
Registry descriptor alias. Unknown exceptions still retain the original
payment conservatively.

This narrows the earlier E84 analysis: the public HTTP loader is a verified
exception to its blanket description of the four legacy descriptor consumers.
The remaining raw descriptor, launch and lifecycle consumers retain their
original conservative payments. No generic close flag, Source replacement,
quota change or inferred consumer acknowledgment is introduced.

The new public API regression executes 16 valid and 16 malformed operator
configuration loads. It checks the exact namespace, digest, Unicode payload,
current-configuration validation, malformed error code, and actual retained
SUM/lease count after every call. Returned configuration remains readable after
the original record and Registry scopes end, under the independent fixture
payment. The complete fixture also refunds its own original bank allocation.

`public-configuration-red/summary.json` records the unchanged loader failing:
each call retains another 330,880 bytes and one lease. The same case passes in
`public-configuration-green/summary.json` after the fix. The initial missing
receiver import and stale enumeration attempts are retained as failures, not
acceptance. The stale executable was rejected before executing the new case.

`public-configuration-full-host-cached/summary.json` passes the unmodified full
Host isolation gate: **275/275**, no failures, errors or skipped cases. Its
unit executable is
`2ba154930c04175ba632af7d5617d33b312a8a9b3b9d68dc5bb9e90c4c86a332`.
Original 900-second module, 60-second case and physical process limits remain.
A preceding attempt spent much of that same module budget rebuilding and timed
out at case 198. It remains failed, despite that case's body reporting success.
The passing run reuses the exact freshly built unit artifact through a
namespace-only target-directory bind; source and compiled inputs are unchanged.

`public-configuration-complete-core/summary.json` then rebuilds and runs the
original complete Core/recovery contract with the fix. Compilation passes, but
the original stale-precondition assertion still receives
`input_attachment.capacity` instead of `application_plan.precondition_conflict`.
The actual uninstrumented contract executable is
`b2d687bb743bde165413635e1c16a9c8a96d7b22306a973cd661aed5b5695e46`.
This correction therefore does not close the complete Core capacity gap.
Public signatures, persisted data and wire protocols remain unchanged; no
migration is needed. PR #49 remains Draft and overall acceptance is incomplete.


`public-configuration-app-staged/summary.json` records all nine normal O2
production build stages passing within their original 900-second caps. The
preceding monolithic Host build timeout remains in
`public-configuration-app-build`. New uninstrumented source App bytes are
`39e14bee51847ce4798d3466276bc65964635e5271d51ccfc2e0bd735bee20b1`;
Minimal bytes are
`07f4433aec3f73eea9558ac40e29b73d839d2e9c4f6aa7ab87537c60b9d92e30`.
These supersede the earlier E1032 App/Minimal artifacts for this loader fix.

`public-configuration-release/summary.json` passes fresh actual Minimal, Coding
and Full assembly and their original relocated clean-environment checks.
Minimal's six-case empty/offline matrix and Coding/Full operator setup pass.
Both Coding and Full also pass the complete 172-case Workflow protocol. Their
other 15 tested Native endpoints exactly match the binaries of the existing
429 passing protocol cases. This preserves the bounded 601-case protocol
evidence without claiming complete Product or Memory application acceptance.
The packaged Coding/Full App is
`ca3b0d8cbebdf509c39a63fad95e0e047ef35dab20c7c5e8b8a890350d4a9033`;
packaged Minimal is
`adae1cae29bbd68c2b1c105766821219165763563c9a7669beb3be846217b78c`.
No provider calls or SDK component builds occur in these checks.

`public-configuration-static/static-gates-release-final.json` passes the original
109 Python regressions and complete architecture gate on this final source and
regression. Generated dependency locks are preserved with hashes before
restoring their approved bytes. No dependency version changes are committed.


### Actual Prepared exports keep their original payments

E1037 extends the temporary numeric diagnostic in
`core-custody-ledger-qualified`. All **167,270** actual counter and lease
SUM/count checks reconcile. Its ownership tags distinguish private Catalog
snapshots, real Prepared consumers and actual producer returns. The trace
observes Prepared metadata remaining held after producer return because the
legacy call/metadata getters export aliases. All eight temporary source files
are restored byte-for-byte; the probe is not a shipped implementation.

`core-export-call-stacks-loaded/stacks.json` records 2,870 getter hits across
86 distinct function-name stacks on the exact diagnostic executable. Actual
Host/Broker validation, execution and Pipeline fallback paths appear there.
The parent debugger disables its startup shell and loads the fixed SDK. It
reads no arguments, locals or core memory. The earlier attempt missing the
native dynamic library remains failed and supplies no stack evidence.

These observations locate real consumers. They do not prove those exported
aliases returned, authorize closing their payments or solve the original
complete Core capacity assertion. No generic closed flag, getter exemption,
quota increase or Source substitute is introduced.


### Captured headless frames have a separate concrete producer

E1038 adds `HeadlessCapturedFrameScope` and
`AppTestRunner.runWithCaptureCustody` in the local cjtui overlay. The scope
registers actual Terminal, TestBackend, command and AsyncRuntime objects. It
rejects retirement during an active runner and later clears only those actual
internal references. Exported result Buffers and snapshots remain readable;
internal retirement conveys no output acknowledgment or bank refund. The old
noncapturing `runOwned` capture rejection remains unchanged.

The concrete `HeadlessDisplayProducer180` owns the complete private golden
inspection helper and the exact stdout writer. It combines real internal
retirement with whole-helper return, output flush and the existing backend
retirement checks before Screen can clear its copied data. Legacy headless
callers retain their old path. Unknown exceptions and backend obligations stay
conservatively held.

Native Todo now uses bounded `HeadlessScript.waitUntil` steps to pump the
ordinary input/update/async loop. Only a reached state is captured during a
wait, so polling does not accumulate duplicate raster frames. Timeout aborts
later scripted input and conveys no task/Data acknowledgment. The Native
fixture uses ordinary selection and Enter keys for AllowOnce on the current
expected ContextRead/Todo request. It writes no approval, Source or Receipt.
The original semantic assertions and 45-second TUI process deadline remain.
Operator CLI preparation retains its separate original 20-second command cap.

The explicit `--workflow-package` fixture option uses the existing actual
inspect/import/enable helper. It binds the exact installed content digest and
Todo document rights, rejects another existing selection, and does not copy or
fabricate Registry records. `scripts/release_gate.sh` supplies its already built
Workflow package. Cards/ask require no such installation.

`captured-frame-await-focused/summary.json` passes all 11 focused O2 lifecycle,
async-completion, timeout and ordinary-input regressions. The full matching
cjtui inventory passes **556/556** in
`captured-frame-await-full-core/summary.json`. The earlier first full run used
the workspace directory and failed five relative-fixture cases; the same ELF
passes in the actual Core package directory. Those failures remain recorded.
The local overlay manifest is updated without changing its upstream identity.

The first invoice conservatively counted raster-sized extents for snapshots
and carried early unowned fixture captures into a later real display invoice.
`captured-tui-summary-coding-release` reaches actual Todo read/save completion
but then rejects a raster invoice. The correction separately measures the
actual exported Buffer, both retained snapshot strings and container backing.
It preserves the existing Buffer/text meters and all real retained peaks.
Only the concrete Screen can report the same absence of copied display owners
already recognized by its original payment API; that observation grants no
Source, refund or early retirement. An earlier real invoice never decreases.
`captured-frame-invoice-focused/summary.json` passes **13/13**, including both
payment-transition controls. The matching full inventory now passes **558/558** in
`captured-frame-invoice-full-core/summary.json`. The actual source App also
passes the unchanged Todo golden in `captured-tui-invoice-existing-todo`: two
new completed Runs, six committed Operations and six completed Receipts, with
no model Attempt. Earlier failures remain recorded.

Actual Coding packaging, clean-environment and setup checks pass in
`captured-tui-await-coding-release`; cards, default and ask pass without owned
survivors. Initial prompt and Todo remain failed. The later save-summary build
again passes cards/ask; two operator preparations fail with peer disconnection.
These are distinct attempts and are not combined into a complete passing gate.
The initial prompt's cause remains unclassified; no historical timeout is
relabeled as GC without physical evidence.

The actual fixture database is `sessions/fixture/state.db`, distinct from the
maintenance CLI's `sessions/state.db`. The readonly inventory proves Todo read
and save complete as two Runs, six committed Operations and six completed
Receipts, with revision 1 and no model Attempt. The earlier maintenance-only
snapshot is not TUI execution evidence. Physical cleanup after a failed golden
is not consumer acknowledgment or release acceptance.

This local extension adds an `Await` alternative to public `HeadlessStep`.
Consumers matching that enum exhaustively must handle the new alternative and
rebuild with the coherent overlay/host. Old-binary compatibility is unverified;
do not mix independently compiled old/new TUI libraries. No persisted schema or
Native wire protocol changes, and no SDK component is built. The overall TUI
acceptance remains PARTIAL, not complete.


### Cold Todo hints and explicit execution use different readiness paths

E1039 fixes the cold Owner's selection order. Help and completion describe a
syntactically valid explicit operator Todo binding without activating plugins.
They do not claim an active contribution or grant execution. An explicit editor,
replacement or Todo command uses the original shared cancellable execution
readiness and atomically frozen Catalog before the complete existing selection.
The frontend cancellation and selected session remain checked across startup.
Missing/malformed selection retains its original error without starting unrelated
contributions. Digest, generation, document rights and Source checks remain.

The new public cold-Owner regressions install through actual APIs, close the
eager setup runtime and reopen the persisted installation in Owner mode.
`cold-todo-red-qualified` records the hint/help assertions failing before the
fix; its other two cases crash in collector frames. `cold-todo-green` passes
the hint/help case with generation zero and no Run, Operation or model Attempt.
The actual Native command and Native cancellation cases remain GC-blocked.
They are not counted as passing and are not repeatedly retried.
`cold-todo-early-cancellation` independently passes the smaller public test
without installed packages, proving cancellation precedes any preparation;
it does not replace the retained Native cancellation case.

The current Native save already commits the correct document, but its frontend
had replaced the original phase/task confirmation with a generic message.
The completion now retains only scalar counts from its already validated Native
result and formats the truthful original confirmation. No host parser,
normalizer, new write or inferred permission is added. Original golden count
assertions stay intact, and the actual editor approval regression asserts the
new public summary. The final Coding artifact validates that summary and the corrected raster
invoice in the original Todo golden. GC stays deferred; complete Core capacity
and the other recorded release requirements remain open. PR #49 remains Draft.


### Final captured Todo artifact and remaining initial-prompt timeout

E1040 records implementation commit `3f25e3b306116caae04fb2431ec5054dbc573437`.
It binds the final production build to source App SHA-256
`8d4d77e86f080e4452b8c601c5bf5e68ff1c78f17414e26ecf78fd565a15bdb9`
and the actual Coding artifact SHA-256
`f1ef23101ad1e45095792cd5a327b3e76263b95e5d9aeac1dc303df582f888d6`.
`captured-tui-final-normal-build/summary.json` records the unchanged fixed SDK
and successful TUI/App builds. The later producer-comment clarification changes
no executable code.

`captured-tui-final-coding-release/summary.json` records actual package assembly,
clean-environment and setup passes. Cards, default, Todo and ask pass their
original golden assertions. Todo uses a fresh home and actual Workflow operator
installation. Its fixture database contains two completed Runs, six committed
Operations and six completed Receipts: two each for `host.context.read`,
`host.plugin.document` and `plugin.axyndra:workflow.todo`. The Todo document is
revision 1, and model Attempt count is zero. All recorded process custody closes
without remaining owned processes or unknown observations.

Initial prompt still times out at the original 45-second process limit after
one committed ContextRead and one completed Receipt, before any model Attempt.
The ordinary-key fixture sees the same approval ID again after its first
AllowOnce choice. It does not repeat a decision against that old card. A
short-lived diagnostic replaces that wait with an explicit repeated-ID failure;
its source is restored byte for byte afterward. No result/cleanup is treated as
an approval, Source or data-consumption acknowledgment.

The original and final-package normal runs retain this failure. Separate
parent-debugger attempts complete the golden with and without ASLR enabled.
Those altered executions do not establish ordinary release acceptance or prove
a cause. No collector stack was captured for the normal timeout; it remains
UNKNOWN rather than being attributed to the deferred GC issue. Repeating the
approval, increasing a deadline or weakening a golden assertion is not a fix.

`captured-todo-final-product-focused/summary.json` records a new complete Product
test compilation timing out at its original 900-second limit. The watcher
cleans all exact owned descendants; it does not supply a test PASS. Therefore
the final public saved-summary assertion has no new unit-run acceptance. The
actual final Todo golden proves its product behavior, while the earlier
hint/help and early-cancellation passes retain their own source boundaries.
The two unchanged Native collector-crash tests remain deferred and were not
retried. The final staged source passes 109 Python regressions and the full
architecture gate in `captured-todo-final-static`. Vendored cjtui provenance,
public contract baseline, dependency pins and shell syntax also pass. These
static results do not replace the retained runtime failures. Complete Core capacity, broader performance, release and other
previously recorded gaps remain open. PR #49 stays Draft and the task remains
incomplete.


### First Prepared export sites and a stronger initial-prompt oracle

E1041 records `core-first-export-stacks/summary.json`. A temporary change logs
only the first transition to unknown custody for each actual Prepared metadata
owner, with function names and no argument or local values. The original full
Core contract compiles in 482.74 seconds and fails in 58.72 seconds at the same
`input_attachment.capacity` boundary. All modified source bytes are restored.
The diagnostic ELF is not a production or acceptance artifact.

There are 43 first transitions: 20 start at the legacy Host executor's plan
getter; 23 start at Broker child-plan validation's call getter. Later calls are
not mistaken for additional owners. This is a stack inventory, not a per-owner
live ledger. Validation also calls catalog descriptor resolvers, so its private
helper's return alone cannot prove that every callback alias has returned. No
unknown hold, quota or payment is cleared on this evidence.

E1042 corrects the initial-prompt golden's acceptance oracle. A separate readonly
check of the actual fixture database confirms that the earlier debugger golden
markers created no new Run, Operation, Receipt or model Attempt. Those markers
are not successful model-execution evidence. The altered debugger launch is not
usable to diagnose the normal timeout's cause; that cause remains UNKNOWN.

When `--workflow-package` selects the actual Native initial-prompt fixture, the
public golden gate now snapshots existing fixture Run IDs before invocation.
After the ordinary UI checks, it additionally requires exactly one new completed
Run, a completed model Attempt in that Run with no active Attempt, and completed
canonical ContextRead Operations/Receipts. Maintenance DB rows and older Runs
cannot substitute. The verifier reads the real store without creating execution
facts or changing any production state. Evidence output contains only counts;
all SQLite connections close explicitly. Existing process deadlines and golden
assertions remain unchanged. The release gate also runs the regression suite.

`native-initial-evidence/red.json` runs the public CLI rejection regression
against `135fc1d1`: an empty Python candidate prints the correct UI marker and
is incorrectly accepted. The current gate rejects it. Operator setup is mocked
only in this validator regression, so it provides no Native or provider credit.
Eight tests cover this CLI failure, absent/new/old Runs, another Run's model
Attempt, running work, missing/failed Receipts, numeric success evidence and the
maintenance/fixture database boundary. These fixture tests do not close the
normal 45-second initial-prompt timeout or the complete release gap.


### Terminal settlement and safe-cut copies under real capacity pressure

E1043 replaces the terminal lane allocation in `AgentThreadRuntime.finish` and
`cancel` with transfer of the same already-paid private lane to the outward
result. The concrete result carrier is registered before the private field is
detached. Earlier public snapshots retain their independent payments. Joining,
cancellation, durable terminal CAS, context-update cancellation and actual
consumer return keep their existing ordering and contracts. No terminal state,
callback return or cleanup report becomes a DATA acknowledgment.

`runtime-terminal-pressure-red` compiles the complete Runtime module and records
both new public pressure tests failing at the original metadata-growth call.
The tests use an actual owned lane, exhaust the actual allocation group and bank,
reject a stale Run, and exercise Completed, Failed, RecoveryRequired and Cancelled
settlements. The repaired module passes 39/39 in
`runtime-terminal-pressure-final`. These ephemeral-sink tests supply no SQLite,
Source or provider acceptance.

E1044 fixes repeated decoded lane copies at a safe cut. The original public
`previousLane()` and `nextLane()` still charge every escaping copy. A closed,
serialized Unit-returning validator instead reuses the constructor's paid parse
and validation scratch. It returns no graph and retains the original payment.
The Store obtains one independently decoded, fully validated paid pair through
`validatedModelLaneCopies232` and uses that same pair for its CAS encodings,
continuation phase, context boundary and complete audit. All original validation
rules, transaction fences, rollback, receipts and concrete SQL return remain.
No allocation multiplier, bank capacity, Source, deadline or refund rule changes.

`runtime-validation-scratch-red` records 41 passes and one failure: repeated
closed validation increased the actual invoice. After the fix,
`runtime-validation-scratch-green` passes 42/42 without skips. The new public
regression also rejects a wrong Thread, verifies frozen-copy independence and
confirms that public escaping getters still increase the retained invoice.

`owned-store-lane-pressure-red` uses the actual SQLite adapter and public owned
Runtime entry with all original 144 MiB bank capacity occupied by real live
allocation groups. The old repeated getters fail the cut. The same full Store
contract passes after the fix in `owned-store-lane-pressure-green`: build
32.70 seconds, execution 614.34 seconds, within the original 900-second limits.
The pressure case verifies the durable new lane, continuation and both complete
old/new audit snapshots. The rest of the original Store contract also executes,
including rejection fences, rollback, migrations and crash recovery.
`runtime-sqlite-lane-integration-final` separately passes the complete original
Thread Runtime/SQLite integration contract. The original complete Host isolation
gate passes **275/275**, no skips, in `lane-copies-full-host`.

The code is in `cbf871fd` and `ee6d5a29`; initial-prompt oracle and user-strip
counting are in `0d592d61`. Existing public signatures and persisted codecs are
unchanged. The new paid-pair function is additive; consumers are rebuilt together.
Old-binary compatibility is unverified. Ordinary source rollback requires no
schema migration and must retain the original accounting and failure evidence.

### Initial prompt completes; remaining gate failures stay explicit

E1045 records staged, uninstrumented production builds in
`validation-scratch-normal-app-staged`,
`lane-transaction-reuse-normal-app-staged` and
`initial-prompt-user-strip-normal-app-staged`. The final source App SHA-256 is
`cc9104ba6255dd29b018da8cdbeb10e6782de60c2b3e96c814489171b668abdb`.
A later terminal-lane comment changes no executable behavior. Temporary Todo
tracing restores every source byte and produces a separately labeled diagnostic
ELF; that ELF is not substituted for the final normal artifact.

The initial timeout included a real aggregate-capacity failure in the safe-cut
copy path, followed by another lane allocation while settling the failure.
The latter exception prevented paid failure publication and left the old
approval visible. This diagnosis does not explain other historical timeouts.
Removing only the terminal allocation, or only the first repeated Store copies,
was insufficient; their failed intermediate runs remain recorded.

`initial-prompt-user-strip-real-initial` passes the original three-size UI gate
and its independent readonly canonical verifier: exactly one new completed Run,
one completed model Attempt, one committed ContextRead Operation and one completed
Receipt. A normal assistant response quotes the prompt; the original UI assertion
counted that response as a second submission. It now counts matching User cards
only and still requires exactly one submission. The canonical verifier continues
to reject UI-marker-only output and old or unrelated execution facts.

E1046 binds the real Coding package in `lane-copies-final-coding-release` to that
normal App. Its packaged ELF SHA-256 is
`0fb47ce2d99fbb30501394c28653b8ee0c94018d7528afee14a7972914d880af`.
Assembly, clean-environment and setup checks pass. Cards, ask and the real Native
initial-prompt scenario pass; the latter includes the strengthened completed
Run/Attempt/ContextRead oracle and original 45-second process limit. This proves
local fixture execution, not an external provider call.

E1047 keeps the whole five-scenario Coding gate **failed**. Default loses its
operator peer; its exact child has an existing SIGSEGV core with
`MapleRuntime::GCTib::ForEachBitmapWord` and collector/root-walking frames.
That occurrence belongs to the explicitly deferred GC work and is not retried.
Todo times out after 45 seconds during save approval, leaving one completed and
one cancelled Run, five committed Operations and no saved document. The failure
is not attributed to GC without corresponding evidence.

E1048 records a fresh-home diagnostic App control and one serial control of the
same unmodified Coding package. The diagnostic returns four successful real
approval calls. `packaged-todo-serial-control` then passes the original Todo
journey in 37.40 seconds including actual operator setup: two completed Runs,
six committed Operations, six completed Receipts, one document at revision 1 and
no model Attempt. The earlier timeout is retained as an unresolved intermittent
failure; neither this pass nor the diagnostic turns the failed whole gate green.

The current complete Core/recovery entry still fails in
`lane-copies-complete-core`: build 693.62 seconds, execution 66.26 seconds, then
`input_attachment.capacity` instead of the required stale-file precondition
conflict. Unknown Prepared/Catalog consumers are not refunded on that evidence.
`lane-copies-product-focused` again reaches its original 900-second complete
Product compilation limit and cleans its exact descendants; its two selected
non-GC controls are not executed or counted as passing. No unchanged Native GC
case is retried. The SDK/runtime is not rebuilt and no additional external model
call is sent.

Overall acceptance remains incomplete. Full Product, complete Core, intermittent
Todo, broad performance, the previously recorded unknown/resource-limit cases
and final release evidence remain open. GC stays explicitly deferred, not fixed.
PR #49 remains Draft. The implementation matrix retains its earlier unmet
requirements; these focused passes do not close or reduce them.

The final tracked code and updated records pass 117 Python regressions and the
full architecture gate in `lane-copies-final-static` (2,965 tracked paths,
39 workspace packages, zero remaining boundary violations). Generated lock
changes are preserved with their bytes, diffs and hashes in
`lane-copies-lock-restoration`, then restored to the reviewed versions. These
static passes do not replace any failed runtime or release gate.


### Further Catalog lifetime diagnostics do not authorize retirement

E1049 records three additional investigations after the published lane fixes.
`readonly-delegation-closed-core` tests a narrow classification candidate for the
existing owned readonly canonicalizer and its pure metadata projection. The
original complete Core still fails at the same stale-file-precondition capacity
assertion (build 410.13 seconds, execution 52.92 seconds). The candidate is
withdrawn byte for byte and **not shipped**; no fee reduction or acceptance is
established by that attempt.

`catalog-first-hold-stacks` instruments every original assignment to the Core
Catalog scope's `held` flag. The complete diagnostic build passes in 500.83
seconds; execution fails at capacity in 50.83 seconds. There are no first-held
transitions in this run. This narrows the investigation; it does not establish
that all scopes returned or permit any payment to close.

`catalog-first-alias-stacks` instead records each Catalog object's first raw
alias transition, preserving both original raw-alias assignments. Its build
passes in 466.44 seconds and the original Core execution fails in 57.00 seconds.
Eight first transitions are observed: seven start at `ToolCatalog.find` through
Pipeline preparation in the isolated-plugin contract, and one at actual revoke
during Native Program import. Only function names are recorded. These are first
transition inventories, not per-owner payment or live-alias ledgers; they cannot
be equated with the 31 earlier snapshot-payment entries or used as refund proof.

Both diagnostic source files and the withdrawn candidate match the published
source byte for byte afterward, with hashes in `catalog-diagnostic-restoration`.
Their diagnostic ELFs remain distinct from the normal Coding artifact and are
not used for release acceptance. Original samples, assertions, error behavior,
144 MiB capacity, task witnesses and unknown-consumer obligations remain.
The next Core investigation must connect actual retained snapshot payments to
their concrete enclosing consumers and complete return witnesses. The failed
candidate and these inventories do not close that requirement.


### Scoped initial Context and private Run view returns

Acceptance remains **incomplete**. E1050–E1056 extend the same requirement and
evidence record. They do not replace the unresolved Core capacity, intermittent
Todo, performance, resource-limit, provider, or release requirements. GC remains
explicitly deferred. No SDK component is built and no additional provider call
is sent.

| Evidence | Implementation and observed result | Status and remaining gap |
| --- | --- | --- |
| E1050 | `snapshot-first-hold-stacks`, `core-return-gate-diagnostic`, and `live-snapshot-share-origins-corrected` inspect actual return gates and live snapshot shares. | Diagnostic only. No counter, helper return, or terminal state authorizes a refund. |
| E1051 | `4d461522` uses `activeRunControl159` in Product context-update and approval-binding queries. `control-only-product-complete-core` advances past the original stale-file-precondition assertion. | Implemented. The next existing-create case still fails at attachment capacity. |
| E1052 | `85cec1f8` adds opt-in scoped Context sequences and four public lifecycle regressions. Core passes 53/53 and Tool Runtime passes 72/72. | Focused contracts pass. Legacy open callbacks and historical exports remain paid. |
| E1053 | The same Core commit returns private recovery views, unused failure-start views, and unused successful failure settlements. Context-boundary resume uses the existing private Context collector. | Implemented and compiled. Original validation, pending consumers, and task-return witnesses remain. |
| E1054 | Current Product compilation enumerates 1,081 tests within 821.85 seconds. One early-cancel control and 12 of 36 affected Context cases pass. Complete Host passes 275/275. | Full Product acceptance remains open. The other selected cases crash in GC. Complete Core still fails at capacity. |
| E1055 | The current Coding package passes assembly, clean environment, setup, cards, and ask. Existing-installation initial-prompt and Todo checks pass with canonical facts. | Upgrade checks pass. Fresh operator preparation for those two scenarios crashes in GC before TUI entry. Whole release remains failed. |
| E1056 | Fixed SDK archives and missing independent-checkout Git objects are restored without changing versions or source. Generated lock files are saved and restored. | Environment recovery only. It does not turn a previous failed gate into a pass. |

E1050 records no first-held snapshot transition in the complete diagnostic run.
The original control predicate eventually reports 27 ready controls and three
active controls. Neither observation proves that a private Context producer or
its original task witness returned. The later inventory copies references from
the existing intrusive snapshot registry, releases its lock, then reads each
state under its own lock. It records six live snapshot states, nine outstanding
shares, no active snapshot loans, and no held flag in those states. Share origins
include Core approval continuation, request Context creation, and Runtime lane
creation. All six readings refer to the same charged custody group; its totals
must not be added once per snapshot. This is not a per-graph payment ledger.
The diagnostic source files are restored byte for byte. An initial temporary
string-escaping compile error is retained separately and has no test credit.

E1051 removes allocations that those Product queries never consume. The queries
still compare the original Run, epoch, cancellation token, Context digest,
waiting-approval state, and durable owner rows. They publish no tool graph or new
authority. The complete Core comparison first passes
`e5-02-stale-precondition`, then fails `e5-02-existing-create` with
`input_attachment.capacity` rather than `application_plan.create_target_exists`.
The final `core-private-views-complete-core` build takes 422.37 seconds and its
original execution fails in 34.24 seconds at that same later case. Capacity,
samples, expected errors, assertions, and the 900-second bounds are unchanged.

E1052 introduces `ToolInvocationContext.withScopedInvocation240` and
`ContextReadSequence.scoped240`. A callback receives a revocable invocation view.
A callback that needs a later reader must call `retainInvocationContext159` and
return that independent consumer through its existing API. A raw historical
snapshot export keeps the original snapshot debt. The legacy sequence
constructor keeps its open callback behavior. Product initial, composed, window,
and journal sequences opt into the new scoped mode. Core tracks the private
Context for the narrow initial-preparation port, while legacy ports and open
sequences keep conservative retention.

`scoped-context-core-red` deliberately substitutes the open callback and fails
two of the four public lifecycle assertions. The correct implementation passes
all 53 Core tests in `scoped-context-core-green`. After the recovery-view changes,
`core-private-views-unit` again passes 53/53. The actual owned parent, retained
child, historical graph, and throwing callback have separate assertions.
`scoped-context-tool-runtime-unit` passes 72/72. These are DATA lifetime tests;
they manufacture no Source, approval, canonical receipt, or task-return witness.

E1053 validates a recovered Run through a private helper that returns only its
epoch. The independent view returns after that helper. The same mismatch and
missing-snapshot errors remain. Context-boundary recovery forks its Context's
own snapshot share before returning the outer Run view; the existing control
still governs that Context. Failure setup reuses `startTurnWithPrivateLane159`
and returns its unused outward view. A successful settlement whose only caller
is failed initial snapshot persistence also returns its unused view. Unknown
exceptions and failed settlements receive no invented return acknowledgment.

E1054 uses the complete Product O2 executable from
`scoped-context-product-focused`. The cancellation-before-preparation case
passes. The configured hint/help case crashes in the collector. The 36 affected
public Context cases in `scoped-context-product-affected` produce 12 passes and
24 GC crashes, with no ordinary assertion failure. Every case retains its
original 60-second case bound, 90-second physical bound, and exact compiled
identity. The full 1,081-case suite is not reported as passing. The original
complete Host gate passes 275/275 in `scoped-context-full-host` with unchanged
Source, cancellation, recovery, and custody checks.

E1055 binds `scoped-context-normal-app-staged` to implementation commits
`4d461522` and `85cec1f8`. All nine production stages pass their original
900-second per-stage limits. The uninstrumented App ELF SHA-256 is
`2ccf3a35d50c855d8d0330b2d10fad87526092b4c7248c052bb17cfad74ee403`;
Minimal is `854f29ca78bd46ae1924de86a0ff836c09a1a82c1575a9b6f5020d7523a6a7aa`.
The assembled Coding ELF is
`f7dd368993d21add4b8bede4c4979d84f481a9f0bb8ef40cf237e41177e54496`.
The fresh-home initial-prompt and Todo checks lose their actual operator child.
The exact reaped child, executable, and core agree on collector failures:
`GCTib::ForEachBitmapWord` with root walking for one, and concurrent
`WCollector::MarkObject` for the other. Sanitized classification records contain
no process lease tokens or command lines. Neither is retried. The earlier
confirmed default GC occurrence also remains deferred.

`scoped-context-existing-installation-initial` uses the same current Coding ELF
with a previously inspected, imported, enabled, and configured actual operator
installation. It copies no Registry, replaces no grant, deletes no fact, and
uses no trusted-mode bypass. The original three-size golden passes in 10.87
seconds. Its readonly completion check finds exactly one new completed Run,
one completed model Attempt, one committed ContextRead, and one completed
Receipt. Existing older Run rows are excluded from the new-run oracle, not
rewritten or counted as this invocation's success.

`scoped-context-existing-installation-todo` then passes in 9.59 seconds under the
original 45-second TUI limit. It adds two completed Runs, six committed
Operations with six completed Receipts, and the first Todo document at revision
1. Both checks are real local fixture execution on an existing installation.
They prove neither clean operator installation nor external provider behavior,
and they do not erase the earlier intermittent Todo timeout.

E1056 retains an interrupted Core build whose final `llvm-objcopy` executable
is absent, followed by a dependency-fetch failure after the dependency cache is
found empty. The same approved SDK and StdX archives pass their recorded SHA-256
checks before extraction. Their versions and bytes remain fixed; no runtime,
compiler, std, or stdx component is built. Public dependencies return at the
same locked revisions. A per-command Git configuration permits public HTTPS
reads without changing the global SSH rewrite or SSH configuration. The
complete build then passes in 809.65 seconds and its original Core execution
still fails at the existing-create capacity assertion. The cause of the
external file disappearance is unknown.

Missing historical Git objects in the independent checkout are restored from
the immutable published blob and existing local ancestry objects. No original
worktree source, index, branch, or configuration is written. Its 82 original
status records retain the same digest. `scoped-context-lock-restoration` saves
ten generated lock files with their bytes, diffs, and hashes before restoring
the reviewed versions.

The new APIs are opt-in additions at source level. Existing constructor and
method signatures remain. An old-binary ABI check has not run; consumers of the
changed class layout must be rebuilt for this candidate. No database schema or
durable recovery version changes. A source rollback must revert both code
commits together so Product no longer selects the scoped sequence API.
Unknown Prepared and Catalog consumers still require concrete ownership and
return evidence. The next capacity change must supply that evidence rather
than waive a getter, increase the 144 MiB bank, or refund on a terminal state.

The final code and these records pass 117 Python regressions and the complete
architecture gate in `scoped-context-final-static`: 2,966 tracked paths, 72
Markdown files, 39 workspace packages, 178 local dependency edges, and zero
remaining baseline boundary violations. Pin, vendored contract, public package,
and SDK compatibility checks pass. These static results do not replace the
failed runtime, full Product, or release gates.


## Scoped Core tool-hook inputs preserve opaque consumer debt

Implementation `980f1dfd` adds the opt-in `ScopedCoreToolHookRuntime240` interface.
Core creates and revokes a separate invocation view around each before, after,
and owned-after hook. A reader that outlives its callback must retain its own
paid Context consumer. Legacy hook runtimes keep their open input contract.
Product selects a private adapter around the same `ProductCodexHookRuntime`;
the public runtime keeps its existing inheritance and direct-call behavior.

| Evidence | Executed scope | Actual result and boundary |
| --- | --- | --- |
| E1057 | Public Core callback, retained child, thrown hook, finite typed failure, and opaque CapabilityPolicy contracts | The open-callback comparison fails view revocation. The final safe complete Core contract passes in 49.80 seconds. These are DATA contracts, not Native or provider acceptance. |
| E1058 | Actual opaque policy retains its original Context during a typed failure | A candidate that refunds every failed private Context fails this counterexample. It is withdrawn. The shipped code retains the original failed-Context debt even when the hook itself opts into scoped inputs. |
| E1059 | Final safe test-profile preparation and original module gates | Runtime 42/42, Tool Runtime 72/72, Core 53/53, and complete Host 275/275 pass without skips. Product O2 compilation finishes in 791.29 seconds and enumerates 1,081 cases; the early-cancel control and 20 affected public hook cases pass. Full Product acceptance remains open. |
| E1060 | Final safe normal production build, Coding package and actual installed-operator upgrade | All nine production stages pass. Coding assembly, clean-env, setup, cards and ask pass. Initial-prompt and Todo complete with new canonical facts under the original TUI limit. Fresh operator GC paths stay deferred. |
| E1061 | Same-bank attachment working-lease candidate and exact safe-code complete Native Core comparison | Tool DATA checks pass 74/74, but the candidate fails the original Native gate earlier at invalid-path. It is entirely withdrawn. Safe code builds in 482.57 seconds and still fails existing-create capacity in 38.93 seconds. |
| E1062 | Final static gates and generated dependency lock restoration | All 117 Python regressions and the complete architecture gate pass. Eleven generated locks are saved and restored to reviewed bytes. No dependency pin changes. |

The E1058 counterexample uses a real public Core entry and a legacy
`CapabilityPolicy` that retains its actual input and delegates to the original
policy. A scoped hook return cannot acknowledge that policy, an owned canonical
resolver, or an executor handoff consumer. The unsafe candidate revoked the
retained policy input. The final code restores conservative `Result.Err` handling;
both finite-provider comparisons retain the same 958,656-byte declared invoice.
No reduction of that invoice is claimed. Public hook inheritance is unchanged.

`scoped-core-hooks-green-safe-full` records the full aggregate and policy
counterexample. `scoped-core-hooks-safe-units`,
`scoped-core-hooks-safe-product-build`,
`scoped-core-hooks-safe-product-affected`, and
`scoped-core-hooks-safe-full-host` identify the final safe source hashes and
artifacts. Test-profile preparation is build evidence only. It does not count
as test execution. An earlier monolithic Product compilation timeout, a missing
adapter import, and a contract working-directory setup failure remain recorded;
none is reported as passing. The earlier HTTP/Pi collector crash is not rerun
or counted among the 20 passing hook cases.

An automatic approval review rejected an attempt to move unit cache artifacts
in an older potentially shared target. That command did not execute. Subsequent
builds use separate, uniquely created production, unit, and standalone targets
owned by this continuation. Their old seed directories are read-only mounts;
no older cache is moved or cleaned. Temporary storage is disk-backed. The
fixed official SDK, StdX and dependency revisions remain unchanged.

The E1060 normal App SHA-256 is
`65303f56ff2990cf2d976aa1f61fdc20dd70d814246934413f2f3ba965d146a5`;
Minimal is `13babf168524d41f03846591581c728690f73e45bf5d617968a7f071f80b9aa2`.
The assembled Coding ELF is
`848f0659f03574a8dfc613857460ec5337dcb8a54424c15ddd918b4efa873594`.
`scoped-core-hooks-safe-normal-app-staged` and
`scoped-core-hooks-safe-coding-entrypoints` retain build, package provenance,
process custody and hashes. Earlier pre-withdrawal App and Minimal artifacts
are ineligible for delivery.

`scoped-core-hooks-safe-existing-installation-initial` completes the original
three-size golden in 11.12 seconds on an actual existing operator installation.
The readonly oracle finds exactly one new completed Run, one completed model
Attempt, one committed ContextRead and one completed Receipt.
`scoped-core-hooks-safe-existing-installation-todo` uses another actual existing
installation whose Todo document does not yet exist. It passes in 10.16 seconds,
adding two completed Runs, six committed Operations with six completed Receipts,
and the first Todo document at revision 1. No Registry, grant or durable fact is
copied, replaced or deleted. These are local fixture upgrade checks, not clean
installation, external provider or full release proof. The earlier intermittent
Todo timeout remains unexplained.

E1061 tried deriving an attachment's unchanged 64 MiB working invoice from the
same actual Native budget group, verified by original-bank reservation identity.
The public DATA tests prove foreign-bank refusal, SUM plus the original lease
header, and independent child lifetime. Those properties do not establish a
useful production lifetime: the long-lived group's high-water charge survives
the short attachment's acknowledgment. The original complete Native gate then
fails at `e5-02-invalid-path`, earlier than the safe version. All four candidate
files, the additive API, and its tests are restored byte for byte; the patch and
failed results remain in `attachment-working-lease-withdrawal`. A first test
compile using the reserved word `foreign` and a later assertion missing the
original 1,024-byte lease header are retained as failed test-development records.
Neither changes production accounting or earns acceptance credit.

`scoped-core-hooks-safe-complete-core` verifies the restored safe code through
the actual original Native and SQLite entry. It reaches
`e5-02-existing-create`, then reports `input_attachment.capacity` instead of
`application_plan.create_target_exists`. The 144 MiB bank, working invoice,
canonical Source, samples, expected errors and original 900-second bounds are
unchanged. This is an open implementation gap, not GC and not a passing gate.

No schema, durable recovery version, dependency pin or Native protocol changes.
The opt-in interface adds source API; existing consumers retain their behavior.
Changed classes require a consistent rebuild, and old-binary ABI is unverified.
Rollback must revert the Core hooks and Product adapter together and preserve
all durable facts and unpaid consumer obligations. GC remains deferred;
all other unmet requirements remain required. PR #49 remains Draft and
acceptance is **incomplete**.


E1062 records `scoped-core-hooks-safe-final-static`: 2,969 tracked paths,
72 Markdown files, 39 workspace packages, 178 dependency edges and zero remaining
baseline boundary violations. Dependency pins, SDK compatibility baselines,
vendor contract and package inventory pass. The 11 saved generated locks and
their diffs are retained in `scoped-core-hooks-safe-lock-restoration`. These
checks do not supersede the failed runtime or outstanding release gates.
