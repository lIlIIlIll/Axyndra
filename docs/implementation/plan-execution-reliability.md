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


## Manual display retirement and coalesced PTY input evidence

This continuation fixes three independent TUI defects without changing the
original performance limits. The final code is `c195e14c`, comprising manual
producer retirement `e85e4d2f`, coalesced input evidence and runner consumption
`aaf17c7b`, and ANSI history batching `c195e14c`.

| Evidence | Executed scope | Actual result and boundary |
| --- | --- | --- |
| E1063 | Original safe Coding package, release cold-start and headless/manual performance entries | Cold start 100/100 and headless 40/40 pass; document and composer print metrics but exit 1. These are failed lifecycle entries, not performance passes. |
| E1064 | Manual producer implementation, public lifetime/refusal/error tests, complete vendored Core and Agent TUI units | Vendored Core 562/562 and Agent TUI 98/98 pass. The actual Coding document, composer and long-transcript entries exit zero. The first test compile rejects mutable local lambda captures; the corrected test uses its own observation object. |
| E1065 | Original complete PTY gate and one unchanged-input search diagnostic | The gate times out on the second search sample. The diagnostic shows a completed Sessions frame containing the input together with later async messages, while the old trace retains only the last message label. Neither attempt is a PTY pass. |
| E1066 | Bounded frame-input evidence and a same-binary runner-consumption control | All 15 samples execute. Eight parser, count, timeout and setup regressions pass. Draining the unchanged setup interval removes artificial active stalls on the same pre-batching binary; its resize still fails the original one-write limit with three writes. |
| E1067 | Original one-write public regression, exact byte/cursor comparison, generic backend compatibility | Before the ANSI fix, complete Core is 563/564 with the one-write case failing. Afterward all 564 cases pass. Original output bytes, cursor behavior and generic backend semantics stay unchanged. |
| E1068 | Final normal App, actual Coding package and complete original performance entries | TUI 98/98, packaging, clean-env, setup, cards, ask, 100 cold starts, 40 headless samples, all three manual journeys and all 15 PTY samples pass. This is not the whole baseline, activation, memory or cancellation performance matrix. |
| E1069 | Final Coding on actual existing operator installations, including the installation with the earlier Todo timeout | Initial-prompt passes in 11.34 seconds with one new completed Run/Attempt/ContextRead. Todo passes in 9.62 seconds with two completed Runs, six completed canonical Receipts and first document revision 1. Original history and operator configuration remain unchanged. |
| E1070 | Final source/static and lock restoration | All 125 Python regressions and the complete architecture gate pass over 2,974 tracked paths. Nine generated locks are saved and restored to reviewed bytes. No dependency pin changes. |

E1063 is retained in `scoped-core-hooks-safe-tui-performance`. The document and
composer loops previously bypassed the concrete headless producer and created
Terminal/TestBackend objects outside its return protocol. Their numerical
assertions passed, but the actual Product display lifetime could not retire.
E1064 routes document, composer and long-transcript loops through that same
concrete producer and `HeadlessCapturedFrameScope.withManualFrame240`.
`HeadlessManualFrame240` uses the actual Terminal, command queue and AsyncRuntime.
It prepays real raster copies before drawing, preserves dirty rectangles and
executes commands through the existing App pipeline. It creates no unused
snapshot archive. The facade revokes its update callback only after the complete
manual helper returns; live or reentrant actions cannot acknowledge the scope.

The existing enclosing scope clears the actual backend, retires the actual
runtime and Terminal fields, and then allows the concrete producer's bound
stdout flush and Screen return checks. No transport or external capture debt
is inferred from internal retirement. The original 120+120 scroll events,
120 typing events, 180 composer insertions, 90 deletions and every threshold
remain. Public tests assert command delivery, payment refusal before rendering,
primary error preservation, facade revocation and rejection of early retirement.

`manual-headless-frame-core-fixed`, `manual-headless-frame-product`,
`manual-headless-frame-coding` and `manual-headless-frame-performance` retain
that first passing source and artifact scope. Later evidence below binds the
final binary rather than treating the first package as final acceptance.

E1065 is retained in `manual-headless-frame-pty` and
`manual-headless-search-diagnostic`. The old gate expected a completed frame's
single last-event label to be `key_down`. A frame can legitimately combine the
actual key input and async completion. Its final label then loses the input's
provenance. The actual diagnostic child remains alive at the deadline and is subsequently
terminated by diagnostic cleanup; this is not classified as a GC crash. The first whole gate additionally requires
owned-process cleanup. That cleanup is not a DATA acknowledgment or a pass.

E1066 adds `frame_inputs`, bounded to five known input kinds, with actual counts
and each kind's first receipt timestamp. It contains no user text or authority.
Existing trace fields remain. The runner matches actual inputs in a completed
frame and measures from the first relevant input, so later async activity cannot
shorten the measured latency. Batched input waits require the actual matching
input count; unrelated sequence increments cannot satisfy the wait. New-format
empty or malformed evidence fails closed, while old trace records retain their
original compatibility path. A missing second input still times out in the
regression. Session setup waits for its actual Enter frame.

The next full gate completes all samples but reports active stalls near the
runner's 300 ms setup sleep. Its separate search diagnostic records 194.88 ms in
actual output writing during the runner's 200 ms pause. The consumer had stopped
reading the PTY, creating backpressure. `drain_for` preserves both original
setup durations while continuing to consume output. A same-binary control in
`coalesced-frame-input-drain-control` then has zero active stalls and still
rejects resize's three writes. No stall is filtered or reclassified as passing.
A fixed-SDK minimal FastNative probe returns `count=0 elapsed_ms=0` before input;
that negative result does not prove the entire application or SDK correct.
The first probe collector missed buffered stdout; the corrected complete output
is in `stdin-read-probe-fixed`. No SDK component is built.

E1067 fixes the remaining actual output behavior. The raw-history branch had
separate cursor-move, line-clear and frame writes despite its batching contract.
`Backend.drawHistoryFrame240` preserves the original generic operations by
default. PresentationBackend forwards the same pending prefix; AnsiBackend
appends origin, clear, history, viewport and cursor to its existing builder and
makes one OutputStream write. No additional full history copy is constructed.
`history-frame-batch-red` retains the failing original test;
`history-frame-batch-green` passes the complete 564-case O2 vendored Core module.
The Core module here is the vendored cjtui package, distinct from Agent Core's
53-case module. ANSI bytes and cursor sequence match the old public operations
exactly; the generic backend's output and snapshot also match.

E1068 is bound to `c195e14c`. `history-frame-batch-product` passes all 98 TUI cases
and the normal App build. App SHA-256 is
`99c4bde94c56d1ba718c6d16361179b5a17e5b68982a49a3da936093634f1c16`.
`history-frame-batch-coding` assembles the real Coding distribution and passes
clean-env, setup, cards and ask. Coding ELF SHA-256 is
`c00d1856b20955e730d30615db73e20f0f28bec65fd90244888f440da9a5c47c`.

`history-frame-batch-performance` passes the original 100 cold starts and all
40 headless runs, with p50 413.8 ms and p95 413.9 ms under the unchanged 500 ms
limit. Document keeps 361 frames, composer keeps 270 measured frames, and the
long transcript keeps 241 frames, all 502 expected entries and exact content.
It materializes 93 documents under the original 200-document ceiling.
`history-frame-batch-pty` passes all five 10,000-row scenarios with three samples
each and 100 stream chunks. Every active-stall count is zero and resize makes
one output write. The original `--timeout 12` setting, the existing 60-second stream-collection
bound and every threshold remain.

| Final PTY scenario | p95 | Original p95 limit |
| --- | --- | --- |
| First frame | 165.45 ms | 650 ms |
| Key repeat | 13.09 ms | 30 ms |
| Stream | 8.34 ms | 80 ms |
| Search | 1.63 ms | 30 ms |
| Resize | 11.95 ms | 80 ms |

These are measured local fixture gates. They do not establish immutable-base
performance comparison, external provider success, all platforms, memory limits,
full Product or full release acceptance. The vendored upstream identity remains
fixed; explicit local overlays, API inventory and content manifest record the
additions. Existing backend implementations keep source behavior through the
default method. Consistent consumer rebuilds are required; old-binary ABI is
unverified. Rollback must revert the related TUI consumer, local overlay and
API hashes together. No database, Source, quota, dependency pin or Native wire
protocol changes. Agent Core capacity and all other unmet requirements remain
open; GC is still deferred and PR #49 remains Draft.


E1069 is retained in `history-frame-existing-initial` and
`history-frame-existing-todo`, using the same final Coding ELF. Both run the
original three-size golden under its original 45-second TUI limit. The initial
oracle finds exactly one new completed Run, one completed model Attempt, one
committed ContextRead and one completed Receipt. Todo reuses the actual
previously configured operator installation that retained the earlier
save-approval timeout. Before this run it has cancelled/completed historical
Runs and no Todo document; those facts are preserved. This invocation adds two
completed Runs, six committed Operations with six completed Receipts and the
first Todo document at revision 1. All operator JSON hashes remain unchanged.
No Registry or grant is copied, reimported or replaced. This successful upgrade
run does not explain or erase the older intermittent timeout or prove a fresh
operator installation. Confirmed fresh-operator GC paths remain deferred.

E1070 records `history-frame-final-static`: all 125 selected Python regressions,
including eight new input-evidence and setup tests, pass. The full architecture
gate passes over 2,974 tracked paths, 72 Markdown files, 39 workspace packages
and 178 dependency edges, with zero remaining baseline boundary violations.
The local cjtui API inventory hash is
`284bb45c3537d8e11e30e9d6a5cfce0d4f275415af4500bb358fae645ae94735`.
Nine generated locks, their diffs and hashes are saved in
`history-frame-final-lock-restoration` before exact restoration. Static checks
and these TUI passes do not clear the remaining Agent Core, full Product,
external provider, baseline or release requirements.


## Scalar input-limit query and withdrawn Readonly experiment

The retained implementation is `77eddb88`. `AgentThreadRuntime.activeModelInputLimit240()`
reads the immutable numeric limit while holding the existing Runtime lock. Core
uses that query instead of allocating an outward ModelLane and snapshot share.
No active Run returns zero, matching the previous Core helper. Existing outward
ModelLane getters, Source, capability checks and return obligations are unchanged.

| Evidence | Entry and scope | Observed result |
| --- | --- | --- |
| E1071 | `scalar-input-limit-red` and `scalar-input-limit-green`, complete Runtime O2 module | The former allocating read fails at an actually saturated 16 MiB DATA bank: 42 passed, one error. The numeric query passes all 43 cases and 100 repeated reads leave the same declared bytes, charged bytes and live-lease count. This scoped bank is not the Native aggregate. |
| E1072 | `scalar-input-limit-core-unit`, complete Core O2 module | All 53 cases pass. Failure Context retention and original task-return rules remain mandatory. |
| E1073 | `scalar-input-limit-complete-core`, original complete Native Core/recovery | Build passes in 457.14 seconds. Execution fails in 36.57 seconds at `e5-02-existing-create`, still reporting `input_attachment.capacity`. The scalar fix does not solve that failure. |
| E1074 | `scalar-prepared-unknown-stacks-native-env`, function-name-only debugger observation | The exact scalar-query Native ELF reaches the same capacity failure. The recorded 69 stack shapes include Readonly validation, execution and service metadata exports. Counts are not a live ownership ledger or a refund witness. |
| E1075 | `closed-readonly-withdrawal`, withdrawn non-attachment Readonly candidate | The candidate compiles but the original Native gate still fails at the same capacity case. Its selected Product run passes 21 of 36 cases; 15 integration cases physically crash. All five modified Host files are restored byte-for-byte, and the added carrier is removed. No candidate implementation ships. |
| E1076 | `scalar-input-limit-product-serial-build` and `scalar-input-limit-product-affected`, final retained source | Complete Product O2 compilation passes in 854.83 seconds with one build job and enumerates 1,081 cases. The 20 selected hook contracts and early-cancellation case pass, 21/21. No other inventory case receives runtime credit. |
| E1077 | `scalar-input-limit-app` and `scalar-input-limit-app-staged`, current normal production rebuild | The original 900-second App build times out. A separate production Product stage also reaches its unchanged 900-second cap. A new App or Coding package for this source is not produced or accepted. Earlier package and TUI evidence retains its recorded source scope. |
| E1078 | `scalar-input-limit-final-static`, final retained source and records | All 125 selected Python regressions and the complete architecture gate pass over 2,975 tracked paths, 72 Markdown files, 39 workspace packages and 178 local edges. The reviewed dependency pins and TUI API hash are unchanged. |
| E1079 | `closed-readonly-source-id-tool-unit`, `closed-readonly-source-id-complete-core` and `closed-readonly-source-id-withdrawal` | A smaller candidate keeps attachment sources byte-identical and reads normal parent identity from the same sealed Source. Tool Runtime O2 passes 72/72 after a 63.74-second build. The original Native build passes in 588.45 seconds, but execution fails in 39.81 seconds at the same capacity case. All six candidate source files and the added carrier are archived and restored. |

The public regression is
`ModelInputLimitPressure240Tests.scalarQueryNeedsNoNewLaneOrLeaseAtTheOriginalFullBank`.
It covers an absent Run, an active Run at the actual bank limit and a completed
Run. The historical InMemory sink retains its original debt. The test does not
claim a zero bank, SQL receipt, Source return or external-task acknowledgement.
The RED run temporarily substitutes the prior allocating Core read into the new
query and restores the exact source after execution.

All Cangjie commands use the fixed official November 4 SDK. Runtime and Core
module commands use their original 900-second stage and 60-second case limits.
The complete Product command is `scripts/pinned_cangjie cjpm test -m agent_product
--incremental --jobs 1 --dry-run --no-color --no-progress`, with a task-owned
explicit target directory and the original 900-second cap. Each selected Product
case runs independently with its original 60-second test and 90-second process
bounds. Public API addition requires consumers to rebuild with the corresponding
Runtime. Old-binary ABI remains unverified. No schema or persisted-data migration
is introduced. Rollback reverts the query, Core caller and public regression
as one change.

Candidate evidence must not be confused with final-code acceptance. The candidate
Product compile first times out at 900 seconds. A separate Host stage passes in
689.03 seconds, but the next Product stage also times out. A one-job Product build
then passes in 424.17 seconds. Its 15 integration failures include native Runtime
collector frames; they are not rerun after the candidate is withdrawn. The final
retained-source build and 21 passes above are separate evidence.

The candidate debugger run ends early with SIGABRT. Its 48 stack shapes and 109
breakpoint hits cannot be compared with the completed observation's 69 shapes
and 2,666 hits. A debugger's zero exit status is not inferior-process success.
The earlier first diagnostic cannot load its native library and yields no useful
stack evidence. Both failed observations are retained without acceptance credit.

The Native bank remains 144 MiB, with its existing 16 MiB reservation floor and
64 MiB attachment scratch invoice. No raw-getter exemption, status-based refund,
new Source, replacement bank, relaxed threshold or extended deadline is shipped.
GC remains deferred by explicit user decision. Core capacity, complete Product,
current distribution rebuild, provider paths, baseline matrix and release
acceptance remain open. PR #49 stays Draft and the task is **not complete**.

E1078 preserves the original unittest and architecture entrypoints. Two earlier
Root/contract generated locks are saved and restored before the code commit.
After the production build, only the exact Root lock is dirty. A read-only audit
and byte/hash guards precede its separate save and restoration. No broad lock
cleanup is performed. Final source/static validation does not convert E1073 or
E1077 into passes.

E1079 does not establish final-source Tool or Native acceptance. Its standalone
Native run uses the original manifest's existing compile profile; no O2 claim
is made for that executable. Both explicit generated locks match earlier
known task-generated bytes before their guarded save and restoration.

Automatic approval review rejects the proposed broader attachment metadata
lifecycle and output-ACK implementation before process creation, citing quota,
authorization, payload-release and consumer-return risks requiring specific
user authorization. That implementation is not applied. A concrete file scope,
return invariants and original acceptance gates are prepared for user review.
Neither rejection nor the failed narrower alternative clears the required
capacity work. Remote publication is separately blocked by an invalid existing
GitHub CLI token (HTTP 401); local commits do not imply the PR was updated.

## Authorized attachment experiment and current production rebuild

The later manual execution approval resolves the earlier approval-review
block. It authorizes the reviewed attachment experiment; it does not change
the SDK, bank, Source, ACK, acceptance limits, or publication permissions.
The experiment starts from retained source `6e1ccf32`, which includes
`77eddb88`. It is withdrawn after the original complete Native gate still fails.

| Evidence | Scope and retained entry | Actual result |
| --- | --- | --- |
| E1080 | `capacity-metadata-approval/state.json`; `authorized-attachment-baseline` | The approved commands execute after manual approval. Eight tracked source baselines are saved before application. The private carrier requires the same Prepared object, encloses reads in callbacks, counts pending loans, and retains one actual metadata consumer through the complete Native helper and attachment ACK. The candidate does not become accepted source. |
| E1081 | `attachment-metadata-scoped-complete-core/summary.json`; `attachment-metadata-authority-complete-core/summary.json` | Builds pass in 503.36 and 511.54 seconds. Runs fail in 45.17 and 43.03 seconds at `e5-02-existing-create`: `input_attachment.capacity` replaces the expected `application_plan.create_target_exists`. The second candidate also closes the file-plan service authority read inside its original loan. Both original 900-second limits and all assertions remain. |
| E1082 | `attachment-metadata-scoped-unknown-stacks`; `attachment-metadata-authority-frame-stacks` | Both function-name-only diagnostics reach the same contract failure. In the second run the selected private executor is entered 11 times and its Root-return method is entered ten times. The inferior exits 1 even though GDB exits 0. Entry counts do not prove allocation retirement or authorize a refund. |
| E1083 | `attachment-metadata-unit-dependencies/summary.json`; `attachment-metadata-module-runs/summary.json`; `attachment-metadata-full-host/summary.json` | The five original dependency stages compile. The candidate passes complete Runtime 43/43, Tool 72/72, Core 53/53, and Host 275/275. The Host gate keeps its 900-second module and 60/90-second case limits. These candidate module results do not clear E1081 or validate withdrawn code as final source. |
| E1084 | `attachment-metadata-current-ledger/summary.json`; `source/manifest.json` | The numeric probe build passes in 560.06 seconds. Execution stops after 11.75 seconds with `StackOverflowError` in the probe's `File.appendTo`. Its 39,550 event lines are an early observation, not a ledger at the capacity failure. All four instrumented files are restored byte for byte. No probe code is retained. |
| E1085 | `attachment-metadata-withdrawal/manifest.json`; `candidate.patch` | All nine candidate source files and the exact patch are saved. Eight tracked files are restored to retained HEAD and the new private carrier is removed. Two generated locks and their diffs are saved before exact restoration. The retained tree is clean at `6e1ccf32`. No attachment candidate is committed or shipped. |
| E1086 | `scalar-input-limit-nine-production-stages/summary.json` | All nine original production stages pass on the restored scalar-query source with the fixed official SDK. Runtime, Tool, Store, Core, Host, Product, RPC, App, and Minimal each keep the original 900-second cap. Product takes 384.00 seconds and App takes 121.60 seconds. This is the existing staged recipe, not an extended monolithic deadline. The earlier two build timeouts remain recorded. |
| E1087 | `scalar-input-limit-coding/summary.json`; package provenance | Current Coding assembly passes in 749.31 seconds. The original clean-environment, setup, cards, and ask checks pass. The current App is `9c9d7231b1cfdf78e0bd4df4b60c2df2a8da3e167353d2c714cb2b44f024ab5e`; Coding is `1ef648607a1bc0035d7a531945308e561871590f841b1edf4b092f34502af589`. The exact packaged native inputs are recorded in provenance. |
| E1088 | `scalar-input-limit-existing-initial/summary.json` | The current Coding package passes the unchanged three-size initial-prompt golden in 13.46 seconds on an actual existing operator installation. Read-only SQL verifies one new completed Run, one completed Model Attempt, one committed ContextRead, and one completed Receipt. Existing facts and operator JSON hashes remain unchanged. This is an upgrade-path check, not fresh-install or external-provider proof. |
| E1089 | `scalar-input-limit-current-performance/summary.json`; `scalar-input-limit-current-pty/summary.json` | The same current Coding ELF passes 100 original cold starts (max 89.0 ms), all 40 headless samples (p50 463.8 ms, p95 464.2 ms), document, composer, and long-transcript journeys. The complete original PTY gate passes all 15 samples: five 10,000-row scenarios with three samples each, the original 100 stream chunks, 12-second case limits, and original latency/output/stall thresholds. This is absolute gate evidence, not the complete matched baseline comparison. |

E1086 and E1087 provide current production artifacts that E1077 lacked.
They do not explain every historical timeout. Fresh-operator paths with matched
GC failures remain deferred by the user's decision and are not retried here.
No SDK component is built and no additional external provider call is made.

The original complete Core capacity gap remains open. Complete Product,
remaining distributions and provider paths, the complete baseline matrix, and
release acceptance remain required. The current initial-prompt result does not
replace the separate Todo gate or explain its earlier intermittent timeout.
No persisted schema, dependency pin, Native protocol, authorization, Source, or
quota changes. The numeric-query API still requires a consistent Runtime/Core
rebuild; old-binary ABI remains unverified. Rollback reverts that query and its
Core caller together while preserving durable facts.

PR #49 remains Draft. Acceptance is **not complete**. GitHub authentication
must be restored before the authorized fast-forward publication and PR update.

E1090 records `scalar-input-limit-current-final-static`: all 125 selected
Python regressions and the complete architecture gate pass on retained source.
The gate checks 2,975 tracked paths, 72 Markdown files, 39 workspace packages,
and 178 local dependency edges. Nine generated dependency locks are saved with
their exact bytes and diffs before restoration in
`scalar-input-limit-current-lock-restoration`. Dependency pins and SDK
baselines pass. Static checks do not clear the remaining runtime acceptance.

## Opaque Linux task names and reconciled allocation categories

The physical process watcher reads Linux stat files as bytes and decodes only
the kernel's ASCII identity fields after the closing task-name parenthesis.
Task names may contain non-UTF8 bytes. They are not authority and do not
determine ancestry or return. Parent, group, session, starttime, dead-state,
pidfd, deadline, unknown-identity, and actual reaping checks remain unchanged.
Malformed numeric fields still fail. A physical process exit is still not a
DATA-consumer ACK.

| Evidence | Executed scope | Actual result |
| --- | --- | --- |
| E1091 | `diagnostic-file-writer-probe`; `retained-scalar-core-stable-ledger/validation.json` | A fixed-SDK minimal global-writer probe passes before the numeric diagnostic. The original complete Native build passes in 668.82 seconds, then execution reaches the same capacity failure in 51.44 seconds. All 174,674 counter/SUM/count checks reconcile across 174,758 events. At the refusal the original capacity is 150,994,944 bytes, charged bytes 106,649,328, requested growth 50,331,648, and overshoot 5,986,032. The Registry group costs 72,881,904 bytes. All four temporary source files are restored. These are accounting facts, not refund authority. |
| E1092 | `retained-scalar-classified-ledger/summary.json` | A first category-tag diagnostic stops after 113.93 seconds because its process watcher reports `process_stat_malformed`. It is a watcher failure, not a passing compile or a compiler diagnostic. Owned survivors are cleaned and reaped, and all eight temporary Cangjie sources are restored. The original malformed bytes were not captured, so the later encoding repair does not establish this failure's cause. |
| E1093 | `proc-stat-byte-identity-red`; `proc-stat-byte-identity-green` | Two new regressions fail before the fix: direct opaque-byte parsing and an actual Linux child whose task name contains a non-UTF8 byte. A pipe handshake keeps that real child alive until observation; the fixture then releases and waits for it. After the fix all 43 process-watcher regressions pass, including the original unknown-identity, negative-field, immutable-signal, PID-reuse, and physical-reaping controls. |
| E1094 | `retained-scalar-classified-ledger-byte-reader/validation.json`; `classified-live-invoices.json` | With the byte reader, classification builds in 491.31 seconds and reaches the original capacity failure in 48.81 seconds. All 174,674 accounting checks reconcile across 175,267 events. The largest method-based category is `reserveSnapshotCatalogData159`: 111 leases totaling 33,413,328 bytes including headers. Prepared metadata is 45 leases totaling 12,562,192 bytes including headers. Current overshoot is 5,986,040 bytes. The eight-byte difference from E1091 is recorded, not normalized away. All eight temporary sources are restored. |

The categories identify where to continue the implementation audit. They do not
establish that any snapshot or metadata consumer has returned. The 144 MiB bank,
16 MiB floor, 64 MiB attachment invoice, SUM accounting, and last-lease physical
retirement remain unchanged. No diagnostic API or probe enters shipped Cangjie
source. The byte-reader repair affects the Python validation harness; the
current App/Coding binaries and their E1086–E1089 scope are unchanged.

The full Core capacity and the remaining requirement matrix are still open.
The original whole-case limits remain. GC stays deferred, and no SDK build or
additional external provider call occurs. PR #49 remains Draft and acceptance
is **not complete**.

E1095 records `proc-stat-byte-identity-final-static`: all 127 selected Python
regressions and the complete architecture gate pass. Dependency pins, package
inventory, TUI API, and SDK baselines remain unchanged. The generated contract
lock is saved and restored in `proc-stat-byte-identity-lock-restoration`.
The fix changes validation-harness input parsing, not product Cangjie APIs,
durable storage, or the physical DATA-return contract. Rollback pairs the
watcher reader with its regressions; it never converts an unknown identity to
a successful return.


## Known derived terminal Receipts and preview publication failure

`reserveSnapshotCatalogData159` also funds model input and Registry DATA.
Its 111 leases in E1094 are not 111 snapshot objects. Actual caller roles and
original completion failures are separated below before any retirement change.
All evidence uses the fixed official SDK and original limits. Evidence names
denote private run directories, not additional checked-in gates.

| Evidence | Executed scope | Actual result |
| --- | --- | --- |
| E1096 | `retained-scalar-allocation-role-ledger` | Build 809.25 s; full Core 54.09 s, failing. All 174,674 checks reconcile. Toolset producers: 44 leases/15,090,256 bytes; Prepared metadata: 45/12,562,248; Registry DATA: 59/9,302,272; model input: 8/9,020,800. These are invoices, not leaked/returned-consumer proof. All ten probe sources restore. |
| E1097 | `retained-scalar-model-return-ledger` | Build 715.42 s; full Core 45.65 s, failing. All 174,674 checks reconcile. Live input custodians lack the original Run task-return witness. Earlier custodians with actual task/provider/caller/worker/Future return retire through the original collector. All eleven probe sources restore. |
| E1098 | `retained-scalar-run-result-ledger`; `retained-scalar-settlement-offset-stacks`; `retained-scalar-unsettled-source-sql` | Invalid path, path-byte-limit and stale precondition first return `thread.durable_commit_failed`, with SQL Run state `recovery_required`. Exact ELF offsets and read-only SQL locate the completion barrier. The children have actual Failed Receipts, matching reserved slots, plans and registers, same-Run/call parents and committed canonical parent results. Unresolved line/dynamic-symbol breakpoint attempts have no evidence credit. |
| E1099 | `completed-derived-failure-red` | Runtime/Tool/Store builds pass original 900 s limits. The public positive completion regression fails before the fix; seven corruption controls pass. Two cases execute; 257 filter-excluded cases receive no pass credit. |
| E1100 | `completed-derived-failure-codec-green`; `completed-derived-failure-full-store` | Rejected/cancelled/timed-out/failed children complete with exact canonical facts, in standalone and same-bank prepaid Store paths. Seven Unknown/state/slot/depth/digest/effect/missing-Receipt counterexamples block completion. All 259 Store cases pass unfiltered. An intermediate JSON assumption fails and is replaced by the original framed codec and paid full decoding. |
| E1101 | `completed-derived-failure-complete-core`; `completed-derived-failure-complete-core-rerun` | An incorrect parameterized `scalarInt` assertion does not compile; parameterized `query` corrects the API use. The next build passes in 407.34 s. Core passes old rejection scenarios through `operation-limit`, then reveals duplicate plugin installation in the artifact-failure fixture. This is not complete Core acceptance. |
| E1102 | `completed-derived-failure-isolated-workspace-core`; `artifact-fault-actual-child-sql` | Independent failure Product receives an independent workspace. Build 307.91 s; run 51.22 s, failing. SQL confirms the actual selected Native read completed. Removing the entire blob root corrupts committed Source artifacts and cannot prove a simple new-publication failure. |
| E1103 | `completed-derived-failure-specific-artifact-core`; `artifact-fault-typed-error-sql` | Only the exact new patch blob is obstructed. Build 340.12 s; run 47.91 s, failing. Actual framed Receipt decoding confirms `application_plan.artifact_store_unavailable`, but generic executing Err becomes Unknown and the parent reports `readonly_delegation.child_outcome_unknown`. |
| E1104 | `completed-derived-failure-known-preview-core` | Build 407.34 s; original Core 48.39 s. The concrete preview executor reports only its own complete storage/generator failure as a known failed result, after current cancellation/generation checks. Original error/file assertions and added exact Failed Receipt/completed Run assertions pass. Core then fails later at the model-selected Program with capacity. |
| E1105 | `known-preview-current-role-ledger` | Build 355.34 s; original Core 46.06 s, failing later. All 202,212 counter/SUM/count checks reconcile. Capacity 150,994,944 bytes, charged 112,708,828, growth 50,331,648, overshoot 12,045,532. Registry costs are 55,630,784 and 23,286,044; live lease sums 49,372,456 and 9,480,640. Fixed buffers cost 237,568. All ten probe sources restore exactly. High-water excess and raw aliases remain paid. |

No public Cangjie signature, storage schema, pin, wire migration, Source,
permission or acknowledgement changes. Registry-backed reads pay before raw
and decoded copies; unknown decoder failures retain the invoice. Standalone
Store retains its existing synchronous codec path without a fallback bank.

Rollback pairs the Store completion proof with its regressions and the concrete
preview result branch with its product fixture. Existing Failed Receipts stay
unchanged and may again block completion under old code. No data is deleted or
reclassified. Current App/Coding artifacts and earlier performance results are
not rebuilt proof of these Cangjie changes. Full Core, Product, remaining
distributions/provider paths, baseline matrix and release acceptance remain
required. GC is explicitly deferred. The task is **not complete**.


E1106 records `completed-derived-final-static`: all 127 selected Python cases
and the complete architecture gate pass, including 2,976 tracked paths,
72 Markdown files, 39 workspace packages and 178 dependency edges. Original
pins, SDK baselines, package inventory and TUI API remain unchanged. Generated
locks are saved and restored. This does not accept the failing full Core.

E1107 records `completed-derived-failure-cleanup-owner-core`: after tightening
the fault fixture to own cleanup only after its directory creation succeeds,
the final build passes in 398.58 seconds. The original Core runs 47.81 seconds,
passes the exact artifact-failure checks and again fails at the later
model-selected Program with capacity. No new quota or return rule is used.


## Product inventory and serialized Pi cancellation

The checks below retain the fixed official November 4 SDK and original quotas,
assertions and deadlines. Evidence names refer to private run directories.
The complete Product gate remains failed. A diagnostic continuation can expose
independent defects after a crash, but cannot turn that crash into acceptance.

| Evidence | Executed scope | Actual result |
| --- | --- | --- |
| E1108 | `attachment-metadata-after-settlement-reapply`; `attachment-metadata-after-settlement-complete-core` | The previously approved same-Prepared metadata/output-ACK candidate is retested after `01e8005d`. Build 390.06 s; original Core 47.36 s, failing at later capacity. All nine candidate sources restore exactly. No candidate is shipped. |
| E1109 | `paid-policy-name-copy-tool-rerun`; `paid-policy-name-copy-full-tool`; `paid-policy-name-copy-complete-core`; `paid-policy-name-copy-withdrawal` | Five focused Tool cases and all 74 Tool cases pass. A paid scalar-name candidate builds in 615.74 s, then original Core fails later capacity after 45.29 s. Its new consumer API and all four candidate sources are withdrawn. Raw getters and high-water accounting remain unchanged. |
| E1110 | `combined-metadata-name-candidate`; `combined-metadata-name-complete-core` | The combined thirteen-file candidate builds in 398.32 s; original Core fails later capacity after 51.67 s. Every candidate source restores. No quota, legacy getter or consumer-return rule changes. |
| E1111 | `retained-settlement-final-unit-dag` | All eight original unit-profile compilation stages pass on retained `01e8005d` Cangjie inputs: Runtime, Tool, Store, Core, Host, Product, RPC and App. Each retains the original 900 s limit and O2 profile. Compilation alone provides no test or release acceptance. |
| E1112 | `retained-settlement-product-fresh-fixtures`; `retained-settlement-product-resume-stat-diagnostic` | All seventeen plugin fixture packages are built through the original gate preparation functions and checked against current manifests, executable hashes and provenance. The first memory fixture run fails on an unobservable malformed process identity. Its owned processes are cleaned up. The raw malformed bytes were not captured, so its cause remains unknown. The later original memory recipe passes; this does not erase the earlier failure. |
| E1113 | `proc-stat-structured-diagnostic-red`; `proc-stat-structured-diagnostic-static` | Two Python regressions fail before numeric-only diagnostics are added. All 45 watcher cases, 129 selected Python cases and the complete architecture gate then pass. Malformed identity still fails closed. Diagnostic fields omit task names, raw bytes, arguments and environment. This adds evidence for a recurrence; it does not claim to fix the unknown earlier identity. |
| E1114 | `boundary-startup-correct-default-target`; `retained-settlement-product-correct-target-continuation` | A self-spawned startup test initially inherits an empty default target, despite its parent using an explicit unit target. The runtime test environment now resolves both to the exact current Product ELF. The original case 71 passes with its original assertions and limits. All 43 earlier passes obtained with the wrong nested default are rechecked. This is a private verification-driver correction, not a production-source fix. |
| E1115 | `retained-settlement-product-cursor1075` and its linked predecessor summaries | The exact 1081-case inventory is exhausted on Product ELF `923add9644b847dd9178a1412644e094e4be57ea07aece58b9d9219aad31d90a`: 498 pass, 575 observed Runtime GC-stack failures remain user-deferred, seven physical crashes remain unclassified, and one actual cancellation regression fails. There are zero unrun cases in this diagnostic traversal and zero whole-module acceptance credit. |
| E1116 | `pi-queued-cancellation-unit-build`; `pi-queued-cancellation-focused`; `pi-queued-cancellation-neighbors` | The original case 794 fails before the fix with lost cancellation code and `plugin.worker_cleanup_pending`. Host and Product rebuild in 300.93 s and 891.66 s. On rebuilt ELF `1d8e96f76b0fa5cf7812f02f424a1f569928a9026aa7da9b399b5bcffcaec365`, original case 794 and fifteen adjacent public cancellation, revocation, capability and isolation cases pass. Case 792 now has an actual Runtime GC stack and is retained as deferred, never retried for a pass. These sixteen passes do not replace full Product acceptance. |
| E1117 | `pi-cancellation-final-static`; `pi-cancellation-generated-lock-restoration` | All 129 selected Python regressions and the complete architecture gate pass after the cancellation and diagnostic changes. Generated locks are saved with full bytes, hashes and differences, then restored. Dependency pins, SDK baselines, package inventory and TUI API remain unchanged. |

The seven unclassified crashes are inventory cases 89, 695, 771, 871, 880,
895 and 1074. Their logs contain `BaseObject::GetSize`, a libc signal, or a
region-index assertion without enough GC frames to satisfy the diagnostic
classification. A GC thread name alone does not move them into the deferred
set. All seven remain failed and receive no pass credit. Process custody is
closed in each recorded run. This does not establish their root cause.

The Pi fix binds the cancellation callback to the actual worker captured for
that invocation. It copies the caller's cancellation kind, code, message and
timestamp into the process cancellation source. After invocation return, the
Host disposes the registration and keeps the serial slot while running the
existing bounded cleanup wait. Incomplete cleanup retains that same owner;
replacement still fails closed. A late callback cannot target a replacement
stored in the mutable thread entry. The original public queued-call test
checks the cancelled result, the independent next call and peak concurrency.
Its assertions and deadlines are unchanged.

This change adds no public Cangjie signature, storage schema, wire protocol,
permission or capacity migration. Rollback pairs the Host lifecycle change
with the original public regression evidence. Numeric process diagnostics and
their Python tests can roll back independently. Neither rollback deletes
Receipts, clears unknown effects, acknowledges an unreturned consumer or
releases an uncollected physical process.

The diagnostic inventory applies to `01e8005d` Cangjie inputs. The sixteen
post-fix Product passes apply to the recorded rebuilt ELF and Host source
SHA-256 `744d70d08873b3164d4ac03decf7d93f790555bc03cc952632cfb493b3c61735`.
Earlier unit and production binaries do not prove the changed Host. Full
Core capacity, full Product and remaining production/distribution, baseline
and release acceptance remain open. GC stays explicitly deferred. No SDK
component is built, no additional external provider call is made, and PR #49
remains Draft. The task is **not complete**.


## Current production packages and request startup boundaries

The following production evidence applies to `a28d159017d6ddec6d2c4c7eceb6c2dc5e43fa9a`.
Later documentation or generated-lock restoration does not alter these tested
Cangjie inputs. All packages use the fixed official SDK and the actual rebuilt
native bridge. No SDK component or external model call is added.

| Evidence | Executed scope | Actual result |
| --- | --- | --- |
| E1118 | `pi-cancellation-nine-production-stages` | Runtime, Tool, Store, Core, Host, Product, RPC, App and Minimal production builds all pass their original 900 s limits. App SHA-256 is `5744b9f540a2515b496964f7144a7ce725d68a31e1de9cbd010a69166a81b2f2`; Minimal is `481697b50e1c9cf71a5f77f55bf5ea2b7b88cfb271bcc0addfedbcfa7eb87388`. These are current builds, not acceptance of every application path. |
| E1119 | `pi-cancellation-current-coding` | Fresh Coding9 assembly passes in 597.21 s. Relocation into the original clean environment, operator setup, cards and ask all pass. Packaged ELF is `5804a9d737830cb687cf8629ad1e61d5131ae008b7e38b18e47396eff24d6e54`; provenance binds it to the actual App source binary and matched bridge. Previously GC-deferred fresh default, initial-prompt and Todo paths are not retried or counted as passes. |
| E1120 | `pi-cancellation-minimal-full-packages` | Fresh Minimal and Full17 assemblies pass, with current production inputs. Minimal relocation and the original actual empty/offline host contract pass. Full relocation and operator setup pass. Full and Coding use the same recorded host ELF. Packaged Minimal SHA-256 is `cda13e861fe3925e94ebfdd7f30ec8d83d373d952814d6fda68bdc9e55ba0307`. Assembly alone is not complete distribution acceptance. |
| E1121 | `pi-cancellation-current-performance`; `pi-cancellation-current-pty` | Current Coding passes all 100 cold starts, all 40 headless samples (p95 464.9 ms against the original 500 ms bound), document/composer/long-transcript journeys, and all fifteen original PTY samples across five 10000-row scenarios. Stream retains 100 chunks and every original latency/output/stall threshold. This is absolute-gate evidence, not an immutable-base comparison. |
| E1122 | `pi-cancellation-current-frontends` | The original full local-provider profile test times out on its first model request at 5 s. The original full CLI entry suite reaches its 180 s outer bound. ACP initialization/authentication/session/configuration reach their assertions, but its first prompt times out at 5 s and cleanup reports `owner.acp_frontend_close_pending`. All three gates fail. The watcher collects all recorded survivors; no unknown identity or unreaped process remains. |
| E1123 | `pi-cancellation-acp-owner-stack`; `pi-cancellation-acp-digest-roles`; `pi-cancellation-acp-durable-state` | Read-only metadata after the original first-prompt timeout contains zero Runs, Model Attempts, Operations, Receipts, audit events and items. A separate no-argument debugger sample observes actual package `SHA256_Update` during first-assembly dependency enable checks. Its role probe counts 1083 file-digest entries across source inspection, materialization, registry reload and enable/dependency inspection. These are debugger call counts, not package counts, leaked-owner proof or uninstrumented timing measurements. No GC failure is captured in these diagnostics, so this timeout stays unresolved rather than GC-deferred. |
| E1124 | `pi-cancellation-current-native-protocols` | Sixteen independent Native protocol checkers pass all 601 reported cases against the newly assembled Full artifacts. Per-endpoint original assertions and internal deadlines remain unchanged. The seventeenth package, Memory, has no equivalent standalone checker here; its application-level 63 MiB acceptance remains separately incomplete. These endpoint checks do not replace Core/Host authority or actual model-path acceptance. |
| E1125 | `pi-cancellation-current-plugin-performance`; `pi-cancellation-current-plugin-performance-writable-home` | The first run reaches a read-only default state directory in the private namespace and fails; this is retained as a harness/environment failure. With an explicit task-private writable default state directory, the complete original absolute plugin performance gate passes seven metric records. Runtime retains its original 12 samples (240 steady IPC exchanges), and both product profiles retain 20 samples. All original thresholds and 300 s runtime/30 s per-sample bounds remain. No immutable-base comparison credit is claimed. |
| E1126 | `pi-cancellation-entry-modes-writable-home` | The private CLI diagnostic also supplies a writable default state directory for its RPC/EOF branches and records only command indices and static verbs. The original main still fails at actual `read README.md:1` after the original 10 s command limit. The test remains failed; no read success, permission acceptance or GC cause is inferred. |

The first model/profile request, first ACP prompt and actual CLI read remain
open acceptance gaps. The ACP sample locates work before Run admission and
shows real package validation in progress. It does not prove a deadlock or
justify skipping content verification, sharing unchecked snapshots, moving
initialization before the request, changing cancellation, or extending a
clock. Operation facts, required plugin handshakes and the atomically frozen
Catalog remain mandatory before model execution.

The new package and performance passes supersede the earlier statement that
all current production binaries predate the Host fix. They do not supersede
any failed full Core, Product, model, CLI, ACP, Todo, Memory, baseline or release
requirement. The seven unclassified physical Product crashes remain failed.
GC remains explicitly deferred, not passed. The task is **not complete** and
PR #49 remains Draft.


## Nested Native stack regression and final artifact verification

The later complete Core check exposes a regression missed by the focused Pi
cases. These results remain visible even though the earlier cancellation
change is already in the Draft PR. No stack size, runtime flag, quota,
assertion or deadline changes to make this check pass.

| Evidence | Executed scope | Actual result |
| --- | --- | --- |
| E1127 | `pi-cancellation-current-complete-core` | Current `a28d1590` Core builds in 455.40 s, then fails after 3.39 s with `StackOverflowError` in the nested Native read-view process/sandbox path. It has not reached the earlier capacity refusal. This is a regression, not a GC-deferred or accepted result. |
| E1128 | `pi-cancellation-core-single-source-control` | Only `javascript_plugin_host.cj` temporarily returns to its exact `01e8005d` bytes. All other source, current Full endpoints, fixed SDK, optimization and original limits remain. Build 422.39 s; original Core 49.56 s, failing at later capacity without stack overflow. Both exact binaries/sources are retained and current source restores in `finally`. This isolates the regression to the Host change. |
| E1129 | `pi-cancellation-separated-cleanup-core` | Extracting only post-return cleanup reduces the selected prologue stack subtraction but is insufficient. Build 360.88 s; original Core 34.02 s, reaching `e5-02-invalid-path` before another `StackOverflowError` during derived SQL admission. This intermediate candidate is not accepted or shipped as the fix. |
| E1130 | `pi-cancellation-returned-frame-core` | Both the original result-consumption match and physical cleanup run in private methods entered after the invocation returns. Build 360.40 s; original complete Core 48.58 s. The stack regression disappears; old rejection/artifact scenarios progress again, and the existing later model-selected Program still fails with `input_attachment.capacity`. Full Core remains failed. |
| E1131 | Exact ELF prologue comparison | The main `invokeObserved` initial stack subtraction is `0x2ea8` in the regressing binary, `0x2798` in the one-file old-Host control and `0x1e08` in the final private-helper candidate. These are measurements of that prologue, not the entire call chain or a performance verdict. The physical call/exception shape is retained by the actual complete Core run. |
| E1132 | `pi-returned-frame-unit-build`; `pi-returned-frame-focused` | Host and Product test-profile builds pass in 230.66 s and 623.28 s. On Product ELF `527117f5db164f206b7e15da357bdaf178ee09d40d2210c9dfbda5ef853c6ba2`, all sixteen original Pi cancellation/revocation/capability/isolation cases pass again. The GC-deferred case 792 is not rerun. |
| E1133 | `pi-returned-frame-nine-production-stages`; `pi-returned-frame-current-coding`; `pi-returned-frame-minimal-full-packages` | All nine production stages pass their original limits. Final App SHA-256 is `cfffc2919bebc32badc5d10e7fe247843d148d57130f4860b05f23c7567d7dd7`; Minimal is `046249471027ccb8ae1b8d59cb47b9c3b23a90887742d8968d3710d71b139537`. All three distributions are freshly assembled through the original production script. Their clean-environment/setup scopes, Minimal empty/offline host and Coding cards/ask pass again. Final packaged Coding/Full ELF is `ae7f31331188ac995f6553e094b6d4aceedbc864ace7866a6e47bc1a10c2e8fc`. |
| E1134 | `pi-returned-frame-native-protocol-identity.json`; `pi-returned-frame-current-performance`; `pi-returned-frame-current-pty`; `pi-returned-frame-current-plugin-performance` | All sixteen final Full Native endpoint binaries are byte-identical to the E1124 601-case protocol passes; unchanged endpoint sources and fixed SDK preserve that evidence. Final host ELF passes all 100 cold starts, 40 headless samples (p95 463.9 ms), document/composer/long-transcript, fifteen PTY samples and the complete seven-record absolute plugin performance gate. Original sample counts, thresholds and clocks remain. This still provides no immutable-base comparison credit. |
| E1135 | `pi-returned-frame-current-frontends` | Final local-provider profile still times out on the original first 5 s request. The original CLI main now passes its actual read, grep and count assertions, but later workspace enable fails with `owner.peer_disconnected` before the paginated grep assertion. ACP first prompt times out at 5 s and reports owner disconnect/broken pipe during cleanup. All three complete entry gates remain failed. There is no direct GC-stack evidence for these failures; no GC deferral or whole-gate pass is inferred. Recorded survivors are collected, with zero remaining/unreaped/unknown identities. |

The final change keeps cancellation bound to the exact captured worker and
preserves the caller's reason. It keeps the serial lock through the original
bounded cleanup attempt. Only result decoding/error projection and cleanup
locals move out of the frame active during nested Native invocation. The
result match is unchanged, payload ownership is unchanged, and a pending
physical cleanup owner still blocks replacement. No new public signature,
permission, receipt, durable schema or logical-payload return rule is added.

Final tested Host source SHA-256 is
`abcf9d9f3b58db6eca45231f5e9de678695572ae20a663799fd7ebaab7599df5`.
Current production/performance evidence in E1133–E1134 supersedes earlier host
binary evidence for these changed Cangjie inputs. E1127 and E1129 stay failed
regression attempts. E1128 is a control, not final-code acceptance. Rollback
must preserve the original cancellation/physical-cleanup contract rather than
restoring the larger regressing frame as a purported complete fix.

The later Core capacity gap, full Product, seven unclassified physical crashes,
positive model/ACP/complete CLI entries, remaining Todo/Memory cases, matched
baseline and complete release acceptance remain required. GC stays deferred.
There is no SDK component build or additional external model call. The task
is **not complete**, and PR #49 remains Draft.


E1136 records `pi-returned-frame-final-static`: all 129 selected Python
regressions and the complete architecture gate pass on the final tested Host
source and evidence update. `pi-returned-frame-lock-restoration` retains exact
generated lock bytes, hashes and differences before restoring reviewed pins.
It also verifies that the result-consumption match moved without content
changes. Only private Host methods and the existing evidence documents change;
no public signature, SDK, dependency or schema migration is added. Full
application acceptance remains incomplete for the failures above.


## Preserve existing operator records during distribution defaults

The existing-record branch in `applyProductDistributionDefaults` calls
`setPluginEnabled(..., true, User)` when the bundle marks that entry enabled.
This overrides a disabled User record and incorrectly resolves a Workspace
record in User scope. The branch contradicts both its preservation comment
and the existing Coding distribution requirements. The fix leaves an existing
operator record unchanged. Normal startup and explicit management retain
activation ownership. Missing defaults still use the original import and
first-assembly enable paths.

| Evidence | Executed scope | Actual result |
| --- | --- | --- |
| E1137 | `core-presence-closed-query` | Replacing the Core fixture's schema-exporting existence query with the existing boolean presence API still fails the original complete Core at later capacity (build 342.31 s, run 43.68 s). This experiment is withdrawn; the fixture restores to exact `cbb4f53f` bytes. It receives no fix or acceptance credit. |
| E1138 | `distribution-existing-record-red` | On the unchanged production branch, four new public Product tests compile in 266.35 s. Explicitly disabled User, imported-but-disabled User and disabled Workspace regressions fail. An enabled User control passes. Actual failures include changed enabled/explicit-disable/lock state and the wrong-scope distribution error. Each case runs against a separately compiled Native C process with the original case limits and closed physical custody. |
| E1139 | `distribution-existing-record-green`; `distribution-existing-record-final-green` | The narrow existing-record fix passes the same four tests after a 393.38 s compile. Adding a public `openProduct` first-install/close/reopen test and rebuilding in 268.29 s passes all five cases. Fresh defaults enable normally; a subsequent operator disable survives reopen without lock mutation. Explicit management enable and real tool calls remain usable. Enabled-instance calls advance from 1 to 2 in the same worker. Final Product test ELF is `9bc355c8525d566e5a5cd7af22281b2e2d19f3e7611a9d76de4b29c8d4718a82`. Natural compiled inventory is 1,086 cases; only these five receive pass credit. |
| E1140 | `distribution-existing-record-nine-production-stages` | All original nine production stages pass with their unchanged 900 s stage bounds. App SHA-256 is `47511d9bce1bdef80f1a3fef39cd2af9cd939f9de55e710833e028065df75b56`. Minimal remains byte-identical to E1133. This is compilation evidence, not fresh distribution, performance or full frontend acceptance on the changed App. |

Final tested `distribution.cj` SHA-256 is
`2274fe73fd76b5426a1aab1bb1d6182f08c2060436a319eb1b60eee1c5e11984`.
The public Native regression source SHA-256 is
`879ac0da6c8e6c55f8f5494ef5242f15ff76da38dae3acff97b1a08429f265b0`.
The direct default-application cases check both registry lock paths, the
absence of a new context selection, retained content identity and actual
post-application execution. The startup case uses the real distributionRoot
configuration path rather than calling a private activation helper.

This fix adds no public signature, dependency, SDK or durable-schema change.
Operators retain control through the existing management API. There is no
migration or automatic state rewrite. Rolling back restores the unintended
re-enable behavior, so a disabled record must not be treated as authorizing
activation. No permissions, Source checks, quotas, ACK rules or clocks change.

The earlier full Core capacity failure, seven unclassified Product crashes,
full Product, full model/CLI/ACP entries, remaining Todo/Memory paths, matched
immutable-base comparison and release acceptance remain open. Known GC
failures stay user-deferred and receive no pass credit. Earlier package and
performance results retain their exact E1133–E1135 artifact scope. This change
does not relabel them as tests of the new App. PR #49 remains open and Draft;
the task is **not complete**.


E1141 records `distribution-existing-record-final-static`: all 129 selected
Python regressions and the complete architecture gate pass. The latter includes
documentation, dependency pins, library boundaries and SDK API baselines.
`distribution-existing-record-lock-restoration` retains generated root lock
bytes and the exact diff before restoring the reviewed lock. No dependency
change is included. Only the production existing-record branch, five public
regressions and the existing evidence ledgers change.


## Current boundary of the seven previously unclassified crashes

E1142 records `product-unclassified-current-seven` on `62375ebc` with the exact
E1139 Product ELF, final 1,086-case inventory and the original seventeen Native
fixture packages. Only the seven previously unclassified identities are
selected. Known GC-deferred identities are not retried. Original test bodies,
case limits, qualified SDK results and physical process custody remain.
All seven selected tests crash; none receives pass credit.

Six current samples include an actual SIGSEGV and Runtime GC frames:
`CodingDistributionTests.freshConfigurationPreservesDisabledUserProviderAndKeepsManagementUsable`,
`PluginProcessEnvironmentTests.reflectedRawAndJsonEscapedSecretsNeverReachPluginOrCanonicalOutput`,
`PluginShellManagedJobTests.sameCallIdAcrossThreadsKeepsIndependentTaskCancellationAndServiceLease`,
`PluginShellServiceTests.cancellationJoinsActualBashChildBeforeCleanupAcknowledgement`,
`InstalledWorkflowDocumentTests.actualSetCreatesThenReplacesOnlyAfterCanonicalGoalRead`,
and `WorkspaceFrontendTests.absentSelectionAndDisabledActualPackageFailBeforeAnyNewRoot`.
The first five capture `MapleRuntime::CheckAndPush`; the last captures
`Mutator::GcPhaseEnum`. These current observations enter the user-deferred GC
boundary. They do not establish a repair or classify the older incomplete
backtraces retroactively.

`PluginRuntimeContractTests.importedPortableCodexSkillsUseInstalledContextProvider`
still has no adequate backtrace: it reports SIGABRT, the regional assertion
`toRegion2Idx != INVALID_VALUE`, a GC thread name and one unresolved native
frame. The private runner's initial classifier labels that combination as GC,
but evidence review rejects that label. The original classifier output is
retained separately; the reviewed summary records this case as
`FAIL_NEEDS_ANALYSIS`. A thread name and assertion are not substitutes for the
required GC stack evidence. No crash, quota, timeout, assertion or return rule
is relaxed. Current counts are zero passes, six observed GC-deferred failures
and one unclassified failure, with no full Product acceptance credit.

This diagnostic changes no product code or acceptance gate. The non-GC Core
capacity, full frontend startup, baseline and release requirements stay open.
The 63 MiB Memory path also retains its earlier observed GC barrier and its
unresolved historical OOM. GC remains deferred, PR #49 remains Draft, and the
task is **not complete**.


## Fresh Coding artifact and retained frontend cores

| Evidence | Executed scope | Actual result |
| --- | --- | --- |
| E1143 | `distribution-existing-record-current-coding` | Original production Coding assembly passes in 475.47 s using E1140 App. Clean environment, operator setup and original cards/ask golden scopes pass. Packaged ELF SHA-256 is `eb99840258c3e09ec1e10ca16ba836801414566dac005ee18016feda0a3f6233`; provenance binds source App `47511d9bce1bdef80f1a3fef39cd2af9cd939f9de55e710833e028065df75b56`. Fresh default/initial/Todo paths already blocked by observed GC are not retried. Full Coding/release acceptance is not claimed. |
| E1144 | `distribution-existing-record-current-frontends` | The three original complete local-fixture entrypoints still fail. Provider profile's first model request exceeds its original 5 s. CLI now disconnects at actual plugin import (before the earlier read/grep progress), and ACP's first prompt exceeds 5 s with owner disconnect/broken pipe. These are failures, not successful retries. Watchers collect survivors with zero remaining, unreaped or unknown identities. No extra real provider call occurs. |
| E1145 | `distribution-existing-record-saved-frontend-cores` | Read-only GDB of two already saved system cores binds the exact E1143 private binary, actual broker role and the corresponding serial CLI/ACP gate intervals. Both terminate with SIGSEGV. CLI's crashing thread contains `BaseObject::GetSize`, `WCollector::MarkObject`, `ConcurrentMarkingWork::Execute` and `GCPoolThread::WorkerFunc`. ACP's crashing thread contains `GCTib::ForEachBitmapWord`, `Mutator::GcPhaseEnum` and `VisitStackRoots`. Both current samples have direct Runtime GC evidence and remain user-deferred, without pass credit. No new execution, arguments, locals, environment dump or SDK build is used to obtain the stacks. |

The two retained uncompressed cores total 1,387,823,104 bytes. Their hashes,
function-only stacks and exact artifact binding remain private failure evidence.
GDB reports unavailable SQLite shared-memory mappings from the completed test
directories; executable and Runtime symbols resolve. No application-data
contents are read from those mappings or included in the repository.
The missing historical portable-Skills backtrace in E1142 is not recovered
from the system core inventory and remains unclassified.

These direct stacks qualify only the two current CLI/ACP failures for the
existing GC deferral. They do not reclassify the local model timeout, older
unmatched failures or all subsequent unexecuted entry assertions. Initial model
startup, full Core capacity, full Product, matched baseline and release work
remain incomplete. `distribution-existing-record-post-package-lock-restoration`
retains all nine generated locks and restores the reviewed pins before
publication. Product source and the five E1139 regressions are unchanged.
PR #49 remains Draft and the task is **not complete**.

## Portable Skills signal-stop evidence

E1146 records `portable-skills-fresh-fixture` and
`portable-skills-signal-fresh-diagnostic` on source `fd392ba5`.
The old fixture directories referenced by the private continuation driver are
absent. That driver fails before starting GDB and receives no execution credit.
The original Skills preparation entry builds a replacement package, passes its
16 algorithm cases and 45 protocol cases, and verifies the packaged content.
Its Native entrypoint SHA-256 is
`592f855506ae6683f49d856bb3542cf511522d8cdc3d3ff2156aead3c1bc7b26`,
identical to the earlier Skills fixture. No SDK component is rebuilt.

GDB runs only
`PluginRuntimeContractTests.importedPortableCodexSkillsUseInstalledContextProvider`
on the unchanged E1139 Product ELF
`9bc355c8525d566e5a5cd7af22281b2e2d19f3e7611a9d76de4b29c8d4718a82`.
The actual test child stops on SIGSEGV in its `gc-main-thread`.
Function-only frames contain `CheckAndPush`, `GCTib::ForEachBitmapWord`,
`Mutator::GcPhaseEnum`, `TracingCollector::VisitStackRoots`, and
`WCollector::DoGarbageCollection`. This current sample has direct Runtime GC
evidence and enters the existing user-approved deferral, without pass credit.
The older regional-assertion abort still has no complete backtrace.

The debugger follows the actual test child and retains the original 60-second
case and 90-second process bounds. It stops at the signal and terminates its
inferiors after collecting function names. Its exit code 0 does not mean that
the test passes. The watcher records no surviving, unreaped, or unknown
processes. Debugging can perturb scheduling. No arguments, locals, object
contents, or full core dump are collected.

The first local-provider timeout, full Core capacity, remaining Product flows,
matched baseline, and release gates remain open. PR #49 stays Draft.

## Prepared producer and consumer lifetime states

E1147 records `core-prepared-lifetime-states` on source `fd392ba5`.
The complete original Core contract rebuilds in 623.66 seconds and fails in
58.45 seconds at the model-selected readonly Program with
`input_attachment.capacity`. Both original 900-second bounds remain.
One temporary source probe records only stable numeric owner IDs, invoices,
consumer counts, header counts, and producer/unknown/released flags at their
actual mutation sites. It changes no allocation, Source, ACK, or refund rule.
The source probe is removed after the run. The cached diagnostic ELF is not a
production artifact.

The 3,452 events distinguish 63 actual Prepared owners. All 63 record their
producer return. Ten record full release with no unknown hold. The remaining
53 have `unknown=true` and remain paid, with a combined recorded base invoice
of 14,412,280 bytes. Four concrete consumer loans remain across those owners.
Zero counted loans on the other owners do not prove that raw exported aliases
have returned. The earlier complete bank reconciliation remains in
`known-preview-current-role-ledger`. This narrower probe is not a new complete
bank ledger.

This rules out a missing Prepared producer-return notification in this run.
The unresolved path is actual raw metadata consumption and alias retirement,
including the four remaining explicit loans. Neither producer return nor a
logical terminal state permits clearing an unknown hold. No quota increase,
guessed consumer ACK, or withdrawn candidate is shipped.

## First local provider startup under trace

E1148 records `provider-profile-retained-writable-diagnostic` and
`provider-profile-retained-path-diagnostic` against source `fd392ba5` and the
unchanged Coding ELF
`eb99840258c3e09ec1e10ca16ba836801414566dac005ee18016feda0a3f6233`.
Each uses a task-private clone of an actual previously installed operator
home. Its regular installed package bytes and the provider package digest are
verified; namespace binding preserves their real installed paths. The original
home is untouched. The lock hash remains
`62386514f3fa45eb0b2d0f914ac43cb74b98d617b2abe01375414da227be206d`
before and after each request.

The actual `--print --model profile-one/shared-model` request reaches the
original five-second bound in both traced runs. Neither local HTTP fixture
receives a request. The path trace records repeated opens of installed package
manifests, libraries, and executables. This establishes work to investigate,
not the cause of the untraced timeout: tracing adds overhead and a concurrent
compilation perturbs timing. Both process watchers record closed custody
without remaining, unreaped, or unknown processes.

Earlier diagnostic attempts failed during setup or cleanup before this
request and provide no timeout attribution. These retained-home runs do not
accept fresh installation, matched-baseline performance, or the complete
provider-profile flow. No new external model call is made. The startup failure
remains unlocated; there is no new GC classification, integrity bypass,
cross-transaction verification cache, deadline increase, or passed model flow.

## Unaccepted ownership candidate and Native stack regression

E1149 records two exact-source Core/recovery runs of an uncommitted ownership
candidate based on `fd392ba5`. Both preserve the original 900-second build and
case bounds, fixed SDK, 144 MiB bank, 16 MiB floor, and 64 MiB attachment work
invoice. These elapsed times describe diagnostics, not performance acceptance.

| Evidence directory | Build seconds | Core seconds | Actual result |
|---|---:|---:|---|
| `core-opaque-boundary-candidate` | 480.40 | 3.07 | New `StackOverflowError` |
| `core-opaque-boundary-stack-corrected` | 376.39 | 48.61 | Original model-selected PTC path still rejects `input_attachment.capacity` |

The first Native ELF is
`3132a7090f9a2f2c8a5d36618bd804c3ebc9bd6cf36d903f0470ed332e849bdc`.
Its backtrace identifies nested Prepared loan closures around the read-view
worker. A private counted data holder lets those capture helpers return before
entering Native code and clears its fields before consumer return. The second
ELF is
`5815d14d59438bfd65bedd23c0563138ea1f22fdc72018790fbb93b7f9befbde`.
It records no stack overflow in that run, but still fails the capacity case.
Both watchers record closed custody with no remaining, unreaped, or unknown
processes. Neither source variant accepts Core or the ownership change.

The `core-opaque-boundary-unknown-sites` debugger attempt cannot resolve its
source-line breakpoint and exits before starting the Native case. It supplies
no Raw-export callsite or acceptance evidence. Refusal-time state and actual
first-export callers still require observation; final producer-return totals
alone cannot establish the state at the earlier refusal.

## Silent untraced provider startup sample

E1150 records `provider-profile-retained-capture-diagnostic` and its separate
process watcher. The Coding ELF is unchanged from E1148. This request starts
from another clone of the original retained operator home, not the homes
modified by the earlier diagnostic requests. Only stale socket nodes are
omitted; installed regular package and lock bytes are verified.

The original five-second `--print` request times out without strace. Neither
stdout nor stderr has captured bytes, and both local HTTP fixtures receive
zero requests. The operator lock hash is unchanged. The saved database has
zero `runs`, `model_attempts`, and `operations` rows. The watcher records closed
custody with no remaining, unreaped, or unknown processes. Existing path-trace
signal records contain no observed SIGABRT or SIGSEGV before truncation.

This narrows the sample to silent work before Run admission. It does not
identify the blocking phase, prove absence of GC involvement, or establish a
deadlock. Concurrent compilation still prevents a matched performance claim.
First local model startup remains incomplete; no integrity check, permission,
deadline, or acceptance requirement is relaxed.

## Refusal-time metadata and historical high-water attribution

E1151 records `core-opaque-boundary-refusal-sites`. This is a temporary
mutation-site probe of the unaccepted ownership candidate, not a passing Core
run. At the actual attachment refusal:

| Accounting field | Bytes |
|---|---:|
| Original bank capacity | 150,994,944 |
| Already charged | 111,628,484 |
| Requested incremental growth | 50,331,648 |
| Overshoot | 10,965,188 |
| Active Prepared base invoices | 3,660,096 |

Sixteen Prepared owners are active at that point. Eleven Workspace owners
have returned producers, no counted consumers, and unknown exports; four
preview owners still have counted consumers; the current Program owner has
not returned. The first-export stacks for all eleven unknown owners identify
`ToolInvocationContext.executeDerivedFrame` reading `prepared.call.name`.
This identifies a retention edge, not permission to refund its backing or a
complete explanation of the bank charge. The temporary probe sources restore
exactly.

`core-registry-historical-peak-attribution.json` separately replays the
already-reconciled E1105 ledger from source `ec5fa1d2`. It captures each
Registry allocation at a consistent derived-ledger observation immediately
after its final high-water growth:

| Historical allocation | Event line | Charged high-water bytes | Live lease SUM bytes |
|---|---:|---:|---:|
| Registry group 1 | 130,621 | 55,630,784 | 55,630,784 |
| Registry group 214 | 200,348 | 23,286,044 | 23,286,044 |

The private record preserves the role decomposition at those peaks. It is
historical evidence, not a measurement of the current candidate. Neither
high-water excess at a later observation nor returned producers establish a
leak, physical heap size, or an actual consumer ACK.

## Withdrawn independent Core-frame candidate

E1152 records `core-independent-copy-frame`. A same-bank independent DATA
frame retains the real 16 MiB floor and existing return guards, but its
458.81-second build is followed by a failing 28.28-second Core run. The ELF is
`0f09ee3e470cae85f5cab7df0db3581aa8e9bf2a44d6c9247395b2ca5cd2c4db`.
The first ungranted file-plan scenario raises `NoneValueException` while
reading its expected error field. This run does not establish that the
underlying error was a capacity rejection.

That payer change is withdrawn. The original Registry-backed copied-plan
payer is restored; the cached experimental ELF is not evidence for restored
source. An unrun scheduler-label candidate is also withdrawn after matching
the scope of the earlier rejected name-copy experiment. Its patch is retained
privately, with no build, test, or implementation credit.

## Existing startup phases and unavailable CPU sampling

E1153 records `provider-profile-retained-startup-forwarded-diagnostic` and its
process watcher. The original fixture filters `AXYNDRA_` variables, so the
earlier `startup-stage` attempt did not forward the diagnostic flag and is not
startup-stage evidence. The valid diagnostic forwards only Axyndra's existing
`AXYNDRA_TUI_PERF_TRACE` switch.

On the unchanged Coding ELF, the frontend emits
`configuration_loading_completed` at 91,231,563 ns. This stage is emitted by
`OwnerNativeClientFrontend180`, not by completed server-side Product assembly.
The request still reaches the original five-second timeout with zero local
HTTP requests and an unchanged operator lock. It does not locate the
remaining server work or accept first-model startup.

The `cpu-sample` and `cpu-parent` records preserve denied `perf record`
attempts. The separate host-parent inherited attempt is also denied before
launching its command. They contain no usable CPU samples; a successful
counter-only prerequisite is not sampling permission. No permission setting,
SDK, deadline, or model-service configuration is changed. These failures
provide neither GC attribution nor performance acceptance.

## Caller-owned file-plan views and narrowed candidate

E1154 records `core-preview-owned-descriptor-cleanup`. The concrete preview
executor now closes its initial caller-owned service descriptor on every
return path and closes both successful post-generation check views. These
are fresh captured-record views; closing them does not close the installed
generation, change its Source, or acknowledge result DATA.

With the broader ownership candidate still present, the build passes in
565.72 seconds. The real Core run completes the file-plan section, including
the known artifact-store failure, then fails at the original model-selected
PTC attachment after 65.87 seconds. Its ELF is
`f83dee780628430823c6eac9ce57022ac57f605cd01e75c9d65a76565a80268a`.
Process custody closes with no remaining, unreaped, or unknown processes.
This is scoped execution evidence, not full Core acceptance.

The broader ownership rewrite is then withdrawn, including its three new
source files. Exact source snapshots, the patch, and withdrawal scope remain
in private evidence. Only the preview-view closure and an owned scalar
distribution-presence check remain under implementation.

The latter replaces complete compatibility-record copies used only for a
presence decision. It preserves the original per-default snapshot timing,
all package integrity checks, existing operator states and scopes, and the
empty-Registry-only assembly rule. Effective-record ranking for context and
workspace selection is unchanged. It is not yet a verified explanation or
fix for the first-model timeout. These two changes require their own final
source builds and Native checks; earlier candidate artifacts do not qualify
them. Core capacity, remaining non-GC flows, matched baseline and release
acceptance remain open. GC remains deferred and PR #49 remains Draft.

## Narrowed candidate production and Native build bounds

E1155 records `owned-view-nine-production-stages` on the two E1154 source
changes. All nine original production stages pass within their unchanged
900-second limits: Runtime, Tool, Store, Core, Host, Product, RPC, App and
Minimal. The resulting App SHA-256 is
`459579d5496a60f4306f15f171692c4af97673600a7b32643c276276a9cf9bb6`;
Minimal is
`046249471027ccb8ae1b8d59cb47b9c3b23a90887742d8968d3710d71b139537`.
These are production compilation results, not Core execution, matched
performance or release acceptance.

E1156 preserves `owned-view-native-regressions` and
`owned-view-native-regressions-resumed`. Both one-job Product test-profile
builds hit their original 900-second limits. Neither runs a test or produces
a current-source Native pass. The first leaves only a few seconds for its
last observed compiler child; the resumed build still compiles dependencies.
Those observations do not establish a compiler hang. Both watchers finish
cleanup with no remaining, unreaped or unknown processes.

The existing eight-stage test-profile build procedure remains applicable,
with each original stage bound and Product's one-job setting unchanged.
Any later staged success must retain these two failures and cannot serve as
cold-build timing acceptance. The current Coding assembly and original
full Core/recovery still require their own execution evidence. Complete
Product, first local model request, matched baseline and release acceptance
remain open. GC is deferred; PR #49 remains Draft and the task is incomplete.


## Current Coding smoke and rebuilt complete Core

E1157 records `owned-view-current-coding` and `owned-view-final-core` on the
same two E1154 source hashes. The fresh Coding9 assembly passes in
865.88 seconds within its original 2100-second limit. Clean-environment
relocation, setup, cards and ask pass with closed physical custody. The
packaged ELF SHA-256 is
`00ea5a21b024255d8e2aa7dfbd3b5101f6fff3e18f02fc0b7863fd1cf78d690f`.
Cards and ask create no model Attempt or Run in their fixture databases;
they are not evidence of a successful provider request.

The dedicated Core cache is rebuilt from the retained two-source candidate,
not reused from an abandoned ownership experiment. Compilation passes in
590.55 seconds. Its ELF SHA-256 is
`bac82f5fc53470443f53385e8eadabea6321c98f5a2197819ac7b99602a6b187`.
The original complete Core/recovery case runs for 93.15 seconds, passes the
file-plan scenarios through the known artifact-store failure, then fails at
the original model-selected read-only Program with `input_attachment.capacity`.
Both build and execution finish with no remaining, unreaped or unknown
processes. This is final-source failure evidence, not complete Core acceptance.

E1158 records `provider-profile-retained-owned-view-current-diagnostic`.
The original local request still times out after 5.003 seconds, with zero
HTTP requests and an unchanged installed-operator lock. The presence-only
distribution read has not fixed this boundary.

The associated parent-GDB records are intrusive diagnostics, not acceptance.
The first stops at an unrelated helper exit. The corrected all-inferior
capture observes the actual Product owner in `openProductAssembly180`,
plugin activation and a sandboxed process launch; nested PID namespaces
produce debugger validity warnings for sandbox children. An owner-only
handoff attempt fails before launching the program; its replacement loses
the owner to a later helper, captures no functions, and requires watcher
cleanup of detached processes. None locates the timeout's cause or provides
GC, successful-model, fresh-install or performance credit.

The eight-stage Native build, remaining non-GC flows, matched baseline and
complete release acceptance remain open. GC remains deferred, PR #49 stays
Draft, and the task is incomplete.


## Narrowed candidate Native regressions and static gates

E1159 records `owned-view-unit-dag` and
`owned-view-native-regressions-after-verified-cleanup`. The original staged
test-profile builds pass Runtime, Tool, Store, Core and Host, but Product
again hits 900 seconds. RPC and App are not reached in that attempt. Normal
dependency compilation still consumes part of Product's stage; the last
observed compiler child has about 64 seconds left. This does not establish
a compiler hang or accept the eight-stage build.

After those normal dependencies exist, the same one-job Product command
passes in 414.90 seconds, still within its original 900-second bound. All
three preceding timeouts remain failed evidence, not cold-build acceptance.
A private continuation-precondition error launches neither compilation nor
tests and receives no credit. The corrected prerequisite verifies physical
cleanup of the failed build; it does not treat that cleanup as a DATA ACK
or weaken successful-case custody checks.

The current Product ELF SHA-256 is
`0d2b7c5c3a40f37e146534f404508401a3e6aa41e0a28c253c08a8de4debdcf2`.
Natural enumeration finds 1,086 cases. The original five real Native
`DistributionExistingNativeRecordTests` all pass: explicit User disable,
imported-but-disabled User state, Workspace scope without User shadowing,
continuous use of the same enabled process, and fresh startup followed by
disable/reopen/management re-enable. Each qualified SDK result reports one
pass, zero failures and zero errors; all physical custody checks pass.
The other 1,081 cases receive no current-ELF execution credit.

E1160 records `owned-view-final-static`: all 129 selected Python regressions
and the complete architecture gate pass. The latter checks 2,977 tracked
paths, 72 Markdown files, 39 workspace packages and 178 local dependency
edges, with zero remaining baseline boundary violations. Ten generated
locks are preserved with exact differences and hashes, then restored to
the reviewed pins; no dependency change ships.

`owned-view-source-newline-restoration` restores untouched mixed line endings
in `distribution.cj`, avoiding an unrelated whole-file diff. Its published
SHA-256 is
`b613d6c882b91565e2a1b4065093e4888ac1d086d19ab9dbe92dfbb92d622e70`.
Normalizing those line endings exactly reproduces the compiled/tested source
SHA-256
`131c29dc93c5847a86768b7c9cb4f68d2963f09dddbe32121e773f0d72f3be33`.
This is a whitespace-only source-equivalence record, not a new runtime
execution. The preview executor's source bytes are unchanged. Artifact
identities and earlier exact-source hashes remain attached to their runs.

The two narrow fixes preserve the existing public API, package integrity
checks, operator activation state, Source, actual result ACK and original
resource limits. Their scoped checks do not solve E1157's complete Core
capacity failure or E1158's first-model timeout. Remaining non-GC Product
and application flows, matched baseline and release acceptance stay open.
GC remains deferred, PR #49 stays Draft, and the task is incomplete.


## Owner-only startup capture and publication checkpoint

E1161 records `provider-profile-retained-startup-parent-gdb-owner3-diagnostic`
and `provider-profile-retained-syscall-duration-diagnostic`. The corrected
debugger handoff follows the actual owner through `setsid`'s fork, then
stays with that owner instead of following plugin helpers. Its function-only
sample observes `openProductAssembly180`, plugin activation and native
sandboxed process launch. This is intrusive startup evidence, not a
successful model request, a CPU profile or a GC classification.

The separate five-second syscall trace runs without another task build.
It observes 16,943 completed reads returning 997,674,973 bytes across all
traced descriptors. Those bytes are not attributed solely to package files.
Completed clone calls total 14.50 ms and completed exec calls total 13.11 ms;
durations overlap across threads and do not represent CPU shares. Repeated
package opens and continued reads at the deadline do not prove which work
causes the untraced timeout. The original five-second request bound and
all integrity checks remain unchanged. Every owned process is collected.

The two narrow source changes are committed as `b18c9b7` and `17880ed`.
Their executed artifacts retain the `fd392ba5` base plus exact working-source
hashes and the E1160 newline-only equivalence. No database, wire, dependency
pin, public API, resource limit or DATA-ACK migration is introduced.
An immutable `4d88fa60` baseline checkout is prepared separately; it has
not yet produced fixed-SDK comparison artifacts or performance results.

Core capacity, first local model startup, remaining non-GC flows, the
matching baseline and complete release acceptance remain open. GC stays
deferred and PR #49 stays Draft. This is a publication checkpoint, not
completion of Issue #45 or its remaining requirements.


## Fixed-SDK baseline artifacts and first-request comparison limits

E1162 supersedes E1161's unbuilt-baseline checkpoint. The separate immutable
`4d88fa60` checkout now passes all eight original production build stages.
Each stage keeps its original 900-second limit and the fixed official SDK.
The baseline App SHA-256 is
`7f2423b7a00b24dcd89f85b7f599d808eda7faaaa0d30b4cb504a8ea6df750ea`.
Evidence is `matched-baseline-fixed-sdk-build`,
`matched-baseline-normalized-lock-build` and
`matched-baseline-original-package-profile`.

The original version-0 lock fails before compilation against an incompatible
cached yjson checkout. The annotated tag object
`c91859feb77aeba392a1fad0f99d731df66be831` peels to the expected commit
`54b4965dee0f0b96710cbc678ec5ec9a126b055c`.
Baseline-only lock normalization to version 1 preserves all three peeled
dependency identities. It changes neither tracked behavior sources nor the
SDK, and does not run `cjpm update`. This is not evidence of a moved tag.

The original package and two-profile localhost fixture pass:

| Baseline profile | Observed request wall time |
| --- | --- |
| `profile-one` | 0.814285 s |
| `profile-two` | 0.843435 s |

Exactly two localhost HTTP POSTs occur and physical process custody closes.
The package ELF SHA-256 is
`a85907b7df0bb579ceb9b68339eadbc1c43b165616571187921bd6debd3af498`.
These are local deterministic responses, not external model calls.
The baseline's fresh built-in setup differs from the candidate's retained
nine-plugin Native setup. These two observations do not complete the
same-condition activation, concurrency, output, memory, cancellation or
performance matrix.

## First-request startup phase attribution

E1163 records `provider-profile-retained-numeric-phases1165-diagnostic`.
Temporary outer Product and finer JavaScript-host probes use the
`d66fd3f7` behavior sources plus their recorded observer hashes. The original
five-second local request still times out with zero HTTP POSTs. The operator
lock stays unchanged and physical process custody closes.

The eight completed activations spend 461–534 ms each in capture before
launch, compared with 22–37 ms in spawn and handshake. The complete activation
ranges are 547–653 ms. Initial Registry loading takes 464 ms. Activation 7
finishes at 5,406 ms, after the original request deadline.
Pin lookup, generation construction, metadata getters and sandbox planning
do not account for the large capture interval in this sample.

`HostJavaScriptPluginHost.mount` calls
`PluginRegistry.captureInstalledOwnedFrame101` through `captureExecutionPin`.
That path reloads and re-inspects the complete User and Workspace Registry
for each activation. This identifies a repeated verification boundary,
not CPU attribution, a deadlock or a GC failure. Source, lock, inode, path
and complete-byte verification remain required. No broader verification
cache or first-install-only serialization exception is applied.
The instrumented package is diagnostic, not a release artifact.

## Reconciled Core charges and legitimate retained Contexts

E1164 records `core-growth-attribution/run` and
`core-snapshot-custody-attribution`. Both rebuild temporary numeric observers
over the original `d66fd3f7` Core behavior. The complete original Native Core
still reaches the model-selected readonly Program and fails
`input_attachment.capacity`. Every observed bank total and derived-lease SUM
reconciles at the refusal:

| Sample | Bank capacity | Charged | Actual requested growth | Overshoot |
| --- | ---: | ---: | ---: | ---: |
| Initial owner attribution | 150,994,944 | 112,563,228 | 50,331,648 | 11,899,932 |
| Snapshot custody attribution | 150,994,944 | 112,563,084 | 50,331,648 | 11,899,788 |

The initial sample binds a 9,360,096-byte peak invoice to
`ownedProductFilePlanCanonical204` and a 4,537,260-byte peak invoice to
`requireCompletedDerivedSettlement240`. The first factory funds its existing
8 MiB construction allowance before loading the plan. The second constructs
a full arguments DOM and typed plan only to compare `bindingDigest`.
These are accounting and call-stack observations, not physical-memory
measurements or permission to lower invoices without removing actual work.

The second sample has three live toolset producer graphs at refusal. Two
earlier preflight Contexts each retain one snapshot share, with no observed
Raw export or active loan. Those facts do not prove that an opaque policy,
resolver or executor has returned its original Context. E1058's real public
`CapabilityPolicy` counterexample still applies. No unknown debt is refunded.
The bank, floor, attachment working invoice and actual owner-return rules
remain unchanged.

## Withdrawn allocation and Context-retirement experiments

E1165 records the dispositions of `catalog-scalar-name-candidate` and
`digest-balanced-candidate`. The scalar-name experiment still fails complete
Core capacity and the original local request deadline. The two-reader
balanced-file digest experiment compiles all nine production stages but its
request still times out at five seconds with zero HTTP POSTs. Neither is
promoted as a fix.

The balanced digest follow-up debugger capture observes only the outer
launcher waiting for `chmod`. It never reaches the actual-owner handoff.
That capture receives no owner CPU, GC, deadlock or request-success credit.
No package verification, original timeout or resource limit changes.

E1166 records
`core-typed-result-context-return-source/disposition.json`.
A blanket private-helper return on typed `Result.Err` is unsafe and withdrawn.
E1058 already proves that a public `CapabilityPolicy` can retain the real
Context through such a failure. Scoped hook completion is not that policy's
ACK. The experiment's smaller bill is therefore invalid retirement evidence;
its complete Core also still fails capacity. Its separate uninstrumented
build reaches the original 900-second limit without executing Core.

The accepted and observer Core sources are restored to their exact original
bytes. Restoration does not restore a previously built ELF: every target
containing this withdrawn candidate is ineligible until rebuilt from the
retained source. No Context-retirement candidate is committed.

Core capacity, first local model startup, remaining non-GC flows, matched
baseline acceptance and complete release acceptance remain open. GC stays
deferred, PR #49 stays Draft, and the task is not complete.


## Historical plan validation without the unused arguments DOM

E1167 records `store-derived-header-red` and `store-derived-header-green`
on a private `d66fd3f7` checkout. The new real SQLite regression reaches
`Runtime.finish(Completed)` with a settled failed derived Receipt and an
actual canonical parent ToolResult. Two original floor reservations and an
11 MiB retained invoice stay live in its fixed 32 MiB test bank.
The original production codec fails
`thread.durable_commit_failed: logical payload aggregate decoded capacity is exhausted`.
This is a fixed-capacity accounting test, not a product-quota change or
physical-memory measurement.

The three-source candidate removes the full arguments DOM only from the
private historical digest check. `StoredValuePaymentMeter` still validates
every original frame, count, depth, UTF-8 sequence, number, duplicate field
and final EOF. Its private projection preserves the required Object kind of
`arguments` and selects every metadata field read by the original decoder.
The public full codec and the Boolean-only historical comparison share that
same metadata decoder. No projected `NormalizedOperationPlan` escapes the
private comparison frame.

The original payer funds the complete raw text, meter and selected typed
metadata before allocation. The same-transaction exact-byte SQL joins,
Source, ancestry, Receipt, unknown-consumer handling and standalone full
codec remain unchanged. No invoice is refunded because a callback or typed
error returned.

The unchanged regression passes after the change and observes the completed
Run, original failed child Receipt and exactly one canonical parent result.
The nine malformed argument and metadata variants pass their rejection case
both before and after the change. Both equal canonical plan cells are
tampered, so SQL self-equality cannot replace decoder validation.
Full natural Store execution passes **261/261**, with no skipped cases,
errors or failures. The one-job build takes 421.76 seconds within its original
900-second limit; full Store execution takes 38.18 seconds.
The Store unittest ELF SHA-256 is
`63e39d50a1af1816502b82e8eb4cf65d01d9fd4b4169ffd745cadb36e6fc8139`.
Exact source hashes and original failed receipts remain in the evidence.

This proves the SQLite completion fix, not complete Core, installed-worker
launch, model startup, performance or release acceptance. The candidate is
not yet promoted to the PR behavior sources. Complete original Native
Core/recovery must be rebuilt and executed separately. The task remains
incomplete, GC stays deferred, and PR #49 stays Draft.


## Rebuilt Core after the historical-header fix

E1168 records `store-derived-header-core-seed` and
`store-derived-header-complete-core`. The private candidate rebuilds from
the verified retained Core seed, not a withdrawn or instrumented ELF.
Its unchanged complete Native Core/recovery build passes in 837.30 seconds
within the original 900-second limit. The rebuilt ELF SHA-256 is
`10592462e0265f79cf147fc54bb0c6a12fd5ddac58cc8e99c9f1f3e653e1947e`.

The real execution runs for 59.06 seconds, reaches all original logged
file-plan scenarios through artifact-store failure, and still fails the
model-selected readonly Program at the original fixture line 2446 with
`input_attachment.capacity`. Physical process custody closes.
The strict historical-header fix therefore has a passing SQLite consumer
regression and complete Store module, but does not close complete Core
capacity. No reduction in the unobserved refusal-time invoice is inferred
from the earlier attribution samples.

The original bank, floor, attachment working invoice, fixture, Source,
SQL, opaque-consumer debt, actual ACK and process-reaping rules remain.
Core capacity and the other non-GC acceptance gaps stay open. GC remains
deferred, PR #49 remains Draft, and the task is not complete.


## Historical-header source promotion

E1169 records `store-derived-header-promotion/source.json` and supersedes
E1167's not-yet-promoted status. The four Store implementation and regression
files are now in the accepted-source checkout with exact byte equivalence
to E1167's complete 261/261 Store run and E1168's rebuilt Core artifact.
No rerun is claimed for copying those identical bytes.

The fix preserves the public codec signature, stored plan representation,
database schema, dependency identities and original accounting limits.
It introduces no storage or wire migration. Its narrow completion fix does
not change E1168's complete Core capacity failure into a pass. Combined
Product behavior and final production, package, baseline and release gates
still require their own current-source evidence.


## Caller-owned startup records and Native regression bounds

E1170 records `startup-record-scope-candidate`,
`startup-record-scope-original-unit-dag` and
`startup-record-scope-dependency-ready-native`.
Serial startup now consumes `OwnedPluginRecordList` directly and closes each
transferred record and the list. The first-install-only batch keeps its
original control invoice and width, uses fixed Future slots, joins every
started producer, and closes its requested-record list after the complete
private helper returns or unwinds. Installed generations keep their own
separately captured execution pins. This does not return an opaque Context,
acknowledge plugin DATA or treat process exit as a DATA ACK.

Two dependency-heavy Product builds and the later staged Product build each
hit their original 900-second limit. All remain failures with zero Native
case credit. The five preceding original unit stages pass. After the staged
attempt produces the normal Product artifacts, a dependency-ready one-job
Product build passes in 391.53 seconds with the same 900-second limit.
No concurrent task compilation runs beside that final build. These warm
dependency observations are not cold-build or performance acceptance.

All five unchanged real Native public Product regressions pass: disabled
User, imported disabled User, Workspace without User shadow, enabled
same-process reuse, and first startup followed by disable, reopen and
management re-enable. Natural enumeration is 1,086; the other 1,081 cases
receive no pass credit. The Product unittest ELF SHA-256 is
`ebfa5d234c989ec0f8c2c47d8ffb60ac39b6740b4e0d3ad2c870698a15d2b166`.
This component build includes the startup-record change, not the later
combined Store/header source set.

The startup implementation is promoted by exact byte equivalence. It keeps
the original empty-registry-only batch fence and does not extend content
verification reuse or `serialize: false` to retained startup.
`combined-startup-header-source` binds both source changes separately;
combined Core, Product, production and package acceptance still need their
own artifacts. The original 129 selected Python regressions and complete
architecture gate pass on the integrated five-file source set in
`combined-startup-header-static`. Architecture checks cover 2,977 tracked
paths, 72 Markdown files, 39 packages and 178 local dependency edges.

These are narrow lifecycle and static results, not complete Core capacity,
first-model startup, matching baseline or release acceptance. GC stays
deferred, PR #49 stays Draft, and the task is not complete.


## Integrated complete Core still refuses attachment capacity

E1171 records `combined-startup-header-complete-core`. The original complete
Native Core/recovery is rebuilt and executed with both integrated fixes.
The build passes in 579.22 seconds under its original 900-second bound.
The new ELF SHA-256 is
`4443850d0e868af1e1fd81c006d45a9cec240319c69b280d8bf47711121aab58`.
Execution takes 49.14 seconds and still fails the original model-selected
readonly Program at fixture line 2446 with `input_attachment.capacity`.
All owned processes are collected. No GC classification or pass is claimed.

The build records the `4009baa` parent plus the exact five-file working-source
hashes. Those bytes are now committed as `91ea759` and `345c4c6`; later
differences are documentation and commit metadata. The exact-source
equivalence preserves this evidence without claiming another runtime run.
The commits are fixups of the original settlement and first-assembly changes,
not a Ready declaration.

The Store and startup-record fixes retain their independent narrow evidence.
Combined complete Core capacity, current complete Product, current release
packages and model startup remain unaccepted. No earlier refusal charge is
substituted for this run's unobserved invoice. GC stays deferred, PR #49
stays Draft, and the task is not complete.


## Current-source refusal and live owner decomposition

E1172 records `combined-current-custody-source` and
`combined-current-custody-attribution` on the `345c4c6` behavior sources.
The original six numeric observers are reused with an isolated trace path.
The safe uninstrumented E1171 Core is the only COW seed. Original Core
Context-retention bytes are verified; no withdrawn typed-error ELF is used.
The diagnostic build passes in 591.82 seconds. Its actual 110.16-second
execution still fails complete Core and exits 1. Neither run is performance
or acceptance evidence.

All 256,191 bank, lease, SUM and custody observations reconcile. The fresh
refusal records these values together:

| Capacity | Charged at refusal | Actual requested growth | Overshoot |
| ---: | ---: | ---: | ---: |
| 150,994,944 | 110,610,312 | 50,331,648 | 9,947,016 |

The complete live-owner decomposition freezes every invoice, including zero
invoices, at this refusal. Group 1 has 460 live leases and a 49,153,248-byte
SUM. Group 214 has 119 and a 9,480,784-byte SUM. Their high-water charges,
two other original 16 MiB reservations and fixed transport charges reconcile
with total occupancy. No unmatched count is described as a leak.

The original three toolset producer graphs remain live. The two earlier
Context shares still do not prove opaque consumer return. Prepared metadata
also remains explicitly unknown: group 1 has 49 live prepared owners with
13,539,368 invoiced bytes; group 214 has four with 878,832. These are original
retention states, not authorization to clear fields, acknowledge consumers
or refund completed Operations.

The diagnostic ELF SHA-256 is
`8f6b9ba8108b133310efb9ca89bca36da9f70e98788efd10eb871c74dcf7ea4a`.
Exact sources, all raw events, refusal-time owner ancestry and prepared
states remain in the private evidence. The collector retains numeric IDs,
amounts and function names, not application owner or child references.
The fixed bank, floor, attachment invoice, SQL, Source, actual ACK and
original deadlines remain. Complete Core and the remaining non-GC gates
are not accepted; GC stays deferred and PR #49 stays Draft.


## Current integrated production rebuild

E1173 records `combined-startup-header-nine-production-stages` on the exact
five-file `345c4c6` behavior source set. All nine original production stages
pass: Runtime, Tool, Store, Core, Host, Product, RPC, App and Minimal.
Every stage keeps its original 900-second limit, O2 profile and fixed
official SDK. The configured task-owned target is used; no old shared
seed or SDK component is rebuilt.

The current App SHA-256 is
`7749c083499914706b456f809ca67dbc5503ae4b38e58bba3305d391ca725647`.
The current Minimal SHA-256 is
`99d9f92c3008f8aa93e1cc0ffc301071403c371f305fb31c8a03cadcd3c115ba`.
These supersede older production binaries only for their exact recorded
source scope. Compilation does not waive the current Core refusal or
establish current Coding, model, complete Product, matching baseline or
release acceptance. GC stays deferred and PR #49 stays Draft.


## Current Coding smoke and unchanged first-request failure

E1174 records `combined-startup-header-current-coding` and
`provider-profile-retained-combined-current1174-diagnostic`.
The original Coding9 production assembly passes in 835.28 seconds within
its original 2,100-second bound. Clean-environment and setup checks pass.
The real executable's captured PTY cards and ask scenarios also pass.
Their actual databases contain zero Runs, Operations, Receipts and Model
Attempts, so those surfaces provide no model-success credit.

The current Coding ELF SHA-256 is
`f2e04de6f8e738336a058b53df8f67d7631614980c0b2551cb0ef04a201ffc71`.
Its App source is E1173's `7749c083` artifact and its behavior sources match
`345c4c6`. No earlier Coding binary is substituted.

With no concurrent task compilation, the original retained-operator local
provider request still exceeds its unchanged five-second timeout.
Observed wall time is 5.005 seconds and the fixture receives zero HTTP POSTs.
Timeout output is not captured; the operator lock hash stays unchanged.
The enclosing watcher exits 0 only because the capture driver records the
failure. The inner result is `FAIL_UNTRACED`, not a successful model request.
Every recorded process is collected. This is neither DATA ACK nor GC proof.

`current-budget-births-gdb` and its writable-temp follow-up remain failed
diagnostics. The first nested namespace accidentally leaves task `/tmp`
read-only and fails before the fixture body. The corrected namespace keeps
the original disk-backed temporary mount, but GDB exits 255 after observing
only the initial Registry root reservation. Neither capture identifies the
late refusal's two live floor owners or earns Core pass credit.
The original SDK, bank, floor, attachment invoice, Source, SQL, permissions,
actual ACK and deadlines remain unchanged.

Current model startup, complete Core and Product, matched baseline and
complete release acceptance stay open. GC stays deferred and PR #49 stays
Draft. The task is not complete.

## Exact current root births and Prepared unknown exports

E1175 records `current-owner-birth-attribution`. The current integrated
behavior sources match `345c4c6`; private instrumentation adds only scalar
root-birth and first-unknown events with function stacks. It stores no owner
or child references. The original complete Core fixture rebuilds within its
900-second bound and still fails at the same readonly Program capacity
assertion. The instrumented ELF SHA-256 is
`f2b11f0100075d4376c718f968e1aeca2d7ee79dd19eb287a062f446869aa74a`.
This is diagnostic evidence, not a production or complete-Core pass.

Actual bank/group identities reconcile the refusal without debugger
ordinals: bank capacity is 150,994,944 bytes, charged capacity 110,610,056,
and this request's incremental growth 50,331,648. The overshoot is
9,946,760 bytes. Registry roots contribute 55,559,520 and 21,258,536;
two floor roots contribute 16,777,216 each; fixed charges contribute
237,568. All observations through the refusal are included.

The first floor is born in
`ApplicationSession.reserveOwnedCheckpointSlot113`, before its actual
client invocation. It pays the copied Run identity and reserved failure
delivery slot. A transferred failure keeps that slot paid until the
actual consumer ACKs. The second floor is born in
`HostToolInputAttachmentSession.init`; its unchanged 64 MiB working invoice
requests the additional growth. Its output-return and actual output-ACK
states remain distinct. Neither root is an inferred transport-frame owner.
These lifetimes do not authorize early retirement, pooling into the
long-lived Registry, or treating callback return as DATA return. No
Run-scoped shared-owner redesign has been implemented or accepted.

The 53 first-unknown Prepared metadata events have two concrete call shapes:
28 export `PreparedToolInvocation.call` through
`HostJavaScriptPluginServiceBroker.validateChildPlan`; 25 export
`operationPlan` through the actual legacy executor frame.
This identifies the export sites, not the last consumers. Their unknown
custody remains charged; no new ACK or refund is inferred.

The original bank, floor, invoice, SUM, Source, SQL, authority and process
cleanup rules remain unchanged. Complete Core, current model startup,
complete Product, matched baseline and release acceptance remain open.
GC stays deferred and PR #49 stays Draft. The task is not complete.

## Current combined Native distribution regressions

E1176 records `combined-startup-header-current-native-unit` and
`combined-startup-header-current-native-dependency-ready` on the exact five
integrated `345c4c6` behavior and regression sources.
The original Runtime, Tool, Store, Core and Host unit-build predecessors
pass. The next Product compilation reaches its unchanged 900-second bound
and fails. That attempt remains failed evidence; all recorded processes
are collected with no unknown identity or unreaped owner.

After retaining that failure and its completed dependency work, a separate
dependency-ready Product build passes in 498.23 seconds, still with one job,
the original 900-second bound and fixed official SDK. This is not a
cold-build or compilation-performance pass, and process collection is not
DATA ACK.

The rebuilt Product unittest ELF SHA-256 is
`96f0671aa39b764bb963edd6dd1e7f21d859ec48050f72a0e2282b882a6d13b8`.
Its full natural inventory contains 1,086 cases. Exactly five unchanged
public Native distribution cases pass: explicit User disable, imported
User disable, Workspace scope without a User shadow, enabled-process
reuse, and actual first startup followed by operator disable, reopen and
management re-enable. Each qualified SDK result reports one pass and
1,085 skipped cases. These five results do not accept the full module.

The current complete Core capacity failure, local model startup,
complete Product/application flows, matched baseline and final release
acceptance remain open. No SDK, allowance, stack, timeout, Source, SQL,
integrity or actual ACK rule changes. GC stays deferred and PR #49 stays
Draft. The task is not complete.

## Current startup cost inside complete package verification

E1177 records `package-inspection-phase1176-build`,
`package-inspection-phase1176-package-proof-continued` and
`provider-profile-retained-package-inspection1177-diagnostic`.
A separate two-file scalar probe measures Registry load, paid row,
package inspection and content digest wall spans. Its behavior sources
match `345c4c6`; all nine original bounded production stages rebuild.
The diagnostic App SHA-256 is
`dd85ae813fdf3940f1bfb5ddb1a11b45a528618053b4ead524b4be79e5421461`;
the derived Coding ELF is
`250458c6cc8a81225569a026f4cd08f93dfce1cc8d362a823fd27ded870ee4fb`.
Only the host, truthful host provenance and ldd report differ from the
current complete Coding package. Every plugin, SDK and library byte is
unchanged.

The first derivative assembly correctly fails provenance publication:
its caller supplies the post-RPATH native hash where the helper requires
the observed raw-copy hash. That failed receipt and caller source remain.
The continuation performs a genuine raw repository-native bridge copy,
records that copy before the unchanged RPATH transformation, and passes
the original before/copy/after checks. Its final bridge bytes equal the
seed. No SDK input or provenance check is replaced or bypassed.

The original local request still times out at five seconds: observed
caller wall time is 5.004 seconds, zero HTTP POSTs, unchanged operator lock.
All 352 scalar events form a valid nested prefix. In 58 complete paired
inspection spans, total wall time is 4,825 ms: 4,806 ms inside content
digest and 19 ms elsewhere in package inspection. The raw capture includes
five completed inspection pairs whose UTC end marker is beyond the nominal
caller deadline; reconciliation marks them explicitly. These sums describe
complete captured spans, not work wholly inside the caller's five seconds.
The enclosing watcher's exit 0 means successful failure capture, not model
success or DATA ACK.

This locates the startup hotspot in repeated full content verification.
It does not identify CPU versus GC time, accept production latency, permit
verification caching, or waive any byte, path, type or integrity check.

## Fixed-SDK digest controls without Product startup

E1178 records `digest-file-micro1178`: an independent O2 single-file caller
compiled and run with the same fixed official SDK. All five raw repetitions,
including the first, remain. Every digest matches an independently computed
expected SHA-256.

| Fixed-SDK control | Bytes per sample | Observed wall range |
| --- | ---: | ---: |
| File read, 64 KiB buffer | 12,121,857 | 1.217–2.853 ms |
| Same file read plus SHA-256 | 12,121,857 | 23.608–24.779 ms |
| In-memory SHA-256, 256 writes | 16,777,216 | 30.852–31.810 ms |

Probe ELF is
`970160df540b33cffe2d9c83834c6e2ef005cea88406e52e12e22eb46dda0dee`.
A separate host Python/OpenSSL control hashes the same file bytes in
22.988–31.350 ms. That is a different execution shape, not an SDK or
matched-product performance gate. The installed stdx digest binary already
references OpenSSL SHA and EVP bindings; no replacement digest library or
SDK change is justified by these controls.

## Same-width digest work and allocation controls

E1179 records `digest-parallel-micro1179` and
`actual-byte-partitions.json` under the E1177 local-request evidence.
The second fixed-SDK O2 probe has ELF SHA-256
`1e3501e34a1e68dcff4dbd67d55a929b4988d67374959f059458c58dd1fa7a91`.
Five serial pairs of 16 MiB hashes take 70.407–116.708 ms; five pairs with
one spawn plus the caller take 35.895–60.048 ms. The variation prevents a
fixed speedup claim. Both digests in every pair match.
Hashing 1,000 32-byte messages with fresh contexts takes 1.256–2.126 ms;
reusing one context for those 1,000 messages takes 0.975–1.878 ms. The reused
context's initial constructor is outside its timed interval. These controls
do not establish useful application savings from a context-reuse change.

The exact unchanged retained operator packages contain 335,039,342 bytes.
Their heavier-reader byte totals for one complete package set are:

| Two-reader assignment | Heavier-reader bytes, summed across packages |
| --- | ---: |
| Current largest file versus remaining files | 219,365,502 |
| Withdrawn largest plus at most one companion | 174,915,626 |
| Hypothetical all-file longest-first partition | 167,526,040 |

These are file-size calculations, not observed startup times. A private
all-file candidate is distinct from the withdrawn one-companion experiment.
It has no model or production acceptance credit. It must retain the same
two readers, two 64 KiB buffers, original paid invoice, complete byte checks,
ordered v2 digest, error precedence, joined worker and actual private-frame
clearing. No quota, deadline or verification-reuse policy changes.

Complete Core, the original model-request gate, full Product/application
flows, matched baseline and final release acceptance remain open. GC stays
deferred, PR #49 stays Draft, and the task is not complete.

