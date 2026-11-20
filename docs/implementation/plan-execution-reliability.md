# Plan execution reliability

> Integration in progress: the current integration preview is based on
> `1866d4c1557558b2a3df70b2b256428a74651959`. The validation results below
> describe the earlier implementation on `364bcec9`; they do not validate this
> new integration. All affected requirements must pass again before complete acceptance.
> Current integration results are recorded separately below. Schema v29 preserves
> the new base's v25-v28 migrations and adds plan state.
>
> Latest completed private Core/ownership diagnostics are recorded in
> [the frozen-refusal bank-identity checkpoint](#frozen-refusal-core-establishes-same-stop-bank-identity).
> They do not replace the public `f0e63eb` behavior source or establish complete acceptance.

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

## All-file two-reader candidate fails the original request gate

E1180 records `digest-all-file-two-reader1180-build`,
`digest-all-file-two-reader1180-package` and
`provider-profile-retained-all-file1180-first-diagnostic`.
The private one-file candidate compiles all nine original production
stages within their unchanged bounds. It preserves the two readers,
two 64 KiB buffers, original invoice, full file checks, ordered v2 digest,
joined worker and private-frame clearing. Candidate App SHA-256 is
`9b87f81d6ac29ae6efe73bcbfc47a3463dbffc1bf3cf6a623e85f9fd96effd77`.

The derivative package changes only the host, truthful host provenance and
ldd report; every plugin, SDK and library byte matches the current seed.
Its ELF SHA-256 is
`e6afa294644b42ac508dea8bf16805c442092233cf007f958a4cf46e7e13cada`.
The unchanged local request still times out after 5.003 seconds with zero
HTTP POSTs and an unchanged operator lock. Read-only comparisons of both
session databases find zero Runs, Attempts, Operations and Receipts in
both the seed and failed candidate. Observing more processes does not prove
Run admission. Physical cleanup closes all observed identities; it is not
DATA ACK. The failure capture did not retain stdout or stderr.

The candidate is not promoted. Its build and package are not eligible as
accepted-source Core, Product or release evidence. Better byte partitions
alone do not satisfy the request gate. Complete pin acquisition publishes
fresh state for the whole Registry; loading only the selected record would
change that contract and is not implemented. No cache, worker-count,
buffer, quota, integrity-check or deadline relaxation is accepted.

## Empty spawn control does not justify a persistent worker

E1181 records `digest-spawn-micro1181`, an independent O2 caller built and
run with the same fixed official SDK. Probe ELF SHA-256 is
`1c51a46bd96e338a5ebffc1915cc660469d38b9bfe0dadb63b3faec240532327`.
All five raw batches remain, including the first. Each starts and joins
1,000 empty Futures and verifies the accumulated result is 1,000.
Observed batch wall time is 2.521–3.290 ms. This control does not establish
useful startup savings from introducing a persistent digest worker;
none is added. It is not a Product or matched-baseline performance gate.

Core capacity, model startup, complete Product/application flows, matched
baseline and release acceptance remain open. GC stays deferred, PR #49
stays Draft, and the task is not complete.

## Earlier high-water phases are not current-owner refunds

E1182 reconciles the original E1175 scalar events again, retaining every
closed-since-peak lease in `peak-phase-decomposition1182.json`. These are
different observation times, not simultaneous allocations:

| Original Registry group | Peak SUM/charge | SUM at refusal |
| --- | ---: | ---: |
| Main Product | 55,559,520 | 49,153,320 |
| Fault fixture | 21,258,536 | 9,480,712 |

At the first peak, the largest later-closed lease is a 9,360,096-byte
file-plan canonicalization frame, with its exact producer stack.
At the second peak, a later-closed 4 MiB lease derives from the metadata
generation. Each peak includes other objects and differs from the final
live set. Neither a closed ledger entry nor the difference between these
numbers proves actual DATA consumption or permits high-water compaction.

## Independent canonicalization alone still fails complete Core

E1183 records `canonical-independent-frame1183-complete-core`.
A private one-file candidate gives the temporary canonicalizer outcome an
independent real message in the same existing bank, using the existing
allocator. It preserves the 16 MiB floor, original 8 MiB construction
prepayment and complete producer/copied-consumer retirement protocol.
That changes transient message occupancy; it does not increase allowance
or shorten an existing owner's ACK contract.

Build passes in 421.03 seconds. Original complete Core fails after
47.21 seconds at the same readonly Program `input_attachment.capacity`
assertion. ELF SHA-256 is
`6fbf1f7e0b02156b172010dd3fb6a149631c90bfe9dc3396eced691cd2e02448`.
No reduction in actual refusal-time charge is inferred from static source.
The source and artifact remain private and unpromoted.

## Actual SDK directory walk and streamed validation candidate

E1184 records `fixed-sdk-directory-walk1184`. The cached main-branch API
index identifies `std.fs.Directory.walk(Path, (FileInfo) -> Bool): Unit`.
The fixed SDK's actual filesystem binary has SHA-256
`ec252fb2dfd8fa6f5d2dc509bc7a95fbf0fd44c8fc19f18ce9ddef11abf5e0c6`.
Its walk entrypoint opens and iterates a native directory handle, invokes
the current-entry callback and closes the handle on ordinary and exception
paths. Its `readFrom` implementation instead materializes an array.
This is static implementation evidence, not an allocation measurement.

E1185 records `streamed-validation1185-complete-core`. This private
three-file candidate combines E1183 with streaming publication-marker
names instead of retaining the whole directory array. Only closed
generation validation receives a path/header scratch invoice.
Full Registry loading, decoded records and record matching retain their
original invoices. Native snapshots still reopen current paths, compare
all bytes and recheck identity/watch events using their already retained,
paid observation buffers. No transport buffer stores decoded DATA.

Build passes in 619.89 seconds. Original complete Core still fails after
50.54 seconds at the same readonly Program capacity assertion.
ELF SHA-256 is
`95bf0aa2c843ee549a82cab1095f3f024a36daaea564062b01d83ca6177241c4`.
Both E1183 and E1185 keep their original 900-second bounds and unchanged
fixture/assertions. All observed process identities close; this is not DATA
ACK. Neither candidate is promoted or earns complete Core/Product credit.
No compiler, runtime, std, stdx or SDK is built or replaced.

The next diagnostic must measure the candidate's actual remaining refusal,
not assume that reducing one earlier phase removes the final bottleneck.
Core, model startup, full Product/application flows, matched baseline and
release remain open. GC stays deferred, PR #49 stays Draft, and the task
is not complete.

## Candidate refusal reconciled with numeric owners

E1186 records `streamed-validation1186-probe`. The private E1185 source
receives the retained scalar-only allocator observer; it does not change
DATA retirement. Build passes in 505.62 seconds. Original complete Core
still fails in 50.91 seconds at the readonly Program capacity assertion.
The full acquisition/growth/refund ledger reconciles with bank occupancy
and each shared generation's SUM at the actual refusal:

| Diagnostic | Bank capacity | Charged | Requested growth | Overshoot |
| --- | ---: | ---: | ---: | ---: |
| E1186 allocator observer | 150,994,944 | 108,536,448 | 50,331,648 | 7,873,152 |
| E1187 allocator and caller-role observers | 150,994,944 | 108,535,320 | 50,331,648 | 7,872,024 |
| E1189 exact model-task/private-caller candidate with observers | 150,994,944 | 108,381,480 | 50,331,648 | 7,718,184 |
| E1192 combined lifetime candidate with observers | 150,994,944 | 104,410,832 | 50,331,648 | 3,747,536 |

E1187 records `streamed-validation1187-roles`. Five retained caller-role
observers are byte-identical to E1175's diagnostic sources. They retain
numeric identities, not owners or children. Build passes in 624.83 seconds;
complete Core still fails in 70.57 seconds. Neither diagnostic is a
performance comparison or acceptance pass.

At E1187's refusal, the main Registry generation has SUM 49,152,216,
charge 53,993,416 and 460 leases. The separate fault-fixture generation
has SUM 9,480,768, charge 20,749,904 and 119 leases. Together with the
two actual 16 MiB roots and 237,568 fixed bytes, these reconcile exactly
to the bank's charge. Different observer runs are not interchangeable
snapshots and their small differences are not attributed to a source fix.

The earlier main-generation peak includes two model-input children of
1,657,968 and 1,287,712 bytes, two prepared-metadata children of 1,437,720
and 1,436,696 bytes, and still-live shared snapshot copies. The earlier
fault-fixture peak includes a 4,356,888-byte loading child. All later-closed
leases and their ancestry remain in `peak-phase-decomposition.json`;
these earlier phases are not summed into refusal-time live ownership.
No generic opaque context is retired, no high-water charge is compacted,
and no observer result is treated as an actual consumer ACK.

All observed process identities close. Both diagnostics and the underlying
candidate remain private and unpromoted. Accepted behavior is unchanged;
complete Core, model startup, Product/application flows, matched baseline
and release remain open. GC stays deferred, PR #49 stays Draft, and the
task is not complete.

## Precise model-task and private-caller candidate still fails Core

E1188 records `model-task-caller1188-complete-core` and
`model-task-caller1188-runtime-unit`. The seven-file private candidate
starts from accepted behavior, without the E1183/E1185 allocation changes.
It exposes a DATA-only witness over the same canonical admitted task
record and its actual target/observer Futures. The prepared model caller
also has to return its complete raw-request helper and clear its private
request, tools and plan fields. Provider ACK, actual action/Future return,
opaque-input retention and independent consumer loans remain mandatory.
Recovery/internal callers retain their original whole-Run witness because
their outer request frames have no corresponding precise return contract.

The production build passes in 511.02 seconds. Original complete Core
still fails in 50.58 seconds at the same readonly Program
`input_attachment.capacity` assertion. Its ELF SHA-256 is
`82a0eeae02e4516449b0962d60e0970e651b3a8248a91a7edabd1c780a1dbca1`.
The original fixture, assertions, limits and 900-second bounds are unchanged.
No Core acceptance credit is granted.

The Runtime unit build passes in 147.78 seconds. Natural inventory changes
from 43 to 45 cases by adding exactly two actual-Future regressions:
one task's DATA witness can return while an unrelated owned task remains
pending; a physically returned failed task does not claim successful Run
termination. Both pass, as do all three existing pending/failed/cancelled
post-canonical scope cases. Each filtered run executes one case and skips
44. This is five-case credit, not a full Runtime or Product pass.
The Runtime unittest ELF SHA-256 is
`5a61b29e50658d7027a0a328192bf6b87e64264927fc55a9cf609e5763940da4`.

Observed process custody closes in the build and run records, separately
from DATA consumption. The candidate and tests remain private and
unpromoted while its actual remaining refusal is investigated.
Accepted behavior is unchanged. The task remains not complete, GC stays
deferred and PR #49 stays Draft.

## Returned model inputs do not erase Registry high-water charge

E1189 records `model-task-caller1189-probe`. It adds only the six retained
scalar/caller-role observers to E1188, not the earlier canonicalizer or
Registry changes. Build passes in 480.49 seconds; complete Core still
fails in 79.04 seconds. ELF SHA-256 is
`009ae5f8f2f194721267d691b88f6af551b623950a1897c4827881c7c5a5f962`;
the event log SHA-256 is
`e2dfb3a66ecbc7856939a10107d6507200fcb0e3424972aefa95cb8b2b42fe23`.
The actual bank refusal is included in the diagnostic table above.

| Registry generation | SUM at refusal | Charged high-water | Live leases |
| --- | ---: | ---: | ---: |
| Main Product | 47,038,096 | 55,340,608 | 457 |
| Separate fault fixture | 9,480,776 | 19,248,872 | 119 |

The complete acquisition/growth/refund and shared SUM ledgers reconcile.
The peak reconstruction uses these actual generation IDs, not the earlier
probe's IDs, and retains every later-closed lease without threshold filtering.
At the earlier main peak, a 9,252,688-byte canonicalizer frame is largest;
at the earlier fault-fixture peak, a 4,194,304-byte validation child is largest.
Both close before refusal. The current and earlier observations remain
separate: completed model DATA retirement does not compact the still-live
Registry generation's high-water charge. Opaque contexts remain retained.
No source is promoted and no Core acceptance is granted.

## Independent path checks are small beside standalone hashing

E1190 records `digest-path-micro1190`, a standalone std/stdx O2 caller on
the same fixed SDK. Its generic input is 22 ordinary files totaling
34,649,056 bytes. It needs no Axyndra API. Collection/sorting occurs
outside measurement; five complete samples retain the first result.

| Standalone work | Observed milliseconds |
| --- | ---: |
| Before/after canonical-root, path-component and file metadata checks; no content read | 1.979–2.679 |
| 64 KiB file hashing and before/after file metadata; no path-component checks | 69.347–90.554 |
| Both sets of work | 71.484–83.102 |

Every full per-file digest feeds an independently verified aggregate,
identical in every hashing sample. ELF SHA-256 is
`d89646533dbcab165306f688f2d7692d679ded05ed4dedde94fa260abc914db7`.
The control does not reproduce Product concurrency, Registry billing,
whole-tree policy, GC or startup. It does not justify removing path
validation or replacing SDK crypto, and earns no model/performance gate
credit. No SDK is built or replaced.

## Measured peak-lifetime combination still fails complete Core

E1191 records `scoped-peak-lifetimes1191-complete-core`. E1189's actual
largest peak holders motivate combining the private exact model-task/
caller contract with the independently owned canonicalizer and streamed
closed-generation validation. The ten source files are exactly E1188
plus E1185; there are no observers or new invoice experiments. In particular,
full Registry loading and record comparison retain their original 4 MiB
invoices. The canonicalizer keeps its real 16 MiB floor, original 8 MiB
working invoice and complete producer/copied-consumer return requirements.

Build passes in 495.57 seconds; original complete Core still fails in
52.12 seconds at the same readonly Program `input_attachment.capacity`
assertion. ELF SHA-256 is
`3b06f4e155cdb090a7d59749f572b7ff91a6a3f6c1e21c63f40059ff9ebc8755`.
The original fixture, assertions, limits and 900-second bounds remain.
Observed process custody closes, which is not DATA ACK. The combination
remains private and unpromoted; the remaining actual refusal must be
measured rather than inferred from the sum of earlier peak holders.
The same ten-file source also passes the complete local architecture gate,
including dependency pins, 15 plugin-boundary regressions, SDK compatibility
baselines and package inventory. Only its generated support-contract
`cjpm.lock` is restored before that check; behavior source hashes are unchanged.
These static results do not replace the failed complete Core smoke.
Complete Core and all other outstanding acceptance requirements remain
open. The task is not complete, GC stays deferred and PR #49 stays Draft.

## Combined candidate still needs actual copy-lifetime attribution

E1192 records `scoped-peak-lifetimes1192-probe`. The six retained observers
measure E1191 without altering billing or DATA return. Build passes in
585.91 seconds; original complete Core still fails in 68.95 seconds.
ELF SHA-256 is
`1d24475fe9c756558656e1c3eef57bda01b4d55c7fae63992690a9e23119be2c`;
the event log SHA-256 is
`c89126b9c77c21e07332861a1d43f130a2a58147609a35d633bb780f639a78a0`.
The actual remaining refusal is included in the diagnostic table above.

| Registry generation | SUM at refusal | Charged high-water | Live leases |
| --- | ---: | ---: | ---: |
| Main Product | 47,037,048 | 51,878,904 | 457 |
| Separate fault fixture | 9,480,776 | 18,739,928 | 119 |

All bank and shared-ledger transitions reconcile. At the earlier main
peak, two model-input children of 1,657,968 and 1,287,712 bytes overlap
two Prepared copies of 1,437,720 and 1,436,696 bytes. All four later close.
At the earlier fault-fixture peak, a 4,356,888-byte full loading child is
largest. These are historical custody observations, not evidence that
the consumers had already returned when new allocations were admitted.

The actual bottleneck has changed since the earlier canonicalizer and
closed-validation peaks. Its copy producers need exact call-site evidence
before another lifetime change; a later close is not permission to refund
earlier. Generic opaque contexts, full loading/comparison invoices, the
bank/floor/SUM and actual ACK rules remain unchanged. Source is private
and unpromoted. Core, model startup, full Product/application flows,
matched baseline and release remain open. The task is not complete,
GC stays deferred and PR #49 stays Draft.

## Exact remaining copy producers identified

E1193 records `metadata-peak-producers1193`. Two observer additions capture
every Prepared-owner constructor stack and every fixture request-copy
payment origin, without filtering amounts or retaining object references.
No allocation or retirement behavior changes. Build passes in 583.58
seconds; original complete Core still fails in 71.47 seconds.
ELF SHA-256 is
`afa55dc47658761072526d133c4a93134bd23665fbfbfa0970f6a939c56f0b82`;
event log SHA-256 is
`f0ee7d14025bab5007b34475bcb3336558e2a08745f1427c9d1a2a995a8f7ca7`.

The reconciled ledger and exact stacks identify the two main-peak
Prepared owners separately:

- `ToolPipeline.loadPreparedForApproval` retains the first through
  `decideCommitted` during the actual Product file-plan recovery contract.
- `ToolPipeline.authorize` retains the second through `decidePrepared`
  in that same committed-approval continuation.

Both request-copy children originate in `copyFixtureRequest159` through
the real `FixtureModelPort.executeReturningInput159` action Future.
Thus the earlier model-input ancestry includes actual old/new fixture
request copies, not merely Core's input wrapper. Their overlap remains
funded; later replacement is not evidence that the old copy could already
be refunded. Full constructor stacks and all peak leases remain private
in `peak-phase-decomposition.json`.

## Initial private approval producer is not acceptance evidence

E1194 records `private-approval-producer1194-complete-core`. A private
prototype scopes approval intermediates around a no-input handoff
notification while retaining the existing full-Prepared notification
contract for actual data consumers. Both delegate to the same canonical
committed-source/authorization/executor implementation.

Build passes in 474.39 seconds. Original complete Core still fails after
55.14 seconds at the same readonly Program capacity assertion.
ELF SHA-256 is
`9e2635864892d130b39ad1f448184cd1027627ed2bd2269b96e6c0e1f23e225a`.
The prototype is not promoted or accepted as a safe lifetime fix:
a no-input notification alone does not certify that a raw executor
returned its Prepared aliases, including an executor that stores the
object without invoking a public getter.

The guarded follow-on must preserve the original whole-Core producer
contract before any actual registration can expose Prepared to descriptor,
handoff or executor code. Parent-held/unknown state and independent
consumer ACKs remain required. Neither a returned callback, a typed Err
nor a completed process proves DATA consumption. No opaque Context,
full loading invoice, Source/SQL or authorization rule is weakened.
Complete Core and all other outstanding requirements remain open.
The task is not complete, GC stays deferred and PR #49 stays Draft.

## Guarded private approval producer passes natural Tool units

E1195 records `private-approval-guarded1195-tool-unit-ready`.
The guarded source keeps the original whole-Core producer lifetime as
soon as an actual registration is selected, before descriptor, handoff
or executor callbacks. A raw executor may store Prepared without reading
a getter; a no-input notification is not its return witness.
Only newly constructed, still-private pre-registration intermediates
can use the complete helper-return contract. Existing parent-held/unknown
state and all independent metadata consumers still prevent retirement.
The fixed frame header remains prepaid in the original Core scope.

The first CJPM skip-build seed discovery exits zero but reports `TOTAL 0`.
The driver rejects that empty inventory before compilation or case credit;
its output remains in `private-approval-guarded1195-tool-unit`.
The continuation enumerates the exact retained ELF directly, then rebuilds
the actual Tool module and uses natural CJPM discovery for real case runs.
This is a runner/cache-discovery correction, not a zero-test pass or a
relaxed inventory assertion.

The unit build passes in 184.10 seconds. The seed enumerates 72 cases;
the rebuilt inventory is exactly those names plus three paid-ledger
lifecycle regressions, with no removals. **All 75 natural Tool unit cases
execute and pass.** Each filtered process executes one case and skips 74.
The added cases prove:

- A returned private producer keeps DATA while its actual consumer is
  still live; the last real consumer returns one actual lease without
  compacting the still-live shared message's high-water charge.
- Registered Prepared exposure retains the original whole-Core producer,
  even after the counted consumer returns.
- An actual unsupported raw resolver still blocks private retirement.

Tool unittest ELF SHA-256 is
`899c2ae8376accfc7b884088b311ceae306ad039a3b8ec7ed8eaa1e07fc2568b`.
The fourteen-file guarded source includes the earlier lifetime combination
and the three new tests. The 144 MiB bank, 16 MiB floor, SUM, 64 MiB
attachment work invoice, real ACKs, Source/SQL, permission, deadline and
stack requirements remain intact. Its additional private frame header is
prepaid in the existing Core scope. No source is promoted.

The observer-free `private-approval-guarded1195-complete-core` build passes
in 690.52 seconds, but original complete Core still fails after 61.21
seconds at the readonly Program `input_attachment.capacity` assertion.
ELF SHA-256 is
`824873371536beb5ce2b670e56a8f645d75d5372186d8369b9f0b759ec4012fb`.
The 75 Tool passes do not fix or replace this failed full Core gate.
Product/application, matched baseline and release validation remain open.
No compiler/runtime/std/stdx/SDK or external model change is made.
The task remains not complete, GC stays deferred and PR #49 stays Draft.


## Guarded source's own refusal remains reconciled and unresolved

E1196 records `private-approval-refusal1196`. It adds only the retained
scalar allocator observer to the exact guarded E1195 source; no caller-role
file overwrites the new exposure guard or private producer links.
Build passes in 730.56 seconds. Original complete Core still fails after
56.32 seconds at the same readonly Program assertion.
Diagnostic ELF SHA-256 is
`93241381830c20a2cc9139a053ce772d3829630b8ec4595ce310b1d87954c804`.

The original refusal point records:

| Bank field | Actual bytes |
| --- | ---: |
| Capacity | 150,994,944 |
| Charged | 104,412,824 |
| Requested incremental growth | 50,331,648 |
| Overshoot | 3,749,528 |

| Live shared group | SUM bytes | Charged high-water bytes | Actual leases |
| --- | ---: | ---: | ---: |
| 1 | 47,038,072 | 51,880,888 | 457 |
| 221 | 9,480,776 | 18,739,936 | 119 |

All ledger events and every peak lease/closed-since-peak entry are
reconciled without a size threshold. Other bank occupancy is not inferred
from these two SUM rows. These are this run's observations, not numbers
copied from the earlier unguarded source. They demonstrate neither a
refund opportunity nor a leak. No producer change earns full Core credit.
The source remains private; the task is not complete and PR stays Draft.

## Streamed rows and typed projection match pass all Registry units

E1197 records the private fourteen-file
`streamed-typed-registry1197-source.json` candidate. It retains E1191's ten
functional sources, not E1194/E1195's new Tool API or producer protocol.
The loader now keeps one JSONL row rather than a full split array.
Requested-record matching compares the exact old lock-line/diagnostic
projection fields without constructing two JSON graphs and strings.
Order of capabilities, contributions and component dependencies remains
significant; no metadata field is silently added to that comparison.

The capture caller prepays handles, complete path copies, bounded getter
copies, unchanged full typed DATA and four additional 8x pointer-slot
occurrences per retained record. The latter follows from each record's
unchanged minimum header invoice. Snapshot/source bytes, per-row
DOM/tree/digest work, full native/package verification and actual return
rules keep their existing owners. This is not a blanket lower work invoice:
the still-allocating matching-pin path retains its original 4 MiB scratch.

Observer-free build passes in 534.85 seconds. Original complete Core still
fails after 49.19 seconds at the same readonly Program capacity assertion.
ELF SHA-256 is
`ddf5f70cbc85ac089adad044bc77fcdc8f26def8a4d55f91ceb52896d080977b`.
Its refusal amounts have not been measured; E1196's values are not reused.

The actual rebuilt Registry unittest ELF and natural CJPM discovery agree
on **38 cases, all executed and passed**, including two added regressions:

- Mixed blank/CRLF rows and a final unterminated history row still permit
  a real installed pin and rollback to the original version/content lock.
- Changed, reordered, truncated or extended requested capability metadata
  cannot match the approved record.

The suite also executes actual saturation, owner/fence retention, complete
package-byte reinspection, same-length rewrite, inode/path replacement,
symlink, workspace grant, writer, rollback and malformed-row cases.
Unit build takes 169.47 seconds; ELF SHA-256 is
`de27478591d1b874e0e6c69e8a89d47cf8ab4f17c097b0d821e44c0c07231089`.
Evidence is `streamed-typed-registry1197-registry-unit`.
The input Core cache has no prior Registry unittest ELF; no historical
Registry count or prior-source pass is invented.
An initial private runner syntax error occurs before compilation; it
earns zero test credit. Correcting that runner does not alter Cangjie
source or assertions.

Remaining detached loading/management state still prepays its original
fixed 4 MiB in a separate actual owner. The capture-only change does not
establish that this holder disappeared or that its DATA was returned.
No source is promoted; Core and all other outstanding acceptance remain
open. GC stays deferred and PR #49 stays Draft.

## Exact fixed-SDK line slicing smoke passes independently

E1198 records `line-iteration1198`, a standalone std-only O2 caller.
Eleven independently specified fixtures exercise actual SDK `indexOf`
byte offsets and slicing: empty/blank input, leading/consecutive lines,
CRLF, final unterminated rows, multibyte UTF-8 and an escaped newline
inside JSON text. Every expected line's bytes and order match.
Compilation takes 1.38 seconds; execution takes 0.50 seconds.
ELF SHA-256 is
`34da9a5923f690cde2d6bae7c25a1453b2edcca0e2b94751a7bae40e35c0269b`.
This uses no Axyndra API or model. It proves string iteration semantics,
not Registry billing, complete Core, startup performance or release
acceptance. Accepted behavior remains unchanged; the task is not complete.

## Detached-state work correction remains incomplete

E1199 records the private sixteen-file
`detached-state-work1199-source.json` candidate. The still-existing
ordinary loading/management `PluginRegistryStateMemory` holder is distinct
from E1197's capture caller. All four production constructor sites and its
real digest regression now explicitly prepay caller path/handle/bounded
getter work; public inspection includes the supplied package root.
No old constructor overload or default invoice remains.

Because the loader now streams rows, the obsolete whole-source byte copy,
line-count scan and split-array invoice are removed. Every immutable
snapshot/source, parser/node, tree/digest, adopted/copy/mutation DATA
charge retains its existing lifetime. Loaded records additionally prepay
the same four 8x caller pointer-slot occurrences. No owner is cleared,
refunded or merged early; the original shared bank, per-owner floor,
attachment work invoice, SUM and real ACK requirements stay intact.

The observer-free original complete Core build passes in 626.49 seconds,
but execution still fails after 49.82 seconds at the same readonly Program
`input_attachment.capacity` assertion. ELF SHA-256 is
`662ea4217ef81f882766bcc0e89a046fca5743adbc2a96b47e6f2c0a0390fa43`.
No remaining refusal amount or floor saving is inferred from the earlier
source. A smaller logical child invoice need not lower a live message's
charged floor/high-water.

The rebuilt Registry unit inventory preserves all 38 actual E1197 seed
names. All execute: **37 pass; one crashes with direct Runtime GC frames**.
The failed case is
`RegistryStateCustodyTests.actualReloadAndCaptureShareOneCustodyButPreserveIndependentGenerationRevocation`.
Its current stderr shows
`GCTib::ForEachBitmapWord -> CJ_MCC_C2NStub -> FileInfo.isSymbolicLink -> inspectPluginPackage`.
That direct frame, not a thread name or region assertion alone, places this
sample in the user-deferred GC scope. It receives zero pass credit and is
not rerun. The original `FAIL_NO_ACCEPTANCE` summary stays unchanged;
`classification-review.json` preserves the evidence and limited conclusion.
No root cause or SDK-only causation is claimed.

Unit build takes 209.54 seconds; unittest ELF SHA-256 is
`2ed3c4530a4a101ea834ce8076aa12051a08dfa4648cbf2d361ae0bb064e9943`.
The 37 successes do not replace the failed full module or Core gate.
Evidence is `detached-state-work1199-complete-core` and
`detached-state-work1199-registry-unit`.
All source remains private and unpromoted. The task is not complete,
the other non-GC requirements remain open and PR #49 stays Draft.

## Corrected-holder refusal still has actual copied-data peaks

E1200 records `detached-state-refusal1200`: exact E1199 source plus seven
retained numeric/function-origin observers. Every diagnostic file replaces
an unchanged original file, not new functional code. Build passes in
454.04 seconds; original complete Core still fails after 69.29 seconds
at the same readonly Program assertion.
Diagnostic ELF SHA-256 is
`fa3f09f4128ee5a36629d055ca543bf64afb8f6db21c71bbfca300fd5a5fd724`.

| Refusal field | Actual bytes |
| --- | ---: |
| Bank capacity | 150,994,944 |
| Charged | 103,777,060 |
| Requested incremental growth | 50,331,648 |
| Overshoot | 3,113,764 |

| Shared group | SUM at refusal | Charged high-water | Actual leases |
| --- | ---: | ---: | ---: |
| 1 | 47,038,160 | 51,879,968 | 457 |
| 221 | 9,480,784 | 18,105,092 | 119 |

The complete unfiltered peak report retains all 416 and 161 peak leases,
respectively, plus every closed-since-peak entry. Main peak still overlaps
the two approval Prepared copies from private loading and authorization,
old/new real fixture request copies, and actual snapshot/data loans.
The fault-phase largest paid child is now a host Registry data copy;
it is not the earlier fixed 4 MiB loading invoice.

Later collection of those owners cannot be used as an earlier ACK.
The smaller child work invoices do not establish an equal reduction in
either message's charged floor/high-water. Three snapshot producers remain
live at refusal; zero raw exports/loans on a snapshot alone does not prove
its enclosing opaque Context has returned. No such Context is retired.
Numeric reconciliation and complete ancestry remain private in
`reconciled-custody.json` and `peak-phase-decomposition.json`.
The source is diagnostic and unpromoted; complete Core is still failed,
the task is not complete and PR #49 stays Draft.

## Private approval DATA move passes Tool but not complete Core

E1201 records the private twenty-one-file
`private-approval-move1201-callers-source.json` candidate.
It avoids a second independent metadata graph only for a freshly privately
reloaded approval intermediate. After the unchanged canonical Source,
current-plan, capability, policy and persisted approval checks, an eligible
Core-owned producer moves its already copied fields into the Approved
wrapper. The old private wrapper is cleared; the same DATA payment,
producer, frozen plan, Source and actual consumer/return rules remain.
An extra control-only wrapper is prepaid in the original scope.
There is no early producer return, DATA refund or new execution authority.

Public `authorize`, retained context-read decisions and all three retained
owned-parent/child authorization helpers keep their original independent
copy semantics. Opaque/held Context, exported metadata, an actual live
consumer or changed producer prevents the private move. Those guards are
not relaxed to obtain a pass.

The initial attempt omits the explicit copying-mode argument at the three
owned-parent/child helpers and fails compilation. No test or runtime
credit is given. The corrected attempt migrates every such caller and
preserves the initial failed output.

The actual Tool build then passes in 56.83 seconds, with dependency-ready
cache from the failed attempt, not a cold-build performance result.
The rebuilt natural inventory preserves all 72 original seed cases and
adds exactly three real paid-ledger cases. **All 75 execute and pass**:

- Moving the private wrapper does not create another DATA lease; the
  payload stays live through the actual last independent consumer.
- An existing consumer prevents transfer until its own frame returns.
- A real raw metadata export or opaque Context keeps the original
  independent-copy route and paid debt.

Tool unittest ELF SHA-256 is
`86ec64378323a98100ed200fc980dc77557c8ac6e0ca6d08564d2b0bc1b78f33`.
Evidence is `private-approval-move1201-callers-tool-unit`.

Original complete Core build passes in 420.94 seconds, but execution still
fails after 46.03 seconds at the readonly Program capacity assertion.
ELF SHA-256 is
`ffee2a062bf53674615d17c55ec5046a6783b1da3690c4c1125923a529b35e52`.
Evidence is `private-approval-move1201-callers-complete-core`.
Successful isolated transfer cases are not proof of eligible transfers
or lower peak charge in that actual production sequence.
No previous-source refusal amount or earlier ACK is substituted.

No source is promoted. The original Core and remaining non-GC gates are
still open; GC stays deferred, the task is not complete and PR #49 stays
Draft.

## Production private moves succeed but the peak shifts

E1203 records `private-move-eligibility1203`. The exact E1201 production
source keeps every guard, with retained scalar allocator observation and
numeric/function-origin labels at the private Scope/metadata-owner
eligibility points. Build passes in 539.33 seconds. Original complete
Core still fails after 48.55 seconds at the same readonly Program claim.
Diagnostic ELF SHA-256 is
`e07e000412ec941ad27350cfc0238d771cb491512ef073fa2b66e64747a4283b`.

Both actual production attempts have an open Scope, no unknown export,
zero consumers and an unreturned producer; **both DATA moves succeed**.
There are no held-Scope attempts or owner refusals. This evidence does
not support removing the opaque Context guard; it remains unchanged.
Successful moves are not DATA returns.

| Refusal field | Actual bytes |
| --- | ---: |
| Bank capacity | 150,994,944 |
| Charged | 103,255,188 |
| Requested incremental growth | 50,331,648 |
| Overshoot | 2,591,892 |

| Shared group | SUM at refusal | Charged high-water | Peak leases |
| --- | ---: | ---: | ---: |
| 1 | 47,038,024 | 51,358,192 | 449 |
| 221 | 9,480,752 | 18,104,996 | 161 |

The main high-water moves to a later phase. Its largest unnamed derived
children include several overlapping megabyte-scale allocations; specific
producers are not guessed from an invoice size. All peak leases, ancestry
and closed-since-peak entries
remain in the full private reconciliation, with `disposition.json`
recording the observed eligibility counts and the unchanged-guard decision.
The earlier copied graph's invoice is not substituted for an actual bank
saving or an earlier refund. No source is promoted; complete Core and the
other outstanding requirements remain open. GC stays deferred and
PR #49 stays Draft.

## Derived constructor origins identify canonical configuration holders

E1204 records `private-derived-origins1204`. The E1203 diagnostic adds one
constructor-origin trace for every actual derived reservation, with stable
bank/group/child IDs and function stacks. All 17,237 captured origins and
the complete numeric ledger are retained; there is no size threshold or
application owner/child reference retained by the observer.

Build passes in 494.34 seconds. Original complete Core still fails capacity
after 117.13 seconds. Diagnostic ELF SHA-256 is
`28cf3f64ccb791306e8b2aa24e0aee63cb118a74a54ff7f052ffc8d735890baf`.
The intrusive all-constructor stacks change timing; this is not a performance
result or a reason to reuse E1203's different refusal amounts.

| Refusal field | Actual bytes |
| --- | ---: |
| Bank capacity | 150,994,944 |
| Charged | 105,161,720 |
| Requested incremental growth | 50,331,648 |
| Overshoot | 4,498,424 |

| Shared group | SUM at refusal | Charged high-water | Peak leases |
| --- | ---: | ---: | ---: |
| 1 | 47,038,072 | 53,472,536 | 452 |
| 221 | 9,480,768 | 17,897,184 | 162 |

Actual constructor stacks now identify two previously unnamed main-group
holders, both still live at the peak and refusal:

| Child | Parent | Actual invoice bytes | Actual creation path |
| --- | --- | ---: | --- |
| 1845 | 1844 | 1,074,464 | `HostCanonicalProjectionConfigurationCache173.loadOwned186` |
| 1855 | 1854 | 1,074,432 | `HostCanonicalProjectionConfigurationCache173.loadOwned186` |

Both are installed compaction selections created through
`OwnedPluginPackageDescriptor.deriveCopiedDataPayment`, not fixture request
copies inferred from similar invoice sizes. Source inspection confirms that
the same payment funds private parser/FD work and remains attached to the
published scalar/text selection. The selection stores path, encoded text,
witness, scalar identities and its payment; it does not store the parser DOM.
Its later complete-byte validation still requires paid UTF8/native scratch.

`peak-phase-decomposition.json` binds every peak and closed-since-peak lease
to available actual constructor stacks. Different high-water timing is not
called a leak, physical memory or an earlier ACK. A private follow-on explores
separate original-bank work and retained-data lifetimes, keeping the full
original parser invoice, all FD/symlink/byte checks and unknown-failure debt.
It has no acceptance credit in this entry. No source is promoted; complete
Core and other non-GC requirements remain open. GC stays deferred and PR #49
stays Draft.

## Canonical parser work returns separately but complete Core still fails

E1205 records the private `canonical-config-work1205` candidate. The owned
configuration cache now registers separate retained DATA and private load
work in the same original shared group. The complete original one-MiB
working invoice, names, FD-copy bytes, parser nodes and identity-copy charges
remain unchanged. A published selection prepays its actual encoded text,
scalar identities and serialized complete-byte/native validation scratch
before construction. It does not keep the parser DOM's working lease.

Only the caller outside the complete private load method returns that work.
The cached DATA payment stays live for its actual views, mounted consumers
and public copied exports. An active load blocks owner retirement.
Unknown construction or close keeps both actual indexed leases; exception
unwinding and a mistaken normal-return notification cannot acknowledge them.
All path, symlink, size, FD witness and full-byte checks remain in place.
No Context, provider or retained metadata consumer receives an invented ACK.

Original complete Core rebuild passes in 867.16 seconds and executes for
54.85 seconds, then still fails the same model-selected readonly Program
attachment-capacity assertion. ELF SHA-256 is
`77b2ba25cdc955555eee0d23dd298ad594704f680cf1830678801ce8f6cede16`.
Evidence is `canonical-config-work1205-complete-core`.
There is no new measured refusal amount or inferred bank saving.

The Host unit fixture follows the same real private work/retained-data
construction boundary. Three initial compile attempts fail: an invalid
default-argument declaration, missing extension import, then missing base
`JsonNode` class visibility. Their outputs and zero test credit are retained
in `canonical-config-work1205-host-unit`,
`canonical-config-work1205-callers-host-unit` and
`canonical-config-work1205-imports-host-unit`.
The corrected explicit argument and both imports affect test source only;
the production source used by complete Core is unchanged.

The dependency-ready Host build then passes in 48.35 seconds.
`canonical-config-work1205-classes-host-unit` naturally enumerates 276 cases;
**only four execute and pass**:

- Independent configuration views retain backing until the whole last action
  and actual last consumer return.
- An active Catalog consumer refuses early retirement and permits the same
  original-bank retry after its complete frame returns.
- Public text exports keep their independently prepaid copies after private
  configuration return.
- An actual private constructor exception leaves parser work and retained
  DATA indexed, even after a normal-return notification is attempted.

Host unittest ELF SHA-256 is
`4c903339c3070a44556d3892cd43d4e99fcc2b3b614eb4a23966ab6c3e2dfa05`.
These are configuration DATA/lifetime tests, not Native execution,
permission, Source or Receipt proofs. No full Host, Core, Product or release
pass is claimed. No source is promoted; the task is not complete, GC stays
deferred and PR #49 stays Draft.

## Actual model-definition copy fields pass full Runtime RED/GREEN

E1206 corrects another concrete copied-DATA field-set mismatch.
`SharedToolSnapshotLoan159.copyModelTools159` independently creates only
available `ModelToolDefinition` names, descriptions and deep-copied schemas,
but previously measured the entire source snapshot: unavailable entries,
execution identities, required capabilities and hook handlers as well.
Those fields remain owned and fully paid by the original snapshot; the
independent model-definition copy does not retain them.

The private correction keeps the existing 131,072-byte (128-KiB) header,
slot/text/schema tariffs, deep structural copy, order, availability and
numeric subtype. It measures only fields actually copied, using the same
field set as the existing selected-definition copy. No source payment is
refunded or request-wide provider invoice subtracted. Actual Prepared,
provider, storage and unknown-consumer return rules remain unchanged.

Two real fixed-capacity regressions use one original 16-MiB bank, with the
complete source prepaid before construction, including large uncopied
execution metadata and an unavailable tool. Pressure leaves room for actual
small definition copies, not another copy of the complete source.
This is a fixed-capacity behavior test, not a new product-capacity target.

The initial test build fails because object construction requires
`JsonObjectEntry`, not a tuple; it receives zero runtime credit.
The corrected fixture uses the existing empty-object/`put` API.
`model-definition-copy1206-red-schema-runtime-unit` then executes both
regressions against unchanged production copying:

| Case | Original production result | Corrected production result |
| --- | --- | --- |
| Uncopied metadata/unavailable tool must not block real small independent copies | FAIL: actual aggregate refusal in `addSnapshot159` | PASS: copies survive source retirement and schema/array mutation remains isolated |
| An actual large available definition must still reject saturation in the same bank | PASS: rejects | PASS: rejects |

The corrected source naturally preserves all 47 names from the executable
RED build. **All 47 Runtime cases execute and pass**, including the actual
task-return witnesses, opaque checkpoint retention, full-bank rejection,
independent consumers and error/frame ACK regressions.
Dependency-ready rebuild takes 48.47 seconds, not a cold-build performance
result. Evidence is `model-definition-copy1206-green-runtime-unit`.
Runtime unittest ELF SHA-256 is
`27e9a0ffd0476c6303c01b07152a9b699a42751f5082046216ba3d7ff0f05369`.
The RED ELF is
`c6c0e0424d74f697f4c1424f9eeb701ea74a533b7eed70c480e1326c3d552f52`.

This is full Runtime-unit credit for the exact private twenty-six-file
candidate, not complete Core, Product or release acceptance. The original
complete Core remains a separate required gate; no previous-source
capacity result or predicted bank saving is substituted. No source is
promoted. The task remains not complete, GC stays deferred and PR #49
stays Draft.

## Portable Codex case has a new directly evidenced GC crash

E1207 captures the still-unclassified
`PluginRuntimeContractTests.importedPortableCodexSkillsUseInstalledContextProvider`
under the original qualified CJPM invocation, all seventeen original Native
fixtures and unchanged per-case/process bounds. The accepted production
behavior is still `345c4c68`; Product ELF SHA-256 is
`96f0671aa39b764bb963edd6dd1e7f21d859ec48050f72a0e2282b882a6d13b8`.
This is not the private E1206 candidate's Product evidence.

A parent-launch debugger observes fatal execution; it does not attach or
sample running tasks. The first launch fails before the case because the
pinned stdx loader environment is missing. The next direct-executable launch
fails SDK internal option parsing. Neither receives case credit.
The corrected launch keeps the original CJPM argv and reaches the actual
Product worker, which crashes with SIGSEGV. The debugger's exit callbacks
then fail before a qualified test summary; that diagnostic wrapper is not
reported as a passing or complete test runner.

The independent system crash receipt binds the actual worker signal,
executable and this exact single-case filter. Its saved core is
797,110,272 bytes, SHA-256
`bfb9a4eabc08c5c0e3fb994f781185166ec3deddc040ce56af70544a31c3a940`.
Offline symbolization of the same bytes and original executable name yields:

`CheckAndPush → GCTib::ForEachBitmapWord → BaseObject::ForEachRefField →
Mutator::GcPhaseEnum → TracingCollector::VisitStackRoots →
WCollector::TraceHeap → CollectorResources::GCMainThreadEntry`.

Another thread is in `InstalledSkillsMigrationHost` Product opening and
default-package inspection. This does not establish that portable import
itself ran. The initial saved `.elf` filename produces a GDB executable-name
warning; loading the hash-identical original executable name removes it.
Both outputs are retained.

Evidence is `portable-codex-fatal1207-cjpm` and
`portable-codex-fatal1207-core-original-name-review`, including the independent
receipt, full symbolized threads and reviewed classification. Raw cores and
machine metadata remain private; no payload is published.
**Only this current sample** joins the user-approved GC deferral, with zero
pass credit. The earlier incomplete SIGABRT is not retroactively
reclassified; debugger timing and an observed GC stack do not prove a root
cause or a fix. No known GC scenario is rerun after this classification.
Complete Product and the PR remain not complete, and PR #49 stays Draft.

## Corrected copied fields still leave a measured capacity refusal

E1208 first records the observer-free E1206 candidate's original complete
Core gate. Rebuild passes in 444.90 seconds; execution still fails after
48.88 seconds at the same model-selected readonly Program attachment claim.
ELF SHA-256 is
`9895e48b70add072494f3713e9a5bedbfe313f1ad538aa9ac572ebc7d4c3aff8`.
Evidence is `model-definition-copy1206-complete-core`.
Full Runtime-unit success does not override this failed original gate.

`definition-refusal1208` retains the same production source with complete
scalar allocator events and labels at actual payer creation sites.
Derived births remain unfiltered numeric events; E1204's intrusive
all-constructor stacks are not used. Build passes in 649.21 seconds;
original Core still fails after 51.03 seconds. Diagnostic ELF SHA-256 is
`95291008cf07db487c15058120fb7c7cfcb176066eb444b8158c161859edda24`.

| Refusal field | Actual bytes |
| --- | ---: |
| Bank capacity | 150,994,944 |
| Charged | 100,817,884 |
| Requested incremental growth | 50,331,648 |
| Overshoot | 154,588 |

| Shared group | SUM at refusal | Charged high-water | Peak leases |
| --- | ---: | ---: | ---: |
| 1 | 45,057,152 | 49,132,872 | 449 |
| 221 | 9,480,768 | 17,893,012 | 161 |

The two main canonical configuration DATA holders retain actual invoices
of 83,984 and 83,920 bytes. Their separate private working children retain
the complete original 1,074,464 and 1,074,432-byte invoices through parsing,
then emit actual close events before the main high-water. The DATA holders
remain live; no view or opaque Context is declared consumed.
`canonical-work-disposition.json` binds these exact children and close
positions to the raw ledger. Its initial private opcode lookup was corrected
against actual `C` close events before this record was written.

The peak's actual independent model-definition copy is 891,856 bytes.
The full source snapshots remain separately paid, including the two
historical opaque-Context owners. They are not retired from zero loans,
callback return or terminal state. The same peak also retains five
622,336-byte mount-descriptor copy holders, identified by actual payer
labels rather than invoice-size inference. Their private byte/String/DOM
scratch is cleared after decoding, while the original combined invoice
stays attached to retained typed descriptors.

`peak-phase-decomposition.json` retains every peak and closed-since-peak
lease, role and ancestry. The small remaining refusal is still a failure,
not a waiver, a promised saving or permission to lower the fixed attachment
invoice. A separate private mount-work granularity correction remains
unaccepted in this entry. No source is promoted; remaining non-GC gates
are open, the task is not complete, GC stays deferred and PR #49 stays Draft.

## Mount parser work separation reaches a later Core inspection failure

E1209 records the private twenty-eight-file
`mount-copy-work1209-original-tariff` candidate. Mount descriptor copying
registers retained typed DATA and a separate private construction lease in
the same original bank. `hostRegistryCopyInvoice81` still pays the complete
original byte/String/parser/DTO construction before copying. The retained
owner prepays all typed fields and seven collections, nested strings,
scalars/enums and the dependency's two bounded semantic-version values
before the complete decode/measurement scratch can return.

Retained pricing keeps the original mount-copy 16x text rate, 2,048-byte
structural rate and 65,536-byte header. A preliminary private version uses
the separate Catalog's 64x text rate and passes thirteen ownership tests,
but is not retained: it changes the mount pricing contract. The original
Catalog helper is restored exactly and the mount path uses its original
tariff. No Core or product-capacity credit is taken from that preliminary
unit-only artifact.

Only the caller outside both complete private helpers clears their
byte/String/DOM scratch and closes working custody. Actual legacy raw DTOs,
Catalog consumers and independent errors retain their DATA. An active copy
blocks public borrow and early retirement. Unknown decode/close keeps both
actual leases and partial fields; neither callback return, process exit nor
a mistaken normal-return notification acknowledges them.

`mount-copy-work1209-original-tariff-host-unit` naturally enumerates 277
cases: the prior 276 names plus one actual unknown-parser-debt regression.
**All thirteen selected adjacent Host cases execute and pass**, including
the existing repeated Registry copies, independent Catalog backing,
construction staging, generation/error shares, HTTP and canonical views.
Rebuild takes 206.43 seconds. Host unittest ELF SHA-256 is
`b0e7124abb7489358a013e5663230d0aeaaa44c2cb32e935ce60303427185ff8`.
This is not a full Host-module pass.

The current lower Runtime also executes all **75 natural Tool cases**
successfully, preserving the 72 seed names and the three actual private
move/consumer/export cases. Build takes 64.09 seconds.
Evidence is `mount-copy-work1209-original-tariff-tool-unit`; Tool unittest
ELF SHA-256 is
`28a84af167e64cc6dfaebb3b17aa9a4efc5ead48533ec0d2d47ed3fc28301c50`.
The E1206 Runtime sources and their lower dependencies are unchanged by
this Host-only follow-on; its 47-case evidence remains applicable there.

Original full Core rebuild passes in 587.08 seconds and executes for
55.51 seconds. It passes the formerly failing capacity/Run-completion
assertion, then **fails the next Run-inspection assertion** requiring the
Program SDK, artifact identity and canonical-arguments digest.
ELF SHA-256 is
`65501facceb806d25c08efc8a1fef9b5ca3bc5a5dd561735a5f33eb648756782`.
Evidence is `mount-copy-work1209-original-tariff-complete-core`.
Run completion alone does not prove a successful Program tool Receipt or
independent worker execution; the later inspection/result failure is not
waived or rewritten as success.

No new refusal amount, bank saving, whole Core/Product/release pass or
source promotion is inferred. The actual inspection output is the next
non-GC investigation. The task remains not complete, GC stays deferred
and PR #49 stays Draft.

## Actual failed Receipts explain the absent successful Program evidence

E1210 adds a fixture-only inspection diagnostic to the unchanged E1209
production candidate. Original full Core builds in 564.95 seconds and
fails in 55.47 seconds at the same metadata assertion. Inspection itself
returns `Result.Ok` with three operations: `host.process.readview`,
`plugin.axyndra:workspace.grep` and `plugin.axyndra:program.run`.
All have a 64-byte canonical-arguments digest and empty SDK/artifact
summaries. That first observation does not establish a projection defect
or successful execution. Evidence is `inspection-diagnostic1210`; its ELF
SHA-256 is
`99c44d1935d085b8ea2d7f8602bd66c245eba7d3de4c4824051ae1e761116ade`.

E1211 keeps the original assertions, adds actual state/Receipt outcomes to
that bounded diagnostic, and preserves only this private filesystem fixture
after normal product/process cleanup. It does not change runtime cleanup,
watchers, SQL, Source, permissions, DATA ACKs, capacity, SDK or the original
900-second build/execution limits. Original full Core builds in 416.78
seconds and fails in 55.78 seconds. Its 209 observed owned processes return
with no surviving, unknown or unreaped identities. Physical return is not
DATA consumption. ELF SHA-256 is
`1f74d36f6ce4bb30c070b7facbfa95dc167858bd9c3050d87f1f84bea088f0b2`.

The actual canonical SQLite, read offline without mutation after watcher
closure, records this failure chain:

| Actual operation | State / Receipt | Canonical result |
| --- | --- | --- |
| `host.process.readview` | `failed` / `failed` | `read_view.output_capacity`: shared logical JSON output capacity is exhausted |
| `plugin.axyndra:workspace.grep` | `failed` / `failed` | `workspace.protocol`: the worker returned invalid JSON |
| `plugin.axyndra:program.run` | `committed` / `failed` | Partial result, `tool_program.subcall_failed`: sub-operation returned an error |

The failed Program result contains the actual native SDK and artifact
metadata, but its Receipt is not completed. The strict completed-input
attachment query requires a completed Receipt and therefore does not admit
this failed root as successful historical evidence. No SDK/hash fallback,
success predicate, canonical join or acceptance assertion is relaxed.
The actionable failure is the actual read-view output reservation, not a
missing SDK field or proof of a successful worker. Its refusal amount and
retaining owners still need their own decision-time observation; the older
input-attachment refusal numbers do not apply to it.

Private evidence is `inspection-diagnostic1211`, including
`canonical-receipt-review.json`, exact source/ELF binding, unchanged original
failure and physical watcher receipts. Both diagnostic variants receive
zero production acceptance credit and are not promoted.

Separately, the observer-free original-tariff E1209 source set passes the
same selected **129 Python regressions** and the **complete architecture
entrypoint**. That entrypoint also passes its fifteen plugin-boundary tests,
documentation, dependency pins and package graph checks. Only the two
generated dependency locks are restored to their original bytes before
these checks; no dependency changes are retained. Evidence is
`mount-copy-work1209-original-tariff-static`. These static passes do not
waive the failed Core, Product, startup, baseline or release requirements.
No behavioral source is promoted; the task remains not complete, GC stays
deferred and PR #49 stays Draft.

## Initial read-view acquisition has a distinct measured bank refusal

E1212 reuses the full scalar allocator observer on the E1209 candidate.
Build passes in 589.27 seconds; original complete Core still fails its
structured inspection assertion after 54.90 seconds. ELF SHA-256 is
`f88b2d2d9294591e23e0a338e8465f3eb1c1f92800b5bc8ccf90b31225e5bf2e`.
All 269,252 captured events reconcile, but no refusal checkpoint appears.
Source review finds an observer gap: it records failed reservation growth,
not the initial `LogicalJsonOwnerBudget.acquire` rejection. An empty refusal
array is not evidence of unused capacity or an absent bank rejection.
`read-view-refusal1212/coverage-review.json` preserves this limitation.

E1213 adds the same eight scalar fields at that initial decision under its
original bank lock. Caller ID zero means no reservation has been allocated;
it is not a new payer or refund. The existing read-view catch additionally
prints only its numeric frozen output maximum and a bounded reason code,
not exception text, arguments or application references. Behavior, locks,
limits, actual ACKs and all original assertions are unchanged.

Build passes in 498.43 seconds; original complete Core still fails after
60.58 seconds. ELF SHA-256 is
`0c8c29c6f35e797ea4a7a8a2552deddaec8005d7c9f8048e03765bb81f73d452`.
All 269,914 events reconcile. The actual read-view maximum is 131,072 raw
bytes; the original floor requires a new 16-MiB owner. Its aggregate refusal
records these values together:

| Capacity | Charged at refusal | Actual requested growth | Overshoot |
| ---: | ---: | ---: | ---: |
| 150,994,944 | 146,776,136 | 16,777,216 | 12,558,408 |

The same-time bank occupancy reconciles as follows:

| Actual holder | SUM at refusal, where applicable | Actual bank charge |
| --- | ---: | ---: |
| Shared metadata ledger 1 | 44,921,368 | 45,785,160 |
| Shared metadata ledger 221 | 7,881,904 | 16,777,216 |
| Application checkpoint slot | — | 16,777,216 |
| Tool-input attachment working owner | — | 67,108,864 |
| All fixed transport buffers | — | 327,680 |

The two standalone owners are identified by their actual constructor
stacks: `ApplicationSession.reserveOwnedCheckpointSlot113` and
`HostToolInputAttachmentSession.init`. Neither may be closed merely because
the output worker needs room. Complete refusal-time live leases and their
ancestry are retained separately from earlier peak and closed-since-peak
leases; invoice size is not used to invent an owner class or release proof.
`read-view-acquire1213` retains raw events, complete reconciliation and
`actual-refusal-live-leases.json`. This is a new output-owner refusal, not
the earlier 50,331,648-byte attachment growth. No diagnostic source is
promoted, no unknown debt is retired and complete Core remains failed.

## Independent copied-definition billing correction ships with Native proof

E1214 isolates only the E1206 copied-definition meter and its two meaningful
fixed-capacity regressions onto published base `6a566b7`. None of the private
RunScope, Core, Registry, Host or diagnostic changes accompanies them.
The corrected production source SHA-256 is
`64709ee2fb7145bd061f11d6646f8caa577ff6a84f29610cffbaefc98a1d3ec0`.
The two files copied into the delivery branch match the independently
verified source bytes exactly.

The fresh RED build uses the original production meter and naturally lists
all 43 existing Main Runtime cases plus the two new cases. The small-copy
case fails in `addSnapshot159` with the actual aggregate exception; the
large available-copy saturation control passes. The SDK reports the former
as `ERROR: 1`, not `FAILED: 1`. The private driver initially misclassifies
that distinction and exits 1; its original output and summary are retained.
`classification-review.json` validates the existing qualified failure and
exact exception/stack without rerunning it or changing a product assertion.

After the isolated correction, **all 45 naturally enumerated Runtime cases
execute and pass**, with original case/process limits and complete physical
custody. Dependency-ready build takes 40.53 seconds; this is not cold-build
performance. Evidence is `model-copy-minimal1214-green-runtime-unit`.
Runtime unittest ELF SHA-256 is
`3e2ae52c72c6432a8c5a171387cbea7ce94dd6c6f49013f20b18cd6105407cc8`.
RED ELF SHA-256 is
`83b8ae051a6ad0936ca2958495d986551c043954010a268248f51d71bc9c41cd`.
The larger candidate's two unpromoted RunScope tests are not present in
Main source; no existing Main test is excluded or skipped by this full run.

A separate real Native executable then imports the public Runtime API and
constructs a fully prepaid source in a fixed 16-MiB test bank. It creates two
independent model-definition copies, retires the actual complete source,
consumes the copies after that return, checks schema/array mutation
isolation and exact numeric spelling, and confirms a genuinely large
available definition still rejects saturation. Caller-frame returns remain
distinct from producer, provider, storage and process completion.
Build takes 54.48 seconds; actual execution takes 0.52 seconds and exits 0:

```text
native_public_copy name=smoke.available literal=1.20e+02 independent=true
native_public_copy large_available_rejected=true
```

Evidence is `model-copy-minimal1214-native-smoke`, including caller source,
manifest, actual Runtime library identities and physical watcher receipts.
Executable SHA-256 is
`932ade5c6a5716eb7e373ae4ea22dda11949bbf81a829550ce8c3af5af341e84`.
This is an actual public consumer, not a unittest-only or mock result.

The identical two-file delivery source also passes the original selected
129 Python regressions and complete architecture entrypoint, including
documentation, package boundaries and dependency pins. Evidence is
`model-copy-minimal1214-main-static`. No dependency or source changes are
retained by those checks; the completed throwaway caller scaffold is
removed after its exact source and successful artifact proof are preserved.

The shipped change measures only available definition names, descriptions
and schemas that the existing copy actually creates. Source snapshots stay
fully paid; the existing header, full-schema tariff, order, numeric type,
deep-copy isolation and unknown/consumer ACK rules are unchanged.
No public signature, dependency, SDK, schema, wire, permission or Source
contract changes. Rollback restores these two Runtime files together;
there is no persisted-data migration or refund.
The larger Core candidate and all numeric/fixture observers remain private.
This isolated fix is not full Core/Product, current App, matching baseline,
startup or release acceptance. Those final-source gates remain open, GC
stays deferred and PR #49 stays Draft.

## Actual Prepared exports remain unknown and are not refunded

E1215 adds stable-ID labels to actual Prepared metadata payment creation,
consumer acquire/return, producer return and first unknown transitions.
Only constructor/first-export function stacks are captured. No application
owner, child, callback or argument is retained by the observer, and all
monetary events remain unfiltered. Private candidate behavior is unchanged.

Build passes in 465.17 seconds; original complete Core still fails after
56.46 seconds at the same structured inspection assertion. Its own initial
read-view acquisition refuses 16,777,216 bytes against 146,776,360 bytes
charged and the unchanged 150,994,944-byte cap, an overshoot of 12,558,632.
The main ledger's live SUM is 43,051,080 while its charged high-water is
45,785,384; different observation phases are not substituted for each other.

The actual live Prepared payments are now identified, not guessed from
invoice size:

| First unknown-export caller | Actual live owners | Invoiced bytes |
| --- | ---: | ---: |
| `HostJavaScriptPluginToolExecutor.executeLegacyActualFrame204` | 25 | 6,957,872 |
| `HostJavaScriptPluginServiceBroker.validateChildPlan` | 30 | 8,320,312 |

All 55 remain unknown; 52 also have actual producer-return markers.
Neither those markers nor a returned individual consumer establishes the
last opaque consumer's return. These payments stay funded. A first export
stack is not a last-consumer witness: catalog effect/capability resolution
and network-policy callbacks can retain the exact borrowed call graph.
The withdrawn E1108 same-Prepared metadata/output-ACK carrier is inspected
only to avoid repeating it; none of its nine sources is reapplied.

`prepared-owner1215` preserves raw observations, all refusal-time live
leases, constructor/first-export stacks and the no-refund/no-reapply
`disposition.json`. Remaining non-Prepared DATA need current constructor
identity before another change is selected. No diagnostic source is
promoted, complete Core remains failed, GC stays deferred and PR #49 stays
Draft.

## Current constructor stacks identify remaining non-Prepared DATA families

E1216 captures every actual derived-reservation constructor stack at the
new output-owner refusal, rather than applying E1204's older phase or
inferring a producer from an amount. All **17,890 actual births** have
matching constructor stacks; all 269,532 monetary/custody observations
reconcile without a threshold. The complete raw log is retained privately.

Build passes in 542.42 seconds. Original complete Core still fails after
131.22 seconds at the same successful Program evidence assertion.
ELF SHA-256 is
`9462eb0e04ead4363c61123f3fd130b3dd09cf1ce9af96d00ef1c433ffefe370`.
Intrusive all-constructor tracing is not performance evidence. Its own
refusal records:

| Capacity | Charged | Actual new output-owner request | Overshoot |
| ---: | ---: | ---: | ---: |
| 150,994,944 | 146,776,304 | 16,777,216 | 12,558,576 |

Selected actual non-Prepared producer families in the primary ledger are:

| Actual constructor path | Live allocations | Invoiced bytes |
| --- | ---: | ---: |
| `HostRegistryCatalogIdentity159.reserveTool159` | 30 | 5,825,088 |
| `ProductRuntime.requestUnscopedPromptBuildResult204` | 13 | 5,262,080 |
| `ToolCatalog.produceLockedToolSetSnapshot159` | 3 | 3,408,912 |
| `hostRegistryCatalogIdentity159` | 9 | 2,893,504 |

The complete family map and every live/peak/closed-since-peak lease retain
their actual constructor stacks. These totals include real retained DATA;
they are not claimed savings or permission to retire an opaque consumer.

Source inspection confirms one specific lifetime mismatch:
`HostRegistryCatalogIdentity159.reserveTool159` adds its original serial,
depth-weighted schema construction peak to the long-lived identity payment,
while a separate original child already pays published flat schemas and
declaration DATA. A distinct private follow-on tests separating only that
construction work, preserving the full original work invoice, tariff,
published aliases and unknown failures. No working amount is lowered and no
metadata/output-ACK or attachment-work candidate is reapplied.
`remaining-derived-origins1216` preserves all evidence and the scoped
decision. The follow-on is not accepted in this entry; no source is promoted,
Core remains failed, GC stays deferred and PR #49 stays Draft.

## Catalog private schema work has an actual frame-return boundary

E1217 tests a separate schema-construction work child in the private
observer-free candidate based on published `8944a2e`. The original
depth-weighted work invoice is funded before construction. The complete
private Catalog helper must return before that child closes. Published
schema/declaration DATA keep their original independent payments and
tariffs. Any unknown construction or funding failure keeps both work and
DATA charged. Empty Catalogs do not allocate a work child.

| Actual Native Host run | Result |
| --- | --- |
| Original schema billing with the two new cases | Positive return case fails; unknown-failure control passes |
| First candidate, 26 selected cases | 25 pass; concurrent-backing case fails two exact private-allocation assertions |
| Candidate with semantic backing assertions | All 26 pass; all 279 cases naturally enumerate |

The first GREEN attempt remains recorded as failed. Its two allocation
assertions assumed exactly three retired children. The distinct work child
correctly adds another 56,384-byte return. The revised test removes those
incidental amount/count assumptions instead of pinning a new total.
It requires actual Catalog retirement to fail while the first producer is
blocked and after its Future returns without the producer-return witness.
It preserves live definitions, no execution, idempotent collection and the
original complete Registry-frame SUM/count/native-bank restoration.

The final selected run builds in 40.97 seconds. Its ELF SHA-256 is
`be4e668bd0c58d3834fc0f1a1a47adc5922fc929145165f89a6b4844e9ceb065`.
`catalog-schema-work1217-red-host-unit`,
`catalog-schema-work1217-green-host-unit` and
`catalog-schema-work1217-return-contract-host-unit` retain source bindings,
natural inventories, qualified results and actual process-return evidence.
This is a retained private candidate, not independent Main or full Host
acceptance. The original complete Core gate has no result for this source
at this checkpoint. No source is promoted, no earlier failed Core result is
reclassified, GC stays deferred and PR #49 stays Draft.

## Current schema-work candidate still fails successful Program evidence

E1218 rebuilds the complete original Native Core contract from the E1217
observer-free source. Build passes in 461.86 seconds. Execution fails after
48.07 seconds at the unchanged successful Program inspection assertion.
Its ELF SHA-256 is
`b25aa13bbbff09fd39e4a7fad8bccbdbdfd09d2f99abc39666d05ef7c26fb16b`.
All 219 observed execution processes return without an unknown identity or
unreaped descendant. That result does not acknowledge DATA consumption.

A separate scalar diagnostic captures this source's own initial output
acquisition, without reusing an earlier refusal amount:

| Capacity | Charged | Actual new output-owner request | Overshoot |
| ---: | ---: | ---: | ---: |
| 150,994,944 | 144,988,160 | 16,777,216 | 10,770,432 |

The requested raw output limit remains 131,072 bytes. The actual refusal
reason is aggregate capacity. Primary-ledger SUM is 41,262,904 bytes while
its charged high-water is 43,997,184. Secondary-ledger SUM is 6,917,656 while
its original floor remains 16,777,216. These are current observations, not
permission to refund an unknown consumer or a cross-run savings claim.

The actual canonical inspection reports failed Receipts for read-view,
Workspace and Program, including the Program whose Operation is committed.
The successful Program evidence join remains unchanged.
Build passes in 512.25 seconds and diagnostic execution fails after
50.46 seconds. Its ELF SHA-256 is
`3ccca8e851aa46bb72ad37a404a0f87b50cab153d4025180c2f7306bee1d37ea`.
All 211 observed execution processes are reaped.

`catalog-schema-work1217-return-contract-complete-core` retains the original
failure. `catalog-schema-refusal1218` retains reconciled monetary events,
actual refusal-time leases and `disposition.json`. The diagnostic driver
did not enable the optional database-retention variable, so original
fixture cleanup ran. No new retained SQLite or raw-SQL result is claimed.
The printed canonical inspection states are current; the older retained
E1211 database remains historical evidence. No source is promoted, Core
remains failed, GC stays deferred and PR #49 stays Draft.

## Independent Catalog schema-work correction has real Product proof

E1219 isolates the schema-work change onto published `8944a2e` without the
other private Core, Host or Registry corrections or any observer. Only
`registry_metadata_copy.cj`, `plugin_tool_mount.cj`, the revised existing
concurrent-backing test and the two-case schema regression file change.
Main's 275 Host cases plus the two new cases naturally enumerate as 277.
The two private unknown-load/mount tests are absent because they were never
Main tests, not because a current Main case was removed.

Original production fails the positive same-bank reservation case while
the unknown-failure retention control passes. RED build takes 531.17 seconds.
Its ELF SHA-256 is
`872639de63f7291cce437578868c63326650a3cbe4410cd10f78f70f240f3d9e`.
With only the four-file correction, all 24 selected actual Native Host
cases pass. GREEN build takes 198.22 seconds. Its ELF SHA-256 is
`9afe8deb89873fbc613cf3e0c6dc73860cdcca39d0e63358ea12ce433ef897f3`.
The selected run covers real Registry and SQLite consumers, independent
shares, physical Future return without DATA acknowledgement, early Catalog
retirement refusal, published schemas and unknown failures.

A separate executable imports public Product APIs. It uses actual Registry
import, package verification, native process mounting and canonical direct
tool invocation. One real worker returns `calls=1` and then `calls=2`;
disabling the plugin makes the subsequent invocation fail. It runs no
model request. The executable SHA-256 is
`043f095ca9032fc09890d45219d89c1f4aac157de54d1ef740d53dfdccbf302f`.
Dependency-ready build takes 2.74 seconds and actual execution takes
0.63 seconds, with all five observed processes reaped. These times are not
cold-build or performance evidence.

`catalog-schema-minimal1219-red-host-unit`,
`catalog-schema-minimal1219-green-host-unit` and
`catalog-schema-minimal1219-native-smoke-linked` retain exact sources,
natural inventories, commands, artifact hashes and process receipts.
Three earlier throwaway-caller compile/link failures remain separately
recorded. They ran no Product scenario and have no runtime pass credit.
The corrected caller uses explicit public imports and the existing
`-lsqlite3` link contract, without a production API or dependency change.

The identical Main behavior sources pass the original 129 selected Python
regressions in 14.17 seconds and the complete architecture entrypoint in
29.23 seconds, including documentation and dependency pins.
`catalog-schema-minimal1219-main-static` records both commands and results.
The task-only public caller scaffold is removed after its exact source,
input fixture and actual ELF have been retained as private evidence.

Only this independently verified correction is migrated to Main. The full
original work invoice is paid through the complete private constructor;
published DATA retain their original tariffs and final-owner guards.
The shared bank, floor, input working invoice, SUM/high-water accounting
and all unknown Prepared/Context debt remain unchanged. Other candidates
stay private. Full Core, full Host, Product, App, release, the five-second
request and matching baseline still have no current-Main acceptance from
these selected results. The task is not complete, GC stays deferred and
PR #49 stays Draft.

## Published Main still rejects input attachment admission

E1220 rebuilds the original complete Native Core gate from published
`96c4eb640404a1cfda50aeaa14ec05f22c00fb1a`, without any unpromoted
Registry, Host, Core or RunScope changes. Build passes in 599.82 seconds.
Execution fails after 48.41 seconds at the original model-selected Program
assertion with `input_attachment.capacity`, before successful Program
inspection. ELF SHA-256 is
`6e3f1699e58f9de69590f81477207627d5856217d6bf05019edffbbb0fa814dc`.
All 197 observed execution processes are reaped, with no unknown identity.

This is current published-Main failure evidence. It is not the E1218
private candidate's later output-owner refusal, and that candidate's
requested amount or overshoot is not assigned to this sample.
The original success assertion, Source, SQL, Receipt, actual owner return
and process-custody requirements remain unchanged.
`catalog-schema-main1220-complete-core` retains source bindings, commands,
the actual artifact and failure. Its early deterministic fixture samples
are neither full Core acceptance nor matching baseline/performance credit.
The task remains incomplete, GC stays deferred and PR #49 stays Draft.

## Independent Registry candidate preserves two unpassed GC samples

E1221 isolates the retained eight-file Registry streaming, requested-record
comparison and caller-work candidate onto published `96c4eb6`. The stale
four-MiB loading comment is corrected. No Host, Core, RunScope or observer
source is copied. Original raw sources, typed DATA, per-row parsing,
complete package-byte inspection, Source and final-owner guards remain.
The candidate does not lower the shared bank, floor or attachment invoice.

All 38 Registry cases naturally enumerate. The original qualified runner
attempts 37, passes 36 and reports one actual error. The older directly
observed GC case is not rerun:

| Case | Actual current result |
| --- | --- |
| `returnedTreeInspectionWorkDoesNotBecomeEachSelectedPinGraph` | SIGSEGV; direct `MapleRuntime::GCTib::ForEachBitmapWord` frame; zero pass credit |
| `actualReloadAndCaptureShareOneCustodyButPreserveIndependentGenerationRevocation` | Existing user-deferred GC sample; not run; zero pass credit |

Build passes in 27.52 seconds. The rebuilt ELF SHA-256 is
`2ed3c4530a4a101ea834ce8076aa12051a08dfa4648cbf2d361ae0bb064e9943`,
identical to the retained E1199 Registry ELF. The current crash is not
rewritten as a pass because an earlier run passed with that artifact.
Its direct Runtime GC frame places only this new sample within the
approved deferral. It does not prove the original corruption cause.

`registry-state-minimal1221-unit` retains the unchanged
`FAIL_NO_ACCEPTANCE` summary, actual qualified outcomes and
`classification-review.json`. No failing case is retried or removed from
the natural inventory. Full Registry, Core, Product and release receive
no acceptance from this run. The Registry candidate is not promoted, the
task remains incomplete, GC stays deferred and PR #49 stays Draft.

## Isolated Registry changes do not close current Core admission

E1222 runs the original complete Core gate on published `96c4eb6` plus only
the eight-file Registry candidate from E1221. The observed Source, SQL,
permission, Receipt, working-invoice and process requirements remain intact.
Build passes in 507.54 seconds. Execution still fails after 49.65 seconds at
the original model-selected Program assertion with `input_attachment.capacity`.
ELF SHA-256 is
`e55996a695373fa195b0aefae25b3f287f74d1a1cb5fcd27a05504876645b044`.
All 197 observed execution processes are reaped.

`registry-state-minimal1222-complete-core` retains exact source bindings,
commands and this failure. Earlier successful deterministic fixture
scenarios do not turn the enclosing failed gate into a pass. The Registry
candidate remains unpromoted. Its two unpassed GC samples remain deferred
with zero current pass credit; no additional quota, timeout or DATA refund
is introduced. The task remains incomplete and PR #49 stays Draft.

## Current published-Main refusal is fully reconciled

E1223 observes published `96c4eb6` with only the private logical-budget
constructor observer. No retained behavioral candidate is added.
Build passes in 471.34 seconds. The original complete Core gate fails in
113.37 seconds at `input_attachment.capacity`. Diagnostic ELF SHA-256 is
`7d423d8f1667e60f5b2543000981d20ae219a578af7abbc1a7992601f06f074c`.
Diagnostic execution time is not a performance result.

The actual first refusal requests 50,331,648 additional bytes from the
existing attachment owner. Capacity is 150,994,944; charged occupancy is
107,401,136; overshoot is 6,737,840. Contemporaneous acquisition, growth,
final-return and fixed-buffer events reconcile every charged byte:

| Actual owner at refusal | Charged bytes | Shared-ledger SUM |
| --- | ---: | ---: |
| Registry root 1 | 53,526,840 | 47,120,456 |
| Registry root 214 | 20,082,296 | 8,516,504 |
| Application checkpoint root 224 | 16,777,216 | Standalone |
| Attachment root 225 | 16,777,216 | Standalone |
| 29 live fixed buffers | 237,568 | Fixed storage |

The attachment request grows its existing floor toward the unchanged
64-MiB work invoice. It is not an initial read-view output reservation.
Every one of 17,252 derived-constructor records has its complete serialized
stack, including all live entries. Raw invoices plus the original 1,024-byte
per-entry ledger header exactly reconcile both SUMs.

The first provisional family report selected a deeper known frame and
misgrouped some Prepared producers under `AgentCore.startOwned`.
That report is preserved, not accepted. Corrected reports use the first
actual non-budget funding frame and retain its next caller and full stack.
They identify 53 live `retainPrepared204` children; this sample does not
observe their export/loan flags or prove any of them may return.

Root 1's peak includes a 9,360,096-byte canonical-plan child, and root
214's peak includes a 4,194,304-byte Registry validation scratch child.
Both children actually close before refusal; their parent high-water
charges correctly remain. This is accounting, not physical-memory or
leak proof, and does not authorize a partial refund.
`main-refusal1223` retains original events, source and artifact bindings,
corrected attribution, exact bank balance and peak/return ancestry.
Complete Core remains failed, unknown DATA guards remain intact, the task
is incomplete, GC stays deferred and PR #49 stays Draft.

## Independent canonical graph lifetime does not yet close admission

E1224 adds one Product canonical-owner correction to published `96c4eb6`
and the eight-file Registry candidate. The copied canonical graph obtains
its own real message in the same bank. It preserves the original
131,072-byte header, 8,388,608-byte construction payment, message floor and
existing exact producer/copy-consumer return gates. Unknown DATA remain
paid. No private Core, Tool, RunScope or Host correction is included.

Build passes in 456.15 seconds. The original complete Core gate still fails
after 46.96 seconds at the unchanged model-selected Program assertion with
`input_attachment.capacity`. Actual ELF SHA-256 is
`656afd936e678d0c97818831c187a673d57e061e8338ebbb7b07b3c1c598696f`.
This observer-free run does not supply a new numeric refusal amount.
`canonical-frame-minimal1224-complete-core` retains exact source bindings,
the actual build and failed execution. An earlier relative-path wrapper
launch failed before compilation; it receives no gate credit.
The candidate remains private. The two unpassed Registry GC samples retain
zero pass credit. The task is incomplete and PR #49 stays Draft.

## Independent private authorization move preserves the actual DATA owner

E1225 isolates four Tool implementation files and three regressions in an
existing test file onto published `96c4eb6`. The private coordinator may
consume only a freshly reloaded, unpublished authorization intermediate.
The scope must be active and unheld, with the exact Core and producer
identity, no raw export, unknown debt, producer return or actual consumer.
Public authorization, retained context-read objects and opaque Context
keep the original independent-copy path.

The coordinator prepays an additional control wrapper, transfers the
already paid immutable fields to its Approved wrapper and invalidates the
old private DATA access. The DATA owner, invoice, final producer/consumer
return rules and frozen normalized plan remain the same. No DATA return,
refund or new execution authority is inferred from the move.

All 75 naturally enumerated Native Tool cases pass, preserving all 72
original cases. The three additions exercise old-access invalidation,
retention through the real last consumer, blocked moves while an actual
consumer remains, and rejection after Raw export or opaque Context.
Build takes 174.91 seconds. Actual ELF SHA-256 is
`c088e2a60417d9081e3413a9e7f26ebdd6eb413520ac961af51759dfa7676f42`.
`private-approval-minimal1225-tool-unit` retains exact sources, inventory,
commands and qualified outcomes. The identical five files are migrated to
Main; `private-approval-minimal1225-main-source-binding.json` records their
byte-for-byte applicability. No other private candidate is migrated.
The identical Main source also passes the original 129 selected Python
regressions in 13.97 seconds and the complete architecture entrypoint in
29.03 seconds, including docs and dependency pins.
`private-approval-minimal1225-main-static` retains both results. The earlier
ad hoc invocation omitted the established script import path; its loader
errors remain recorded with zero acceptance credit.

## Tool-only public Core smoke still fails attachment admission

E1226 rebuilds and executes the original public Native Product/Core/recovery
entrypoint from the same independently isolated five Tool files, without
private Registry, Host, Core, Product, RunScope or observer changes.
Build passes in 462.35 seconds. Execution fails after 45.93 seconds at the
original model-selected Program assertion with `input_attachment.capacity`.
Actual ELF SHA-256 is
`4b9eb28df39ab8bee8c9d52cf0d0e2a730f58a764b7dbd1e0a12cda92f7bbf9f`.

`private-approval-minimal1226-complete-core` retains the failed complete
gate, exact source bindings and real execution command. Unit passes do not
turn it green. This observer-free run does not establish an actual move
count or saved-byte amount, and E1223's earlier bank values are not assigned
to it. Full Core, Product, App, release, five-second request and matching
baseline remain unaccepted. The task is incomplete, GC stays deferred and
PR #49 stays Draft.

## Batched enables publish once and verification never reuses

E1227 reproduces a separate non-GC transaction defect in the original
Registry. `setEnabledBatch` calls the ordinary setter, which publishes
each prefix before later namespaces validate. On a later missing namespace,
the old code restores memory but leaves changed lock bytes and Workspace
grants. A newly opened Registry observes that rejected prefix.
The real User/Workspace enable-and-disable regression fails before the
fix; the successful two-namespace control passes.

The correction uses the existing private batch deferral for enable/disable
as well as import. It publishes the scoped lock after all requested
records validate, restores loaded records on prepublication failure and
always clears deferral so ordinary subsequent mutations still publish.
Original dependency, content, fence, scope and recovery checks remain.

The generic writer-fence verification cache is removed, not widened.
A Registry writer fence does not prevent arbitrary package-file mutation.
Every dependency and target inspection now uses the original full-byte
inspector. No verification result is reused, even during first install;
this conservatively satisfies the single-first-install-transaction reuse
ceiling without creating another cache, permission or Source authority.

| Evidence | Actual result | ELF SHA-256 |
| --- | --- | --- |
| `registry-batch-minimal1227-red-unit` | Failed-batch state regression fails; successful-batch control passes | `e47a7518b8a85080bd62865cda321abf1b19e27bc8da0e38019046355a340c8e` |
| `registry-batch-minimal1227-green-unit` | 35 qualified passes; one current GC crash; two older GC samples not run | `68aeeb9175507996ad51a57df647806bc602809aa85e7eca96a4b492b22378b6` |
| `registry-batch-minimal1227-native-smoke` | Standalone public Registry consumer exits zero with all six expected observations | `d4ae33b97d5c91d5412f8a13f8d13150bb5c6a992fc2e108c0584b8de6741a06` |

All 38 cases remain naturally present. Both new regressions pass after the
fix, including unchanged durable bytes/grants after failure, reopened
state, every successful namespace and later ordinary single mutations.
The current `seventeenActualInstalledPinsShareOneRealAllocationWithNearEightMibAndSessionOwners`
sample crashes with SIGSEGV and direct
`MapleRuntime::GCTib::ForEachBitmapWord` above `std.fs.exists` and
`inspectPluginPackage`. Only that observed sample joins GC deferral.
It receives zero pass credit, is not retried, and does not establish the
original corruption cause. The original `FAIL_NO_ACCEPTANCE` summary
remains unchanged; `classification-review.json` records all three
unpassed GC samples.

The separate public executable performs real native Registry writes,
package materialization and reopen in User and Workspace scopes. It
observes rejection of a later namespace without persisted prefix,
successful batch publication, ordinary disable and rejection after an
actual same-length installed-byte change. The fixture code is never
executed. Build takes 54.23 seconds; dependency-ready execution takes
0.64 seconds. These are not cold-start or five-second-gate results.
Its exact caller source and actual output are retained, then the task-only
caller scaffold is removed.

The combined Main Tool/Registry source also passes the original 129
selected Python regressions in 14.02 seconds and complete architecture
entrypoint in 29.18 seconds, including docs and dependency pins.
`registry-batch-minimal1227-main-static` retains the final source bindings.
Public method signatures and disk formats are unchanged. Operators who
previously saw a failed batch should inspect actual records before
retrying; historical prefixes are not rewritten by guessing earlier intent.

Only these two independently exercised Registry files are migrated to
Main. Other Registry work/streaming candidates stay private. The fixed SDK,
bank, floor, input work, SUM/high-water, unknown DATA debt and actual final
ACK requirements remain unchanged. This is not full Registry, combined
Core, Product, App, release or matching-baseline acceptance. The task is
incomplete, GC stays deferred and PR #49 stays Draft.

## Current committed Tool and Registry corrections still fail full Core

E1228 rebuilds the original complete Native Core/recovery gate from
published `925170fc7783956b3a9cbeb1146bd6476db07377` only. There is no private
mount, Registry work/streaming, Core, Product canonical-frame, RunScope or
observer source. Build passes in 422.09 seconds. Execution fails after
47.50 seconds at the unchanged model-selected Program assertion with
`input_attachment.capacity`.
Actual ELF SHA-256 is
`285ead312c3acddf0d177e400a31b30857ae9bf51c61a426c46a0a6cfb37122c`.

All 229 observed execution processes are reaped, with no surviving,
unreaped or unknown process, no watcher fault and both actual leader and
watcher returned. Physical cleanup remains explicitly not DATA ACK.
The observer-free run supplies no new refusal amount; E1223's earlier
source-specific balance is not applied to this artifact.

`registry-batch-main1228-complete-core` retains exact source and package
bindings, commands, the failed gate and its actual process census.
Two task-generated lock rewrites preserve the same dependency identities;
their exact diff is retained and only those two files are restored.
Component and standalone Registry passes do not satisfy full Core.
The task remains incomplete, GC stays deferred and PR #49 stays Draft.

## Mount descriptor scratch ends at its actual private copy frame

E1229 independently corrects `HostRegistryMountDescriptor159` on published
`925170f` Tool/Registry source. Previously, each retained mount descriptor
kept the complete UTF-8/source/parser/DTO construction invoice after the
actual decoding helper had returned. The correction prepays that same
complete work invoice in a private child, then separately funds the live
typed descriptor before detaching scratch. Both the actual decoding and
retained-DATA measurement helpers must return before that child closes.
The original 16-times text and 2,048-byte structural tariffs remain.
All 14 descriptor text fields and seven collection roots, including nested
contribution fields, are included.

This is not a receipt or mount ACK. The descriptor's real DATA owner stays
paid until its actual complete consumer frame returns. Borrowing is
rejected while private work remains. Unknown parsing, funding or
measurement failures retain both work and DATA; subsequent return notices
do not clear their partial aliases.

| Evidence | Actual result | ELF SHA-256 |
| --- | --- | --- |
| `mount-copy-minimal1229-red-host-unit` | Original production source fails the new saturation case | `5b262b472d97ebfa7367dc6008a4b60eedce2820c3ed2a5550be4ea39b178e57` |
| `mount-copy-minimal1229-green-host-unit` | All 26 selected Native Host cases pass | `2c6122dd6b9c7f4f147da7d580bac2cb9dae43560b2cd22f17f21b5ef77bff41` |
| `mount-copy-minimal1229-native-smoke` | Public Product imports and enables a real Native worker, observes calls 1 and 2, then rejects invocation after disable | `e3e6c9eb69fba5ae36ce71f5e199dd5733118f49fdaefe6c1532539561c041a2` |

The saturation regression uses the actual Registry and original Native
bank with an installed eight-extension Pi metadata fixture. Its JavaScript
files are never executed. It first observes rejection of another genuine
independent message, then keeps all 32 descriptor copies alive while
checking them against the original record. Only their actual helper
returns permit final retirement. The separate deliberate partial-parser
failure uses an isolated fixed bank and proves that return notices leave
both charges and aliases intact.

Host naturally enumerates 279 cases: the original 277 and two additions.
Only the 26 executed cases receive credit, not the whole module.
The standalone public Product smoke builds in 138.19 seconds and runs
dependency-ready in 0.63 seconds with exact expected output and closed
process custody. It is not a cold-start, five-second or matching-baseline
result. Caller and fixture bytes are retained with the evidence before
removing the task-only caller scaffold.

Only `registry_metadata_copy.cj` and
`owned_registry_mount_descriptor159_test.cj` migrate to Main. Their
SHA-256 values are respectively
`a0b80f072cae3bf096a5f88bb13ba72190156c6b360742f24fcc527178de4555`
and
`8e6a7cf58ebc2c18b8e5f2c42701b918928fda8802f22b4b9fc621a433f1b203`.
The accepted schema correction remains unchanged; no other private
Registry, Core, Product, RunScope or observer change is included.
The fixed SDK, bank, floor, attachment work invoice, SUM/high-water,
permissions, Source, SQL, recovery and actual final-ACK rules remain.
Public method signatures and disk formats do not change.

Full Core remains unaccepted: E1228 still fails on its own exact artifact;
these Host and Product observations do not replace the unchanged complete
gate on the new source. Full Product, App, release, five-second request
and matching baseline also remain unaccepted. The task is incomplete,
GC stays deferred and PR #49 stays Draft.

The identical migrated Main source also passes all original 129 selected
Python regressions and the complete architecture entrypoint, including
documentation and dependency pins. `mount-copy-minimal1229-main-static`
retains the exact source bindings and actual commands. These static
checks add no complete Core or broader runtime acceptance.

The test hash above identifies the actual Native-tested bytes. Before
commit, the edit tool's unrelated whole-file CRLF conversion is removed:
all 401 unchanged original lines keep their exact original endings, and
only new or changed lines use LF. Final test SHA-256 is
`8f1fb3da357f2bbfb4c0ae9a8b0a4781d32f5a3444f1b19676357dfd35b2d76b`.
`line-ending-equivalence.json` retains both raw hashes and verifies equal
LF-normalized source. No Cangjie token, literal, case or production byte
changes; existing Native and static evidence remains applicable.

## Mount-only correction still fails the original complete Core gate

E1230 rebuilds the unchanged full Native Core/recovery entrypoint from
published `925170f` plus exactly E1229's two Host files, without an
observer or any other private candidate. Production source matches the
migrated Main bytes. Build passes in 641.93 seconds within the original
bound. Execution fails after 47.21 seconds at the original model-selected
Program assertion with `input_attachment.capacity`.
Actual ELF SHA-256 is
`4698bf5921ab7688f7ca0eb4112a54967d48cd8fa839e365c17903087c5d8760`.

All 243 observed execution processes are reaped, with no surviving,
unreaped or unknown process, no watcher fault and both leader and watcher
returned. Physical cleanup is not DATA ACK. This observer-free run gives
no new numeric refusal or savings count; E1223's older balance is not
assigned to it.

`mount-copy-minimal1230-complete-core` retains the exact source diff,
bindings, command, actual failure and process census. The independent
Host and public Native Product passes remain narrowly valid, not full
Core or broader acceptance. The task remains incomplete, GC stays
deferred and PR #49 stays Draft.

## Current refusal reconciles every root and its actual peak

E1231 instruments published `78ba31d` with only the established temporary
numeric allocator observer. There is no functional candidate or SDK
change. The unchanged full Core gate again fails
`input_attachment.capacity`; intrusive execution timing is not performance
evidence. Actual diagnostic ELF SHA-256 is
`91fec6e472ded678917f5ad7eed5f860c06cf2a6f1fb616710c2b292f7bda24f`.

| Original refusal fact | Bytes |
| --- | ---: |
| Bank capacity | 150,994,944 |
| Charged at the actual decision | 102,454,672 |
| Actual incremental request | 50,331,648 |
| Overshoot | 1,791,376 |

The requesting root is 225 in actual bank 2. Full acquisition, growth and
return events exactly reconcile both charge and root/buffer counts.
Derived invoices plus the original 1,024-byte per-lease header exactly
reconcile every live SUM, without threshold filtering.

| Actual owner | Charged bytes | Current derived SUM | Live derived entries |
| --- | ---: | ---: | ---: |
| Root 1 | 50,179,248 | 43,772,848 | 460 |
| Root 214 | 18,483,424 | 6,917,632 | 119 |
| Root 224, actual checkpoint slot | 16,777,216 | Standalone | Not applicable |
| Root 225, actual input attachment | 16,777,216 | Standalone | Not applicable |
| 29 actual fixed buffers | 237,568 | Not applicable | Not applicable |

Checkpoint and attachment identities come from their actual constructor
stacks, not equal floor amounts. All 17,323 derived constructors retain
their first actual non-budget funding frame, immediate next caller and
full original stack. Every currently live paid child has an origin.
Prepared and Catalog invoices remain real retained DATA, not inferred
leaks or refund authority.

Actual root-growth events also identify the earlier peak separately from
current SUM. Root 1's last growth occurs while file-plan canonical child
11290 retains a 9,360,096-byte invoice. Its constructor is the real
`ownedProductFilePlanCanonical204` path. Its later ledger close precedes
the refusal, but the original Catalog root remains alive and retains its
high-water. Root 214's last growth includes the actual 4,194,304-byte
Registry validation scratch. These observations do not permit lowering
high-water, clearing unknown debt or inventing any consumer ACK.

`main-refusal1231` retains the complete bank balance, unfiltered numeric
events, first-funder/full-stack attribution, actual peak leases and exact
canonical close/standalone-root identities. All 184 observed execution
processes are reaped without surviving, unreaped or unknown processes.
Physical cleanup remains not DATA ACK.

This new source-specific balance replaces no earlier artifact's facts.
It supports evaluating a separately paid same-bank canonical construction
frame on the current source; it does not turn the failed E1224 candidate,
current complete Core, or any broader gate green. The task remains
incomplete, GC stays deferred and PR #49 stays Draft.

## Current isolated canonical message still fails complete Core

E1232 tests published `78ba31d` with only the private
`file_plan_canonical_owner204.cj` payment-scope change. It retains the
original 131,072-byte header, 8,388,608-byte work invoice and complete
retained-DATA meter, but places that canonical carrier on a real separate
message in the same bank with the original floor and consumer-ACK guards.
There is no observer or Registry working-scope candidate.

Build passes in 565.16 seconds. The original complete Core gate still
fails after 57.62 seconds with `input_attachment.capacity` at the same
model-selected Program assertion. Actual ELF SHA-256 is
`35546098a10468a21efb1de6e8a478c2d8d103c961a7945e69af2250049acd89`.
All 198 observed execution processes are reaped with no surviving,
unreaped or unknown processes. Physical cleanup remains not DATA ACK.

`canonical-frame-current1232-complete-core` retains the exact one-file
diff, source binding and actual failure. No numeric savings, new refusal
amount, full Core pass or acceptance is inferred. The candidate remains
private and ineligible; Main remains unchanged. A separate diagnostic
observes its actual refusal rather than retrying it unchanged for a pass.
The task is incomplete, GC stays deferred and PR #49 stays Draft.

## Private canonical diagnostic still exceeds the original bank

E1233 adds only the established numeric observer to the failed private
E1232 source. Actual diagnostic ELF SHA-256 is
`61c92df9edff931d9737d3bef7cca8e9d51a9dd45573dfbc2a5017ac7be73dec`.
The original Core gate still fails `input_attachment.capacity`.

| This private artifact's original refusal | Bytes |
| --- | ---: |
| Actual charged amount | 100,832,504 |
| Actual incremental request | 50,331,648 |
| Original bank capacity | 150,994,944 |
| Overshoot | 169,208 |

Root 1 is charged 48,556,768 with live SUM 43,773,024. Root 221 is
charged 18,483,736 with live SUM 6,917,688. Standalone roots 231 and 232
each hold 16,777,216; 29 fixed buffers hold 237,568. All amounts and counts
exactly reconcile at this refusal. No other artifact receives these values.
This is not permission to refund either live DATA or retained high-water.

The physical census also records one `process_stat_malformed` observation.
Empty known-survivor and unreaped lists do not resolve that unknown
identity or grant process-closure credit. The original failed diagnostic
summary remains failed. `canonical-refusal1233` retains the exact source,
trace, balance and bounded identity diagnostic. No candidate is promoted
from this attempt.

## Native admission validates owned bytes without a decoded load

E1234 isolates a different Registry defect. Non-loading pin validation
opens the 4 MiB JSON-loader scratch despite comparing already-funded
native frozen bytes. The native implementation reads into its retained
`observation_buffer`, compares exact bytes/inodes and drains the original
watches. It publishes no decoded row or new descriptor.

The correction requires the original real 65,536-byte admission frame,
keeps every native snapshot/path/watch/buffer owner paid and uses that
closed validation path. The full 4 MiB scratch remains on actual JSON
load, capture and matching paths. No existing invoice is refunded or
high-water reduced.

Publication checks previously materialize a whole `Array<FileInfo>`.
They now use `Directory.walk` with the original typed recovery error.
The exact fixed SDK's filesystem ELF is read, not rebuilt: its walk uses
one directory handle, reads the next entry and closes on both ordinary
return and callback exception. Dangling markers and `lock.jsonl.txn-*`
entries remain fail-closed; no pending file is interpreted as authority.
`native-validation1234-api-source` binds this implementation evidence to
the readonly SDK filesystem SHA-256
`ec252fb2dfd8fa6f5d2dc509bc7a95fbf0fd44c8fc19f18ce9ddef11abf5e0c6`
and unchanged native backend source.

| Evidence | Actual result | ELF SHA-256 |
| --- | --- | --- |
| `native-validation1234-red-unit` | Real bank-pressure pin regression fails; ordinary writer-contention control passes | `58ac456960bbed2b772d3298b3abe5da3866ce288275f5d1c6d4c137ad600b71` |
| `native-validation1234-green2-unit` | All 36 eligible Native Registry cases pass | `095707a83c91eb3fbb51d7c4a02fd0193727776247bf707f3eae58e460709772` |
| `native-validation1234-native-smoke` | Standalone public Native Registry observes real saturation, valid unchanged pin, rejected byte mutation and both dangling recovery-entry kinds | `474f336c6563efbd58f54cd103992c284e8f0a4ab011b76bef2ab5d85c1cdfd7` |

All 39 natural cases remain: the original 38 and one addition. Three
specifically GC-deferred cases are not rerun and retain zero pass credit.
The regression keeps a real paid pressure loan live, returns only
unfilled caller-owned guard reservations, validates the unchanged pin and
then proves that an actual lock-byte mutation is still rejected.
Existing inode/ABA, grant, shared-fence, full package-byte capture,
publication, raw-publisher and original-floor regressions also pass.

The first GREEN compile rejects a mutable local captured by a callback.
That failed build is preserved separately; the final callback directly
throws the original recovery error, with SDK exception-handle cleanup
verified. No assertion or bound is changed.

The actual standalone executable builds in 60.19 seconds and runs
dependency-ready in 0.54 seconds, with exact expected output and closed
process custody. Both dangling publication-marker and transaction-prefix
symlinks return `plugin.registry_recovery_required`. Caller and output
bytes are retained before removing only that task's caller scaffold.
These are not cold-start, five-second, model, plugin-execution or
matching-baseline results.

The same Native source passes all 129 selected Python regressions and the
complete architecture entrypoint. `native-validation1234-static` retains
the original commands and exact source binding. Only three Registry
production files and the actual pressure regression differ; no generic
cache, SDK/native backend source, permission, Source, SQL, recovery,
unknown Context/Prepared debt, bank/floor/SUM or final-ACK rule changes.

These independently exercised Registry files are still private at this
checkpoint. A separate unchanged complete Core gate evaluates their
combination with the canonical payment scope. Component and public
Registry passes do not preclaim that result. The task remains incomplete,
GC stays deferred and PR #49 stays Draft.

## Combined source reaches inspection but full Core remains failed

E1235 builds published `78ba31d` plus exactly three E1234 Registry
production files and the private canonical payment-scope file. There is
no allocator observer, unit fixture or other private source.
Build passes in 554.74 seconds. The unchanged full Core gate fails after
53.16 seconds at the next Program inspection assertion, not the earlier
returned-Run assertion. Actual ELF SHA-256 is
`b188942beee42537eae482919e58a8dafb54b18d53b592cbc18a6f63255c5557`.

The Run is Completed, but that is not proof that its Program tool or
input consumption succeeded. The required SDK/content/argument fields
do not satisfy the original inspection check. Canonical Operation,
Receipt and attachment evidence must determine the actual tool outcome;
the SQL/provenance join and expected fields remain unchanged.

All 198 observed execution processes are reaped without surviving,
unreaped or unknown processes. Physical cleanup remains not DATA ACK.
`native-canonical1235-complete-core` preserves the exact four-file diff,
source, actual failure and census. No complete Core, Program, Product,
release or performance pass is claimed. The combination remains private
pending diagnosis. The task is incomplete, GC stays deferred and PR #49
stays Draft.

## Actual canonical receipts explain the failed Program inspection

E1236 replays the exact already-built E1235 ELF only to retain previously
unavailable actual SQLite evidence. No rebuild, source, assertion,
fixture path, environment, allowance or SQL change is made. The original
gate fails at the same inspection check after 57.38 seconds; no repeated
failure or Completed Run is counted as acceptance.

An event-driven external observer opens SQLite files read-only at
creation. It performs no live query or content read, takes no SQLite
lock, creates no hardlink and does not intercept deletion. After the
actual case returns, it copies six original DB/WAL/SHM inodes already
unlinked by the original fixture. Inode identity is checked; all observer
FDs close and its thread returns without errors. All 203 actual execution
processes are reaped with no unknown, surviving or unreaped processes.

The actual canonical rows show a failed `plugin.axyndra:workspace.grep`
derived Receipt with `plugin.snapshot_stale`: Pi package verification
failed or its bytes differ. Its parent `plugin.axyndra:program.run`
Receipt is failed with `tool_program.subcall_failed`; the Run is
Completed. An actual input-attached audit exists, but the successful
completed-attachment provenance join correctly rejects that failed
Receipt. No inspection metadata is synthesized or join condition relaxed.

`native-canonical1236-retained-store` preserves the retained store, inode
manifest, exact read-only canonical receipt/audit projections and scope.
The primary DB passes `quick_check`. Both DB and WAL byte images remain
identical after offline analysis; the copied primary SHM read marks
change, explicitly recorded with before/after hashes. Original application
files are already unlinked and closed. The underlying package-verification
failure remains to be distinguished from a genuine byte change. This is
diagnosis, not a Program, Core or release pass. GC stays deferred, the
task is incomplete and PR #49 stays Draft.

## New-source refusal is the additional package digest worker

E1237 adds only the frozen scalar/constructor observer to the exact E1235
four-production-file combination. Build passes in 601.78 seconds.
The original full Core still fails its Program inspection after 121.29
seconds. Diagnostic ELF SHA-256 is
`b655d315259bb1b6c94e9e1f19703fafd3d7ead54a9a07f5f8de3df9c238b617`.
This intrusive observer provides no acceptance or performance credit.

The observer writes scalar events to its existing append-only disk-mapped
temporary sink, not stderr. The two actual process-start boundaries
separate old E1233 events from this run; both segments are preserved.
Every one of 13,988 unique current derived births matches exactly one
constructor stack in current stderr. No run was repeated to recover the
sink and no custody-growth threshold is applied.

The first actual refusal is now on Registry root 1:

| Refusal fact | Actual bytes |
| --- | ---: |
| Existing shared-bank charged amount | 150,972,536 |
| Actual additional requested growth | 98,304 |
| Unchanged shared-bank capacity | 150,994,944 |
| Overshoot | 75,896 |
| Root 1 charge and live SUM | 48,792,176 |
| Other Registry root 221 charge | 17,974,792 |
| Root 221 live SUM | 6,917,688 |
| Actual checkpoint root 231 charge | 16,777,216 |
| Actual input root 232 charge | 67,108,864 |
| All 32 actual fixed buffers | 319,488 |

All roots plus buffers exactly equal the bank charge; each derived invoice
plus its original header exactly equals its live SUM. The refusing child
13039 is the original `PluginRegistryStateMemory` inside `Registry.inspect`
called by Pi `startThreadHost` for the actual nested Program service path.
Its paid amount is 4,226,984 bytes before its header. The next required
98,304 bytes fund the actual additional package digest reader, retained
file records and Future/control. Original current-byte package inspection
remains mandatory.

The exact capacity failure is caught by `Registry.inspect` and the Pi
launch match converts that inspection error to `plugin.snapshot_stale`.
It is not evidence that package bytes changed. Neither this exact
reconciliation nor a retired lease permits lowering a high-water mark,
refunding a live owner or treating the input's logical state as ACK.
All 203 actual execution processes are known and reaped. The separate
build census is also clean. `native-refusal1237-complete-core` preserves
all events, source, constructor coverage, balance, raw stderr and scope.
No complete Core, Product or release pass is claimed.

## Qualified Native Registry validation promoted to Main

E1238 migrates exactly the E1234 three Registry production files and its
genuine-pressure/source-mutation regression to the delivery checkout.
All four raw SHA-256 identities equal their actual Native-qualified
sources, without a line-ending exception. The private canonical payment
change and all allocator observers are excluded.

Only non-decoding Native admission uses its already-paid original
65,536-byte frame and retained snapshot/path/observation buffers.
Full 4 MiB scratch remains on JSON loading, capture and matching paths.
Publication-name checking streams entries and still rejects dangling
pending-marker and transaction-prefix symlinks. Actual inode/watch/byte
checks, writer fences, recovery errors and immutable admission remain.
No existing DATA owner is returned or billed less.

Exact-source evidence carries forward the real failing-before pressure
case, 36 passing eligible Native regressions and standalone public
Registry pressure/mutation/dangling-record smoke. Natural inventory is
39; its three known GC cases remain unexecuted and get zero credit.
Native unit ELF is
`095707a83c91eb3fbb51d7c4a02fd0193727776247bf707f3eae58e460709772`;
public smoke ELF is
`474f336c6563efbd58f54cd103992c284e8f0a4ab011b76bef2ab5d85c1cdfd7`.

The actual delivery checkout additionally passes the original 129 Python
cases in 18.93 seconds and complete architecture gate in 43.80 seconds.
`native-validation1238-promoted-main` records those commands/results and
all four exact source identities. This is not the full Core combination,
nor whole Product, startup, matching-baseline or release acceptance.
Core's non-GC gap remains open. GC stays deferred, the task remains
incomplete and PR #49 stays Draft.

## Real full-byte inspection reproduces the worker pressure defect

E1239 builds a standalone public Native Registry caller against published
`c054476`. A deterministic Pi package has two real 1 MiB payloads, a
manifest and an extension that must never execute. Independent standard
Python SHA-256 computes both original and same-length-mutated complete
v2 tree identities. The unpressured current-byte inspection matches the
original exact digest.

The caller then holds five actual same-bank independent reservations,
grows its paid loan to actual bank refusal, verifies that another actual
independent message is refused, and returns only 66 never-filled
caller-owned fixed guards. Under that real pressure, the original
inspection fails `plugin.registry_metadata_capacity`. No Source DATA,
unknown consumer or high-water mark is acknowledged.

E1240 changes only the optional parallel-selection block in a private
checkout. The original full-byte serial path still reads every file,
checks path/root/type/symlinks, pre/post metadata and size, enforces the
same tree limits and emits the identical canonical v2 format. The exact
same caller bytes now match the full original digest under pressure,
detect the changed full digest and preserve the original immutable
descriptor. Nothing is cached or authorized by those DATA comparisons.

| Actual Native evidence | Result | ELF SHA-256 |
| --- | --- | --- |
| `package-pressure1239-red` | Exact unpressured tree matches; actual pressured inspection fails capacity | `1ac7314fed2662092cb5c9489086ca991ae885de6bbe8e0824ddd7e5462eec36` |
| `package-pressure1240-green` | Identical caller passes all original/changed full-tree and pressure checks | `4b8d5fb2d36265d2744edee1eb974d8561e2dacc843a6076a29dde4892892373` |
| `package-serial1242-clean-smoke` | Corrected clean serial production passes the same complete actual checks | `ecd2200675024bf3bd9e13240912905c1d195a853365d9a8fbd063d035237c49` |

Each actual execution has no surviving, unreaped or unknown processes.
These are focused Source-inspection results, not matching performance,
five-second startup, plugin execution or complete Core acceptance.
The serial experiment remains private; no current Main behavior is
changed by these results.

## Clean serial combination still fails original full Core

The private cleanup removes the unused extra reader, its work-accounting
method and largest-file bookkeeping. The initial E1241 build correctly
catches that the deleted worker file also housed the shared canonical
tree-entry formatter. Its original eight-line implementation is moved
unchanged into the active digest file. That failed build is preserved.
The first Core preflight also preserves the old pin-test hash mismatch;
the corrected proof uses the exact already-published E1238 test hash,
not a removed source guard. No Core executed in that failed preflight.

E1242 then builds published `c054476` plus the clean serial production
and the same private canonical payment-scope file, without an allocator
observer or a unit fixture. Build passes in 512.40 seconds. The unchanged
complete Core gate still fails its original Program inspection assertion
after 55.40 seconds. Actual ELF SHA-256 is
`4e1ace8ec3c3062154dd3d76469710a4b01f110e44e3de5dda3d89c71b1145e6`.
All 201 observed execution processes are known and reaped. The original
four-stage source/receipt expectations are not weakened.

The event-driven read-only inode observer retains six actual DB/WAL/SHM
images after the original fixture unlinks them; all its FDs close and
its thread returns. Raw captured images remain unopened in SQLite and
retain all six original hashes. Only separate analysis copies are queried;
their primary DB passes `quick_check`, then all analysis connections close.

Actual current-source canonical receipts still distinguish the Completed
Run from failed `plugin.axyndra:workspace.grep` and
`plugin.axyndra:program.run` receipts. The derived error is
`plugin.snapshot_stale`, the parent error is `tool_program.subcall_failed`,
and the actual input-attached/handoff audits do not satisfy the original
successful completed-attachment provenance join. No SDK field or receipt
is synthesized. The underlying new-source failure and amount require
fresh attribution; the old 98,304-byte refusal is not transferred to this
artifact.

`package-serial1242-complete-core` and
`package-serial1242-retained-store` preserve the exact source, original
failure, physical census, original inode images and canonical SQL
projection. Component pressure success does not close this non-GC Core
gap. The combination remains private and the task is incomplete.

## Clean serial regression qualification preserves original gates

E1243 converts the real full-tree pressure/mutation caller into a permanent
Registry regression. Its first build detects an accidental own-package
import; removing that import fixes the actual cyclic dependency without
changing any assertion. The original failed build remains preserved.
Natural Native inventory is required to be the original 39 plus that one
case, with all three original GC-deferred cases still excluded from
execution and receiving zero pass credit. E1245 actually passes all 37
eligible Native cases against the natural inventory of 40. Actual unittest
ELF SHA-256 is
`ab622a50442658f87097254ad651e9ea011910376b25f493ff348b91d8c8f220`.
`package-serial1245-unit` records every original name, command, qualified
single-case result and closed process custody. This is selected-case credit.

E1244 passes the original 129 Python cases but correctly fails architecture
because the historical E792 row presents the now-deleted worker path as
an extant authority. The private documentation keeps the entire old
investigation and GC conclusion, identifying its historical filename
without claiming that deleted source still exists.

With that authority formatting and the own-package import corrected,
E1246 passes all original 129 Python cases in 18.05 seconds and the
complete architecture gate in 41.86 seconds.
`package-serial1246-static` records actual commands, complete source
identity and both results. Full 4 MiB loading work, 64 MiB input work,
the 144 MiB bank, original floor/SUM/high-water, actual ACK, permissions,
Source and recovery remain unchanged.

Neither this static pass nor a focused Native pressure pass gives whole
Registry/Core/Product/App, startup, matched-baseline or release credit.
Only E1238's separately qualified Registry admission correction is
published. The serial/canonical combination remains private, GC stays
deferred, the task remains incomplete and PR #49 stays Draft.

## Fresh serial-source refusal belongs to actual private manifest parsing

E1247 rebuilds the exact failed E1242 production and canonical combination
with only the frozen, unfiltered numeric allocator observer added. The
original complete Core still fails Program inspection. Actual ELF SHA-256
is `4f0095ac30b11c4231b97d3a6ca724ac7bbffd3ac696e2c1658d5eeddb71244b`.
All 179 observed execution processes are known and reaped.

| First actual refusal fact | Bytes |
| --- | ---: |
| Unchanged bank capacity | 150,994,944 |
| Charged at this refusal | 150,971,744 |
| Actual additional request | 31,384 |
| Overshoot | 8,184 |

Every active lease invoice and header agrees with its ledger SUM.
All root charges and 32 live fixed buffers agree with the bank. All
13,990 derived identities have unique actual constructor stacks, without
threshold filtering. The current private-document frame belongs to the
real nested `Registry.inspect` call reached from the Pi launch check.
The observer records its prepayment, node growth and return rather than
inferring them from the failed parent receipt.

`package-serial-refusal1247` preserves the complete event stream, original
failure, exact bank reconciliation and private-document constructor stack.
The old worker refusal amount does not apply to this ELF. This accounting
proves the current refusal, not a leak, a refund or a performance result.

## Actual manifest-read work has a separate retirement witness

E1248 keeps the original full file read, UTF-8 conversion, manifest parser,
directory/layout validation and fresh tree-byte inspection. It does not
replace complete inspection with a hash comparison. The private candidate
funds the original full 4 MiB read work before I/O, separately from returned
text/error DATA. Those outputs receive their full independent invoice
before escaping the private frame.

The raw byte holder clears after the actual reader and publication helper
return. Only its same-payment, one-shot typed retirement can release read
work. A recorded exact prepublication refusal may return that private work.
Another logical error after actual output acceptance remains unknown and
cannot acknowledge it. Full Registry loading/capture work and input work
are unchanged.

The identical Native public Registry caller now returns only 65 never-filled
fixed guards, rather than the previous 66. It retains the genuine bank and
independent-message refusal checks, original full-byte digest, changed-byte
digest and immutable old descriptor assertions. Caller SHA-256 is
`d161b9b577b1a2b5c931c46ef8995d6d007b572e587c3cfd7b5cc40c7b994720`.

| Stronger-pressure Native evidence | Actual result | ELF SHA-256 |
| --- | --- | --- |
| `manifest-read1248-red-smoke` | Original serial implementation fails `plugin.registry_metadata_capacity` after the genuine refusal | `652eb802beaf509d0038bc96ff38f586df0de177f8801389fe7cc44ed137316e` |
| `manifest-read1248-green-smoke` | Exact caller passes original/changed full-tree and immutable descriptor checks | `8a50f97d10c27e675a31fd557880e2aeb8dde88f78c21889470301fdb3f2cde3` |

Both executions close their original strict process custody. The Native
Registry caller does not link the private canonical payment candidate.
Full Core qualification of the combination and actual retained-DATA/error
boundary qualification are not yet accepted. No new production change is
published from these experiments. The task remains incomplete, GC stays
deferred and PR #49 stays Draft.

## Reader boundaries pass but full Core reaches another package-check refusal

E1250 passes all 37 eligible Native Registry cases and three new public
`inspectPluginPackage` boundary cases on the exact E1248 production.
Registry inventory remains 40, with the same three known GC cases not run.
Extension Runtime naturally enumerates 103 cases; only the three new cases
run, so the other 100 receive no credit.

The public boundary cases use a real fixed 32 MiB ledger with two actual
message floors. Exact read DATA survives a later consumer failure. An
actual before-publication payment refusal returns only private read work.
A different logical error after retaining real output keeps that work
charged and refuses the next real consumer. The fixture clears its actual
DATA only after the asserting consumer frame returns. These are lifetime
and saturation results, without a product quota change.

| E1250 Native artifact | SHA-256 |
| --- | --- |
| Extension Runtime unittest ELF | `ba31544c42af98209125a3d2159deec154f919cbe25d126a2f8cf3c35f3381d3` |
| Registry unittest ELF | `3703ae4cc56b8807dc964a58aa7a1acca044d3afaf6595c17f76fad70a77a003` |

E1249 builds the same private production plus the canonical payment
candidate without either unit fixture or numeric observer. The unchanged
complete Core still fails its original Program inspection assertion.
Actual ELF SHA-256 is
`7480ec2ee5eee426503e60e1e869ab01408fc7b4a7b38b9e5a1def0fb15e889d`.
All 196 observed execution processes are known and reaped.

Six actual DB/WAL/SHM inode images survive the original fixture unlink.
All observer FDs close and its thread returns. Raw images retain their
capture hashes and remain unopened in SQLite. Only separate analysis
copies are queried, and the actual database passes `quick_check`.

The real receipts now include the derived `host.process.readview` operation.
It fails `read_view.package_changed` with “worker package is unavailable”.
Workspace reports `workspace.protocol`, and Program remains a failed
partial receipt despite the Completed Run. Thus the read change reaches
a later real child but does not establish successful Program provenance.
The old snapshot-stale diagnosis and refusal amount do not apply to this
artifact without new evidence.

`manifest-read1250-unit`, `manifest-read1249-complete-core` and
`manifest-read1249-retained-store` preserve the actual commands, source,
qualified results, process custody and original canonical projections.
The full Core gap remains open. The candidates remain private.

## Fresh read-view refusal needs a new working-payment increment

E1251 adds only the frozen unfiltered numeric observer to the exact failed
E1249 production. Its actual ELF SHA-256 is
`a84058f04769c66a76beb8c48c7216c6a169164f66f2599162723c9b0005033c`.
The original complete Core still fails. All 204 execution processes are
known and reaped.

| Current first refusal fact | Bytes |
| --- | ---: |
| Unchanged bank capacity | 150,994,944 |
| Charged at this refusal | 150,812,360 |
| Actual additional request | 505,720 |
| Overshoot | 323,136 |

The exact constructor belongs to the fresh full 4 MiB package-inspection
work payment, reached from the actual read-view executor's package check.
The requesting ledger's live SUM remains below its billed high-water.
That slack is insufficient for the full original work invoice, producing
the recorded increment. It is not permission to refund the historical
peak or reduce the invoice.

All current live invoices, headers, root charges and 33 fixed buffers
reconcile. All 14,289 derived identities have unique actual constructor
stacks. `manifest-read-refusal1251` preserves every live holder and its
original stack without threshold filtering. Current attribution does not
prove any opaque or older consumer has returned its DATA.

E1252 passes the original 129 Python cases but catches one more historical
E792 authority reference in the private issue ledger. Only that reference's
formatting is corrected, reusing E1246's qualified wording. The entire
historical GC evidence, exact old status excerpt and later refutation remain.
The failed architecture result is preserved; corrected qualification is
separate. Whole Core, Product, startup, matched baseline and release remain
unaccepted. The task is incomplete, GC stays deferred and PR #49 stays Draft.

## Published admission source passes all nine production builds

E1253 rebuilds only published `c054476` in a new task-owned cache. Its
16 source identities exclude the private serial, reader, invocation-work,
canonical and numeric-observer experiments. All original nine production
stages pass under their original bounds and strict process custody.
The fixed official SDK remains read-only.

| Current published-source artifact | SHA-256 |
| --- | --- |
| App ELF | `29518401b621209883d7a203d9462218122381362d9bdcb3b56cb3e9ea2b3588` |
| Minimal ELF | `18b1b4ac1f2d7809fdfc6cf907450de505518de7a8267f2a23b5dc6d9c160a8c` |

`native-admission1253-nine-production-stages` records each real command,
source identity and artifact. This is production compilation evidence.
It does not establish a current Coding package, successful local model
request, matching performance or complete release.

E1254 separately passes the original complete architecture gate in 45.08
seconds after the private issue ledger's E792 formatting correction.
All production/test hashes remain identical to E1252, so its 129 Python
successes remain applicable. `manifest-read1254-architecture` records that
reuse and the entire original architecture command. This qualifies only
the private reader combination's static gates.

## Current-invocation work handoff remains a private experiment

E1255 identifies the other retained Registry root as the actual independent
artifact-failure Product. Its surviving custody is not available for
arbitrary reuse or refund. Opaque contexts, Prepared values, copied fixture
observations and all original return proofs remain paid.

The new private design assigns inspection work to the actual current
invocation's existing Application reservation, without changing its initial
failure-metadata invoice or acknowledgement protocol. A concrete one-shot
funding ticket owns only a new empty control child. The inspector obtains
a distinct full 4 MiB child after checking the same original bank.
Closing the empty ticket cannot close that actual working child.

Only the latest exact request consumer can request funding. Supplier code
receives no Raw Context, Source, ToolCall, plan or Registry reservation and
runs outside Core/custody/Registry locks. Closed or absent suppliers preserve
the original Registry payment path. Every reopened manifest read requests
fresh funding. Actual read bytes and unknown-output retention still obey
the existing typed return witness.

E1256 exercises the public Registry entrypoint with actual same-bank caller
funding. It first establishes genuine bank growth and independent-message
refusals. After returning 48 never-filled fixed guards, ordinary inspection
still fails capacity. Funded inspection then matches the complete original
and changed tree digests and preserves the immutable old descriptor.
Another real independent message remains refused afterward.

Actual Native ELF SHA-256 is
`e8b5d0ff2f50bb8b158cc3df4d3f4a86912b85ee33bda43c29a11d531287d9b4`.
`invocation-work1256-native` preserves exact source, all six output checks
and closed process custody. This caller links Domain, Registry and Extension
Runtime only. The new Core/Application binding is not compiled or accepted
by that result. Its new ownership/recovery and complete Core requirements
remain unverified. No private candidate is published.

The bank, floor, SUM/high-water, full working invoices, permissions,
Source, canonical SQL and actual DATA ACK requirements remain fixed.
Whole Core, Product, startup, matching baseline and release remain
unaccepted. The task is incomplete, GC stays deferred and PR #49 stays Draft.

## Published-source Coding package passes selected real entrypoints

E1257 assembles the actual Coding package from E1253's published-source App.
Actual package ELF SHA-256 is
`98e572e0a49b01de502c9cb9c61dfb06d10dd5074e6352345e06308060332c12`.
The original package assembly, clean environment, setup and real captured
PTY `cards` and `ask` scenarios all pass with closed process custody.
Source and original App identities match before and after packaging.

`native-admission1257-current-coding` retains commands, package provenance,
terminal evidence and actual canonical state projections. The known
GC-deferred fresh-operator scenarios are not retried or counted passed.
The original local model request gate and complete frontend/release and
matching-baseline acceptance remain separate. No private reader, work-owner,
canonical or numeric-observer candidate enters this package.
The task remains incomplete, GC stays deferred and PR #49 stays Draft.

## Current-invocation binding advances Core but does not complete it

E1258 compiles the private Core/Application binding with the serial digest,
manifest-reader and canonical-payment experiments. The unchanged complete
Core fixture still fails its original Program SDK/content/arguments SQL
assertion. Actual retained canonical receipts now show
`host.process.readview` failing with `read_view.output_capacity`, rather than
the earlier package-validation error. The parent Program subcall remains
failed despite the Run's Completed state.

Actual Core ELF SHA-256 is
`43aa91b94f1cce535f18a41fd8d7f88f369635cd28b9c3eb82ac04844020fd22`.
`invocation-work1258-complete-core` preserves commands, source binding and
closed custody for all 194 observed processes. Six original database/WAL/SHM
inodes were retained read-only before deletion. Their raw hashes remain
unchanged; only independent analysis copies were queried, with connections
explicitly closed. `invocation-work1258-retained-store` preserves the full
typed canonical projection. No SQL, assertion, permission or DATA-return
requirement is relaxed. The new output refusal has not yet been numerically
attributed; amounts from E1251 do not describe this different refusal.

## Published Coding package still fails the original first-model deadline

E1259 runs the untouched `provider_profiles_blackbox` against E1257's actual
published-source Coding package. The first
`--print --model profile-one/shared-model` local HTTP fixture request exceeds
the original five-second subprocess deadline. The second profile is not
executed. The outer 180-second bound is unchanged; all 50 observed processes
are reaped with no unknown or remaining process.

`native-admission1259-provider-profiles` binds package SHA-256
`98e572e0a49b01de502c9cb9c61dfb06d10dd5074e6352345e06308060332c12`
and the exact unmodified fixture. There are no concurrent agent Native builds
during this gate. The timeout is not GC evidence or a passing local-model,
matching-baseline or release result.

## Private funding and custody regressions pass only their selected cases

E1260 initially fails compilation because a new test uses the reserved
identifier `foreign`. The failure is retained. E1261 changes only those four
local references to `otherBank`, then passes all 53 selected real Native
cases: four new same-bank funding/foreign-bank/replay/saturation cases,
nine original request-custody/task/opaque/actual-failure-ACK cases, three
public manifest-read DATA/error cases and 37 eligible Registry cases.
Registry naturally enumerates 40; its three known GC cases remain unexecuted
with zero credit. No complete module or application pass is claimed.

| E1261 selected module | Actual Native ELF SHA-256 |
| --- | --- |
| Domain | `0dd782140b93c4ab1980d3c6dc2a730fa54ce3d5bf3fdded4f4388dfdec99519` |
| Core | `b2d27409fadd26ce5d5719be8e0408e61a97fabe40aa1362b7f10e5b506356f1` |
| Extension Runtime | `13ceec51c18b501ecdd180b9f36bdbe1490f6223e88e38c37d6351ef538f0532` |
| Registry | `7019a5f764b5cc18ed63b6a835a20719757fc80e8df6bf6b910fa2189cc949d9` |

`invocation-work1260-unit` retains RED compilation evidence;
`invocation-work1261-unit` retains source, natural inventories, exact selected
cases and closed process custody. Production source is identical to E1258;
the test-only identifier correction does not change its failed Core result.
The private experiments are not promoted or published. Whole Core, Product,
first local model request, matching baseline and final release remain
unaccepted. The task is incomplete, GC stays deferred and PR #49 stays Draft.

## The new read-view output owner needs its own original floor

E1262 observes the initial output acquisition, not the earlier inspection
growth. The actual request is 16,777,216 bytes against 150,517,568 charged
bytes and the unchanged 150,994,944-byte bank: a 16,299,840-byte shortfall.
The requesting root is zero because no output owner was admitted.

| Actual E1262 root | Constructor-bound role | Charged bytes | Live derived invoices |
| --- | --- | ---: | ---: |
| 1 | Main Product Registry custody | 48,821,064 | 45,114,024 |
| 221 | Independent artifact-failure Product Registry custody | 17,482,744 | 6,917,680 |
| 231 | Current Application checkpoint slot | 16,777,216 | 135,296 |
| 232 | Actual input attachment | 67,108,864 | Not a derived ledger |
| Fixed buffers | 33 actual reservations | 327,680 | Not derived leases |

The complete sum reconciles exactly. All 14,299 derived births have unique
corresponding constructor stacks; all 589 refusal-time shared holders and
their full origins are retained without threshold filtering. Actual
immediate funders distinguish Prepared copies, catalog copies, source loans
and fixture observations. A deeper Program caller is not the allocation owner.

Actual diagnostic ELF SHA-256 is
`26278c789f1444bc31ca3653e0fa3b6d0bc3793f85ebadf148fbfe0d5f97fb4a`.
`invocation-output1262` retains the full events, constructor traces and bank
reconciliation. The original complete Core still fails. Shared high-water
remains until the last actual lease closes; closing a child does not refund
the original root. Neither a low current SUM nor a completed Product permits
borrowing or refunding the independent artifact-failure root.

## Current first-unknown attribution does not establish final DATA return

E1263 adds private source-only observations at actual first unknown exports
and Prepared collection attempts. Complete Core still fails with closed
process custody. Actual diagnostic ELF SHA-256 is
`b503b578dce6af58fba71067df49b073ec2cea186e77dfb9a3c80362be4b24cd`.
Its own initial output refusal requests 16,777,216 bytes against 150,518,032
charged bytes: a distinct 16,300,304-byte shortfall.

The trace records 55 Prepared first-unknown exports and two Core Context
first-unknown observations. The Prepared callers are the regular Host Tool
Executor's plan getter and Service Broker child validation's call getter.
For 52 still-live owners, prior observations establish both actual producer
return and the monotonic unknown flag, totaling 14,137,472 invoiced bytes.
Last-observed consumer counts are not claimed as refusal-time counts.

`invocation-debt1263` retains every observed first-export stack and the fresh
bank/owner correspondence. This reconfirms the E1175 boundary on current
source; the first getter is not the last consumer. Descriptor capability,
effect and network callbacks can retain a ToolCall over canonical arguments.
The existing `hasRawPreparedCallResolver204` predicate covers canonical and
preparation-read callbacks, not those three callback families. Reusing it or
a nominal closed flag as a general release proof would be incorrect.

E1267 therefore withdraws an unused private exact-Core Host getter helper
before any caller migration or compilation. No candidate ELF exists and no
main source changes result. No unknown flag, Context field, quota, floor,
high-water, Source, SQL or ACK rule is changed. A correct cutover still needs
concrete closed consumers or independently paid copies with actual transfer
and field-clearing evidence.

The existing offline E1258 artifact-failure Product database identifies
Program, Workspace read, read-view and file-plan proposal operations. The
file-plan failure is real; the other Product's logical completion is not a
return receipt for its retained metadata.

## Standalone chmod timing is not startup hotspot proof

E1264 compiles and runs a standalone standard-library probe with the fixed
official compiler and package-manager versions. It has no Axyndra imports,
configuration or wrapper dependency. All 30 actual permission subprocesses
complete successfully and leave the real file at mode 0600.

| Standalone process workload | Samples | Whole-process wall time |
| --- | ---: | --- |
| No permission subprocess | 3 | 24.89–26.13 ms |
| Ten `executeWithOutput` chmod subprocesses | 3 | 34.78–37.01 ms |

`standalone-chmod1264` preserves source, executable, commands and raw results.
The separate Core diagnostic build can perturb these timings. They are not
CPU attribution, current App phase timings, a matching release baseline or a
passing five-second request. The incidental historical chmod stack does not
justify replacing permission operations or removing their fail-closed checks.

## Portable Skills classification first requires a qualified executable

E1265 refuses the debugger run before executing any case: the original cache
no longer contains the qualified historical Product ELF. The required hash
is not found among the 18 retained task-owned unittest paths inspected.
The guard failure is retained; no different executable is relabeled and no
historical failure is reclassified as GC.

E1266 instead starts a fresh current-published-source Product test build.
It exceeds the original 900-second compilation bound. All 110 observed
processes are closed with no unknown or unreaped process. Static dependency
and Product archives are generated, but no new case is executed or counted
passed. `portable-skill1266-current-product` retains the failed build, exact
source and custody. Cold-build, portable-case and whole-Product acceptance
remain open. The task is incomplete, GC stays deferred and PR #49 stays Draft.

## Current Portable Skills sample has direct Runtime GC evidence

E1268 reuses the actual static dependency and Product archives generated by
the failed E1266 attempt. The normal incremental Product test build succeeds
in 403.23 seconds under the same original 900-second bound and unchanged
source, compiler, options and tests. This is not a passing cold build.
Natural enumeration lists 1,086 cases. A subsequent fixture-path guard fails
before case execution because the new target bind hides historical package
paths; that failed attempt is retained.

E1269 maps the actual original task-owned fixture cache read-only, without
altering it or substituting packages. All 17 original manifests, provenance
records and Native entrypoint hashes match. It reuses the unchanged compiled
ELF and natural enumeration, then executes only the still-unclassified
portable Codex Skills public case under its original deadlines.

Actual Product unittest ELF SHA-256 is
`f2a941be17cd75cd4e1f8fa4521d385d4d008fc95a73217e99bebf3cd6fad87a`.
The case fails with SIGSEGV in `gc-main-thread`, with an actual
`MapleRuntime::CheckAndPush` frame from `libcangjie-runtime.so`.
All ten observed processes return with no unknown or unreaped process.
`portable-skill1269-current-product` retains the exact fixture bindings,
normal test frontend output and reviewed classification.

Only this current artifact/sample enters the user's GC deferral, with
zero pass credit. The older `9bc355c8` SIGABRT/region-assertion sample remains
unclassified; its history is not rewritten. The new stack does not establish
the underlying SDK-versus-application root cause. No debugger retry of the
now-observed GC path is needed. Whole Product, Core capacity, first local
model request, matching baseline and final release remain unaccepted.
The task is incomplete, GC stays deferred and PR #49 stays Draft.

## Private full-invoice output custody advances but does not complete Core

E1271 independently inspects the nine retained Coding packages in distribution
and reverse order. All 18 complete v2 digests match their independent golden
values. The two orders take 1.546 and 1.276 seconds respectively. Caller ELF is
`aff3c787620ddb59b77d4a83ae0c2672e635f566db0475e71fb8ea7692ebc328`.
These are standalone inspection controls, not App startup, shared-bank
pressure, a matching baseline or the original five-second request gate.
`package-inspection1271` retains the actual sources and full-byte bindings.

The E1272 private candidate adds a distinct output DATA child of the actual
one-request supplier. The original same-bank check, full
`max(16 MiB, 8 * bytes)` invoice, live SUM, child headers, high-water and real
output consumer remain. A closed, ambiguous or absent supplier does not
select another request's owner. No allocation token grants execution authority.

| Evidence | Actual result and qualification boundary |
| --- | --- |
| E1272, `invocation-output1272-unit` | Six new test-only tuple-index syntax errors prevent execution; no passing cases. |
| E1273, `invocation-output1273-unit` | Seven actual Domain custody cases and nine existing Core cases pass; the new ambiguous-request case fails. Overall qualification fails. |
| E1274, `invocation-output1274-unit` | Rejecting the Run-wide supplier when multiple request consumers remain makes all ten selected Core cases pass. Other naturally enumerated cases receive no credit. |
| E1275, `invocation-output1275-complete-core` | Build passes; the original complete Core consumer crashes before its original Program provenance check. No Core pass. |
| E1277, `invocation-output1277-nine-production-stages` | A fresh target builds all nine original production stages within their original bounds. Build-only evidence, not a successful Core consumer. |
| E1279, `invocation-output1279-complete-core` | Fresh complete consumer rebuild passes; execution still fails the original SDK/content/canonical-arguments inspection assertion. |
| E1281, `invocation-output1281-complete-core` | Passing the original request's DATA supplier explicitly across the process-only cancellation projection permits the first read-only Program and its original provenance check to succeed. The original new-Thread rerun still fails. |

E1274 Core unittest ELF is
`cda06a1ec3f018998f2dc7df1a53fa07a74315cead2b3b010cf026128613ae62`.
E1273 Domain unittest ELF is
`f788b1ac1bbc87b81a182f9fda9dcca4e10a5c6f34adadafad7cc9ec7d90f6a8`;
its seven cases cover actual retained data, full invoices, foreign-bank
rejection, saturation and duplicate-close protection. Neither is whole-module
acceptance.

The E1277 private App is
`355f281e9d1c2691d29f19450756169833b44183a8c4c52faa03f59f0c1e263f`.
The failed E1279 Core ELF is
`6c23d30010f8f745ea6539751a6b2b6ccb3c0778f3d3c493b53000b8d626a60a`.
The failed E1281 Core ELF is
`d8cf46ae62d0d0437e6534e07770d9f593d2944019a2c1d6c8a36d10d15959ed`.
All remain private; the published host behavior remains `c054476`.

## Saved invalid-PC sample is not GC evidence

E1276 reads the already-existing E1275 core with the exact
`e1fe5595ef16d3d824454b4ebcbf66fc4e1c361a93209d4fb75230622ed18b8e`
consumer and its matched Native bridge. It does not start a new inferior,
replace the SDK or repeat the failed workload.

The original `schd-worker` PC is `0xffffffffffffffff`. Signal reporting then
crashes in `FrameInfo::ResolveProcInfo`, through frame analysis and
`PrintSignalHandlerStack`. Other GC threads in the saved process do not prove
the original fault is GC. The apparent Native return address points into
read-only `/proc/%ld/stat` text, not a validated callee or a proven stat-parser
defect. Classification remains unclassified invalid managed PC with a
secondary signal-unwind crash, zero pass credit and no GC deferral.
`invocation-output1276-saved-core` retains the reviewed binding and the
779,202,560-byte original core. A later build not reproducing that signal
does not prove stale ABI or an SDK root cause.

## Current new-Thread refusal has its own complete balance

E1283 adds only task-private numeric bank, root, lease and birth observations
to the E1281 candidate. It preserves the current DATA APIs, original complete
fixture, actual acknowledgements, tariffs and deadlines. Every growth is
recorded without threshold filtering; diagnostic records retain no owner or
child references. Its exact consumer ELF is
`dacd48b080cb03c789113a381d8edfcafa7498e109dbcd242f074baf247b0d8c`.
The original new-Thread assertion still fails.

| Refusal-time quantity | Bytes |
| --- | ---: |
| Actual bank capacity | 150,994,944 |
| Actual charged amount | 101,156,680 |
| Actual requested growth | 50,331,648 |
| Actual overshoot | 493,384 |
| Root 1 high-water charge | 49,857,376 |
| Root 220 high-water charge | 17,482,728 |
| Root 235 current checkpoint slot | 16,777,216 |
| Root 236 actual input attachment before refused growth | 16,777,216 |
| All 32 live fixed transport buffers | 262,144 |

The four roots plus fixed buffers exactly equal bank occupancy. Root 1 has
45,896,336 live SUM across 470 leases; root 220 has 6,917,680 across 119.
Their high-water-minus-live differences are not evidence of a leak, return
or permission to refund. Root 235 is the actual new Application checkpoint;
root 236 is created by `HostToolInputAttachmentSession` before its original
64 MiB working prepayment. No older refusal's amounts or root roles are
substituted for these observations.

`invocation-output1283-complete-core` retains all 252,280 numeric events,
actual live-root constructor stacks and the exact balance. Its 256 execution
processes return without surviving or unknown identities. The earlier E1281
case closes all 239 execution identities. Physical closure is not DATA ACK.
Canonical receipts in both retained failure stores identify
`input_attachment.capacity`; the successful earlier parent Program receipt
does not make the later Run successful.

The E1275 and E1279 filesystem observers had incorrectly watched the task
directory rather than its mapped temporary parent. Their empty captures do
not establish that no Store existed. `core-store-observer1281-smoke` verifies
the corrected observer against a real committed SQLite row after the original
path is unlinked. E1281 and E1283 each retain six actual original DB/WAL/SHM
inodes with zero links. Only separate copied analysis images are queried.
Both E1283 analysis databases pass `quick_check`; connections close and all
six raw hashes remain unchanged. Retention is failure provenance, not a new
Store authority or a DATA return witness.

The numeric observer is removed back to the exact E1281 DATA API source.
E1285 tries funding the actual input attachment from that one-request supplier
while retaining its complete original 64 MiB invoice, real child header and
existing attachment ACK/cleanup conditions. Build passes, but its actual
`a18c5a3ece42dfcad787ce22863b92f1026f398d885b1dd426de40875155bdc3`
consumer fails earlier at `fixture.input_copy_capacity`, before the previously
successful first Program milestone. All 248 observed execution processes
close without unknown identities. The same-bank working high-water would
remain with the longer-lived checkpoint; it is not a shorter DATA lifetime.
The input-funding change and its helper rename are fully withdrawn to E1281.
The original independent 64 MiB attachment owner remains. No old metadata/
output-ACK or early-release scheme is reapplied and no Core pass is claimed.

E1289 maps the twelve largest actual live invoices from the existing E1283
capture to their own original constructor stacks, without another consumer
execution. Two approximately 1 MiB holders come from canonical-configuration
loading. The selected configuration stores strings, not its temporary parser
DOM. E1290 is a private one-file experiment separating the unchanged full
parser/FD invoice from a distinct prepaid retained string-data child, using
the existing 16 KiB plus eight-times-text metadata tariff. The whole original
load/publication frames must return before unused parser data can close;
unknown or published consumers stay paid. No amount, ordinary root floor,
high-water, Source/current-file comparison or actual consumer ACK is waived.
Its three naturally enumerated public DATA ownership regressions pass on
`bbe3cd53b7847d6693642ec26c5046b8f54df2d4f99733e715b75e7991afb7c3`.
They cover independent Registry shares, Catalog-blocked early return and
independent public text exports. The original runner then fails its stale
ten-case aggregate assertion. The retained finalizer verifies the original
three receipts, 279-case inventory, source hashes and physical closure without
rerunning or adding case credit. This is three selected passes, not full Host
or Core acceptance.

The original complete Core consumer builds as
`18851cce2bf5fc4c186f04eb61c862361d9bf27a473a59f28f61b3bec6d0f409`.
It advances through the new-Thread Program rerun, then fails the original
same-Thread new-Run assertion with `input_attachment.capacity`. All 261
observed execution processes close without unknown identities. E1294 queries
only separate analysis copies of its retained canonical databases and the
earlier withdrawn E1285 input experiment. All four copied databases pass
`quick_check`, every connection closes, and all twelve original DB/WAL/SHM
hashes remain unchanged. E1290's latest Run and joined Operation/Receipt fail
with the actual attachment-capacity error. Earlier completed Runs do not
authorize DATA refunds or establish complete Core success.

## Actual Native optimization and clean runtime artifact controls

E1278 builds and packages the unchanged standalone ModelProvider with the
fixed official SDK. Its raw and final ELF bytes exactly match the current
Coding package. Actual verbose compiler commands show that only `yjson`
has explicit `-O2`; the other ten compilation modules, including the entry,
have no explicit optimization option. Workspace flags alone are not proof
of standalone dependency flags.

E1280 adds only the standalone dependency override and rebuilds the same
actual producer. The last explicit optimization flag on each of the eleven
actual compiler commands is `-O2`.
E1282 runs its unchanged 51-case real executable codec/protocol suite:
51 pass, zero failures, errors or skips, with all process identities closed.
These are controlled host-wire-peer cases, not Product authority, SQL,
public providers or actual HTTP credential injection.

| Single actual ModelProvider artifact | E1278 control bytes | E1280 candidate bytes |
| --- | ---: | ---: |
| Raw producer ELF | 18,100,048 | 14,190,960 |
| Final packaged ELF | 18,350,825 | 14,441,785 |
| Complete package apparent bytes | 55,149,536 | 51,240,496 |

Candidate raw ELF is
`c8e3bf4e4c5e1fb8a8d2d34d5e712af61d3842113cddbb30c7c81ec7466ffa35`;
the final ELF qualified by all 51 cases is
`1b039280b58ffc16c765aa12b79ed43ec31474a6b73f4b1a951f910a22dc518b`.
No SDK library or license is removed. This is size and producer evidence,
not a performance or five-second acceptance result.

The actual 17-builder manifest inventory already has dependency-wide `-O2`
in Workflow and MCP. Fifteen, not sixteen, lacked it before this experiment.
E1284 extends that existing convention privately and also fixes actual
runtime-artifact pollution: the old Coding output contains compiler targets
with `.cjo` interfaces, while its loader report exposes the build output path.
The existing public clean-environment check gains actual artifact/privacy
assertions and fails against that real old artifact before the new assembly.
No mock packager or copied command assertion is used.

The real nine-package Coding producer now gives each builder an explicit
target under a unique mode-0700 sibling outside the runtime artifact.
Compiler evidence remains outside the artifact; no target or interface is
published as runtime payload. Loader diagnostics replace the output prefix
with `<package>` while retaining missing-library rejection. Assembly passes
in 904.86 seconds under the original 2,100-second bound. Real relocated
clean-environment and setup checks pass with their original bounds and full
process custody. The exact host ELF remains
`98e572e0a49b01de502c9cb9c61dfb06d10dd5074e6352345e06308060332c12`.
The nine Native packages total 313,775,454 apparent bytes. This is not whole
distribution size, RSS, benchmark or eight Full-only package acceptance.

The new ModelProvider raw and final bytes equal E1280, so its 51-case
executable evidence applies without a duplicate run. The other quiet build
targets contain option hashes, not recorded actual compiler command lines;
no all-dependency command proof is inferred from those opaque hashes.
`native-release1284-current-coding` retains RED, actual production targets,
before/final hashes, complete package provenance and clean/setup custody.

E1286 runs the exact unchanged two-profile local HTTP/SSE fixture against this
new artifact with no concurrent Native build or live sampler. The first
request still exceeds its original five seconds; the second profile is not
credited. All 98 observed processes close without unknown identities.
`native-release1286-provider-profiles` preserves the failure and fixture
SHA-256. Smaller packages and clean/setup passes do not satisfy startup.

These candidates are not promoted. Complete Core, the original model request
deadline, remaining non-GC application flows, matching baseline and final
release remain unaccepted. GC remains user-deferred with zero passing credit.
The task is incomplete and PR #49 remains Draft.

## Snapshot canonical work and retained graph remain separate private candidates

E1293 separates the original snapshot producer's canonical-codec work from
the retained snapshot graph. The complete original meter still prepays all
schema getters, canonical strings, path frames and construction work. A
second child then prepays the retained nodes, strings, slots and fixed
metadata before it receives the actual snapshot graph. The private producer
returns before its original holder clears that graph and closes its working
payment. The retained holder continues to own the graph, including historical
exports and unknown consumers. This is an ownership transfer, not proof that
the graph has been consumed or that an opaque Context has returned.

`toolSetSnapshotLocked159` also reads the actual definition once per entry
instead of invoking its full-schema-copying getter three times. No definition,
capability, Source, SQL, attachment invoice or consumer ACK is removed.

The meter's compiled private layout changes, so the original nine production
stages build against a genuinely empty private target. All nine pass.
App SHA-256 is
`b90a16be14c7e0e6d900762a888a1e0cfbcf5b7cd4eb3c5066577d921242ce99`;
Minimal SHA-256 is
`30b53ffa77d8c24ac0a4ca8874a51d608af041fd2a1c9cdf7898a28e4bfd83ee`.
`snapshot-data1293-nine-production-stages` retains the exact source map,
commands and process-custody records. This grants build credit only.
E1296 subsequently passes 86 naturally enumerated real SDK case executions:

| Module | Natural inventory | Executed and passed | Native ELF SHA-256 |
| --- | ---: | ---: | --- |
| Runtime | 45 | 6 | `4fe5b1524845908a71244f628c015623a5c8992080db981c2411f0ef06aa254e` |
| Tool | 75 | 75 | `fcf3bf6a2dafdd9d23783bf98a54694fd6cbdafa6a80fec9802bfa499ca26e0a` |
| Host | 279 | 5 | `cb70901442bac09a98c557207a5edbd674f8dde7191829e0c255a1f00ad51d02` |

Every naturally enumerated Tool case runs in its own original isolated
process. Runtime covers scalar, actual copied-definition saturation and
identity ownership. Host covers actual Registry/Catalog snapshot return,
historical export and all three selected canonical-configuration cases.
No full Runtime, Host or Product pass is claimed.

E1295 builds the unchanged complete Core consumer as
`60b7fde407349f1cdab3367ac81bcfbada082641c05a78affb3f54bc1b8d8c42`.
It passes the original new-Thread and same-Thread Program reruns, then fails
the original direct-control rejection assertion. All 262 execution process
identities close without unknown identities. Its actual canonical Store
contains the completed third Program's exact SDK, artifact and argument
provenance, followed by one failed Direct Run with no Operation or model
Attempt. These facts do not identify the returned Outcome or authorize DATA
refunds. Both separate analysis databases pass `quick_check`; all six raw
DB/WAL/SHM hashes stay unchanged.

E1300 retains a diagnostic-only consumer whose assertion message identifies
the unexpected outer `Ok`. Its original boolean and SQL assertions stay
unchanged. E1304 then tries a stricter typed `Denied` assertion with the same
permission code and exact call/tool identity, plus canonical zero-execution
checks. That attempt still fails at the same predicate. The test adjustment
is fully withdrawn, including the changed no-Thread SQL assertion. It is not
a test fix, a permission pass or evidence that the original assertion is
obsolete. E1307's further bounded Outcome diagnostic has no acceptance
credit. The original contract remains the required consumer.

These implementations remain private. Complete Core, remaining Product and
application flows, matching baseline and final release remain required.

## System-only leaf dependencies do not need a package search path

E1291 builds the original nine production stages for the current published
admission host plus same-width all-file balanced hashing. It retains one
caller, one worker, two 64 KiB scratch arrays and every current-byte check.
E1297 composes that host with the unchanged E1284 Native9 packages using the
actual host provenance publisher. Clean environment and setup pass, but the
first original Profile request still exceeds five seconds. This is a new
source and package workload, not a passing replay of E1180.

E1298 identifies actual unnecessary ELF layout growth:
`libboundscheck.so` requires only system `libc`, yet every ordinary packager
adds an `$ORIGIN` RUNPATH. The original library's large load alignment makes
that metadata addition expand the packaged file.

E1301 changes the copied library only: inspect its actual dependency closure,
keep `$ORIGIN` for DSOs with bundled dependencies, and remove search metadata
for system-only leaves. The original complete dependency resolver, clean
loader verification, library inventory and license checks remain. No SDK
source, DSO code, library, notice, scratch allocation or quota changes.

| Exact artifact payload | Before, bytes | Leaf-layout candidate, bytes |
| --- | ---: | ---: |
| ModelProvider `libboundscheck.so` | 2,100,601 | 71,720 |
| Complete ModelProvider package | 51,240,496 | 49,201,814 |
| All nine Coding Native packages | 313,775,454 | 295,427,316 |

The actual ModelProvider retained-target builder passes, followed by all 51
original executable protocol cases with zero failures, errors or skips.
Its source and packaged entry ELF hashes remain E1280's; the changed DSO
payload receives its own actual runtime verification.

E1302 executes the other eight Coding retained-target packagers and reuses
the byte-exact E1301 ModelProvider output. E1305 executes all eight Full-only
retained-target packagers, including unchanged MCP's existing transitive
layout. All seventeen package closures pass with the exact original raw ELF,
required library-name sets, system dependencies, engines and licenses.
Sixteen packagers receive the generic leaf fix; MCP already avoids this
growth and is unchanged. These are retained-input packaging checks, not new
Full-only source builds or proof of their new compiler flags.

The actual distribution sealer and host provenance publisher bind the smaller
Native9 composition to packaged host
`9f5f59e49ebe0e91a73e0c3e274a55fb1a2ad39eea6b8e0a69f638f77a386aad`.
Original clean-environment and setup consumers pass. E1303 then runs the
unchanged two-Profile local HTTP/SSE fixture without a competing build or
live sampler. Its first request still exceeds five seconds. The second
Profile is not credited. Reduced bytes, complete loading and codec passes do
not establish startup, matched performance or final release acceptance.

`balanced-native1297-provider-profiles`, `leaf-runtime1301-model`,
`leaf-runtime1302-coding`, `leaf-runtime1303-provider-profiles` and
`leaf-runtime1305-full-only` retain source maps, exact commands, complete
provenance and physical process custody. These candidates are not promoted.
The task remains incomplete, GC remains deferred with zero passing credit,
and PR #49 remains Draft.

## Direct rejection follows the accepted Run-snapshot contract

E1309's diagnostic-only consumer identifies the actual earlier result:
`Completed(isError=true, error=readonly_delegation.target_stale)`. The
source-defined top-level `error` field, not an inferred enum or missing
diagnostic field, supplies that code. This is not a complete Core pass.

The accepted fixed-SDK contract already permits Direct readonly roots with
an actual available Run snapshot. The historical blanket no-Direct/no-Thread
assertion conflicts with that contract. E1311 migrates only that assertion:
the unchanged unavailable-target request must return the exact typed
`Completed` error, preserve call identity and have no execution receipt.
Canonical SQL additionally requires one failed Direct Run, zero Operations
and execution Receipts, and zero model Attempts. A failed Run is a durable
control record, not execution or authorization. The successful Program's
original SDK, argument, artifact and seven-receipt checks remain unchanged.
No production permission, Source, snapshot or execution guard changes.

The complete consumer, ELF
`12578acf243ad933da5306e852463933359ed402d56e15fff6177a6d49f691da`,
passes the corrected early assertion and both earlier Program reruns, then
fails the next partial Program at `input_attachment.capacity`. The later SQL
assertions are not reached and have no runtime passing credit. E1311
retains all six original Store images; E1316 queries separate copies only.
Both copied databases pass `quick_check`, their newest canonical failure
records the attachment-capacity code, and all raw DB/WAL/SHM hashes remain
unchanged. Clean physical process custody does not retire DATA.

`direct-snapshot1311-complete-core`,
`direct-snapshot1311-store-retained` and
`direct-snapshot1311-canonical-analysis` retain the actual source, exact
consumer, process custody and canonical facts. The candidate remains private.
This migration supersedes E1307's provisional requirement to retain the old
predicate; the failed E1304 `Denied` attempt remains withdrawn, not repaired
or retroactively credited. Complete Core and every other unmet requirement
remain open.

## Publication-source packaging is qualified without private runtime experiments

E1314 moves only the sixteen generic system-only-leaf packager changes and
the clean-artifact producer/checker changes into the publication checkout.
Standalone manifests, compiler options, dependency pins and Cangjie/native
source remain unchanged. Private O2 overrides, balanced readers and Core
ownership candidates are not included.

The actual Coding producer builds all nine Native plugins from those
unchanged standalone manifests under the fixed official SDK. Compiler
targets are unique mode-0700 siblings, never runtime artifact contents.
The loader report replaces the actual package prefix with `<package>`.
The original relocated clean-environment consumer now also rejects compiler
interfaces and private home paths; its earlier real artifact RED is retained.

| Actual publication-source verification | Result |
| --- | --- |
| Complete fresh Coding9 producer | Passed, 723.10 seconds |
| Relocated clean environment | Passed |
| Setup | Passed |
| ModelProvider executable protocol | 51/51, no failures, errors or skips |
| Natural packaging Python regressions | 23/23 |
| Existing selected Python regressions | 129/129 |
| Complete original architecture gate | Passed |

The unmodified host source uses raw App
`29518401b621209883d7a203d9462218122381362d9bdcb3b56cb3e9ea2b3588`.
The actual new packaged App is
`98e572e0a49b01de502c9cb9c61dfb06d10dd5074e6352345e06308060332c12`;
the newly built ModelProvider entry is
`25d8550af0339cfd78c704020b63319bf935db0b1bee119e9317a8ecbe1e03ae`.
The sixteen publication packager inputs also byte-match the actual E1301,
E1302 and E1305 seventeen-closure consumers. This reuses their retained-raw
Full-only closure proof, not fresh Full-only source-build or optimization
evidence. Every required library, engine and license remains included.

`packaging-publication1314-current-coding` and
`packaging-publication1317-static` bind actual commands, source inputs,
artifact hashes and closed physical process custody. The packaging fix is
the only promoted candidate at this checkpoint. These results do not satisfy
the five-second model request, complete Core/Product, matched performance
or final release requirements.

There is no public API, lock format or persisted-data migration. Changed
package bytes receive their actual new provenance and ordinary content
identity. Existing installed records and operator enable/disable/scope choices
are not rewritten or implicitly upgraded. Explicit operator management must
select an updated package; rollback selects the preceding release/package
without deleting settings or Store data. Source pins and execution checks
remain required. The task is not complete and PR #49 remains Draft; GC stays
deferred with zero passing credit.

## A catalog-cut working child still fails the later capacity contract

E1313 privately separates catalog-cut codec work from its retained replacement
snapshot without changing class layout or payment floors. The original nine
production stages pass on the ABI-consistent target; private App is
`c955bd363b84e38ad51aa7a47208a66951e37faf8ad1fa658a107d65c9a945c5`.
E1315 rebuilds the complete consumer as
`d7d5abe7b806d6f7d349f54f3738059386592c4369a7bd223528e4a2eca40eda`.
It still fails partial Program attachment capacity, with no complete Core
credit. Its working child does not change the original shared-ledger
high-water rule. The six retained original Store images remain exact; both
separate final analysis copies pass `quick_check` and confirm the latest
`input_attachment.capacity` receipt. No quota, root floor, supplier, DATA
ACK, Source, SQL or production authority is weakened. This candidate remains
private; `catalog-cut1313-nine-production-stages`,
`catalog-cut1315-complete-core` and
`catalog-cut1315-canonical-analysis-final` retain the actual evidence.

## Current partial-Program refusal distinguishes retained owners from growth triggers

E1321 observes the exact E1315 functional candidate with numeric-only
bank/root/lease events and constructor stacks. Its fresh-target consumer is
`c2b1616050e68649d096443dc829f77b597a411a91f6e53ec245787afa0e526c`.
The later partial Program still fails attachment capacity. These figures
belong to that observed refusal, not the later numeric-copy fix.

| Refusal-time quantity | Bytes |
| --- | ---: |
| Actual capacity | 150,994,944 |
| Actual charged amount | 102,661,848 |
| Actual incremental request | 50,331,648 |
| Actual overshoot | 1,998,552 |
| Main Registry root high-water charge | 51,595,904 |
| Independent artifact-failure Product root charge | 17,224,792 |
| Current checkpoint slot | 16,777,216 |
| Actual input attachment before refused growth | 16,777,216 |
| All 35 live fixed buffers | 286,720 |

The four roots plus buffers exactly equal bank occupancy. The main root's
live SUM is 47,210,976 across 487 leases; the independent fault Product's is
6,917,680 across 119. These gaps are not refunds or leak proof. All retained
leases and constructor categories remain unfiltered. Seventy actual Prepared
metadata copies account for 19,841,256 bytes including their child headers.
The last main-root high-water increase instead comes from a Fixture request
copy and its active observation. Its eventual return does not retire other
consumers.

No constructor enters E1313's catalog-cut helper. That experiment is withdrawn
to the exact original method; it never established a capacity improvement.
All six original Store images remain exact, and both separate copied
databases pass `quick_check` and confirm the actual capacity Receipt.
`catalog-cut1321-diagnostic-core` retains the complete numeric stream,
exact birth attribution and all active lease categories; its timing and
diagnostic allocations have no performance or production acceptance credit.

## Numeric fixture copies pay live formatter work, not cumulative scratch

The actual Fixture clone adds 16 KiB permanently for every copied number,
although formatter/materialization work occupies a private scalar frame.
E1324's real regression fails before the fix with a fixed 16 MiB bank, a paid
15 MiB source and a bounded numeric schema. The existing genuine capacity
and partial-copy retirement control still passes. This is not an increased
product quota or a removal of saturation testing.

The fix preserves the original 16 KiB working tariff and prepays it before
formatting and materialization. It retains the original node and actual
spelling invoices, but does not add completed scalar scratch to the retained
request's running invoice. The same original ledger keeps its high-water;
no payment closes or DATA acknowledgement changes in this helper.

E1325 passes all ten naturally enumerated Fixture cases. E1328 independently
rebuilds and executes the same entire module on the publication checkout,
with only the production helper and its real regression changed. It passes
10/10, including actual saturation, overlapping callbacks, raw exports,
observation revocation and unknown-consumer retention. Its Native unittest
ELF is `eaed847a55db6c102483afbf11deac4587ce56227ed14689f4990d3169cdb903`.

E1331 compiles an independent public-API consumer against those exact Main
sources. Actual execution verifies bounded acceptance, all numeric values,
exact `1.2300e+400` spelling, source-mutation isolation, continued payment for
a live raw export, genuine larger-input refusal before events and actual
failed-copy retirement. Consumer ELF is
`24b72078aaac68d2191f66901b84ba098cfce32c2a5f5b9c0c5fdc42adb16f6b`.
Its earlier E1328 caller build failed on a missing direct JSON class import;
that failed build is preserved and receives no runtime credit.

E1334 builds all original nine production stages from the exact public
two-file correction. App is
`9882573d3b11d8c5f7f3eb5dcbbf80fbc14940bbe53f97f4cadf54a1c683b96a`;
Minimal is
`18b1b4ac1f2d7809fdfc6cf907450de505518de7a8267f2a23b5dc6d9c160a8c`.
There is no public signature, layout, dependency, SDK, authority, Source,
SQL, original bank/floor/attachment invoice or deadline change.

Complete private Core E1326 still fails the later partial Program's
`input_attachment.capacity`; separate canonical copies confirm the failure
with all six raw images unchanged. E1325's earlier Core attempt stops at a
parent-source preflight mismatch before compilation or execution; E1326
names the exact already-accepted Direct fixture delta instead of removing
the guard. Neither run establishes complete Core acceptance.

E1332 additionally measures the same remaining refusal after the numeric
fix: charged 102,268,824 bytes plus actual 50,331,648-byte growth exceeds the
unchanged 150,994,944-byte bank by 1,605,528 bytes. Exact reconciliation
accounts for all roots and fixed buffers. Its 74 first unknown-consumer
transitions are 46 child-plan `call` exports and 28 ordinary Host executor
`operationPlan` exports. These identify retained metadata paths to inspect,
not permission to release unknown DATA or infer a leak. Separate canonical
copies retain all six original image hashes.

`fixture-number1324-red-unit`, `fixture-number1328-main-unit`,
`fixture-number1331-public-caller` and
`fixture-number1334-nine-production-stages` retain exact source, commands,
artifacts and physical process custody. E1335 also passes the original 129
selected Python regressions and complete architecture gate on those two
public source changes. Its copied legacy scope string is corrected by a
separate exact-command qualification without rewriting the original result.
Only this independent numeric-copy
correction is eligible for publication; the other Core candidates remain
private. The task remains incomplete, GC remains deferred with zero pass
credit and PR #49 remains Draft. No stored-data migration is introduced;
rollback restores these two files without deleting retained facts or debts.


## Default Native transitive layout still misses the first-request gate

E1337 keeps published `fb35f5345293abf604d12d4d9ae5beabc03e02f8`
Cangjie sources and all original standalone compiler options. Its only nine
private source deltas apply the existing MCP executable-transitive-RPATH
convention to Coding packagers. Every required runtime library, system
dependency and license remains checked; the pinned Workspace engine is
byte-exact. No verification result is cached or reused.

The actual complete fresh Coding9 producer passes in 505.81 seconds, followed
by relocated clean environment, setup and all 51 ModelProvider protocol cases
with zero failures, errors or skips. Explicit compiler targets stay outside
the runtime artifact. All eight generated lock serializations are restored
to exact published bytes. The current public raw App is
`9882573d3b11d8c5f7f3eb5dcbbf80fbc14940bbe53f97f4cadf54a1c683b96a`;
this experimental packaged host is
`45817356245a9f6f947fe39ca3bca94e7313c4c2facb478520b74e1ee7c06f0a`.

The original profile test still times out on its first model request after
exactly five seconds. Its subsequent temporary-directory cleanup also fails;
the independent watcher returns and records no remaining, unreaped or
unknown-identity process. Physical cleanup is not a DATA-consumption ACK.
No GC cause, deadlock, current canonical Run count or successful first
request is inferred. This layout remains private and is not a startup fix.

`transitive-rpath1337-current-coding` retains exact commands, per-package
source/output/runtime/license provenance and the failed result. Its 292,639,424
bytes across all nine Native packages are artifact-size evidence, not a
matching performance comparison. PR #49 remains Draft and the task remains
incomplete.

## Balanced-reader combination stops before the first request in a direct GC fault

E1338 combines only the private E1337 Native layout with the retained balanced
package reader. The reader preserves full path, mode, size and content
verification, two prepaid 64 KiB buffers and the original per-entry control
charges. No compiler option, SDK component, bank, floor, timeout or verification
cache changes. All nine production stages and the complete fresh Coding9
producer pass, followed by clean environment, setup and 51/51 ModelProvider
protocol cases. The producer takes 502.71 seconds; this is not a matched
performance comparison.

The current raw App is
`b9feaa0791239abd00b6da8e20e60202776a96dfd04a023ba5f3958a02ea492e`;
the combined experimental packaged host is
`21c247606a4b4f4a72311266a44a62c7ba14d6d5e88dc561b8942c9ac5b6fa69`.
The original profile flow fails during provider-install enable with
`owner.peer_disconnected`, before its first model request. The watcher closes
all three adopted processes with no remaining or unknown-identity process.
That cleanup proves neither a DATA return nor successful activation.

E1342 reads the existing core for this exact packaged worker. The crashing
thread directly traverses `BaseObject::GetSize`,
`WCollector::ForwardObjectExclusive`, `TryForwardObject`, `ForwardObject`,
`Mutator::GCPhasePreForward`, `SlotRoot::VisitWAHGCRoots` and
`TracingCollector::VisitHeapReferencesOnStack`, under the collector's
`Preforward` / `DoGarbageCollection`. Runtime mappings bind the stack to this
artifact. This current sample is within the user-deferred GC scope, with
zero pass credit. It is not the five-second request timeout and does not
classify older incomplete failures. Hashing frames on other threads do not
establish a performance cause.

`transitive-balanced1338-current-coding` and
`transitive-balanced1342-saved-core-analysis` retain exact commands, artifacts,
the 746,196,992-byte core and the read-only function trace. Both layout and
reader candidates remain private. No identical GC-blocked replay, SDK repair
or external model call is made.

## Broad metadata borrowing is withdrawn, not counted as a capacity fix

E1340 rejects the uncompiled broad Raw-getter replacement. Ordinary catalog
resolvers, inspectors and process ports are open retention boundaries; a
callback's return cannot release the Prepared graph or waive its original
unknown-consumer debt. No build, test, source publication or passing credit
is assigned to that proposal.

The functional checkout is restored against all 58 retained E1326 source
hashes, including the original read-view output funding that one restoration
had accidentally dropped. E1341 additionally checks actual last peaks for
all 74 measured first-unknown Prepared owners: every one exceeds its existing
131,072-byte seed. The smallest is 144,272 bytes and the largest 513,424 bytes.
There is no seed-only excess to refund; lowering or splitting the seed would
not remove these measured debts.

`metadata1340-withdrawal` retains the exact restoration and numeric-only
analysis. No strong owner references are retained in the diagnostic output.
The independent numeric fix remains published, all other Core candidates
remain private, the task remains incomplete and PR #49 remains Draft.

## Independent text copies reach the next unchanged Core budget boundary

E1344 tests a narrower private alternative to the withdrawn borrowing
proposal. The original Prepared call, plan and JSON stay private on the
internal read-view path. Strings handed to open inspectors, process ports
and result consumers are independently copied and prepaid in the same
original shared-bank lineage. Each text owner uses the existing 8 KiB
control granularity, 1 KiB occurrence charge and conservative UTF8
construction charge; the original whole-Prepared 128 KiB prepay is unchanged.
Copied unknown DATA remains paid after the original producer and its actual
consumers return. No callback, process exit or cleanup ACK refunds it.

All 77 naturally enumerated Native Tool cases pass, including two new
regressions: the original Prepared becomes inaccessible while independent
exported strings remain usable and paid; a genuinely saturated bank refuses
a new text copy and the unpublished actual child lease retires without
refunding any other owner. Existing Raw-export, private-move, consumer,
Source and saturation controls remain passing. The Tool test ELF is
`ed35e601232d12fa9297d6b372fb698498f9d245e31c3f6ca2a0f198694be18c`.

The fresh complete Core/recovery consumer builds in 610.24 seconds and runs
for 80.66 seconds. It passes the previously failing partial Program attachment
and one-slot handoff assertions, then fails the unchanged
`parent maxToolCalls blocks the child scheduler reservation` assertion.
The actual consumer ELF is
`c2cb6efafac74bad0effbc3b8dc895a9a51d79e87f2a0b8524dda1aaa2bad681`.
Separate read-only canonical analysis shows the one-call Run has exactly
one root operation, one failed root receipt containing
`budget.tool_calls_exceeded`, and zero durable child admissions, but its
public Run incorrectly completes. The scheduler did refuse; the next
defect is loss of its typed control failure across the Native business-result
boundary. The assertion, limit, Source and SQL requirements are not relaxed.

E1345 naturally enumerates and executes all 279 Host cases. Exactly one
errors because its required actual Native fixture environment variable was
omitted; 278 pass. This is an incomplete harness invocation, not GC or a
passing Host module. A subsequent run must provide the original hash-bound
fixture rather than skip the case or lower its assertions.

`external-text1344-tool-unit`, `external-text1344-complete-core`,
`external-text1344-store-retained`, `external-text1344-canonical-analysis`
and `external-text1345-host-unit` retain exact source, commands, failed/public
outcomes and original Store image identities. Only separate copies are
opened by SQLite; all original observation FDs close. No complete Core,
Host, Product, application, startup, matching-baseline or final-release
credit follows. All these runtime candidates remain private; the task is
incomplete and PR #49 remains Draft.

## Typed Native scheduler failure reaches a later, separately measured refusal

E1346 preserves the actual shared scheduler's pre-action
`budget.tool_calls_exceeded` error in the existing paid broker control-error
field. Native business JSON cannot set that fact. The actual Native helper,
existing descendant/document fences and current input/attachment checks run
before the original typed error returns. No cancellation, parallel ledger,
quota increase or assertion change is introduced.

The unchanged complete Core consumer now passes its parent tool-call budget
assertion. Separate read-only canonical copies show a failed Run, one failed
root receipt with the original `budget_exceeded` kind and all three original
dimension/limit/observed fields, and zero child admissions. The limit is
still one and the refused observed count two. Its current ELF is
`8944d88ad4fa98f45695b732deb9b7fe1e50c57069bd31d1d0af0420790b077e`.
The same full run later fails `input_attachment.capacity` in the first
forbidden-write Program scenario. This does not establish a permission
bypass or acceptance of that scenario.

E1347 supplies the original hash-bound Native fixture and passes all 279
naturally enumerated Host cases, with no skips. Its ELF is
`231684e4670674dff179fe37290c3571c4976b2643edce7996c6881650c3c523`.
This qualifies E1346 Host source, not subsequent private candidates.

E1349 uses a fresh diagnostic ABI on the same functional source. The actual
later refusal has charged 101,172,680 bytes, this request's 50,331,648-byte
growth and the unchanged 150,994,944-byte bank: overshoot 509,384 bytes.
All holders reconcile at that exact refusal:

| Holder | Charged bytes | Live shared SUM | Active shared leases |
| --- | ---: | ---: | ---: |
| Root 1 | 50,147,704 | 47,929,208 | 553 |
| Root 220 | 17,126,480 | 6,701,336 | 121 |
| Root 261 | 16,777,216 | Not shared | Not shared |
| Requesting root 262 | 16,777,216 | Not shared | Not shared |
| All 42 fixed buffers | 344,064 | Not shared | Not shared |

The high-water/live-SUM gaps authorize no refunds. Floor, attachment invoice,
tariffs and actual DATA-return rules remain unchanged. The original numeric
probe writes a hardcoded append-only sink; its complete raw stream contains
the older E1332 epoch and the current epoch. The current 767,954-row epoch is
selected without threshold filtering and bound by its final actual reservation
to the current function trace. The initially attempted stdout parse is
recorded as a wrong-input error, not another Core run or missing refusal.

`external-text1346-complete-core`, `external-text1347-host-unit` and
`external-text1349-diagnostic-core` retain exact source, artifacts, original
Store identities, numeric extraction and full reconciliation. Original Store
FDs are closed; only separate copies are opened by SQLite. Complete Core,
the forbidden-operation matrix, later recovery and final release remain
unaccepted. All these runtime changes remain private.

## Project-only Native optimization still misses the original request deadline

E1350 keeps the same public `fb35f5345293abf604d12d4d9ae5beabc03e02f8`
source and immutable default-compiled App as E1337. Eight actual standalone
Coding projects add dependency-wide `-O2`. Workflow keeps its existing
`-O2` manifest; its independent producer ELF is not the App ELF. All 57
verbose compiler invocations across 22 distinct entry/dependency modules
carry the option. These are repository or pinned application dependencies,
not builds of the official Cangjie compiler/runtime/std/stdx/SDK.
The installed fixed SDK remains read-only.

The original complete fresh Coding9 producer passes in 1,007.10 seconds,
followed by relocated clean environment, setup and 51/51 ModelProvider
protocol cases. Runtime, system, engine, license and source/post-link
provenance checks are unchanged. The packaged host remains byte-identical to
E1337, `45817356245a9f6f947fe39ca3bca94e7313c4c2facb478520b74e1ee7c06f0a`.
The eight optimized entries are new artifacts; total Native package bytes
are 271,375,536. Artifact size and producer time are not matched performance
acceptance.

The first actual local profile model request still times out at the original
five seconds. Its subsequent temporary-directory cleanup also errors.
Neither a GC cause nor deadlock is inferred from this output. No external
model call, deadline increase, integrity cache or performance waiver is used.
`startup-o2-1350-current-coding` retains the actual dependency-wide commands
and failed request. The compiler-option/layout combination remains private
and is not a startup fix. The task remains incomplete and PR #49 stays Draft.

## Private read-view retirement does not resolve Core capacity

E1351/E1352 fail compilation because the new private helper lacks the existing
serializer import. Neither attempt runs a consumer. E1353 adds that import
and builds a fresh complete Core ELF,
`a90adcae390be4f4856aceb0d7025e72080733db317270acac0a64d97856a83e`.
The unchanged Core contract still stops at the first forbidden-write Program
scenario. Separate canonical copies show `input_attachment.capacity`, not a
successful permission-denial result.

The same source passes all 281 naturally enumerated Host cases in E1354,
including two private callback-lifetime cases. Its Host ELF is
`07113f21b8b0bd8cf5c97ba350d6f00ba6d26b920d2a4ce0b80e9c0e76474d68`.
These cases do not establish complete Core or application acceptance.
The private read-view route is withdrawn. Its three existing Host files
return to the measured E1346 source, and its two new files are removed.
Exact sources and both outcomes remain in `private-readview1353-source-retained`,
`private-readview1353-complete-core` and `private-readview1354-host-unit`.

The E1349 numeric trace identifies the last Root 1 high-water growth with
lease 17188. Its recorded birth stack reaches
`PluginRegistryPackageInspectionMemory1248.openWork1248` from current-byte
package inspection before Native worker startup. That temporary lease reaches
4,224,792 bytes and then closes. Its return does not lower the Root's bank
high-water charge or authorize a refund.

## Per-allocation manifest funding remains an unaccepted private candidate

E1356 retains the original 1 MiB manifest bound and growing byte-list reader.
It prepays the original fourfold byte-list envelope before each growth or
oversize-sentinel allocation, plus two 64 KiB buffers and 8 KiB control.
Actual invocation-funded work keeps its existing 4 MiB floor. The original
144 MiB bank, 16 MiB message floor, 64 MiB attachment work, full package
verification and private read-return witness are unchanged.

The fresh complete Core build succeeds in 586.52 seconds. Its ELF is
`c0a65b6c47280a81612ea8718f80dab20dd7e78a365963554314ecbf54c7e022`.
The unchanged consumer stops earlier, at matched Program sample three after
a child returns an error. The parent assertion does not expose that child's
underlying error, so neither capacity nor GC is assigned from this output.
The first passive Store recorder watches the wrong parent and captures no
images. Its empty projection supplies no canonical evidence. E1360 corrects
only that diagnostic directory and observes the same ELF. This diagnostic
does not reproduce the earlier sample-three failure and grants no acceptance.

E1357 runs every naturally enumerated Extension and Registry case with the
original isolated bounds. E1359 corrects the actual missing
`AXYNDRA_REPO_ROOT` prerequisite for three pipe-fixture cases, using the same
Extension ELF and unchanged source without rebuilding.

| Module | Natural cases | Individually passing cases | Unresolved outcome |
| --- | ---: | ---: | --- |
| Extension | 104 | 104 across E1357/E1359 | No second complete-module execution |
| Registry | 40 | 39 | One unclassified `CheckAndPush` SIGSEGV |

The four manifest-reader cases, including actual allocation refusal without
publication or false ACK, pass. The real whole-package pressure and
same-length byte-mutation case also passes. Extension ELF:
`9431daf23710d9eb80f04c5b25cc936b67957fce4dc3855a6695eb8c236e2c76`.
Registry ELF:
`183916b97104744afa7b3d354f364bffcd6bd3d761f3c2405672a667dc330dd1`.
No usable core is found for the exact Registry crash. Its incomplete runtime
boundary stack does not establish a user-deferred GC failure.

`reader-growth1356-complete-core`, `reader-growth1357-extension-registry-unit`
and `reader-growth1359-service-fixture-recheck` retain the exact scope and
outcomes. The reader change remains private and does not resolve Core.
The task remains incomplete, user-deferred GC has zero pass credit, and
PR #49 stays Draft.

## Corrected canonical observation reaches a later forbidden-shell refusal

E1360 runs the unchanged E1356 ELF only to obtain previously missing
canonical child provenance. The corrected watcher uses the actual mapped
temporary-directory parent. It retains six original Store files read-only,
closes every observer FD, and opens only separate analysis copies.
The copied database passes `quick_check`; raw images remain unchanged.

This execution passes all three matched Program samples and the intervening
plan scenarios. Its actual forbidden-write root has one failed business
receipt and zero derived admissions. The following forbidden-shell root has
`budget_exceeded` / `input_attachment.capacity` and zero derived admissions.
The unchanged whole Core contract still fails. This is not evidence of a
shell execution, a permission bypass or the cause of the earlier
same-ELF sample-three failure.

`reader-growth1360-canonical-observation` and
`reader-growth1360-canonical-analysis` retain the exact current sequence.
The older E1349 refusal's numerical balance is not assigned to this run.
Further attribution of that older trace binds its second shared Root 220
to the artifact-store-failure Product's actual Registry construction, and
Root 261 to `ApplicationSession.reserveOwnedCheckpointSlot113`. Neither
Product close nor checkpoint completion proves their DATA has returned.
Every E1349 first-unknown Prepared export is retained: 30 Legacy and 28
`validateChildPlan` origins on Root 1, and one Legacy and two
`validateChildPlan` origins on Root 220. These are first exports, not
last-consumer or refund witnesses.

E1362 composes actual reader-growth prepayment with the narrow private
Native plain read-view route. The revised route independently pays both
the call ID and complete encoded input before opaque handoff. Its complete
private loan frames unwind before field clearing on exceptional exits too.
All other Raw paths, frozen-plan and current capability checks, actual
worker fences, attachment invoices and DATA acknowledgements remain.
This composition is private and unverified at this checkpoint. Whole Core,
application, startup, matched-baseline and final release remain open;
PR #49 stays Draft.



## Current read-view composition still fails complete Core

E1362 now has actual execution evidence; the preceding checkpoint's
“unverified” describes its state before this execution. Its fresh build
takes 731.62 seconds and the original complete Core run takes 79.77 seconds.
All three matched samples, intervening plan cases, exact one-call scheduler
rejection and forbidden-write scenario proceed. The following forbidden-shell
scenario fails `input_attachment.capacity`, before any derived admission.
The actual canonical root is operation 100; root 99 has the denied-write
business failure, not an attachment or permission bypass.

Core ELF:
`ecf3ae87d295307c867da6c803366c01c0cb811e1dd5d3e62c9a8df5a3eaf670`.
E1363 passes all 281 naturally enumerated Host cases on that source; Host ELF:
`292e321158e323604b9e88c5958962ab5d551da40d8794d067b970a9fe7e46b6`.
Six original Store files are retained read-only. Every observer FD closes;
separate analysis copies pass `quick_check`. Canonical plan decoding is
checked by exact re-encoding, not by interpreting arbitrary JSON text.

`reader-frame1362-complete-core`, `reader-frame1362-store-retained`,
`reader-frame1362-canonical-analysis` and `reader-frame1363-host-unit`
retain these distinct execution and component results. No complete Core
credit follows from the Host pass.

## Current refusal accounting identifies an aliased derived-call boundary

E1367 rebuilds the exact E1362 behavior with three private numeric-only
overlays: the existing reservation observer, first-unknown metadata origins
and catalog first-held origins. Every other protected source matches E1362;
removing the metadata observations leaves the same functional tokens.
The trace uses a fresh unique sink and retains every event without filtering
small growth. Neither logs nor closures retain owner or child references.

The actual first refusal reconciles exactly:

| Current E1367 quantity | Bytes |
| --- | ---: |
| Charged at refusal | 102,044,284 |
| This request's actual incremental growth | 50,331,648 |
| Unchanged shared-bank capacity | 150,994,944 |
| Overshoot | 1,380,988 |

The charge is the sum of these current holders:

| Holder | Charged bytes | Live SUM bytes | Live leases |
| --- | ---: | ---: | ---: |
| Main shared Root 1 | 51,352,112 | 48,461,520 | 565 |
| Artifact-failure Product Root 220 | 16,785,484 | 6,705,760 | 121 |
| Actual checkpoint-slot Root 265 | 16,777,216 | — | — |
| Attachment requester Root 266 | 16,777,216 | — | — |
| 43 fixed buffers | 352,256 | — | — |

This identifies custody and the actual refusal, not a leak, DATA return,
or permission to refund the difference between SUM and high-water.
The active checkpoint slot and attachment work remain real live invoices.
E1349's older figures are not applied to this execution.

Every current first-unknown metadata origin is retained: Root 1 has ten
`executeServiceChildFrame159`, 21 Legacy and 28 `validateChildPlan` origins;
Root 220 has one Legacy and two `validateChildPlan` origins. The ten private
read-view Parents first export through
`prepareDerived → pipelineCall204 → Prepared.call`.
These are first exports, not last-consumer witnesses.

Changing that getter alone would be unsafe. The actual
`readViewChildArguments` constructs a new outer object but reuses the frozen
Parent's host fields and intent. A normalizer, validator or policy callback
that retains the child call can therefore retain the Parent's JSON subtree.
The copied call must be independently paid before any such open callback;
a nominal loan or copied call wrapper is not isolation.

Diagnostic Core ELF:
`19047753ba7709adf2b349c681f8938605348c1612e4ecc9dd77f1ccfcfd8d86`.
`current-debt1367-diagnostic-core`, its complete `events.txt`,
`remaining-exports.json`, `current-debt1367-store-retained` and
`current-debt1367-canonical-analysis` preserve the source-bound trace and
separate canonical outcomes. Complete Core still fails forbidden-shell
attachment capacity; the diagnostic execution is not acceptance.

## Independent complete derived inputs pass Tool contracts but not Core

E1374 adds a same-bank, data-only complete copy of the derived `ToolCall`
and the actual Parent call ID. The original 8 KiB control and 16 KiB scalar
copy work are prepaid before graph copying. The existing occurrence meter,
tariffs, cycle checks and exact numeric spelling remain in use. Copies
exposed to open callbacks stay paid as unknown DATA; callback return,
canonical completion and physical worker exit do not acknowledge them.

Only a still-private detached Parent uses this route. Already Raw/unknown
or ownerless Parents retain the original conservative path. Both
`prepareDerived` APIs still call the same `prepareResolved` and preserve
Source/context checks, frozen-plan matching, current capability ceilings,
canonical OperationRuntime and SQL rules. There is no caller-supplied
authority, alternate executor or generic opaque-Context refund.

E1375 passes all 79 naturally enumerated Tool cases. Its two added behavior
regressions verify mutation isolation from the actual frozen Parent,
retained copied JSON and exact numbers after the Parent's actual DATA
return, and genuine saturation with no publication or retained unaccepted
lease. Existing Raw, Source, approval, replay and actual custody controls
also pass. Tool ELF:
`fe76a03cd28dd6a6aeacda9a2a2e66c636d6fc1878d1beb53700758c18ad1b2e`.

The actual complete Core still fails the subsequent forbidden-shell
attachment boundary after all matched samples and preceding plan scenarios.
Fresh build: 580.88 seconds; original run: 81.45 seconds. Core ELF:
`0ff1409f62e562c677f804e08f867fc8d3353d7fdda1926c7c3013c5595ace23`.
All six original Store files are retained; separate copies pass
`quick_check`. The actual failed operation remains root 100 with
`input_attachment.capacity` and zero derived admissions.
E1367's numerical balance is not assigned to this new execution.

`owned-derived1374-core-source.json`, `owned-derived1374-complete-core`,
`owned-derived1374-store-retained`,
`owned-derived1374-canonical-analysis` and `owned-derived1375-tool-unit`
bind this private composition and its limits. E1379's current numeric-only
attribution and E1382's post-change Host run are pending at this checkpoint.
None of these private runtime candidates has been promoted to the PR.

## Actual yjson AST attribution does not yet fix first CLI execution

E1364/E1365 isolate the fixed SDK's actual SHA-256 implementation without
an Axyndra dependency, wrapper, runtime or setup requirement. A standalone
64 MiB/64 KiB-buffer caller produces the exact reference digest in each of
three executions. Reported Cangjie hashing times are 139, 129 and 132 ms;
the three reference Python process times are 128, 131 and 131 ms.
Initial missing-library launch failures are preserved separately; no
algorithm ran in those failed launches. This is a narrow causal probe,
not a matched 20-sample product benchmark or a replacement hash implementation.

Actual archive-symbol inspection attributes all three AST initializer
references to the pinned yjson archive. Axyndra's domain, logical payload,
process and yjson-support producer archives have none. Real standalone
Derive and separate static-library consumer probes do not acquire AST
dependencies. The pinned yjson `src/lib_json_bind.cj` instead has an unused
`import std.ast.*`; its remaining code uses no AST symbol.

E1371 changes only that line in a task-private copy of all 43 pinned
yjson Cangjie sources. A nested namespace binding supplies this explicitly
modified dependency; the original cache's 43 source hashes remain unchanged.
No Axyndra source changes, official SDK changes, library omission or skipped
integrity checks are involved. This is not an unchanged-pin release.

E1373 combines the same private dependency with the existing eight Native
manifests' dependency-wide `-O2` and verbose producer commands. Workflow
already has its original `-O2`; all nine public packagers remain unchanged.
Both experiments use the same previously qualified immutable App input.

| Actual private experiment | Native package bytes | Coding9 producer | Clean/setup | ModelProvider | Original first CLI call |
| --- | ---: | --- | --- | --- | --- |
| E1371, no unused AST import | 231,689,691 | Pass, 505.47 s | Pass | 51/51 | Five-second timeout |
| E1373, same dependency plus O2 | 210,489,067 | Pass, 1,082.04 s | Pass | 51/51 | Five-second timeout |

Each actual Native ELF loses its AST `DT_NEEDED` entry and the package
closure no longer requires the AST library; the library is not merely
removed from the package. Original runtime, engine, license, clean-path
and post-link identity checks still run. Audited generated E1371 lock
churn is restored exactly to the original pins. The modified dependency
and O2 candidates remain private and are not an accepted startup fix.

`sha-probe1364/corrected-summary.json`, `derive-link1366`,
`derive-static1369`, `startup-no-ast1371-source.json`,
`startup-no-ast1371-current-coding`, `startup-no-ast-o2-1373-source.json`
and `startup-no-ast-o2-1373-current-coding` retain the distinct proof scopes.

## First CLI timeout is not proof that no HTTP request was attempted

The original profile gate applies its five-second timeout to the complete
CLI subprocess, not just HTTP. Its uncaught `TimeoutExpired` traceback
does not print captured child stdout/stderr. Earlier timeouts alone
therefore do not locate initialization, request execution or shutdown.

E1378 adds observation only around the unchanged original fixture:
actual SSE-handler entry/return timestamps, original `invoke` entry/unwind
and captured partial output if `TimeoutExpired` occurs. Original request
authentication/model assertions, response bytes, configuration, commands
and five-second bound remain unchanged. All retained E1373 App, Native,
dependency and fixture-source identities are guarded.

This execution takes a different failure path: the first original `invoke`
unwinds after 4.923 seconds with `approval required`; neither actual HTTP
handler is entered, and profile two is not attempted. The original
nonzero-exit assertion fails. This is not a successful first call,
startup-budget acceptance, or evidence that approval should be bypassed.
The earlier timeout executions are not retrospectively reclassified.

The physical watcher observes and reaps the actual descendant processes;
no owned or unreaped process remains. That physical result is not a DATA
ACK. The existing Core-only Store watcher captures zero files because the
real CLI uses `sessions`, not the fixture's `state` directory. No canonical
Store claim follows from that empty capture.

E1381 smoke-proves a narrow sessions-directory adapter using a separate
throwaway real SQLite WAL fixture: all three original inodes survive
normal unlink, no observer error occurs, and every FD closes. The actual
CLI's pending plan/approval and the canonical reason for its decision
still require observation; the smoke fixture is not that evidence.
`startup-observation1378` and `startup-observer1381-selfcheck` retain these
different scopes.

The public checkpoint remains documentation-only `414b4f8`, with behavior
source `fb35f53`. E1376 preserves the complete existing PR body and reads
back the exact current head, Open state and Draft flag after a body-only
update. Non-GC Core, the first complete model call, remaining non-GC
Product/application flows, matched baseline and final release remain
unaccepted. User-deferred GC has zero pass credit; PR #49 stays Draft.

## Current owner attribution and withdrawn canonical-call prototypes

E1382 runs the natural 281-test Host inventory against the E1374
independently paid derived-input source: all 281 pass. The actual Host ELF
is `56ce30a046ff2e2d1190a17d1b86f1a1c14dbb90d320ab015393eb8a8b33e5cd`.
This supplements E1375's Tool79 result, not the failed complete Core.
`owned-derived1382-host-unit` retains the exact inventory and process
custody results.

E1379 observes the same E1374 functional candidate with numeric-only
bank/root/lease and first-export hooks. Every original event is retained
without threshold filtering. At its actual first refusal:

| Quantity | Actual bytes |
| --- | ---: |
| Original bank capacity | 150,994,944 |
| Charged immediately before refusal | 101,205,084 |
| This request's incremental growth | 50,331,648 |
| Overshoot | 541,788 |

The shared-ledger sum, fixed buffers and total bank balance reconcile at
that event. Root 1 accounts for 50,512,920 bytes. These are E1379's actual
values, not a reuse of an earlier request's cost or proof of a leak.

All 100 actual canonical plans round-trip exactly. The 33 workspace read
or grep plans use `read-view-intents/v2`; the 21 Program plans use
`readonly-delegation/v1` and retain their original input-attachment path.
The new narrow plain Native read-view path cannot be generalized to
Program attachments on that evidence.

There are 52 first-unknown metadata exports: root 1 has 21 Legacy executor
and 28 child-plan validation sites; root 220 has one Legacy and two
child-plan validation sites. The ten earlier `prepareDerived` Parent
exports are absent, but first-export location is not last-consumer or
retirement proof. Six original Store images are retained, every observer
FD closes, and separate analysis copies pass SQLite `quick_check`.
`current-debt1379-diagnostic-core`, its unfiltered `events.txt`, and its
canonical-analysis evidence preserve this failed execution.

E1386 then independently prepays a canonical resolver-call copy before
the original open resolver callbacks. Tool80 passes in E1387 and Host281
passes in E1388. Complete Core nevertheless fails **earlier**, at partial
Program admission with `input_attachment.capacity`; receipt 88 records
the failure after the second Program rerun's completed receipt 87.
The Core ELF is
`c416ae5540e78112ada3f118d971b9677586c48af180a332499a83028ba73b78`.
No passing aggregate Core result or production acceptance follows.

E1392 additionally keeps the ordinary resolved descriptor inside a closed
predicate, preserving the original capability, effect and approval
resolver calls and implementation/schema checks. Its complete Core
again fails at the same earlier partial Program boundary. Its ELF is
`d4f5e09eff546f2219d55bf398585505fc92c7aa1a14d51f779e9696bdb93a0a`.
Six actual Store images survive closure, separate analysis copies pass
`quick_check`, and receipt 88 again records the capacity failure.

The E1393 natural 82-test Tool execution has 81 individual passes and one
invalid control-test assertion, **not** a passing Tool suite. That
assertion incorrectly equates Raw Catalog backing retention with an
independent Core DATA loan's `held` state. The actual code sets
`rawAliases159` on the Catalog; it does not set the Core loan's `held`
flag. A successful loan return therefore neither contradicts Catalog
retention nor proves the Catalog's DATA was returned.

E1398 withdraws these unpromoted E1386/E1392 prototypes and their obsolete
tests, including the incorrect control. The assertion is not repinned and
production code is not changed to satisfy it. The earlier causal claim
that `resolvedDescriptor` directly holds the whole Core producer is
withdrawn. Every protected functional source hash is restored exactly to
E1374, reusing only that source's existing qualification; a newer cached
Core ELF is explicitly stale, not restored-source evidence.
`canonical-child1386-complete-core`,
`closed-descriptor1392-complete-core`, their retained Store evidence,
`closed-descriptor1393-tool-unit/withdrawal-and-invalid-test.json`, and
the preserved source snapshots retain the failed attempts and correction.
No private candidate is promoted and no current numerical charge is
inferred from E1379 after these later attempts.

## Actual default Skills preparation is a separate approval boundary

E1385 corrects the first-pathname-only CLI capture limitation by retaining
every distinct observed SQLite inode read-only until actual process
closure. A throwaway two-generation WAL fixture verifies both lifetimes
separately. In the real CLI, eleven inodes are retained: one main DB,
five WALs and five SHMs. No main-DB replacement is inferred from repeated
WAL creation, and unrelated WAL generations are not combined.

A separate main-only analysis copy passes `quick_check`; its operation
ID exactly matches the real CLI's printed pending operation, and its
normalized plan round-trips exactly. The plan is `host.context.read`,
requires approval for two `outside-workspace.read` absence witnesses
under the settings root, and also includes the workspace Skills absence
witness. Actual model attempts, approval decisions and HTTP-handler
entries are all zero. On CLI exit the actual pending preparation read is
cancelled with `operation.cancelled_before_execution`.

The first original invocation exits with `approval required` after about
4.801 seconds; profile two is not attempted. The existing Provider
transport/credential grants and the read-scope allowlist do not authorize
this separate preparation read. This is not successful Provider execution
and does not justify skipping approval or removing default Skills.
The earlier first-pathname image set's empty Run query is not evidence of
no admission; E1385's exact operation match supersedes that ambiguous
analysis. `startup-observation1385`, its retained original inodes, and
its separate canonical-analysis evidence preserve the actual boundary.

E1390 attempts a distinct focused profile fixture using the supported
workspace-only context recipe while leaving service grants and read
scopes byte-identical. It fails during the original operator
`plugins enable` command, **before** the context rewrite, original
five-second `invoke`, or either local HTTP request. No focused profile
success or default Coding acceptance is claimed.

The existing core from that exact failed process supplies direct
`BaseObject::GetSize → WCollector::MarkObject →
ConcurrentMarkingWork::Execute → GCPoolThread::WorkerFunc` evidence.
Only this E1390 sample joins the user-deferred GC set, with zero pass
credit. Older timeouts and peer disconnects are not retrospectively
classified. The retained compressed core is 8,461,039 bytes; its SHA-256
is `9030e858fcd7dd038ec33e9681c040b31b619889b0f227f0f5f049802f3c41e1`.
`provider-profiles-workspace1390` preserves the process, artifact-bound GC
classification and private failure evidence; the identical failed path
is not replayed.

At E1395 the public head is documentation-only `81c608a`; public behavior
remains `fb35f53`. The existing PR body is preserved through an update and
the exact head, Open state and Draft flag are read back. The non-GC
Core gap, first complete model call, remaining Product/application
acceptance, matched baseline and final release remain unaccepted.
There is no new external model call, SDK rebuild/replacement, quota,
stack or deadline increase, manual CI, force update, Ready, merge or
Issue closure.

## Refusal-time lifecycle census separates unknown and producer debts

E1398 adds numeric lifecycle events to the exact restored E1374 functional
candidate. Metadata events contain only bank/root/lease IDs, consumer and
header counts, retained invoice and four scalar state flags. A separate
numeric relation joins each metadata payer to its actual Core producer
lease. No owner/child references are retained in diagnostic logs or
closures. Erasing the hooks preserves every functional metadata token;
the other two overlays differ only by their numeric methods/relation and
unique event sink.

The fresh actual Core ELF is
`fea54428416085e5acb68ea198152d4a96976fce670b54cb9459f30b4b3482df`.
Complete Core still fails the forbidden-shell assertion because operation
100 fails attachment capacity; operation 99 retains its original
`readonly_delegation.tool_denied` result and zero child admission.
This execution's actual refusal is **101,205,532 charged +
50,331,648 requested against 150,994,944 bytes**, 542,236 over. The
current shared sum, fixed buffers and total bank balance reconcile.
These values replace neither E1379's different observation nor a DATA ACK.

At that exact refusal, 3,855 lifecycle events describe 94 metadata owners.
Joining their last actual state to the current ledger gives:

| Root | Metadata state | Owners | Actual current bytes |
| --- | --- | ---: | ---: |
| 1 | Returned; producer returned, zero consumers | 38 | 0 |
| 220 | Returned; producer returned, zero consumers | 1 | 0 |
| 1 | Known; producer not returned, zero consumers | 3 | 1,026,456 |
| 1 | Unknown; producer not returned, zero consumers | 6 | 1,606,888 |
| 1 | Unknown; producer returned, zero consumers | 39 | 10,690,512 |
| 1 | Unknown; producer returned, one consumer each | 4 | 653,944 |
| 220 | Unknown; producer returned, zero consumers | 3 | 622,312 |

The 39 actually returned owners all have zero current ledger charge.
Unknown debts remain paid even where the producer has returned. The
three known, unreturned owners share the exact producer whose birth stack
is the original one-slot `product.client.start` scenario. That observation
does not authorize retiring them before the original task, request,
output and ACK fences actually return.

The unfiltered numeric file is 29,941,173 bytes. All six original Store
images survive normal closure; all observer FDs close and separate
analysis copies pass `quick_check`. `metadata-lifecycle1398-diagnostic-core`
and its `metadata-census.json` bind every state to the actual refusal.
The copied proof's old human-readable sink label is corrected explicitly
in `metadata-lifecycle1398-proof-text-correction.json`; the hashed source
and actual new unique sink are E1398, not reused E1379 output.

E1402 identifies two concrete missing boundaries on that direct-client
path: the budget-only fixture clone drops existing custody, and public
Core entrypoints bypass the real custody frame used by owned result
APIs. The private correction routes both API result forms through that
same actual frame and keeps owned wrappers on the private bodies to
avoid double counting or premature failure cleanup. It does not invent
custody for ownerless requests, return a caller's retained original
request, or skip any task/output/ACK fence.

The first compile attempt fails on two mistaken constructor-only member
forwards, `userRequestedThinking` and `thinkingSource`; no runtime is
executed. E1404 removes those two mistakes, keeping the original effective
thinking/model snapshot forwards and seven genuinely existing fields.
Erasing exactly those seven additions restores the byte-identical full
original fixture SHA-256
`03505319750aa97c87a2648b5d27043404f14887e089f7f87b098794afd6c1d9`.
No original scenario, assertion or limit is removed or relaxed.
This candidate is still private and **unaccepted**; compiling progress
or identifying the missing frame is not a passing complete Core run.

E1403 compiles the actual Core unittest module and naturally enumerates
54 cases. Only the ten existing request-custody cases execute, each in
its original isolated process and unchanged bound: all ten pass. They
cover actual task return, caller aliases, unsubmitted/unknown admission,
typed paid failure with genuine consumer ACK, unknown exceptions and
ambiguous funding. The actual unittest ELF is
`83a0a74c805ecf0443ae9e436c3bb5634029a370f7c8d8018c2e1bc8ecf16729`.
`actual-core-frames1403-custody-unit` retains the complete inventory and
per-case process evidence. This is not 54/54 or a passing complete
Core/recovery execution; the separate original full run remains pending.

## Genuine public Core frames advance to real cancellation recovery

E1404's corrected actual build succeeds, then the complete original Core
run **still fails**, at a new boundary rather than attachment capacity.
Its ELF is
`b065a1e83a7aa268fabd3c377408cafa5b6fed140ce4ca6ed4beee32c1769699`.
The existing forbidden-shell and subsequent static-syntax assertions
return successfully, followed by the real Native read-cancellation
contract. Main operation 100 now has the required
`readonly_delegation.tool_denied` receipt; operations 101–104 retain
their exact forbidden/static-syntax outcomes. No E1398 charge is assigned
to this uninstrumented new candidate.

Execution then fails `plugin.duplicate_namespace` in
`NativeProgramContractBinding` while constructing the separate Program
cancellation/recovery Product. That fixture uses new settings/state
directories but the original Workspace, whose Workspace-scope Native
namespaces are already installed by the earlier Product. Duplicate
import rejection is correct; the cancellation/recovery assertions have
not yet executed and receive no pass credit.

The observer now retains **twelve**, not six, original images from four
actual Store instances. The original two-DB analysis helper is explicitly
limited to its two queried stores; additional separate copies cover both
new cancellation stores. All four pass `quick_check`, all twelve original
hashes remain unchanged and every observer FD closes. The Native-read
cancellation Store contains one Run/operation; the failed Program setup
contains neither. `actual-core-frames1404-complete-core`, its retained
originals and `additional-cancellation-stores.json` preserve these
distinct scopes.

E1406 corrects only this independent fixture's Workspace isolation,
following the existing artifact-failure fixture pattern. It copies the
actual `src/alpha.cj` and `src/beta.cj` bytes into its own Workspace;
product import rules, real Native packages, permission checks, Source,
SQL, cancellation/recovery assertions, actual ACK and process cleanup
remain unchanged. The same Core code and all original limits are reused.
The combined, actually executed erasure of that setup change and the
seven budget-clone field forwards restores the exact original fixture
SHA-256 recorded above; `actual-core-frames1406-fixture-erasure.json`
states both transformations explicitly.

The separate E1403 ten-case unit result remains applicable: Core runtime
and unit sources have not changed, and the isolated Workspace setup is
outside that module. It is not rerun to manufacture more credit.
The new complete cancellation/recovery execution is pending; neither
the original-boundary improvement nor fixture setup is whole-Core,
Product, matched-baseline or release acceptance. All runtime candidates
remain private and PR #49 stays Draft.

## Cancellation recovery still requires an actual first child Receipt

E1406 builds and reaches the independent cancellation Product without the
duplicate import. The complete run still fails the original prerequisite:
`cancellation starts only after child one has a completed durable Receipt`.
The actual ELF is
`c6f884d2a5c533a34f8a30017f10555aa90fbfa4850d0f3151f8b78741c45df9`.
Its separately copied actual Store has one failed Run, one completed local
model attempt, and only the Parent Operation. The Parent receipt is
`input_attachment.capacity`; there are zero derived admissions.
Neither cancellation at the intended boundary nor recovery is accepted.
The durable-Receipt prerequisite is retained, not weakened or replaced by
logical completion.

E1409 moves the existing real main `product.close()` to immediately
after its last use, before starting independent cancellation fixtures.
It calls the unchanged production cleanup API and supplies no DATA-return
assertion. Complete Core **still fails** the same first-child prerequisite.
Its ELF is
`d7c80312057711fac6055707f4da9f258c1ee200b8cdc23af464f4565aca72fa`.
The actual post-close cancellation Store still has a failed Parent
`input_attachment.capacity` receipt and no child admission. Real Product
closure therefore does not establish that unknown DATA returned or that
the current refusal was resolved. No earlier charge is reused for it.

E1409 uses the already-validated all-inode reader with Core's actual
directory-role watcher. Its smoke fixture starts the watcher before
creating the real `case/state` hierarchy, retains both WAL lifetimes
and recovers markers 1 and 2 from separate main-only analysis copies.
The two earlier zero-capture probes used the wrong hierarchy or a
pre-existing case root; they remain zero, not evidence of no database.
The Core parent watcher intentionally does not enumerate existing cases.

The actual E1409 execution retains twelve distinct original inodes.
Each of its four observed sources has one main DB, one WAL and one SHM;
no repeated WAL generations are combined. All four separate analysis
copies pass `quick_check`, every normalized plan round-trips, all raw
hashes remain unchanged and every FD closes. The Native-read cancellation
Run is actually cancelled; the Program cancellation Run is failed before
its first child. `actual-core-frames1406-complete-core`,
`actual-core-frames1406-canonical-analysis/actual-cancellation-boundary.json`,
`actual-core-frames1409-complete-core` and its separate canonical
projections retain the actual outcomes.

Current owner/invoice attribution and an independent unmodified-public
client lifetime reproduction remain separate investigations. A private
caller invocation initially erases the fixed SDK selector and exits
before compilation; it has no runtime or failing-before credit. The
corrected invocation preserves that existing readonly SDK selector.
No private runtime candidate is promoted, and complete Core remains
unaccepted.

## Current cancellation refusal and public request-frame regression

E1411's diagnostic ELF fails earlier than the Program cancellation fixture.
The Parent Program is partial after an invalid Workspace JSON response and
`read_view.terminal_missing`. No bank-refusal event is observed.
`current-cancel1411-diagnostic-core` retains that unclassified failure.
It does not locate the later cancellation refusal or establish a GC cause.

E1417 retains every numeric event but removes diagnostic console stacks.
The rebuilt ELF is
`bee7f5f6807dcbb241d0f948c1fd215bc9d49dbccb66377c7722353843108975`.
The complete gate again reaches the original first-child durable-Receipt
prerequisite and fails attachment capacity. This is an observed new run,
not a causal claim about E1411's protocol failure.

| First actual E1417 refusal, bank 2 | Bytes |
| --- | ---: |
| Fixed capacity | 150,994,944 |
| Charged at refusal | 115,775,012 |
| Actual requested growth, root 292 | 50,331,648 |
| Overshoot | 15,111,716 |

The complete ledger reconciles exactly. Root 1 is charged 48,657,848 bytes
with 35,958,192 bytes in live shared leases. Its 41 known returned metadata
owners have zero charge. No known prepared metadata owner with zero
consumers is still waiting for its producer return. Unknown metadata remains
paid. The earlier three missing producer returns are no longer a current
explanation or an available refund.

`LogicalJsonSharedCustody` deliberately keeps its high-water charge until
all leases return. The difference between the charge and the current SUM
is not refundable capacity. The fixed bank, floor, attachment invoice,
actual ACK and unknown-copy rules remain unchanged.
`current-cancel1417-stackless-diagnostic-core` retains all 34,133,942 bytes
of events and `current-refusal-and-metadata-census.json`.

E1419 independently reproduces a narrower bug on public `10c4125` sources.
A standalone public Product caller installs and enables the actual Native
Workspace package. Its request has existing paid custody, and one local
fixture model request completes. The complete request/snapshot helper then
returns. DATA correctly remains paid before the application ACK, but stays
retained after that real ACK because public Core did not enter and return
its request frame.

The earlier missing-SDK-selector invocation never compiled. A fresh Product
without a Registry payer legitimately has no request custody; its caller's
`NoneValueException` is not this regression. An unnecessary forced-O2
caller build reaches its original 900-second limit without runtime credit.
E1419 uses normal default options and reproduces the exact request-frame
error. Those failed harness attempts remain recorded.

E1422 changes only public Core frame handling and affected tests.
The frame helper becomes generic. Public start, continuation, restricted
start, resume, context-boundary resume, and decision enter the real frame.
The owned failure APIs call their private bodies inside their existing
frame, avoiding double counting and premature collection. Typed paid
failures and unknown exceptions keep their existing obligations.
No private working-funding, Host, Registry, dependency or billing candidate
is included. The Core source SHA-256 is
`cfbc438c76d6fcf25cd31287e03396936a93ccd64473a3eddba3bb45e9ff6a47`.

The exact same caller, Native package, default compiler options, readonly
official SDK and original limits produce a passing public GREEN.
The application ACK is required before DATA returns.
RED and GREEN ELFs are respectively
`09b402308f4110d9c52d5ded5d9397f0a291f3e95da21061b7284023b7edb7e7`
and `15d28f589ede38bf1ece78efe4fecd96558fa4690ee224d6ef60872f38c0b0ff`.
`direct-client1419-default-public-red` and
`direct-client1422-default-public-green` retain both source maps, unchanged
caller and Native identities, actual logs and physical process custody.

The permanent Product regression uses the existing Native Workspace
fixture and a returned request/snapshot helper. Its original nine custody
regressions and the production build are separate pending checks.
This public consumer fix does not accept the private complete Core gate,
remaining Product/application flows, first-call budget, matched baseline
or final release. The task remains incomplete, GC remains user-deferred
with zero pass credit, and PR #49 stays Draft.

## Public custody regressions pass, Product compilation remains pending

E1423 passes all nine original public custody regressions. The SDK naturally
enumerates 53 Core cases; only the selected nine receive runtime credit.
The actual Core unittest ELF is
`d76b6986f9ecf4ff5f16296db644c9b64cbaa32f81bc48d90694873862664ba2`.
The cases retain actual task return, application ACK, accepted-consumer,
typed paid-failure and unknown-exception checks.

The following one-job Product compilation reaches its unchanged 900-second
limit. The new permanent Product test is not executed and receives zero
pass credit. The completed process receipt records cleanup of the owned
compiler tree, with no remaining processes, unreaped children or unknown
observations. This physical cleanup is not DATA-consumption evidence.
`public-request1423-custody-unit` retains the natural Core inventory,
qualified individual results and failed Product build.

The existing `prepare_workspace_dependencies` recipe explains the recovery:
a killed monolithic test build does not commit CJPM's incremental index.
Its bounded test-profile predecessors commit each successful layer.
The successful Core stage is preserved; the next Host predecessor is
prepared separately before another Product build. Original limits remain.
No Product, whole-Core or release acceptance is inferred from compilation.

E1426 passes the unchanged 129 selected Python regressions and complete
architecture gate over the four public Core/test changes and current
records. The gate checks 2,978 tracked paths, 72 Markdown files, 39 workspace
packages and 178 local dependency edges, with zero baseline boundary
violations. `public-request1426-final-static` retains the actual output.
These static checks do not resolve the failed complete Core cancellation
prerequisite or qualify the pending Product regression.

## Current public production build and exact remaining private holders

E1424 passes all nine original production stages for the four public
Core/test changes. Each stage keeps its original 900-second bound.
The App SHA-256 is
`580df41d76db2f40fda7234ff584bb4406f6063a4a4c7b2a914240a34b13e156`;
Minimal is
`2e5c7e99f156cbf4abec86f61af1cc2fa15908694b5e9dbdbc64d242f1d9ce10`.
`public-request1424-nine-production-stages` retains the full source map,
original stage commands, physical process receipts and artifacts.
This is build credit only. Current Coding packaging is a separate check.

E1428 passes the original Host unit-profile predecessor at its unchanged
900-second bound. It commits the next dependency layer after the successful
Core stage. The permanent Native Product regression remains pending its
own compilation, natural enumeration and actual filtered execution.

E1425's private diagnostic compiler prints `cjpm build success`, but the
process guard rejects a numeric `Z / 0 / -1 / -1` exit snapshot with
`PF_EXITING`. Its overall entry remains failed and Core is not executed.
No fresh invoice or process-return credit follows from the compiler message.

The [Linux v7.2.11 `do_task_stat` implementation](https://raw.githubusercontent.com/gregkh/linux/v7.2.11/fs/proc/array.c)
reads state before `lock_task_sighand`. When the later lock fails,
PPID, PGRP and SID can retain their initialized `0 / -1 / -1` values.
The private observer correction accepts only this exact exiting-zombie
shape, preserving its original signed fields. Known owned zombies remain
unreaped; existing final-observation and actual wait requirements remain.
Live, partial, unreadable and unproven identities still fail closed.

E1432 reproduces two failing identity/lifetime regressions on the original
parser. E1433 passes all 47 process-isolation tests after the narrow private
correction, including real successful-process, detached-live-child and
timeout controls. The old diagnostics fixture used a valid exiting Z state
as malformed input; it now uses a genuinely invalid live state. The unrelated
fixture-byte hash assertion is removed. `zombie-exit1432-identity-red` and
`zombie-exit1433-identity-green` retain the exact scope. The observer change
is not yet promoted and does not retroactively accept E1425.

E1434 reuses the completed Cangjie cache with unchanged Cangjie sources,
then executes under the corrected private observer. Both process receipts
have zero unknown observations. Complete Core still fails the first-child
durable-Receipt prerequisite. Its actual ELF is
`b5d54150873e575bc11da282f5a5f31a64e68c56114eb6a866cbe41bee3f68de`.
The actual refusal is 115,774,804 charged plus 50,331,648 requested against
150,994,944 capacity, an overshoot of 15,111,508 bytes. The complete bank
ledger reconciles exactly. No older refusal amount is assigned to it.

The file-only method/line origins identify the current holders:

| Actual root | Constructor or allocation owner | Current charge |
| --- | --- | ---: |
| 1 | Main Product `PluginRegistryMetadataCustody` | 48,657,656 |
| 220 | Separate artifact-store-failure Product Registry | 16,785,500 |
| 286 | Program cancellation/recovery Product Registry | 16,777,216 |
| 291 | Actual `ApplicationSession.reserveOwnedCheckpointSlot113` | 16,777,216 |
| 292 | Requesting `HostToolInputAttachmentSession` | 16,777,216 |

The 57 live unknown metadata owners first export through
`HostJavaScriptPluginToolExecutor.executeLegacyActualFrame204` (27) and
`HostJavaScriptPluginServiceBroker.validateChildPlan` (30).
These are first-export origins, not last-consumer acknowledgements.
The current artifact-failure Registry is not the Native-read cancellation
Registry. Root 291 is a real owned-checkpoint slot, not an inferred request
or duplicate attachment. Their paid high-water and unknown-copy rules stay
unchanged.

`current-cancel1434-export-origins-core` retains all 34,136,253 bytes of
numeric events and 659,624 bytes of method/line origins. Its exact
refusal-time metadata census preserves the original lease headers.
The observer retains twelve original inodes from four stores.
All four separate analysis copies pass integrity and canonical roundtrips,
all original hashes remain unchanged, and all observer FDs close.
The Program cancellation Parent has `input_attachment.capacity` and zero
derived admissions. Cancellation at its intended boundary and recovery
remain unaccepted. GC remains user-deferred with zero pass credit.

## Permanent public client contract and current Coding checks

E1429's Product-only compilation still reaches its original 900-second
limit after the successful Host predecessor. Both Product attempts remain
failed, with no Product runtime credit. Their evidence is retained in
`public-request1423-custody-unit` and
`public-request1429-native-product-regression`.

The newly added request-lifetime regression moves to
`support_tests/public_client_request_custody_contract`, initialized by the
fixed SDK's `cjpm init`. The original Product test file is restored byte
for byte. No existing Product test is removed, skipped or weakened.
The independent public-client executable is registered in both
`vnext_contract_gate.py` and `release_contracts.txt`, before the existing
compound Product contract.

E1440 builds and executes this permanent consumer against the current
Coding Native Workspace package. It installs and enables the real package,
uses the request's existing paid custody, and completes one local fixture
model call through public `client.start`. The complete request/snapshot
helper returns before the outer caller acknowledges. DATA remains paid
before that actual application ACK and returns afterward. Original Core
task/output/settlement witnesses remain required.

The actual permanent consumer ELF is
`1b38a2bc4f256d956955585a9d8ac931228f7a3e28503d81e2ba32640252564c`.
The Native Workspace ELF remains
`3ffe67aa889aaf3b8497646ce6e869c5cc8b676f615346e3269facee79d105c1`,
identical to the qualified public E1419 RED and E1422 GREEN.
`public-client1440-integration` retains source identities, actual logs and
complete physical process receipts. The production Core implementation
bytes are unchanged from the passing nine stages and current Coding build.

E1435 passes original Coding9 assembly, clean-environment, setup and all
51 local model-protocol contracts. Its Coding ELF is
`8d089676c8027aac561241b0f87100a1d5dc41957ced5bac26b7328f878e9121`.
`public-request1435-current-coding` retains the actual Native input/output
hashes, producer targets, loader checks and provenance.
No external application-model call is made. These checks do not exercise
the blocked five-second first call, complete TUI/CLI/ACP, matched baseline
or full release gate.

The narrow exiting-Z observer and its regression changes are copied to
the public checkout with exact byte equality to E1433's 47-case result.
E1441 then passes all 131 selected Python regressions and the complete
architecture gate on the integrated source. The count changes from 129
because three semantic state/lifetime cases replace one fixture-byte
hash assertion. Genuine live-child, timeout, unreadable/partial identity,
PID-reuse and actual-reaping rejection remain covered.

The permanent consumer is the new regression's integration layer.
It does not replace or accept the failed complete Product module.
The nine original Core custody cases retain their narrower E1423 credit.
Complete Core cancellation/recovery, other Product/application flows,
first-call budget, matched baseline and final release remain unaccepted.
The task is not complete. GC stays user-deferred with zero pass credit,
and PR #49 stays Draft.

## Current headless goldens and failed real-terminal initialization

E1446 passes the original `cards` and `ask` headless goldens against E1435's
current Coding ELF, bound to public head `6b7591a`.
The gate launches PIPE-based headless fixtures, not a PTY, and writes terminal
diagnostics only on failure. The private driver's initial captured-PTY label
was incorrect. Its original summary is retained; the corrected summary in
`public-client1446-current-tui` is authoritative and grants headless credit only.

E1447 runs the original public-wire `rich-responses` case through a real tmux
PTY with that same Coding ELF and its actually built Native Model package.
Public import, list and enable operations succeed. The terminal then remains
at `loading session` and does not reach `Enter send` within the original
20-second wait. No user request key is sent and the local Provider receives
zero HTTP requests. The exact ANSI output, screens, empty input log, fixture
configuration and process receipts are retained in
`public-client1447-real-pty`.

The case requires forced termination and leaves one owned process for the
strict outer watcher to clean up. Final cleanup has no remaining, unreaped
or unknown owned process, but this does not accept the forced case or supply
a DATA ACK. The other eight Model cases are not run after this shared
initialization failure. No MCP package is built or imported by this sample.
There is no direct GC evidence for this failure; its cause remains unclassified.
This Linux tmux case supplies no mouse, resize or other-platform credit.

E1450 separately copies the failed terminal case's actual persistent
main/WAL/SHM after final process cleanup. Only analysis copies are opened by
SQLite; `quick_check` passes and raw and original hashes remain unchanged.
The connection closes explicitly. The actual Store contains four metadata
rows and zero recorded Threads, Runs, Operations, Receipts, model attempts
or approval decisions. These facts do not establish that no uncommitted
work occurred or identify a GC/deadlock cause.
`public-client1450-real-pty-canonical` retains the copies and projection.

## Invocation-funded attachment candidate remains private and incomplete

E1445 adds one real Native-bank lifecycle case to the existing Host inventory:
282 cases naturally enumerate, with the original 281 unchanged. The actual
Pipeline prepares a read-only allocation fixture against its real canonical
Store. No Tool or file effect is executed. An actual invocation supplier is
present, but the original independent attachment allocation fails with
`input_attachment.capacity` under pressure that admits the full derived invoice.

The fixed SDK reports one executed ERROR, zero passes and 281 filtered cases.
The private driver initially expected `TOTAL 1` instead of the full module
total. Its original classification is retained. The corrected qualification
checks the exact error, all natural-inventory counts, source/ELF identity and
actual physical closure from the same output; the failing case is not rerun.
`scoped-attachment1445-red-unit` retains this qualified RED.

E1449's private candidate uses the existing actual invocation-funding channel,
not a long-lived Registry lease. It transfers a distinct attachment owner
with the original full 64 MiB invoice in the same 144 MiB bank. Original
16 MiB floor, SUM and high-water rules remain. Absence of an offered funding
source keeps the original allocation path; an offered source's refusal never
falls back to another payer. Attachment Source/SQL checks and actual ACK
methods are unchanged.

All five affected Host cases pass, including the two original saturation
refusals. The new case proves that closing the actual parent cannot refund
the retained work, a returned session with pending output stays paid, and its
actual allocation-fixture ACK permits return. This allocation-only proof is
not real Native process/output-consumption acceptance.
The Host ELF is
`dbf5206b8d531ec6a3eb6a3c54d834a941e9542a7a5e72e8b50c9d3d10ed856f`;
`scoped-attachment1449-green-unit` retains all five qualified results.

E1451 rebuilds the complete original Core/recovery contract from that retained
functional source, under the original compilation and execution deadlines.
Build and physical closure pass, but Core still fails the prerequisite that
child one have a completed durable Receipt. Its current ELF is
`363014e0e1737e9093a8b3e7f480091c116158709e18ff1291c4cba24cc57895`.
This is not the earlier cached or withdrawn artifact.

E1453 retains twelve original inodes from all four actual Stores, closes every
observer FD, and checks separate canonical copies without changing raw hashes.
The actual Program Parent now admits its Workspace/readview children rather
than failing the earlier attachment admission. Both children fail:
Workspace reports invalid worker JSON; nested `host.process.readview` reports
`read_view.package_changed`, `permission_denied`, `worker package is unavailable`.
The Parent has a failed Receipt and a completed Run. Completion therefore
does not establish successful Tool execution. Neither capacity nor GC is
proven as the cause of this new nested error.
`scoped-attachment1451-full-core` and
`scoped-attachment1453-canonical-analysis` retain the actual result.

The candidate and its new unit case are not promoted to the public source.
Cancellation at the intended boundary, recovery and complete Core remain
unaccepted. The real-terminal initialization failure, remaining Product and
application flows, original five-second call, matched baseline and full
release requirements remain open. No external application-model call is made.
**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Current four-MiB refusal and nine real Model terminal passes

E1454 runs the complete original Core/recovery entrypoint with the current
private attachment candidate and the established numeric-only overlays.
Its rebuilt ELF is
`d6f87118ae847373ecaab773621c55e3e7aba074b7664bd59de108d77ed8364d`.
Build and actual physical process closure pass; the complete contract still
fails its first completed-child Receipt prerequisite.

The first actual refusal is a 4,194,304-byte growth request, not the earlier
50,331,648-byte attachment growth. At that exact decision, the bank holds
149,574,292 bytes against 150,994,944 capacity; overshoot is 2,773,652.
The current account balances exactly:

| Actual holder | Refusal-time charge, bytes |
| --- | ---: |
| Main Product Registry, root 1 | 48,658,000 |
| Artifact-failure Product Registry, root 210 | 16,785,348 |
| Current cancellation/recovery Registry, root 266 | 16,777,216 |
| Actual owned-checkpoint group, root 271 | 67,263,616 |
| Four actual fixed buffers | 90,112 |
| Total charged | 149,574,292 |

The constructor stacks identify the checkpoint group directly. Its actual
live leases contain the 67,108,864-byte attachment invoice, checkpoint
134,272 bytes, a 16,384-byte control lease and the refusing zero-valued lease,
plus their four original 1,024-byte headers. The new lease requests the
original 4 MiB inspection-work invoice. Main Registry SUM is 35,958,344
while its paid high-water is 48,658,000; this difference is not a refund
or leak proof. Original SUM/high-water and actual return rules remain.

`scoped-attachment1454-numeric-core` retains all 34,679,396 event bytes and
614,348 origin bytes without growth threshold filtering.
E1460 projects all four actual Stores from twelve retained original inodes:
integrity and canonical roundtrips pass on separate copies, raw hashes stay
unchanged and every observer/analysis handle closes.
Actual Workspace/readview children still fail, including
`read_view.package_changed`; a completed Parent Run is not successful Tool
execution. Complete cancellation/recovery and Core remain unaccepted.

E1452's separate TUI diagnostic receives and decodes the actual draft reply,
then a real submitted request fails before HTTP dispatch with
`network.gateway_unavailable`: the bridge reports that its Unix socket path
is too long. Global performance tracing also writes into the terminal.
This diagnostic remains failed and supplies neither original-public
acceptance nor a cause for E1447's earlier initialization failure.

E1455 runs the unchanged public Coding ELF through all nine original
public-wire Model PTY cases, with performance tracing off and only the
fixture output placed at short absolute paths in the task's disk-backed
temporary mount. Original permissions, mediated networking, approvals,
20-second waits and timeout scenarios are unchanged; there is no
HostNetwork fallback. All nine cases and their strict physical-custody
checks pass:

- Responses, Completions and Messages display delayed, byte-split SSE text,
  reasoning and usage while the fixture gates the final chunk.
- Esc and Ctrl-C show cancellation, reject late cancelled text and permit
  a subsequent actual request.
- HTTP error, Run wall timeout, incomplete EOF and invalid UTF-8 show visible
  failures and complete the subsequent actual request.

`public-client1455-short-pty` retains exact key bytes, ANSI, screenshots,
wire requests, stream events, canonical model attempts and process receipts.
This accepts those nine Linux tmux cases, not mouse/resize, the original
five-second default profile, matched performance or complete release.

E1456 independently builds the actual current Native MCP package with the
fixed official SDK, normal manifest flags and an own fresh target.
The package closure passes and its ELF is
`eb7ce44d01006f9c14a5e9ac6628f48ab919515c2fec094341151912453cf8d4`.
No compiler/runtime/std/stdx/SDK is rebuilt.
E1457 uses it with the unchanged public Coding ELF in the original real
`mcp-tool` PTY case. Public installation succeeds, but service startup is
denied with `plugin.http_service_grant_invalid` before the actual MCP
exchange. It has no success or GC credit.

The private evidence copier then fails on a Unix socket, after the native
case has already failed. Preservation is completed from the retained
originals without rerunning the case: regular files and symlinks are copied,
the nonregular endpoint is inventoried and its original node remains.
Final outer cleanup does not accept the forced case or acknowledge DATA.
`public-mcp1456-package` and `public-mcp1457-real-pty` retain both boundaries.

The real MCP Tool path, private Core candidate, unclassified portable Skills
case, remaining Product/application flows, first-five-second request,
matched baseline and complete release remain open.
**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Current MCP readiness and empty lifetime observation

The public candidate is `1816566` plus changes to `product.cj`,
`product_owner_peer180.cj` and `process_broker.cj`. Source SHA-256 inventories
are retained with each build. The fixed official SDK, original budgets,
deadlines, authority checks and physical-custody rules are unchanged.

`ProductRuntime.startPluginService` now completes the existing deferred
startup before reading the service instance generation. Existing entry,
configuration and capability checks still precede startup. The existing
`HostCallerCancellation` covers startup and the service call.
E1470 first reaches the real MCP exchange and subsequent request, but fails
final owner teardown with `owner.peer_read_failed`. It is not a whole-case pass.
E1473's separate numeric diagnostic build passes the case without reproducing
that reset; this diagnostic result is not public-artifact acceptance.

`ActualProductOwnerPeer180.readOwnerLifetimeFrame180` is restricted to the
optional post-frontend observation. An empty reset or EOF can report
`owner.peer_lifetime_absent` only when no partial physical input remains.
An authenticated frontend cannot opt into this path.
`ActualOwnerFrontendRendezvous180` accepts that absence only after its existing
bounded check proves the same pinned owner returned. Local reader and packet
retirement still follow whole observation-helper return.
No process exit, callback return or logical terminal state substitutes for DATA
ACK. Ordinary reads, partial input, invalid UTF-8 and timeout retain their
original contracts. E1470 did not record its buffered bytes, so the new rule
does not retrospectively prove that earlier reset was empty.

E1478 runs all ten new real Unix-socket `ProductOwnerLifetimeReadTests`.
The focused package compiles every actual Product production source but only
the new test file. All ten pass; the full Product suite remains unaccepted.
The ELF is
`f08cdb9974b0a853ecf23942b846262d61dfcc2637449956ccd62f4941d4acd8`.
The invocation uses `scripts/pinned_cangjie cjpm test -m agent_product
--target-dir <isolated-target> --skip-build --no-color --report-format=XML
--report-path <evidence>/report`.
E1477's unsupported JSON report option ran no tests. E1478 corrects only that
option and reuses the successful build and natural ten-case inventory.
`owner-lifetime1477-focused-native` and `owner-lifetime1478-focused-native`
retain both outcomes.

E1479 separately builds the current production Product and App. It runs the
original `support_tests/tui_path_coverage/plugin_acceptance.py` with frozen
actual Model and MCP packages, the native dependency, a short disk-backed
fixture path and each original `--case`. All ten pass on App ELF
`44e30e73df7ff4703d1cb2105470ecec8dbfcac8c54a9ea69f94a71ce51de746`:
the three rich-stream protocols, Esc cancellation, Ctrl-C, HTTP error, timeout,
incomplete EOF, invalid UTF-8 and MCP Tool invocation.
The MCP case includes actual startup, `tools/call`, Tool-result consumption
by the next model request, service cleanup and a successful subsequent request.
Every case passes its strict physical-custody check.
`owner-lifetime1479-real-pty` retains commands, source hashes, keys, ANSI,
screens, local requests, canonical attempts and process receipts.
This accepts these Linux tmux paths, not mouse, resize, other platforms,
the original five-second default profile, matched performance or full release.

The private Core candidate remains separate. E1468 preserves the complete
matched workflow assertions and returns its seven request-owner handles only
after the whole actual caller helper returns; an exception cannot reach that
ACK loop. E1472 builds the candidate and runs the complete original Core
contract. It fails the cancellation prerequisite at `read_view.output_capacity`.
Its first refusal is fully reconciled:

| Bank capacity | Charged | Actual requested growth | Overshoot |
| ---: | ---: | ---: | ---: |
| 150,994,944 | 150,774,220 | 12,582,912 | 12,362,188 |

The four retained canonical Store projections pass `quick_check`.
The apparently completed Run contains a failed Program receipt and a failed
depth-two read-view receipt; it is not a successful cancellation/recovery run.
`matched-request1472-numeric-core` and `matched-request1474-canonical-analysis`
retain the actual refusal, raw Store bindings and decoded results.
The balance does not establish a leak or authorize a refund.

Complete Core, portable Skills classification, remaining Product and
application flows, the first-five-second request, matched baseline and full
release remain open.
**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Portable Skills fixture and current native GC classification

The public candidate remains `1816566` plus the E1479 production changes and
one fixture correction in `skills_migration_test.cj`. Production code is
unchanged after E1479, so its ten real PTY passes remain applicable.

E1483 runs an independent consumer of the public Product API using the exact
original portable Codex package contents. Import and enable succeed.
The first context request then fails `tool.hard_denied`, before a Model attempt.
The retained canonical `tool_audit` records `sensitive-path.read` for the
fixture's managed Skills directories: its minimal distribution omitted the
shipped read scopes. The wrapper exits zero despite the uncaught Cangjie
exception; missing success markers correctly keep this result failed.

`InstalledSkillsMigrationHost` now calls the existing
`codingFixtureReadScopeDefaults(bundle)` before opening Product. The helper
copies the real shipped `coding-read-scopes.json`; production classification,
credentials protections and operator overrides are unchanged.

E1484 reuses the same consumer ELF,
`49beab1c1773349958ce129f7abee24d01d8f1c0d777538e3d6860cc3e482db7`,
with only that recipe added to the otherwise identical bundle.
The actual public flow passes: import, enable, `$research` selection,
canonical Skill body and lazy-reference metadata, a second completed Run,
successful `read_context_resource` with exact immutable bytes, and Product
close after whole caller-frame return and real owner ACK.
`portable-codex1483-actual-consumer` and
`portable-codex1484-actual-consumer` retain RED/GREEN logs and Stores.
This narrower passing executable does not prove the original native case fixed.

E1487 uses `scripts/pinned_cangjie cjpm test -m agent_product
--target-dir <isolated-target> --no-run --incremental`, then the natural
`--skip-build --dry-run` inventory. The complete Product ELF is
`dbd119bb8e425a5db205dc6b398a4fbef25e4ffabc4ba7d7c281f71c31ad190c`.
It enumerates 1,096 cases. The sole selected case is
`PluginRuntimeContractTests.importedPortableCodexSkillsUseInstalledContextProvider`,
with original `--parallel 1 --timeout-each=60s` and 90-second watcher.
It fails with SIGSEGV: zero pass, one error, 1,095 excluded.
`portable-original1487-current-native` retains exact source hashes, the ELF,
inventory, filter qualification and physical-custody receipts.

E1488 resolves the actual fault at `0x637f21` to
`MapleRuntime::CheckAndPush(BaseObject*, set&, stack&)`.
Disassembly of the pinned runtime binds this helper to the
`Mutator::GcPhaseEnum` reference visitor; the faulting instruction follows
`BaseObject::GetTypeInfo`. Runtime SHA-256 is
`99b4841d0ce313a7ca9081af9daa30245d41bbeb6dd04574e37c8bbd7e136c9a`.
No system core was available for this exact worker. The static caller binding
is not a recovered dynamic backtrace.
`portable1488-runtime-classification` preserves this distinction.
Only this current runtime GC-enumeration failure enters the user-deferred
scope, with zero pass credit; the historical incomplete SIGABRT is unchanged.

## Current default-request and Core diagnostics remain failed

E1485's first private host copy omitted the production RPATH and never reached
the request. E1486 applies the existing packaging recipe and provenance helper.
The relocated App is
`33a176b980ea89de217d79751a82b5b05e57fc56fe2dce0b13d2dc7bc69fbde9`;
all original package files except the App, ldd report and host provenance stay
unchanged. This targeted reassembly is not a fresh complete release producer.

The original `support_tests/provider_profiles_blackbox/check.py` still times
out on its first request at five seconds, with no captured output or HTTP POST.
The retained Store has zero Runs, Model attempts and Operations.
E1489 observes only the actual request descendants with `strace`; it keeps the
complete defaults, original operator/request limits and strict process cleanup.
The diagnostic records 63,904 completed selected syscalls, including 34,376
`readlink` calls and 1,319,548,664 positive read-return bytes.
These counts are not uninstrumented wall-time attribution.
The retained E1190 control already found path checks small beside hashing,
and earlier same-width reader candidates failed or reached directly qualified
GC failures. No path check, full-byte verification or SDK crypto is replaced.
`profile1486-current-default` and `profile1489-startup-syscalls` retain the
original failure and bounded diagnostic evidence.

E1490 separately rebuilds the private E1472 Core candidate with numeric-only
first-unknown representation labels. No public production source, Source,
SQL, invoice, quota, ACK or deadline changes.
The new ELF is
`795d35ced2f4777deebe8cc4381bc1fe0ddcd531d41a32552869b7520fdc5d58`.
The complete `--core-and-recovery-contract` still fails the original
requirement for a completed durable child Receipt before cancellation.
The first actual refusal is:

| Bank capacity | Charged | Actual requested growth | Overshoot |
| ---: | ---: | ---: | ---: |
| 150,994,944 | 150,774,564 | 12,582,912 | 12,362,532 |

The main root's 53 first-unknown exports comprise 25 plugin plans with
attachment/delegation fields, 23 single-intent plugin plans and five other
shapes. Labels record scalar identities and field presence, not authorization
or last-consumer return. Twelve original Store inodes are retained read-only;
all observer FDs and its thread return. This is not DATA ACK.
`metadata1490-first-export-shapes` retains the prior sources, exact candidate,
complete run and original Store images. The candidate remains unaccepted.

**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Current checkpoint gates and canonical Core refusal

E1493 runs the existing selected Python regression command, full
`scripts/architecture_gate.sh`, and `scripts/dependency_pin_gate.py` through
the fixed SDK wrapper. All 131 selected Python tests pass. Architecture,
documentation, plugin boundaries and dependency pins pass. The eight captured
source/document/lock hashes are unchanged across these checks.
`checkpoint1493-static` retains commands, logs and exact source binding.
This adds no complete Product, Core, baseline or release acceptance.

E1494 analyzes separate copies of all four E1490 Stores after physical
execution and observer closure. Each passes SQLite `quick_check`; all twelve
raw-image hashes remain unchanged. The Program cancellation Run is completed,
but its parent Receipt is failed/partial, its Workspace child fails, and its
depth-two read-view Receipt reports `read_view.output_capacity`. The original
completed-child prerequisite remains unsatisfied.

The current refusal-time accounting reconciles exactly, including the fixed
65,536-byte buffer and three 8,192-byte buffers:

| Actual root | Bank charge | Active shared SUM | Live leases |
| --- | ---: | ---: | ---: |
| 1 | 45,663,776 | 32,964,120 | 265 |
| 210 | 16,785,540 | 5,919,416 | 50 |
| 266 | 16,777,216 | 13,176,568 | 161 |
| 271 | 71,457,920 | 67,263,616 | 4 |

These are current E1490 identities and balances, not the older peak's holder
counts. A charge above active SUM does not authorize reducing its retained
high-water invoice. Source inspection also confirms that
`reserveRegistryData180` delegates the requested invoice to an actual child
lease; its name alone does not establish another Registry metadata copy.
`metadata1494-canonical-analysis` retains the canonical projection, original
image preservation receipt and numerical reconciliation. No execution is
replayed and no DATA owner is acknowledged by this analysis.

**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Approved single-startup verification transaction

E1496 identifies repeated full Registry/package inspection in the existing
startup loop. Each installed-plugin pin calls `pluginLoadRegistryInitialState`.
The retained E1489 trace contains 75 successful manifest opens across nine
installed packages. Manifest-open counts are not complete-verification counts
or uninstrumented timing.

The fixed SDK digest library already calls native SHA-256. E1190's complete
34,649,056-byte fixture hashes in 69.347–90.554 ms. An independent OpenSSL-backed
Python control over those same 22 files takes 73.129–83.892 ms across five
samples, with the same aggregate digest. This does not establish a benefit
from replacing SDK crypto. `startup1496-fresh-verification-analysis` retains
the source chain, byte identities and measurements.

The user explicitly approves extending verification reuse from first
installation to one already-installed-plugin startup transaction. Reuse
across startups remains prohibited. This supersedes the earlier first-install-only
restriction for this bounded path; it does not waive current-byte inspection,
Source/Registry identity, tamper rejection, resource accounting or five seconds.

The candidate adds `PluginRegistryStartupTransaction`, created under the
existing Registry mutex and shared writer fence. It owns the fully inspected,
paid Registry state and its validated metadata generation. Each namespace can
be captured once. Each capture checks the generation and current identity,
then freshly verifies the selected package and its dependency bytes before
using the existing execution pin and admission fence.

Product passes this transaction only through installed-plugin startup.
Ordinary management/mount calls retain their fresh full inspection; first
installation is unchanged. Product closes the transaction before a quarantine
mutation and opens a fresh one for remaining records. Final closure detaches
the inspected state only after active capture frames return. Existing pins and
admission leases retain their own actual custody.

E1497 rebuilds with the fixed official CJC `1.3.0-alpha.20261104001050` and CJPM
`1.3.0-alpha.09`. Its Registry test ELF is
`8cd09f3d36383110e4f03c717595a2e1d5fc1f701e25f5c82b2d99b24fac0711`.
Natural inventory is 50. All 47 selected non-GC cases pass, including 11 new
startup cases:

- Each installed identity is captured once; closed and foreign transactions
  cannot mint pins.
- Target and dependency-byte changes are rejected. A fresh transaction rejects
  a corrupt unselected package.
- Metadata ABA, same-byte metadata replacement and Workspace publication revoke
  the batch; fresh capture preserves the effective Workspace scope.
- Concurrent duplicate captures admit one pin.
- Closing the transaction and pins does not refund custody held by a real
  admission lease. Capacity becomes available after that lease returns.

The three previously qualified GC cases are not rerun and receive zero pass
credit. Commands, complete inventory, individual qualified results, exact
source copies and hashes are in `startup-transaction1497-registry`.

E1498 builds the complete current Product test ELF,
`d71aab889ffe4e835170b146e5c0fe1f9ccdaaef32d78f3f0a1435667b98def1`,
and naturally enumerates 1,098 cases. Nine selected cases pass:

- Three installed Native C packages start and retain independent per-process
  invocation counters.
- An actual middle-package registration mismatch quarantines that package.
  The other packages remain usable; close/reopen preserves the disabled state
  and starts fresh working processes.
- The five existing distribution/operator-record regressions pass.
- Ordinary Native Tool and command-only Product entries still execute through
  canonical Receipts and the existing disable path.

`startup-transaction1498-product` retains the fixed-SDK build, complete
inventory, original per-case limits, real C fixture identities and qualified
results with physical process custody closed. The other 1,089 Product cases
are not run and receive no pass credit.
Both gates apply to `290f9fd` plus the uncommitted startup changes, bound by
their source hashes. The original five-second request still needs proof.

**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Current startup candidate builds; profile prerequisite has direct GC evidence

E1499 passes all nine original production stages against the E1498 source
hashes, with the original 900-second per-stage limits. Raw App SHA-256 is
`349ed674193dd5797d8cd3de78d0e368b2dd31d18a0a3d80b4f6886c581ed62b`;
Minimal is
`39cc8748f2fedfdc64e85f7c16bb249f5e12b420033ca548edcae704fd1204de`.
The complete accepted Product test executable is retained before target reuse.
`startup-transaction1499-production` records every command, exit and artifact.

E1500 keeps the frozen 255-file Coding package's Native plugins, auxiliary
library and SDK runtime bytes. Only the App, loader report and explicit
derivative provenance change. Packaged App SHA-256 is
`5678c1a0d611f1617068f40dd558b611839e50f7b64f415955c51ee2241c57a1`.
This is a source-bound App comparison package, not a complete fresh release.

Two private preparation failures occur before any fixture execution.
The Native identity guard first rejects the current Clang 23 helper against
the frozen Clang 15 helper, despite identical C source. The comparison retains
the original package's exact helper bytes instead of introducing that second
variable. The atomic provenance publisher then rejects the copied old receipt.
That receipt is retained separately; publication resumes after the already
completed App relocation and loader check. Neither failure is request evidence.

The original `provider_profiles_blackbox/check.py` then fails during the
operator's `plugin list --json`, before either five-second Model invocation.
The client reports `owner.peer_disconnected`; actual HTTP POSTs are zero.
All 33 observed execution processes have closed custody. This is not DATA ACK.

The matching owner SIGABRT core is retained and read with GDB, with arguments,
locals and automatic debugger downloads disabled. Its faulting thread has
direct `RegionInfo::MarkObject → WCollector::MarkObject →
ConcurrentMarkingWork::Execute → GCPoolThread::WorkerFunc` frames.
The loaded packaged runtime SHA-256 is
`f035bb72edce6867a6a4e0bff8a06a9cef66fb4a3f795b019d5ec7e7ef7599ad`.
The core is 744,689,664 bytes, SHA-256
`d6e661f11e7bcc1fc89e5ea0a9c876366d27ed756ee6405f9f445b473d307f95`.
`startup-transaction1500-profile/owner-core-diagnosis.json` binds the actual
owner, App, runtime, core and function backtrace.

This current sample is user-deferred GC with zero pass credit. The original
E1486 five-second timeout is not reclassified. No replay, larger deadline,
capacity change, disabled check or SDK replacement is used. The new startup
transaction has no passing five-second performance result.

**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Direct Native dependency restart and rollback evidence

E1501 runs the preserved E1498 Product test executable with the fixed SDK and
Clang 15 Native helper. All 14 selected cases pass: the nine E1498 cases plus
dependency-first restart, transitive disable, old-generation update rejection,
cycle/corrupt-dependency rejection and failed-dependent-handshake isolation.
The helper SHA-256 is
`36ca7f5f003c1136239f64cde95195b7371beaf4acafcafb355526a5363ee790`.
The Product ELF and Cangjie source hashes remain those accepted by E1498.

Production target reuse made CJPM's skip-build enumeration return zero cases.
That preflight was rejected. Direct execution of the preserved test ELF then
enumerated the same 1,098 identities as E1498. A second private preflight
rejected reused observer output paths before launch; fresh paths were used.

The 14 real executions each report one passing case and 1,097 skipped cases,
exit zero and close physical process custody. The driver nevertheless labels
them failed because its parser requires CJPM's additional project-summary
section, which the direct executable does not emit.
`startup-transaction1501-direct-native-dependencies/direct-elf-qualification.json`
checks the actual package, suite, case, full inventory, totals, exit and custody
against the retained raw logs. It rejects five malformed-result controls.
No output is synthesized, no case is replayed, and the original failed driver
summary remains intact.

This is 14-case Native Product evidence, not complete Product, DATA ACK,
five-second performance or release acceptance. The production-source change
also adds its two test files to the existing unit inventory.

**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Current startup source static gates

E1502 passes 131 selected Python regressions, the complete architecture gate
and dependency-pin validation. Its source guard covers the E1498 Cangjie
inputs, unit inventory, root lock and both acceptance records; every guarded
file is unchanged during execution.
`startup-transaction1502-static/summary.json` records commands, exits and
source hashes. The private launcher first rejected a non-executable Python
driver before execution; invoking it through Python ran the original gates.
The generated root lock is then restored to its tracked dependency entries.
The final pin check passes with 32 llm4cj locks; no behavior source changes
after E1502.

The accepted scope remains the 47 Registry cases, 14 selected real Native
Product cases, nine production build stages and these static checks.
Complete Core, remaining Product/application acceptance, matched-baseline
comparison, the original five-second gate and full release remain open.

**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Local startup checkpoint and complete inventory repair

E1503 commits the approved startup transaction as
`f0e63ebd086cc1768cdf917692257d3665f42fbc`, preserving the E1498/E1501
Cangjie source hashes. Staged privacy validation, commit hooks and the final
documentation check pass. GitHub GraphQL, command-local HTTP/1.1 REST,
independent REST retrieval and exact-branch fetch then fail with EOF,
connection reset or TLS errors. No push or PR write is attempted.
`startup-transaction1503-publication/receipt.json` retains the local commit
and the last verified remote checkpoint, `290f9fd`, Open/Draft.

E1504 selects 491 previously qualified non-GC Product cases not already
covered by E1501. Its first preflight fails before fixture execution because
the complete unit inventory omits nine existing test files: four Runtime,
one Core, one Host and three Product files. The failure remains in
`non-gc-product1504-fixtures/inventory-preflight-failure.json`.

E1505 adds all nine missing paths to `scripts/product_unit_inventory.json`,
without deleting tests or changing assertions. The original
`scripts/product_unit_gate.py --inventory-only` entry passes for all 29
inventoried packages and 576 test files. `unit-inventory1505-green/summary.json`
records the actual inventory-only result: zero executable-test credit.
No Cangjie source changes, and the remaining 491-case execution is not yet
accepted.

**Not complete; GC user-deferred with zero pass credit; no Ready or merge.**

## Current non-GC Product sweep and bounded build recovery

E1504 finishes all 17 original Native fixture builders, the read-view helper
and the Native C fixture with the fixed SDK and Clang 15. Package entrypoints,
bundled libraries, provenance and source hashes are recorded in
`non-gc-product1504-current-inventory-fixtures/summary.json`.
Fixture preparation alone gives no Product credit.

E1506's monolithic Product build exceeds its original 900-second outer
watcher bound. Its worker receipt is missing, the watcher exits `-9`, and
the private reporting code then raises a secondary `KeyError`.
`non-gc-product1506-current-cases/failure-disposition.json` preserves the
failed build and cleanup evidence. No case executes and no build pass is
claimed. The deadline is not increased.

E1508 uses the existing six-stage unit-build DAG: Runtime, Tool, Store, Core,
Host and Product. Each stage passes under its original 900-second bound;
Product retains `--jobs 1`. The resulting Product ELF is byte-identical to
E1498/E1501:
`d71aab889ffe4e835170b146e5c0fe1f9ccdaaef32d78f3f0a1435667b98def1`.
Both the actual CJPM frontend and direct ELF naturally enumerate the same
1,098 cases. The 491 selected executions produce **475 passes and 16 native
SIGSEGV errors**, with complete physical-process custody receipts.
Evidence is `non-gc-product1508-original-unit-dag/summary.json` and
`non-gc-product1508-current-cases/summary.json`.

E1509 classifies only those 16 current samples. Fourteen fault in
`MapleRuntime::CheckAndPush`; the fixed SDK binary has four direct call or
tail-jump sites for that helper, all in `Mutator::GcPhaseEnum` or
`Mutator::GCPhasePreForward` visitors. The other two samples directly name
those GC phases. Runtime SHA-256 is
`99b4841d0ce313a7ca9081af9daa30245d41bbeb6dd04574e37c8bbd7e136c9a`.
`runtime-checkandpush-callers.json` and the corrected
`failure-signatures.json` retain the exact evidence. Static caller binding is
not a recovered dynamic stack or proof of the corruption's root cause.
These samples enter the user's GC deferral with **zero pass credit**.
No earlier incomplete crash is reclassified and no failed case is replayed.

E1510 runs the ten lifetime-reader cases added since the old 1,081-case
inventory and absent from E1501/E1508. All ten pass on the same current ELF,
covering complete responses, ordinary and lifetime EOF/reset, partial bytes,
invalid UTF-8, timeout and authenticated-frontend isolation.
`non-gc-product1510-lifetime/summary.json` binds the source, existing natural
enumeration, original bounds, actual logs and custody receipts. An initial
relative-driver-path launch fails before executing Product; the absolute
driver path runs the cases without changing sources or limits.

Together with the 14 distinct E1501 passes, this gives **499 passing current
case identities, 16 current GC-stack failures and 583 unexecuted identities**.
The acceptance applies to `f0e63eb` behavior sources and the E1505 inventory
repair. It is not complete Product, DATA ACK, performance or release evidence.

## Current Core constructor attribution still exposes a capacity failure

E1507 adds function-only constructor-stack observation to the private Core
diagnostic candidate; no public behavior, invoice, limit or ACK changes.
The original full Core contract builds and runs under its original bounds,
but still fails the Program-cancellation prerequisite: child one has not
completed its required durable receipt. Diagnostic ELF SHA-256 is
`0927f017c107b82755f5b2280558ac15087e9b75dabbbe00b98e59d1e74ac346`.
The observer source is restored after capture. This is not public `f0e63eb`
Core acceptance.

`metadata1507-all-constructor-origins/attribution.json` reconciles 21,770
actual derived-constructor identities and 336,066 numeric balance checks,
without an amount threshold. At the main metadata owner's peak, 541 live
leases sum to its exact 45,663,216-byte charge. The refusal records:

| Quantity | Bytes |
| --- | ---: |
| Bank capacity | 150,994,944 |
| Charged at refusal | 150,773,900 |
| Actual requested growth | 12,582,912 |
| Overshoot | 12,361,868 |

The peak includes 53 Prepared copies billed at 14,055,280 bytes, 30 mounted
tool owners at 5,825,088 bytes, four snapshots at 3,483,904 bytes and 13
registry-data reservations at 3,280,384 bytes. These constructor identities
locate billed custody; they do not prove leakage or permit retirement.
Later closed leases do not authorize refunding the owner's high-water mark.

All 12 original DB/WAL/SHM inode images are retained. Separate analysis copies
of all four Stores pass `quick_check`; original hashes remain unchanged and
all analysis connections close. The actual Program Run is completed with a
failed partial parent receipt, a failed Workspace child and a depth-two
`read_view.output_capacity` failure. The Native cancellation Store is cancelled
and the artifact-failure Store is completed. These distinct canonical facts
do not make the failed Program-cancellation assertion pass.
`canonical-analysis/projection.json` retains the projection and raw-image
integrity result.

E1512 restores GitHub metadata retrieval and exact-branch fetch. PR #49 is
Open/Draft at `290f9fd`; that fetched head is an ancestor of the local
checkpoint. Publication remains fast-forward-only, with no Ready, merge,
issue closure or manual CI action.

**Not complete. Complete Core, remaining application acceptance, the original
five-second gate, matched baseline and full release remain open. GC stays
user-deferred with zero pass credit; PR #49 stays Draft.**

## Current queued cancellation and real App PTY acceptance

E1512 publishes the startup fix and inventory checkpoint by fast-forward to
`8d7721a`. The remote head and PR body are read back; PR #49 remains Open/Draft.
The exact selected diff, privacy checks, hooks and publication receipts are
retained in `publication1512-current-read`.

E1513 runs the remaining inherited non-GC queued-cancellation regression on
the unchanged current Product ELF:

```sh
scripts/pinned_cangjie <product-unit-elf> \
	--filter=PluginRuntimeContractTests.piExtensionHostRestartsQueuedCallAfterCancellation \
	--parallel=1 --timeout-each=60s --no-color --no-progress
```

The case passes under the original 90-second process bound, with actual
process-custody closure. The existing complete enumeration still contains
1,098 cases; this invocation executes one and excludes 1,097 by its filter.
`non-gc-product1513-cancellation/summary.json` binds the source, command,
Native result and process receipt to Product ELF SHA-256
`d71aab889ffe4e835170b146e5c0fe1f9ccdaaef32d78f3f0a1435667b98def1`.
The distinct current total is now **500 passes, 16 user-deferred GC-stack
failures and 582 unexecuted case identities**. There is no complete Product
pass or DATA ACK inference.

E1514 executes all ten original real Linux tmux PTY cases using the current
E1499 App. Its SHA-256 is
`349ed674193dd5797d8cd3de78d0e368b2dd31d18a0a3d80b4f6886c581ed62b`.
The App binds to `f0e63eb` behavior sources; `8d7721a` changes only the two
acceptance records and test inventory. The Model package, MCP package and
Native helper are the byte-identical retained E1479 fixtures, not newly
built distribution packages.

Each case runs the existing entrypoint with its original assertions and
bounds:

```sh
python3 support_tests/tui_path_coverage/plugin_acceptance.py \
	--candidate <current-app> \
	--model-package <retained-model-package> \
	--mcp-package <retained-mcp-package> \
	--native-library <retained-native-library> \
	--output <private-disk-output> --case <case>
```

All ten pass: `rich-responses`, `rich-completions`, `rich-messages`, `cancel`,
`ctrl-c`, `http-error`, `timeout`, `incomplete-eof`, `invalid-utf8` and
`mcp-tool`. These exercise actual App keys, local Model HTTP/SSE requests,
delayed chunks, MCP execution, visible states and continued use after
cancellation. `real-pty1514-current-app/summary.json` binds the exact inputs,
package files, ANSI output, terminal snapshots, canonical assertions and
exit/custody receipts. Every case exits zero with its actual passing result.

No external model is called and no SDK component is rebuilt. Mouse, resize
and other platforms remain unverified. These ten App flows do not replace
the separately blocked packaged CLI/ACP paths, complete Core, the original
five-second gate, matched-baseline comparison or full release acceptance.
**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Private concrete-policy candidate still fails complete Core

E1515's fixed-SDK probe establishes that function values do not expose an
`Object` identity through `Any`; it does not attest that a callback is closed.
The unpromoted E1516 candidate instead implements the existing read-view and
readonly-delegation descriptor policies as concrete code. Descriptors with
opaque call resolvers retain the original Raw metadata path and debt.

The first unit build fails on two test-only language mistakes: using
`getOrThrow` on the domain `Result`, and capturing a mutable local in an
escaping lambda. The corrected tests use the existing Result variants and
an immutable reference to the retained-call holder. No assertion is relaxed.
The rebuilt complete Native ELF enumerates 82 cases. All ten selected cases
pass, including a successful opaque resolver that keeps its arguments alive
and retains positive billed debt after producer return. Its allocation probe
was oversized rather than an otherwise admissible full-bank request; see the
E1533 correction below. These unit DATA results are not actual Core acknowledgements.
`metadata1516-fixed-policy-units-compile2/summary.json` binds these results to
ELF `8381c35af1cd9fe16e5264fa4bb25ab72b618a2a7e3dfdbebb8de47eac2af386`.

E1517 rebuilds the unchanged full Core/recovery contract from this candidate
and runs `--core-and-recovery-contract` with the original fixed SDK, fixtures
and two 900-second build/run bounds. Build exits zero; the actual contract
exits one at the required completed-first-child Receipt assertion.
ELF SHA-256 is
`2d6784a46f7cb17c73d51e97437b3d43b77bf2c5b19316b55f33b0bac748c3a3`.
No candidate Core changes are promoted to the PR.

All four actual Stores are retained without modifying live SQL or deletion.
Twelve raw DB/WAL/SHM images retain their hashes. Separate analysis copies
pass `quick_check`, exact canonical plan roundtrip, operation/effect plan
agreement and reserved Receipt identity checks; all connections and observer
FDs close. The Program Run is completed with a failed partial parent,
`workspace.protocol` on its first child and `read_view.output_capacity` at
depth two. This is not successful cancellation or GC evidence.
`metadata1517-fixed-policy-core/summary.json`, `canonical-retention.json` and
`canonical-analysis/projection.json` retain the source, command, process and
canonical facts. The initial offline JSON-decoder assumption is separately
recorded as an analysis error; Store plans use the existing canonical codec.

Further analysis of the already captured E1507 history covers all 53 live
Prepared-copy identities:

| First Raw export | Identities | Billed bytes |
| --- | ---: | ---: |
| Legacy Native execution frame | 25 | 7,237,928 |
| Child-plan validation | 28 | 6,817,352 |

All have an actual producer-return witness and remain marked unknown at that
historical refusal; four also retain a concrete consumer. The Legacy group
uses readonly-delegation plans with input attachments. This locates remaining
consumers but does not prove their DATA return or the candidate's current
charge. No quota, floor, working invoice, Source, SQL or actual ACK rule changes.
**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Private Native stack repair and scalar-receiver evidence

E1519–E1533 remain task-private candidates and diagnostics. None of these
behavior changes is promoted to the PR. The public behavior source remains
`f0e63eb`; the 500 distinct Product passes, 16 current GC failures, 582
unexecuted Product identities and ten real App PTY passes retain their
previous source and artifact scopes.

All Core runs below use the original complete
`--core-and-recovery-contract`, fixture source SHA-256
`3b1b82119de930fe60072180bc57fed02f5ed8e823be5682fab41334f941a9a7`,
fixed official SDK and unchanged 900-second build/run bounds. The Native
helper remains
`36ca7f5f003c1136239f64cde95195b7371beaf4acafcafb355526a5363ee790`.
No compiler, Runtime, std, stdx or SDK is rebuilt or replaced.

### Actual Native stack boundary, not the first visible source frame

E1519 gives the readonly attachment lane concrete metadata consumers,
independently paid encoded Strings and a revocable observer. Its full
attachment invoice still waits for actual parent return, output ACK and
successful attachment close. E1520 builds successfully but fails the original
Core contract with printed stack-overflow traces. E1522 reduces the new
attachment-only helper's static frame from 3,880 to 2,072 bytes, but does not
fix that failure: the actual artifact-failure Root has no input attachment
and takes the Legacy lane.

E1524's breakpoint on the first visible `nativeProcessWriteAdmitted`
prologue records no hit. E1525 observes one actual Runtime stack-overflow
throw; its ordinary debugger unwind past `C2NStub` is invalid and interprets
JSON bytes as return addresses. That unwind is not heap-corruption evidence.
E1526 instead binds the loaded Runtime and reads a bounded, monotonic
69-entry frame-pointer chain through the actual C2N guard. Native argument
stack bytes are zero, remaining guard space is minus 128 bytes, and the
shortfall is 128 bytes.

E1527 moves the original post-Native result/SQL/output/cleanup body verbatim
into a private helper entered only after the actual Native invocation
returns. The active Legacy caller's static frame falls from 10,632 to 4,664
bytes. No stack size, deadline, authority, failure precedence or ACK rule
changes. The rebuilt original Core run has zero `StackOverflowError`
traces and reaches the later cancellation prerequisite, but still exits one
because the first child lacks the required completed durable Receipt.
Its ELF is
`89e3537d2d3320c5f7069916a6280d911ad441b16f834a705080b15f290daca2`.
This repairs the private candidate's stack regression, not complete Core.

E1521 rebuilds the original five-member unit dependency DAG on E1527 source
and passes the three existing attachment-owner cases: actual initial
reservation refusal, actual growth refusal with its attempted lease returned,
and full-invoice retention until both parent return and output ACK. The Host
ELF naturally enumerates 282 cases; only those three execute.
Its SHA-256 is
`d75be6ca9159a5e78db0068c236e241936b8ab6963e46b88df6c7e1859313e10`.

Retained entry points:

- `metadata1520-attachment-custody-core/summary.json`
- `metadata1522-attachment-custody-core/failure-classification.json`
- `metadata1526-c2n-frame-chain/actual-frame-chain.json` and
  `actual-boundary-contract.json`
- `metadata1527-actual-native-result-frame-core/summary.json` and
  `verbatim-result-ownership-body.json`
- `metadata1521-attachment-owner-units/summary.json`

### Scalar receiver removes a real export, but Core still fails

E1528 observes 32 actual first Raw exports: 25 through the derived scheduler's
tool-name argument, six through readonly preview validation, and one through
the no-attachment Legacy Native lane. This is export-site evidence, not a
count of refundable owners.

E1529 replaces the scheduler's retained String with a three-way value kind,
not the previously withdrawn paid name-copy experiment. The frozen call is
classified under a private loan before the opaque scheduler callback.
The original distinction remains: `run_program` or `plugin.*` may yield a
Root frame, but only `plugin.*` may enter a derived frame. Source checks,
operation identities, transition ordering, depth/width/operation bounds and
actual slot release remain unchanged; all callback and frame callers migrate.

E1530 rebuilds the complete original Core and still fails the completed-child
Receipt prerequisite, without a stack-overflow trace. Actual canonical records
show the partial failed Program, `workspace.protocol` and the depth-two
`read_view.output_capacity`. The ELF is
`cef1c871477cc247962e5c5afd9ce8d9df2f28843bc6e370542f9ca6b928854f`.

E1531 passes all 84 naturally enumerated Tool cases, including the two new
scheduler-policy boundary cases, and the same three Host invoice/ACK cases.
Every case runs in a separately qualified Native process with the original
30-second case and 90-second process bounds. This proves complete Tool
inventory coverage in isolation, not aggregate single-process suite behavior
or complete Host/Core/Product acceptance. The unit artifacts are:

| Module | ELF SHA-256 | Natural inventory | Actual passes |
| --- | --- | ---: | ---: |
| Tool | `e67bc248957bf0e784dd2472989ddcdafca2c1205631a3d3eb0e387063bb69ee` | 84 | 84 |
| Host | `b27df9a812e66f57e3db3df5d765a3c462773a28b7823c42e5060b9e5ca153fe` | 282 | 3 |

E1532 observes the unchanged E1530 ELF without Cangjie instrumentation.
The scheduler-name exports are absent; six preview-validation exports and
one Legacy export remain. Exact disassembly binds all budget fields and
stack slots. One real `grow` refusal occurs while the bank mutex is held:

| Refusal fact | Bytes |
| --- | ---: |
| Fixed bank capacity | 150,994,944 |
| Actually charged | 145,492,476 |
| Actual requested increment | 12,582,912 |
| Remaining capacity | 5,502,468 |
| Overshoot | 7,080,444 |

Four message slots and four fixed buffers are charged at that observation.
The actual caller is the read-view output path through
`InvocationWorkingFunding1255.acquireOutputData1272`,
`acquireDerivedMessageData1272` and shared-ledger `ensure`. This establishes
real saturation rather than merely trusting the generic output-capacity error.
It does not identify every live payer, equate Raw exports with refundable
owners, or permit high-water refunds. No owner address is treated as a stable
identity and the debugger retains no application owner reference.

E1530 and E1532 each retain four actual Stores and twelve raw DB/WAL/SHM
images. Separate analysis copies pass integrity, canonical roundtrip,
operation/effect-plan and reserved-Receipt checks. Raw hashes remain unchanged;
process custody, observer threads and observer FDs close.

Retained entry points:

- `metadata1528-current-first-export-sites/first-export-events.json`
- `metadata1529-slot-kind-contract/contract.json`
- `metadata1530-slot-kind-core/summary.json`,
  `failure-classification.json` and `canonical-analysis/projection.json`
- `metadata1531-slot-kind-units/summary.json`
- `metadata1532-current-refusal-boundary/observed-boundaries.json`,
  `exact-boundary-bindings.json`, `current-conclusion.json` and
  `canonical-analysis/projection.json`

### Remaining private preview work and corrected test evidence

E1533 replaces the actual preview primitive's constant denied-network closure
with a concrete policy implementation. The validator still requires its exact
frozen parent, current host-only descriptor, immutable implementation/schema
and current capability ceiling. Ordinary contribution callers explicitly
require non-host-only descriptors. Opaque resolvers keep their original Raw
export and debt; no successful callback becomes a DATA acknowledgement.
The original policy identity flags are preserved rather than inventing an
additional capability resolver. E1535 passes all 86 naturally enumerated Tool
cases, including both new preview/authority regressions, and the same three
Host invoice/ACK cases. All original five unit-build stages pass. Each case
still runs in its own actual Native process with unchanged bounds; complete
Host/Core/Product and aggregate single-process acceptance remain unproved.
Tool ELF: `98c04e5dcbf8d0b6d00c5100cd71d4d9a70209d42d5b4cbf26f10b7cb67e1b68`.
Host ELF: `43024e4b304688902f6b484802821b10c57b3a503e7bb2b4078302f4409906e0`.
See `metadata1535-preview-policy-units/summary.json`.

E1534 rebuilds that exact candidate successfully and runs the original complete
Core. It still exits one at the completed-child Receipt prerequisite, with zero
stack-overflow traces. Its actual depth-two read-view operation reports
`read_view.output_capacity`; that generic error alone is not a new complete
bank/owner attribution. The frozen ELF is
`33e6f5e51c77c33ab49e366ca1139cb38515012d847a68a4bff0008c00f6b2a7`.
Four actual Stores and twelve raw images are retained and checked only through
independent analysis copies; observer FDs and actual process custody close.
See `metadata1534-preview-policy-core/summary.json`,
`failure-classification.json` and `canonical-analysis/projection.json`.

E1533 also corrects the existing opaque-resolver test's bank probe. Its former
16 MiB raw request invoiced 128 MiB against a 16 MiB bank, so rejection alone
could not prove retained debt. Earlier actual retained-text and positive
occupancy assertions remain valid, and recorded pass counts are unchanged.
The corrected probe requests one raw byte, which invoices exactly the
original 16 MiB floor. E1535 executes and passes the corrected case without
changing any product quota, invoice or retirement rule.
See `metadata1533-preview-policy-contract/opaque-probe-correction.json`.

E1523 reconciles all 582 unexecuted public Product identities against retained
failure evidence: 575 in the earlier complete cursor, six in the reviewed
seven-case classification, and the portable Codex case in E1487/E1488.
The last item has an exact Runtime GC fault/call-site binding, not a recovered
dynamic backtrace; it does not reclassify the older incomplete SIGABRT.
This read-only reconciliation executes no case and changes no current pass
count. `product1523-unexecuted-dispositions.json` records the source artifacts.

### Current refusal distinguishes opaque exports from outstanding consumers

E1536 adds only task-private scalar events to the E1533 behavior. Exact token
comparison after erasing named observation code preserves all original
non-observer code, including string literals and quota/lifecycle rules.
Logging allocation, stack and timing overhead remain real; this is not
clean-source or performance acceptance. The diagnostic retains numeric bank,
reservation-group and lease IDs, never an owner reference or a stack capture,
and records every custody growth rather than applying a size threshold.

The rebuilt original complete Core still fails the same Receipt prerequisite.
Its actual bank refusal is capacity 150,994,944, charged 145,130,404,
incremental request 12,582,912 and overshoot 6,718,372 bytes. The request is the
original full 16 MiB output invoice less 4 MiB of already billed high-water
slack, not a smaller output invoice. Replaying all bank events reconciles the
charged balance exactly, including 90,112 bytes in four fixed buffers.

| Diagnostic reservation group | Billed bytes | Live ledger SUM | Live leases | Instrumented metadata state at refusal |
| --- | ---: | ---: | ---: | --- |
| 1 | 39,887,000 | 26,258,008 | 292 | Four owners have producer returned, one consumer outstanding each, and no unknown export |
| 210 | 16,918,156 | 5,699,136 | 49 | One unknown owner has producer returned and zero consumers |
| 266 | 16,777,216 | 13,388,656 | 164 | Three metadata owners and their current Core scope remain active |
| 271 | 71,457,920 | 67,263,616 | 4 | The actual pending 16 MiB child invoice requests the refused growth |

Only one first Raw metadata export remains in this run; the six earlier preview
exports are absent. That does not explain all live leases: most have not yet
been attributed to concrete receiver types. In particular, the four outstanding
consumers are not unknown exports and cannot be cleared merely because their
producer, Operation or process ended. Their actual creation and return paths
still require attribution. No early refund or invented ACK is applied.

The diagnostic ELF is
`dc829c7144ae6f1ea1d1d45d5a56a7391ae202bc37f2ba103428d3587bb7e175`.
Four actual Stores and twelve raw images again pass separate-copy canonical
checks with unchanged raw hashes and closed observer/process custody.
Retained entry points under `metadata1536-current-owner-attribution/`:
`summary.json`, `current-conclusion.json`,
`numeric-analysis/bank-reconciliation.json`,
`numeric-analysis/live-owner-states.json` and `canonical-analysis/projection.json`.

E1537 reuses that exact frozen diagnostic ELF without another build. At the
disassembly-bound scalar event boundary, a read-only debugger captures 98 actual
metadata-consumer origins with zero capture errors. Register/stack values
already contain numeric bank/group/lease identities; no managed owner pointer
is followed. Within this run, all four consumers still outstanding after
producer return join to `productFilePlanResultMetadata204`, called by
`PluginFilePlanProposeExecutor.execute`.

The actual canonical rows identify the four failures: invalid path, path-byte
limit, stale precondition and existing create target. The helper returns their
original `Result.Err` without a metadata-consumer retirement path. Its success
path separately waits for the actual result payload ACK. This does not justify
calling the failure a DATA acknowledgement: a safe fix must preserve the error
and account for any original or independently copied data still held by its
receiver. No error code, SQL outcome, Source check or ACK is changed in E1537.
Other live lease types remain unclassified, so retiring these four alone is
not claimed to solve capacity.

The debugger exits zero but the actual inferior exits one at the original
Receipt prerequisite. Its independent bank reconciliation is exact; canonical
retention again checks four Stores and twelve unchanged raw images.
See `metadata1537-live-consumer-origins/outstanding-consumer-origins.json`,
`exact-boundary-binding.json`, `numeric-analysis/bank-reconciliation.json`
and `canonical-analysis/projection.json`.

Complete Core, the remaining application flows, original five-second request
gate, matched-baseline comparison and final-source release acceptance remain
open. **Not complete; GC remains user-deferred with zero pass credit;
PR #49 stays Draft.**


## Same-run attribution of all live lease births

E1539 replays the unchanged E1536 diagnostic ELF
`dc829c7144ae6f1ea1d1d45d5a56a7391ae202bc37f2ba103428d3587bb7e175`.
The read-only debugger observes disassembly-bound reservation-creation
boundaries after scalar IDs have been loaded. It does not dereference managed
owners, invoke inferior functions, alter reservations or filter small growth.
All 21,513 captured births match the actual scalar log; 3,597 bounded native
call chains are retained, with zero capture errors.

At the first actual refusal, all **509 live leases** join to creation paths
from this same run. Every group's live invoices plus its 1,024-byte lease
headers reconcile exactly to ledger SUM. The complete bank also reconciles:
capacity 150,994,944, charged 145,127,092, incremental request 12,582,912 and
overshoot 6,715,060 bytes, including 90,112 fixed-buffer bytes. These are
logical charges, not a physical-memory measurement or evidence of a leak.
Lease IDs are not matched across runs.

The largest live invoice categories in reservation group 1 are:

| Actual creation path | Live leases | Invoice bytes, excluding lease headers |
| --- | ---: | ---: |
| `copyPreparedDerivedInput204` | 61 | 7,063,456 |
| `HostRegistryCatalogIdentity159.reserveTool159` | 30 | 5,825,088 |
| `reserveSnapshotCatalogData159` from Product prompt building | 7 | 2,794,496 |
| `produceLockedToolSetSnapshot159` from the Core model lane | 3 | 2,612,496 |
| `copyPreparedExternalText204` from the private read-view input path | 81 | 2,188,736 |

All 61 derived-input copies originate in the actual
`HostJavaScriptPluginServiceBroker.executeServiceChildFrame159` path.
Their owner currently retains the independent call and argument graph
permanently, because arbitrary preparation callbacks may retain them.
Birth attribution identifies that owner and its charge; it does **not** prove
that its receivers returned their DATA. The actual full 64 MiB attachment
invoice, SUM/high-water rules, 16 MiB floor and 144 MiB bank remain unchanged.
The four file-plan error-path consumers from E1537 also remain unresolved.

The debugger exits zero, but the inferior again exits one at the original
completed-child Receipt prerequisite. Four actual Stores and twelve raw images
are checked through separate canonical-analysis copies, with raw hashes
unchanged and observer/process custody closed. This adds no Core pass,
performance result or public-source acceptance.

Evidence under `metadata1539-other-live-lease-origins/`:
`live-lease-origin-joins.json`, `root-live-invoice-summary.json`,
`exact-boundary-binding.json`, `numeric-analysis/bank-reconciliation.json`
and `canonical-analysis/projection.json`.
The next candidate may retire only an actually closed preparation input frame
after independent Core copies, while keeping remaining Source identity paid
on the same bank; opaque receivers and unproven returns must remain charged.
**Not complete; GC remains user-deferred with zero pass credit; PR #49 Draft.**

## Closed derived-input return is real, but complete Core still fails

E1540 adds a private DATA-only return path for the copied service-child input.
It does not use the nominal closed-resolver flag as evidence. Eligibility
requires the actual concrete validator and capability policy, no opaque
descriptor preparation or policy callbacks, safe denied-network evaluation,
and an independently retained Core copy for the same Derived parent identity.
Repeated loans, an active input frame and unexpected unwinding remain paid.

After the actual private loan and preparation frame return, the owner prepays
the remaining original call/tool/parent identity Strings on the same bank and
reservation group. Only then does it clear the call/argument graph; after that
clearing helper returns, it closes the original full input lease. It does not
copy or discard the still-live identity backings. A refused prepayment leaves
the original graph and invoice intact. Source authority, output ACK, the
144 MiB bank, 16 MiB floor, full 64 MiB attachment invoice and high-water
accounting are unchanged.

### Original Core and actual return boundaries

E1541 rebuilds the original complete Core fixture on the source manifest
`e7ce990402994ef14c63314747c37cc89ff7352654fc884c508bc4bd2d7b5a25`.
Build exits zero; the actual fixture exits one at the same completed-child
Receipt prerequisite, with no stack-overflow trace. Canonical rows show a
failed `plugin.program.run`, its failed `workspace.read` child, and a failed
`host.process.readview` grandchild with `read_view.output_capacity`.
The Core ELF is
`139ca37550f12a0f85692bf6012c2772319659234f044d0f9f0da770b7555f08`.

E1543 observes that exact frozen ELF with disassembly-bound, read-only debugger
breakpoints. All 350 boundary events decode without capture errors:

| Actual input state | Count | Observed result |
| --- | ---: | --- |
| Completed private input loans | 64 | All use the concrete validator and policy |
| Descriptors with opaque callbacks | 59 | Input return refuses; full graph remains paid |
| Callback-free, safe, independently copied inputs | 5 | Actual graph clears, original lease closes and return succeeds |

The five returned full invoices total 521,744 bytes; their retained identity
invoices total 64,400 bytes. These are observed lease invoices, not a measured
bank refund, physical-memory saving or complete live-ledger reconciliation.
The actual locked output refusal still has capacity 150,994,944, charged
144,673,220 and incremental request 12,582,912 bytes: overshoot 6,261,188.
Different runs' charges are not subtracted to claim a causal saving.

The diagnostic driver exits zero, but its actual inferior exits one. Both
E1541 and E1543 retain four actual Stores and twelve raw images, checked through
separate analysis copies with unchanged raw hashes and closed process/observer
custody. Neither run passes complete Core.

### Native regression scope and test correction

E1542 first fails unit compilation because two new callbacks capture mutable
local Boolean variables; it executes no unit cases. E1544 moves those two flags
onto the existing test fixture object without changing their assertions.
Only that test file differs from E1540: all 2,661 other inputs are byte-identical.
The corrected manifest is
`4437d08227eb3d6a401448c817a98be676919dd066bf201e95f451d3ebba7b3a`.
E1541 therefore remains applicable to its unchanged production source.

E1545 passes all five original unit-build stages, all **95 naturally enumerated
Tool cases**, and the same three Host invoice/ACK cases in isolated Native
processes. The nine added input-return cases cover retained Source identity,
opaque descriptor/validator/policy receivers, active-frame refusal, unexpected
unwind, identity-prepayment refusal, missing independent Core data, and a later
closed loan after an earlier opaque borrow. The DATA fixture does not admit
Source or execute an operation. The Host cases retain their original invoice
and actual ACK assertions; they are not a Native Program execution proof.

- Tool ELF: `0e9541a815509d8396ad8a5bfeb42806cdcb0e111a1af0d2e41a844e339600b3`.
- Host ELF: `33c58f03c6d30e1307bfd54a970f7519976def54f5b74c48acb55529a5b07b64`.

Original build, enumeration, case and process-custody limits are retained.
These passes do not establish aggregate single-process suite behavior,
complete Host/Core/Product acceptance or public-source acceptance.

Retained entry points:

- `metadata1541-derived-input-core/summary.json`,
  `failure-classification.json` and `canonical-analysis/projection.json`;
- `metadata1543-derived-input-return-observation/observed-boundaries.json`,
  `current-conclusion.json`, `exact-boundary-binding.json` and
  `canonical-analysis/projection.json`;
- `metadata1542-derived-input-units/summary.json` for the failed compile;
- `metadata1545-derived-input-units/summary.json` for exact corrected source,
  inventories, commands, artifacts and actual Native results.

The four file-plan error-path consumers remain unresolved. Opaque mounted
canonicalizers remain paid; callback or logical completion is not their DATA
ACK. All changes above remain private. Public `f0e63eb` behavior and public
pass counts are unchanged. **Not complete; GC user-deferred with zero pass
credit; PR #49 Draft.**

## Concrete read-view policy and remaining Host custody

E1546 replaces the actual Host read-view primitive's three pure capability and
network callbacks with the existing concrete policy mechanism. The new
`ReadViewChild` case computes the ordered resource requirements once and retains
the original primary/static/additional ordering, de-duplication, denied network,
invalid empty-resource scope and frozen descriptor identity flags. Opaque
mounted canonicalizers are unchanged and remain paid.

The private source manifest is
`1763f99f4bfbc76398f8a59ab1ec204bf7ce75c2a5ed0558926ba208679cdac6`.
It changes four files from E1544: the concrete policy, descriptor capability
assembly, actual Host registration and three DATA-only regression cases.
No permission, Source, SQL, bank, floor, attachment invoice, high-water, output
ACK or process-return requirement changes.

### Complete Core still fails; isolated regression cases pass

E1547 builds the original complete Core fixture in 410.769 seconds, then fails
after 94.056 seconds at the completed-child Receipt prerequisite. There is no
stack-overflow trace. The canonical chain remains failed `plugin.program.run`,
failed `workspace.read`, and failed `host.process.readview` with
`read_view.output_capacity`. Its ELF is
`b8a0f5c00d92dd080b71b33fb125691efe9dfd45f782cb22c36e76523222c703`.

E1548 passes all five original unit-build stages, all **98 naturally enumerated
Tool cases**, and the same three Host invoice/ACK cases. The three added cases
cover exact resource/frozen identity parity, the invalid scope for no resources,
and real input-graph return without losing either resource requirement.
Each case runs in its own Native process. These DATA fixtures do not admit
Source or execute an operation; the Host cases do not execute a Native Program.
They are not aggregate single-process, complete Host/Core/Product or public
acceptance.

- Tool ELF: `8ed80cc0dacece2bfbdd52ccbdbca9308c57d6a3ad1b63b9480a004989c19bcc`.
- Host ELF: `c478846cc1ecb645e735ee8ae2080385cd6d52fc10334955471ce91bb857321d`.

### Exact current return and refusal observations

E1549 observes the frozen E1547 ELF with read-only debugger breakpoints and
read-only source/SDK mounts. All 540 input-boundary events decode without input
or bank capture errors. All 64 private loans use the concrete validator and
capability policy:

| Actual input state | Count | Observed result |
| --- | ---: | --- |
| Closed, independently copied metadata | 30 | Graph clears and original full input lease closes |
| Opaque descriptor callbacks | 24 | Original graph and full invoice remain paid |
| Closed preparation without independent Core metadata | 10 | Original graph and full invoice remain paid |

The 30 original invoices total 4,655,664 bytes; their retained identity invoices
total 404,096 bytes. This is not a measured bank refund or physical-memory
saving. At the actual locked refusal, capacity is 150,994,944, charged occupancy
140,995,116 and incremental request 12,582,912 bytes: overshoot **2,583,084**.
No charge is subtracted across separate runs to claim a causal saving.

All eleven observed input instructions and their preceding calls/stores are
bound to the current disassembly. The three complete bank instruction streams
match E1543 after link-address normalization. Generated closure/symbol
annotations prevent whole-function equivalence claims for the five input
functions; only the verified observation points are used. No inferior calls,
state writes, DATA text or retained owner references are added.

Initial source inspection suggested Host precedence: the inheritance routine
copies the paid Core consumer, while Host selection bypasses Core copying.
That inspection did not establish which live contexts had inherited control.
E1554 below rejects the proposed explanation: the actual Host selector returns
None and the child Context lacks the paid Core consumer. The earlier association
with PTC samples was based on log ordering, not dynamic receiver evidence.

The diagnostic driver succeeds but its actual inferior still exits one.
Both E1547 and E1549 retain four actual Stores and twelve raw images. Separate
analysis copies pass canonical checks, raw hashes remain unchanged and actual
process/observer custody closes. Original execution and unit deadlines remain.

Retained evidence:

- `metadata1547-readview-child-core/summary.json`, `failure-classification.json`
  and `canonical-analysis/projection.json`;
- `metadata1548-readview-child-units/summary.json`;
- `metadata1549-readview-child-observation/observed-boundaries.json`,
  `current-conclusion.json`, `exact-boundary-binding.json`, current disassembly
  and `canonical-analysis/projection.json`.

All behavior changes remain private. Public `f0e63eb` behavior and pass counts
are unchanged. The four file-plan error-path consumers, opaque canonicalizers,
complete Core, application flows, original five-second gate, matched baseline
and final-source release remain open.
**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Actual copy selector rejects the Host-precedence hypothesis

E1550 privately tests an additional Core-owned metadata copy after eligible Host
preparation, with original-bank identity checks and independent Core producer/
consumer return. Its 2,662-input source proof hashes to
`c07b401bd217ff27ec803a4bb5a75f45c0bd6b3029533f1536b2039def3cf4f1`.
This candidate is **ineffective on the missing-copy path** and is not carried
into the next candidate.

### Complete Core and actual input returns remain unchanged

E1551 builds in 381.732 seconds but the original complete Core fails in 88.398
seconds at the same completed-child Receipt prerequisite. The canonical chain
still ends in failed `host.process.readview` with `read_view.output_capacity`.
No `StackOverflowError` appears. Its frozen ELF is
`bb061fc4b57dc3b206c049c58b46537a0669e2d21f8235feba82bb40344f84f0`.
The native library remains
`36ca7f5f003c1136239f64cde95195b7371beaf4acafcafb355526a5363ee790`.

E1552 passes all five original unit-build stages, all 101 naturally enumerated
Tool cases and the same three selected Host cases (282 naturally enumerated).
Each runs in its own Native process. The three new tests exercise independent
Core producer/consumer retention and raw-export retention, not the real missing
selector path. They do not rescue E1550 or transfer credit to E1555.

- Tool ELF: `84736198376fe992d85d4f5ceafb3b1c70354a70efdc304b3aedb527851280b7`.
- Host ELF: `7a2737a72b30799428aa7ea8e1ffe524b602369c1d90a0eab28fc190d20ac4f3`.

E1553 observes that exact ELF read-only. Its 540 input events still show
30 real input-graph returns, 24 opaque paths kept paid and ten closed paths
without independent metadata. No input or bank capture errors occur. The
returned original invoices total 4,656,112 bytes; retained identity invoices
total 404,096 bytes. These are invoice observations, not measured bank refunds.
At the actual locked refusal, capacity is 150,994,944 bytes, charged occupancy
140,996,100 and the incremental request 12,582,912: overshoot **2,584,068**.
The diagnostic succeeds; the actual inferior exits one.

### Actual receiver selection, not source-order inference

E1554 adds nine exact current-instruction observations to the same frozen ELF.
Only events with the actual private derived-input caller in a bounded native
frame chain are recorded. Reference results are tested for null; no DATA text,
owner identity addresses, inferior calls or state writes are introduced.

| Actual selection observation | Count |
| --- | ---: |
| Host selector returns no consumer | 421 |
| Actual paid execution-failure consumer absent | 40 |
| Corresponding Core-scope selection has no consumer | 40 |
| Present consumer satisfies the actual PlanCopy subtype check | 224 |
| New E1550 Host-only eligibility selector entered | 0 |
| Catalog snapshot-payment absence branch entered | 0 |

The forty absent-consumer observations form four distinct call sites with ten
occurrences each: registration entry, snapshot selection, registration lookup
and prepared retention. Their real stacks include the private Native read-view
call and the actual Core nested-tool slot. There are no selector capture errors.
This rejects Host precedence as the explanation; a source routine capable of
copying control does not prove the actual child received that control.

The actual E1554 inferior still fails. Its locked refusal records capacity
150,994,944, occupancy 140,996,484 and growth 12,582,912 bytes: overshoot
**2,584,452**. No cross-run subtraction is used to claim a saving.

E1551, E1553 and E1554 each retain four actual Stores and twelve raw images.
Separate-copy analysis passes canonical checks; raw hashes remain unchanged
and process/observer custody closes. The E1551 recorder directory initially
differed from the analysis helper's expected name; renaming only that private
capture directory allowed analysis without rerunning Core or changing raw data.
Original execution deadlines and fixed SDK remain unchanged.

### Ordinary frozen read-view parent control inheritance

The broker currently inherits controls for frozen Program delegation or
**Derived** read-view parents. Its ordinary frozen read-only read-view parents
are excluded by that Source-kind condition. E1555 removes only that condition
and uses the same existing parent-control inheritance routine, including its
Run, epoch, cancellation, budget, snapshot, environment, service and capability
validation. It does not create a payer or change authorization or Source.

E1555 starts from E1546, not E1550. Exactly one source file changes:
`agent_host_runtime/src/javascript_plugin_service.cj`. Its 2,662-input source
proof hashes to
`3763037d474d4ba96df58a8d9f1248f4c664817bb22ddc87e21a13f3c46c2137`.
E1556 builds in 403.813 seconds, then the original complete Core fails in
92.053 seconds at the same completed-child Receipt prerequisite. The actual
canonical chain still ends in `read_view.output_capacity`; no stack-overflow
trace appears. ELF:
`566360bf3affeb55169944c520fb86e665b543c66cef0147d2064705d8458ed6`.
Its four Stores and twelve raw images pass the same separate-copy checks,
with unchanged raw hashes and closed process/observer custody. This is not
complete Core acceptance. E1559 below observes actual copied-input retirement
on that frozen ELF rather than inferring it from the source change.

Retained evidence:

- `metadata1551-hosted-core-data-core/summary.json`, `failure-classification.json`
  and `canonical-analysis/projection.json`;
- `metadata1552-hosted-core-data-units/summary.json`;
- `metadata1553-hosted-core-data-observation/current-conclusion.json`,
  `observed-boundaries.json`, `exact-boundary-binding.json` and current disassembly;
- `metadata1554-core-copy-selection/current-conclusion.json`,
  `observed-selection.json`, `exact-boundary-binding.json`, current disassembly
  and `canonical-analysis/projection.json`;
- `metadata1556-readview-control-core/summary.json`, `failure-classification.json`
  and `canonical-analysis/projection.json`.

E1557 separately extends the existing failed-preview output path to all
concrete generator validation/storage failures, not just artifact-store
failure. It preserves typed error fields and routes them through the existing
failed `ToolResult` payload lease, whose actual consumer ACK returns the
metadata consumer. The generic `Result.Err` path remains paid; early Source
and permission checks, post-generator cancellation/revocation checks and the
separate authorized workspace-application root are unchanged.

This changes only `agent_product/src/plugin_file_plan_service.cj` relative to
E1555. Source proof:
`e7bc3d91e93b666775079161afbc93b3855d6a5c658bab571ce159aec0a26701`.
E1558 below completes that original Core verification and still fails.
Neither a returned error nor callback completion is DATA acknowledgement.

Public `f0e63eb` behavior and pass counts are unchanged. Complete Core,
remaining ownership paths, application flows, the original five-second gate,
matched baseline and final-source release remain open.
**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Actual input retirement, preview ACK and inline transport gap

E1559 observes the exact E1556 ELF at current locked instructions. Its 560
input events show **40 actual graph clears and full input-lease closures**,
24 opaque descriptors kept paid, and no closed input missing independent
metadata. Returned original invoices total 6,329,128 bytes; retained identity
invoices total 530,624 bytes. Those are owner invoices, not a measured bank
refund. The earlier missing-control path is repaired; complete Core still fails.

### Concrete failed-preview output and actual retirement

E1558 rebuilds E1557 in 287.170 seconds. Original complete Core then exits one
in 90.585 seconds at the same completed-child Receipt prerequisite, ending in
`read_view.output_capacity`; no stack-overflow trace occurs. Its frozen ELF is
`4068e5cf93e8bbf8305134aab7eb6f009ba010211e196a81f0bd8226215f15d4`.
The native library remains
`36ca7f5f003c1136239f64cde95195b7371beaf4acafcafb355526a5363ee790`.

Actual before/after canonical records preserve every original typed field for
five failed previews: invalid path, path-byte limit, stale precondition,
existing create target and unavailable artifact store. Every corresponding
operation/outcome remains failed and each output has `is_error: true` with the
original service error code. Four errors now use the existing flat failed
`ToolResult` representation instead of the generic nested error wrapper. This
is error-contract evidence, not proof of DATA return or complete Core success.

E1560 observes that exact ELF. The reviewed exact file-plan payload callback
performs **11 real metadata-consumer decrements** to zero; producer-return is
still false at those ACKs. Separately, **110 observed metadata graph clears and
successful payment closes** occur after the owner retirement guards pass.
ACK and complete DATA retirement remain distinct. One observed collection has
unknown/raw custody, zero consumers/headers and a retained invoice of 271,176
bytes; it stays paid. This is not a complete live-owner inventory.

The actual instruction observations have no capture errors. At the locked
refusal, all three observations below retain capacity 150,994,944 bytes,
incremental growth 12,582,912 bytes, four message groups and four fixed buffers:

| Observation | Charged bytes | Overshoot bytes |
| --- | ---: | ---: |
| E1559, control inheritance | 139,672,780 | 1,260,748 |
| E1560, concrete preview output | 139,014,068 | 602,036 |
| E1561, raw-export origin | 139,014,628 | 602,596 |

Each diagnostic driver succeeds but its actual Core inferior exits one.
Cross-run subtraction is not a refund measurement. E1558–E1561 each preserve
four actual Stores and twelve unchanged raw images; separate-copy canonical
checks and actual process/observer custody checks pass.

### The remaining observed raw path is an actual inline invocation

E1561 records 70 raw exports with exact native caller chains and no capture
errors. The actual chain enters `executeLegacyActualFrame204`, ordinary input,
readonly delegation validation and the service broker's raw plan/call access.
The separate artifact-store-failure Product has a canonical Program root with
no `input_attachment`: its workspace read and process child complete, preview
fails, and Run completes. The unchanged fixture explicitly sets
`inputAttachment: false`. This is not the previously withdrawn schema-query
experiment.

The private owned readonly lane only admitted attachment-present plans.
E1562 generalizes that same Native/observer lifetime to inline input; existing
attachment acquisition, full working invoice, validation, file close and
actual ACK still apply when an attachment exists. No dummy attachment, new
payer, fixture change or callback-return refund is introduced. The helper and
its callers cut over from attachment-specific to invocation names.

This identifies an ownership coverage gap, **not its attribution to the
refusing bank**. The observations do not correlate the separate Product's
metadata owner with that bank; equal invoices are not object identities.

E1563 stops during compilation because the helper lacks its existing `yjson`
extension import. It runs no Core inferior. An earlier direct driver invocation
also failed before compilation because the required isolated wrapper was
omitted; both failures are retained. E1564 changes only that import relative
to E1562. Its 2,662-input source proof is
`ec42713a8cf063156fd2919fbe36e84bd8c49800ad1efa44ff003e58de34d0de`.
E1565 builds in 297.262 seconds, then original complete Core exits one in
90.389 seconds at the same completed-child Receipt prerequisite with
`read_view.output_capacity` and no stack-overflow trace. Its frozen ELF is
`aeab2ea54a8bdc8fc2362485c74811df27818437eba6be3388a0b5b1eca17bb1`.
The original fixture, SDK, native library and all limits remain unchanged.

E1566 observes 66 private input loans: 41 actual graph clears/full-lease closes
and 25 opaque inputs retained. It records 111 actual metadata graph/payment
closes, 11 exact file-plan payload ACKs and zero Raw-export markers at the
installed current `holdUnknown204` instruction. This is not a universal Raw
access or live-owner inventory claim. Its locked refusal still has capacity
150,994,944, occupancy 139,091,828 and incremental growth 12,582,912 bytes:
overshoot **679,796**. No cross-run subtraction is a refund measurement.

The new same-stop live-owner snapshot fails an unlocalized assertion, so
E1566's diagnostic as a whole is incomplete. E1567 explicitly stops every
thread before snapshotting, then fails while reading a registry reference;
its phase and traceback are retained. It provides no owner/bank attribution.
This debugger reader failure is not an inferior GC crash. E1567's separately
valid locked refusal records occupancy 139,091,484 and overshoot 679,452 bytes.
The actual inferior still exits one. Exact fixed-SDK reference-barrier ABI is
being inspected read-only; no runtime call, build or replacement is authorized.

E1565–E1567 each preserve four actual Stores and twelve unchanged raw images.
Separate-copy canonical checks and process/observer custody checks pass.
No public or complete-Core pass is credited.

Retained evidence:

- `metadata1558-preview-failure-core/summary.json`,
  `failure-classification.json` and `preview-error-comparison.json`;
- `metadata1559-readview-control-observation/current-conclusion.json`;
- `metadata1560-preview-actual-ack/current-conclusion.json`,
  `file-plan-payload-callback-binding.json`, current disassembly and
  `observed-boundaries.json`;
- `metadata1561-last-raw-metadata-origin/current-conclusion.json`,
  `observed-raw-origins.json` and `canonical-analysis/projection.json`;
- `metadata1563-inline-readonly-core/summary.json`, `build.log` and
  `preflight-correction.json`;
- `metadata1565-inline-readonly-core/summary.json`, `failure-classification.json`
  and `canonical-analysis/projection.json`;
- `metadata1566-refusal-live-owner-ledgers/current-conclusion.json`,
  `exact-boundary-binding.json` and current disassembly;
- `metadata1567-all-stop-owner-ledgers/current-conclusion.json` and
  `derived-input.gdb`.

Public `f0e63eb` behavior and pass counts remain unchanged. Complete Core,
remaining opaque ownership, application flows, the original five-second gate,
matched baseline and final-source release remain open.
**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Frozen refusal core establishes same-stop bank identity

E1568–E1569 resolve the debugger-reference limitation without changing product
source or the fixed SDK. **Complete Core still fails; no public pass is added.**

E1568 binds the installed runtime ELF, native virtual tables and read-barrier
instructions. E1569 runs the unchanged E1565 Core ELF through the isolated
`metadata1569_frozen_refusal_core.py` driver with the original 900-second bound.
At the actual locked refusal, the debugger stops all threads and saves one
868,587,336-byte core. This is a diagnostic snapshot, not a crash core.
The inferior subsequently exits one at the existing completed-child Receipt
prerequisite.

The snapshot binds `IdleBarrier → CollectorProxy → WCollector`. The first
offline decoder rejects a ghost-region reference instead of blindly clearing
its tag. The completed decoder follows only already-completed forwarding
routes. It checks cached live-prefix counts against the saved bitmaps.
All 284 reference reads resolve: 6 untagged, 273 tagged non-ghost and 5 forwarded.
No inferior function is called, and no heap or runtime state is written.

The same snapshot contains 66 input owners and 3 Prepared metadata owners.
Forty-one input graphs have actually returned; their identity payments remain.
Twenty-five opaque input graphs remain paid. All three metadata producers
have not returned, so none is claimed retired.

The four decoded ledgers reference the actual refusing bank. E1570 resolves
their live lease maps; E1573 matches payments to holder registries. IDs apply
only within this frozen snapshot.

| Ledger | Live invoice SUM, bytes | Charged high-water, bytes | Input owners | Metadata owners | Live leases | Leases matched to holder registries |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 13,270,592 | 16,777,216 | 2 | 3 | 164 | 42 |
| 2 | 20,260,096 | 33,889,080 | 61 | 0 | 298 | 211 |
| 3 | 5,384,736 | 16,877,244 | 3 | 0 | 51 | 31 |
| 4 | 67,263,616 | 71,457,920 | 0 | 0 | 4 | 0 |

The requesting frame holds ledger 4's mutex. Its lease 8 currently invoices
zero and requests the original 16,777,216-byte message invoice. The wanted SUM
is 84,040,832, so the actual bank growth is 12,582,912 bytes. At that decision,
bank occupancy is 139,091,572 of 150,994,944 bytes: overshoot **679,540**.
Four message slots and four fixed-buffer reservations are live.

The observed ledger high-water total is 139,001,460 bytes. The remaining
90,112 bank bytes are not attributed to particular holders merely by
subtraction. Fixed-buffer holders and the original funding/high-water stacks
still need correlation. The difference between live SUM and high-water is
not refundable under the existing contract. Registry and owner locks were
not acquired; this is not an allocator-wide owner inventory or a leak finding.

The fixed runtime SHA-256 is
`99b4841d0ce313a7ca9081af9daa30245d41bbeb6dd04574e37c8bbd7e136c9a`.
The core SHA-256 is
`f3428609d2e3ec362dabaeb8588855b26e81b3cce17e2c44f4f0192e695673aa`.
Source remains E1564 and consumer ELF remains E1565. Four actual Stores pass
separate-copy checks; twelve retained raw images keep their recorded hashes.
Actual process custody closes, the observer thread returns, and all observer
file descriptors close.

Evidence is retained in `metadata1568-fixed-reference-abi/binding.json` and
`metadata1569-frozen-refusal-core/`: `summary.json`, `snapshot.json`,
`capacity-refusal.core`, `owner-ledger-routed.gdb`,
`same-stop-owner-ledgers-routed.json`, `resolved-forwarding-fields.json`,
`current-conclusion.json`, `raw-image-verification.json` and
`canonical-analysis/projection.json`. The rejected first decoder and its error
remain alongside the successful offline decode.

E1570 reads the actual HashMap buckets and live entry chains using the pinned
collection ELF's layout. All 517 live invoices, plus each entry's original
1,024-byte header, reconcile exactly with their ledger SUM. All 69 original
input/metadata payments match current map entries; requester lease 8 matches
the locked refusal frame. Ledger 4's 67,108,864-byte lease is not assigned a
holder merely from its amount.

E1571–E1573 traverse concrete model, snapshot, Tool and Host holder fields
from this consumer's type metadata. Class field offsets include the verified
8-byte object header. They match **284 distinct same-bank leases**, including
103 copied external-text owners, 17 escaped mounted-descriptor graphs and
62 catalog declaration holders. The remaining 233 leases lack holder-registry
attribution; the requester's frame identity is separately established above.
One Catalog consumer belongs to another bank and is excluded from these totals.

The observed model request is unexported but not retiring. Three older shared
snapshots each retain a share. Mounted-descriptor graphs have escaped, and
catalog identities retain configuration aliases. None of these observations
proves DATA return. E1574 separately reads the legacy copied-graph ArrayList
using the exact SDK accessors: it is empty at this stop, which does not remove
the escaped graphs in the mounted-descriptor registry.

These checks use the retained E1569 core only: no new fixture execution,
inferior calls, SDK changes or refunds. Evidence includes `binding.json` and
the decoder/output in `metadata1570-frozen-lease-map/`,
`metadata1571-frozen-owner-roots/`, `metadata1572-frozen-host-tool-roots/`,
`metadata1573-frozen-nested-registry-holders/` and
`metadata1574-frozen-legacy-graph-list/`. The last directory also retains the
exact collection accessor disassembly.

Public `f0e63eb` behavior is unchanged. Complete Core, remaining ownership,
application flows, the original five-second gate, matched baseline and
final-source release remain open.
**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Pinned identities resolve the actual fixed-buffer charges

E1575 verifies that this consumer's bank, shared-ledger and fixed-token
constructors allocate their immutable Mutex fields through the installed
runtime's pinned-object entrypoint. Observed constructor epochs distinguish
reuse; arbitrary moving object addresses are not lifetime identities.

E1576 executes the unchanged E1564 source/E1565 ELF under a numeric-only
observer and saves another core at the locked refusal. Offline reference
decoding binds four live ledgers and four fixed reservations to that bank.

| E1576 snapshot ledger | Observed birth epoch | High-water bytes | Live SUM bytes | Live leases |
| --- | --- | --- | --- | --- |
| 1 | 27 | 16,777,216 | 13,270,592 | 164 |
| 2 | 1 | 33,889,208 | 20,260,208 | 298 |
| 3 | 13 | 16,877,292 | 5,384,752 | 51 |
| 4 | 28 | 71,457,920 | 67,263,616 | 4 |

Their high-water total is 139,001,636 bytes. Actual fixed reservations add
90,112 bytes, exactly matching the bank's 139,091,748-byte occupancy:
a 65,536-byte `HostArtifactStore.openServiceArtifactWriter` buffer used by
`HostToolInputAttachmentSession.stageFrame204`, and three 8,192-byte
`JavaScriptExtensionHost.readLine` handshake buffers. Their observed births,
pinned identities and sizes match the frozen inventory. All 174 fixed-buffer
charges in this execution subsequently reach actual bank-release commits.
This attributes charges, not DATA retirement or a leak.

The high-water **history capture is incomplete**. The observer tracks shared
`ensure` growth but omits `derive` header growth. Sequence 77 records an actual
1,024-byte `derive` charge; sequence 79 then fails the stale expected-cost
assertion. The original output retains 94 attempts, 94 commits and 10,404
diagnostic errors, including secondary missing-attempt errors. This partial
history cannot identify the final peak's original funding stacks.

Complete Core still exits one. Four canonical Stores pass separate-copy
checks; actual process custody closes, the observer thread returns and all
observer descriptors close. The saved core is 865,660,528 bytes, SHA-256
`745d13a021a4da4e364e83da6e3a7ab2e8ad1bfa69014b17cfa1e722b4347e9d`.
It is a debugger-generated refusal snapshot, not a crash classification.

Evidence: `metadata1575-fixed-mutex-identity-abi/binding.json` and
`metadata1576-growth-history-core/`, including `current-conclusion.json`,
`summary.json`, `growth-history.jsonl`, `growth-state-at-refusal.json`,
`growth-symbols.json`, `decoded-owner-ledgers.json` and the retained core.
The fixed SDK, original bank, floor, invoices, SUM/high-water rules, permissions
and actual ACK requirements are unchanged. Public `f0e63eb` behavior and pass
counts are unchanged. Complete Core and the remaining acceptance work stay open.
**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

E1577 binds the omitted `derive` caller and the standalone reservation caller
to this exact consumer's machine code. Corrected diagnostics must retain raw
attempts, commits and refusals before cross-event assertions; deriving a header
must not be mistaken for unexplained accounting growth. This is a diagnostic
correction, not a product fix.

## Complete growth capture locates the remaining cancellation failure

E1578 corrects the observer without changing E1564 source or the E1565 ELF.
It records 5,296 attempts, 5,295 actual bank-charge commits and one refusal,
with zero capture errors or pending growth records. Caller attribution covers
5,254 shared `ensure` calls, 37 `derive` header calls and five standalone
reservation calls. Raw observations precede cross-event assertions.

Offline decoding of this new core matches all four surviving ledgers to their
observed pinned constructor epochs. Their historical charges total
139,001,204 bytes; the four actual fixed buffers add 90,112 bytes.

| E1578 bank capacity | Charged at refusal | Actual requested growth | Overshoot |
| ---: | ---: | ---: | ---: |
| 150,994,944 | 139,091,316 | 12,582,912 | 679,284 |

The original Registry ledger's 33,888,848-byte peak ends at
`FixtureRequestSnapshot159.beginObservation159`, after a 1,268,000-byte
request copy. The surviving Store ledger peaks at
`StoredValuePaymentMeter.operationPlanHeader240`; the current invocation
ledger peaks at the original package-inspection working invoice. These are
actual funding stacks, not assignments inferred from equal floor amounts.

This execution reaches `runProgramCancellationRecoveryContract`, after the
earlier Product's explicit `close()` and the native-read cancellation helper.
It fails **“cancellation starts only after child one has a completed durable
Receipt”**. The current independent Product is observed at ledger birth epoch
27. The old Registry ledger still has 298 live leases, including three
single-share snapshots. Neither Product closure nor those share counts
acknowledge opaque Contexts or public exports.

Complete Core still exits one. Four canonical Stores pass separate-copy
checks; all twelve retained original-inode images match their recorded size
and hash. Actual process custody, the observer thread and all observer file
descriptors close. The 867,290,736-byte core has SHA-256
`295be2f118d3b511ff20001938561cc822c88eb07cd368a895bafb1804d68d88`.

Evidence is in `metadata1578-complete-growth-core/`: `current-conclusion.json`,
`growth-history.jsonl`, `surviving-ledger-funding.json`,
`decoded-owner-ledgers.json`, `raw-image-verification.json`,
`canonical-analysis/projection.json`, `debugger.log` and the retained core.
The incomplete E1576 capture remains intact.

E1579 is a separate **unaccepted fixture-only candidate**: before each of the
six independent prohibited-Program scenarios, it calls the existing
`FixtureModelPort.retireLastRequest159()` for the prior observation copy.
No request probe crosses that boundary. The existing API clears only eligible
private cached data; exported or active observations remain paid. Product
source, scenario inputs and every assertion are unchanged. This does not
change ordinary model-cache replacement semantics, retire opaque Contexts or
establish a general Product-capacity fix.

Public `f0e63eb` behavior and pass counts remain unchanged. Full Core,
remaining application flows, the original five-second gate, matched baseline
and final-source release acceptance stay open.
**Not complete; GC user-deferred with zero pass credit; PR #49 Draft.**

## Workspace preserves a failed read-view Receipt before worker launch

E1580 rejects the E1579 fixture-only change. The rebuilt Core consumer
(`9c550669a58a52111f1e2c3c9be778102c709bf939de72af0cae59ce5a1f9f21`)
still exits one at the first durable child Receipt prerequisite. Four separate
Stores pass `quick_check`; all twelve original DB/WAL/SHM images retain their
hashes. In the cancellation Store, `host.process.readview` has a **failed**
Receipt with `read_view.output_capacity`. Its Workspace parent instead reports
`workspace.protocol` because it tried to parse worker stdout; the host had no
worker output to return. The Program records `tool_program.subcall_failed`.
The unmodified assertions correctly reject that sequence. The fixture change
is not promoted.

E1581 fixes the diagnostic in `plugins/workspace/src/protocol.cj`. After
checking the service, request and Receipt identity and the negotiated size
bound, Workspace returns the host error code and bounded message when a
failed receipt supplies no worker stdout. A worker transcript still goes
through the original parser. Neither result can turn a failed Receipt into
success or authorize a retry.

The fixed-SDK package build used the locked local search engine. Six real
packaged protocol cases passed: host denial without stdout, successful worker
read, edit with two Receipts, missing Receipt, truncated worker, and transport
failure. Packaged Workspace ELF:
`8410089e8c0a189ffa4a7a8f665977bcbc6b0c8ce1258ddf772491fbd9e47f90`.
Both build and test process-custody checks passed. Evidence:
`workspace1581-failed-readview-receipt/{summary.json,wire.log}` and
`metadata1580-fixture-observation-core/canonical-analysis/projection.json`.
This is a Workspace protocol fix, not a Core capacity or distribution pass.

## Program cancellation, CLI startup and the current Coding package

E1582 reduced the private fixture's Registry reads to the three descriptor
fields it uses. The original complete Core executable still exited one:
the cancellation Store recorded `read_view.output_capacity` before the first
child could complete. Four Stores passed `quick_check` on separate copies.
All twelve original images kept their sizes and hashes. The fixture change
is not promoted. Evidence: `metadata1582-projected-binding-core/`, ELF
`0a527300bb53c5a42cf45af1b164055efe23502b011bd196d92e709307ed9e8b`.

E1583 ran the unchanged `scripts/cold_start_gate.py` on the packaged
baseline (`4d88fa60`) and candidate App. Each arm started 100 fresh
processes under the same environment and checked the exit code and exact
version string. The baseline ran first. The OS page cache was not reset.

| `--version` wall time (ms) | P50 | P95 (nearest rank) |
| --- | ---: | ---: |
| Baseline | 79.469 | 97.612 |
| Candidate | 63.363 | 72.718 |

This command exits before Product configuration, plugin activation or a
model request. `matched1583-package-cold-start/` retains all 200 samples and
both process-custody records.

E1584 ran `scripts/package_candidate.sh` from archived public source
`31ca034b1f` with the fixed SDK. The production App and all 717 inputs in
its build record matched. The producer rebuilt all nine Coding plugins.
The relocated clean-environment and setup checks passed, as did all 44
Workspace package tests on the **shipped** plugin. The packaged App has
the same hash as the E1583 candidate:
`5678c1a0d611f1617068f40dd558b611839e50f7b64f415955c51ee2241c57a1`.
The shipped Workspace ELF is
`1aba218c859db0fcc2b5114db88be8344710face5b5ead0ae7154c54a1595e4a`.
See `release1584-current-coding/{summary.json,workspace-all.json,workspace-all.log}`.
These results do not close the five-second model request or the full release.

E1585 fixes the cancellation fixture's Workspace collision in `4fac5a49e1`.
The preceding Product installs plugins at Workspace scope. The cancellation
Product now copies its two real read inputs into a separate Workspace
instead of trying to install over the first Product's records.
`--program-cancellation-recovery-contract` exercises this boundary after
a real prior Workspace installation. It passes with the original timeouts,
SQL assertions, worker-directory cleanup and process census. The cancelled
Run retains a completed `workspace.read` child and its completed
`host.process.readview` receipt. The second read is rejected with `run.cancelled`.

The same public-source ELF
(`a54666c37588037970e1fa763130f28137b56f5f53c789515aafa38b9560f293`)
**fails** `--core-and-recovery-contract` earlier. The model-selected read-only
Program has a failed `input_attachment.capacity` Receipt. No layer between
the model and the worker was skipped. The four distinct Stores from these
two runs passed `quick_check` on analysis copies, and all twelve original
images match their recorded sizes and hashes. See
`public1585-cancellation-core/{summary.json,canonical-analysis/projection.json}`.

E1586 ran the original `plugin_performance_baseline/check.py` on both sides
under an exclusive measurement lock. The two arms used the same SDK, package
and fixture path roles, and fresh operator state. The baseline's annotated
dependency tag resolves to the same source commit used by its normalized
lock. Both arms passed the original investigation ceilings. Times below are
milliseconds, and RSS values are bytes. P50 and P95 use nearest rank.

| Metric | Samples per arm | Baseline P50 / P95 | Candidate P50 / P95 |
| --- | ---: | ---: | ---: |
| JS extension cold activation | 12 | 56.809 / 110.807 | 56.123 / 66.876 |
| First call | 12 | 2.127 / 3.219 | 9.394 / 10.204 |
| Steady IPC | 240 | 2.353 / 10.007 | 10.010 / 10.071 |
| Extension worker RSS | 12 | 18,268,160 / 29,376,512 | 15,278,080 / 20,828,160 |
| Cancellation including 100 ms trigger | 12 | 125.310 / 132.193 | 124.166 / 138.010 |
| Fixture `/help` | 20 | 162.251 / 193.909 | 449.084 / 472.143 |
| Fixture `/help` peak RSS | 20 | 90,288,128 / 90,988,544 | 51,048,448 / 51,613,696 |
| Declarative plugin inspect | 20 | 152.027 / 204.434 | 468.504 / 496.808 |
| Declarative plugin inspect peak RSS | 20 | 90,304,512 / 90,927,104 | 51,154,944 / 51,621,888 |

First-call P95 and both Product startup P95 values were higher in this
candidate sample despite passing the ceilings. These single-host results
do not measure default Native Coding activation or establish a cause.
`matched1586-plugin-performance/{baseline,candidate}/summary.json` binds the
runtime executables, packaged Apps, original results and process-custody
checks to their respective arms.

### Concurrent extension calls, progress and physical worker return

E1587 measures two real JS extension workers using the same echo fixture.
Each arm runs 12 overlapping call pairs at each payload size. Each worker
must return its own exact bytes and one progress event. The close timer
starts with the worker PID present and ends after close with that PID absent.
Measurements are nearest-rank P50 / P95 in microseconds.

| Bytes per worker each way | Metric | Samples per arm | Baseline | Candidate |
| ---: | --- | ---: | ---: | ---: |
| 256 | Pair completion | 12 | 3,936 / 10,200 | 10,055 / 10,138 |
| 256 | First progress | 24 | 1,504 / 1,909 | 557 / 1,345 |
| 256 | Normal close and reap | 24 | 6,020 / 11,629 | 19,994 / 27,698 |
| 32,768 | Pair completion | 12 | 90,153 / 119,378 | 5,464 / 10,128 |
| 32,768 | First progress | 24 | 2,275 / 3,332 | 1,488 / 2,247 |
| 32,768 | Normal close and reap | 24 | 6,714 / 14,880 | 17,496 / 27,978 |

Candidate close-and-reap P95 was higher at both sizes; 32 KiB pair completion
P95 was lower. The candidate returns its payload only after checking it.
Process exit is not a DATA acknowledgement. These measurements do not time
cancellation-to-reap or default Native package activation. Raw pairs and
per-arm identities: `matched1587-output-reap/{baseline,candidate}/`.

### Fresh packages, Core caller return and Todo save approval

**E1588 — package acceptance.** `scripts/package_candidate.sh` produced fresh
Minimal (zero plugins) and Full (17 plugins) packages from `e904dd5`, using
717 host inputs matched to the E1499 production receipt. Both passed
`package_candidate_clean_env`. Minimal passed all six cases in
`minimal_empty_host_contract`; Full passed `setup_blackbox`. All six stage
receipts record physical process return. Packaged ELF SHA-256:

| Package | SHA-256 |
| --- | --- |
| Minimal | `d55eb1f3e1b3916fe600165962bd181da35f45ada18752d4be66c75df232dbd7` |
| Full | `5678c1a0d611f1617068f40dd558b611839e50f7b64f415955c51ee2241c57a1` |

Evidence: `release1588-minimal-full/summary.json` and per-stage logs. These
checks do not prove model connectivity, complete Product or baseline parity.

**E1589 — Core input ownership.** At `95104ca`, the matched Program fixture
holds all seven paid requests through the three comparison pairs and the
missing-read case. After the caller and SQL reader return, it checks that
each owner's DATA is still held, sends the actual caller acknowledgement and
checks that DATA has returned. An exception does not send an acknowledgement.

The rebuilt executable (`21eb91259d79123fb6f33c4f4c0ed7a9a44ae40c636890404e9fe354a8482282`)
ran the original complete Core fixture with the E1585 plugin identities. All
seven ownership checks passed. The aggregate still exited 1. The main Store
has 35 Runs and 69 Operations; the artifact-failure Store has one Run and
four Operations. Both passed `quick_check` on analysis copies. The
model-selected Program's root reported partial failure: `workspace.grep` and
its derived `host.process.readview` failed at `read_view.output_capacity`.
No Operation in this execution reported `input_attachment.capacity`. The
Run's completed state does not override its failed receipts. The first
output reservation precedes worker channel creation; the receipt alone
does not identify its billed amount or justify a refund.
Evidence: `public1589-matched-caller/{summary.json,complete.log,canonical-analysis/projection.json}`.

**E1590 — historical Todo timeout.** Read-only analysis of the first two
Runs in the original E1047/E1048 operator stores isolates the difference to
the second Run's save approval. Both used Coding ELF
`0fb47ce2d99fbb30501394c28653b8ee0c94018d7528afee14a7972914d880af`;
both completed the preceding user-approved `host.context.read`.

| Save observation | Original timeout | Passing control |
| --- | ---: | ---: |
| Entered `waiting_approval` after Run start | 726 ms | 508 ms |
| Time in that approval wait | 33,028 ms | 4 ms |
| Save execution handoffs | 0 | 1 |
| Document operations | 0 | 1 |

The failed save had a cancelled receipt and no approval decision. The
control had user approval and a completed revision-1 document. The
33,028 ms interval is a journal interval, not the outer 45 s TUI deadline.
The stores cannot establish whether the UI sent or received the final key.
Later runs on the same operator home were excluded. All six original
DB/WAL/SHM hashes remained unchanged; both analysis copies passed
`quick_check`. Evidence: `todo1590-historical-approval/journal-boundary.json`.

### Read-view budget refusal and first-request approval

E1592 (`80e47d24`) returns four more direct fixture requests after their
callers finish. The reopened store uses only the Run ID. The eleven caller
acknowledgements pass; the complete aggregate still fails inside
`workspace.grep`. Evidence: `public1592-four-callers/`.

E1594 captured the E1592 executable at the first refused output reservation.
Under the bank lock, `LogicalJsonOwnerBudget.acquire` requested 16,777,216
bytes for a 131,072-byte raw output limit. The bank had charged 146,961,488
of 150,994,944 bytes across four slots. The request exceeded capacity by
12,743,760 bytes. No fifth slot was created.

Two request owners remained at that stop. Their Run IDs matched the
`durable-product-program-thread` and `e5-03-authorize-valid` store rows.
The first still had a Core frame and a consumer. The second had neither,
but lacked an application acknowledgement. The fixture submits on one
application session and approves on another. The resumed session cannot
acknowledge the original session's DATA. All 55 inspected Prepared metadata
owners recorded an unknown consumer. None of these observations authorizes
a refund. Evidence: `public1594-readview-refusal/`.

E1595 returned an executor error for the known refusal. That prototype
incorrectly produced an unknown child outcome and was discarded.
E1596 (`d0e8e2ae`) reports a failed tool result before `openChannel` and
requires cleanup before publishing it. The canonical child Receipt now
records `read_view.output_capacity`, `budget_exceeded`, `retryable=false`
and `fallback_allowed=false`. Both ancestors record failure. The main store
contains 35 Runs and 69 Operations; the artifact-failure store contains one
Run and four Operations. Both analysis copies passed `quick_check`, and all
six original images kept their hashes. The complete aggregate exited one.
Evidence: `public1595-readview-category/` and `public1596-readview-prelaunch/`;
final Core ELF `eb20e2cd3883d6f064c2bfccb8dded7d29e58b0b0d9944626d770c53d931c33a`.

E1593 measured 12 cancellations per build with identical extension bytes,
a 100 ms cancellation trigger and a 4 s invocation deadline. Each call
reported progress with a live worker, returned `process.cancelled`, and had
no worker PID at return. The post-close check observes absence; it does
not timestamp the worker's exit. Evidence: `matched1593-cancellation-reap/`.

| Time from cancellation trigger (µs) | Baseline P50 | Baseline P95 | Candidate P50 | Candidate P95 |
| --- | ---: | ---: | ---: | ---: |
| Typed return | 17,672 | 27,519 | 20,042 | 40,081 |
| First PID check after close | 17,683 | 27,533 | 20,056 | 40,101 |

E1597 used the E1584 Coding package and a copy of the E1486 operator's
245 durable files. The installed package lock and service grants remained
unchanged. With loopback-only networking, the original five-second
`invoke` returned after 4.52 s with `approval required`. The canonical
Operation requested `host.context.read` for the Skills provider. Its Receipt
was cancelled with no approval decision. There were no model attempts or
HTTP requests, and the second profile did not run. Evidence:
`profile1597-existing-operator/`. This is a separate failure from the E1486
timeout and the E1500 fresh-setup GC crash.

### Production packages, terminal flows and the two first-request failures

E1598 built all nine production targets at `d0e8e2ae` using the pinned
toolchain. E1599 assembled three fresh distributions from those outputs.
All three passed the clean-environment check. Minimal passed all six
empty/offline cases; Coding and Full passed setup. All build and package
stages returned with physical process custody closed. Evidence:
`public1598-production/summary.json` and `release1599-production-packages/summary.json`.

| Package | Bundled plugins | Packaged ELF SHA-256 |
| --- | ---: | --- |
| Minimal | 0 | `614cc4a1a9451a04474e90ac91bb3c4a30e68d95e8bdba399930cd993a538bff` |
| Coding | 9 | `4b1d7cc06afa0209b9b11335ba892163e9c15fbce58887eb716ec9c063821b47` |
| Full | 17 | `4b1d7cc06afa0209b9b11335ba892163e9c15fbce58887eb716ec9c063821b47` |

E1601 passed all ten original real-PTY scenarios on the E1598 application
(`cca7ae89bb7da4046187d095d61e1473738f3acd92b1248e80054d14ae019f67`).
They exercised Responses, Completions and Messages streaming, cancel and
Ctrl-C with recovery, HTTP error, timeout, incomplete EOF, invalid UTF-8
and an MCP tool. The local servers ran in an isolated network namespace.
The process receipts, terminal output and snapshots are in
`pty1601-final-production/`. No mouse or resize case was run.

E1602 compared two copies of a nine-plugin operator home, starting from the
same 245 files. Only the workspace arm changed `plugins/context.json`; both
retained the same installed packages, read scopes and service grants.
The original `invoke` ran against the E1599 Coding executable.

| First request | Default Skills | Workspace-only Skills |
| --- | --- | --- |
| CLI observation | `approval required` at 3.913 s | Original 5 s timeout |
| Context-read Receipt | Cancelled, no approval decision | Completed; context safe cut committed |
| Model attempt | None | Created, dispatch state `prepared`; no dispatch timestamp |
| HTTP and second profile | Neither reached | Neither reached |
| Physical custody | Closed | Five surviving descendants required exact-PID cleanup; none remained afterward |

The workspace arm's journal records `running → failed` and a nonretryable
`runtime.run_stale` diagnostic before any dispatch claim. The guard checks
the Run ID, epoch, settlement and cancellation; this diagnostic alone does
not distinguish them or establish their ordering relative to the CLI
timeout. Both database analysis copies passed `quick_check`. Evidence:
`profiles1602-final-coding/`, including `durable-timepoints.json` and the
workspace arm's `pre-dispatch-diagnostic.json`. This is not a Provider
connection failure or a successful alternative default.

### Memory seed, first-request deadline and Todo first save

The original Memory seed failed inside `JsonDirectWriter.finishString`,
before application startup: it requested 66,060,790 bytes when the largest
contiguous block in the fixed heap was 65,097,728 bytes. `46b15c25` changes
the test fixture, not application storage. The writer streams into one byte
buffer, SQLite binds it as TEXT, and the same transaction copies the event
at the exact revision to the current-state table. The test checks storage
class, exact escaped Unicode and the entire 66,060,288-byte body in both
tables; equality of two truncated copies would not pass.

The first single-stage build hit its original 900 s limit and earns no
credit. E1603 built all six stages separately under their existing limits.
Product ELF `3c35fa81547156fbfdd8a6dfc8dbed9da91cefd2508228ea03c7bf709cf9c6c6`
enumerated 1,099 cases; the seed test passed in 4.87 s, with 1,098 skipped.
Evidence: `memory1600-oracle-seed/` and `memory1603-staged-seed/`. The
GC-deferred application workflow was not rerun.

E1604 correlated passive syscall timestamps from the original five-second
`invoke` with the workspace-only operator's durable rows. Relative to entry
into `invoke`, Run creation occurred at +3,867 ms, context handoff at
+4,235 ms and the completed context-read Receipt at +4,559 ms. The first
SIGKILL was sent at +5,001 ms; the Run recorded cancellation at +5,047 ms.
There was no context safe cut, model attempt, dispatch or HTTP request in
this sample. All observed descendants exited. Evidence:
`profiles1604-time-boundary/workspace/correlated-events.json`.

E1605 ran the E1599 Coding package with the original headless golden gate.
Cards and ask passed on a fresh home. Initial prompt passed on an installed
operator copy with one completed Run, context read and model attempt. A
copy already containing Todo revision 1 was rejected by preflight, before
launch. A different installed operator had six historical Runs and no
document; the first save on its copy took 7.30 s, added two completed Runs
and six completed Receipts, recorded four approvals, and created revision
1 without a model attempt. The source operator was unchanged. Evidence:
`golden1605-final-coding/`. These results do not replace E1601's PTY checks
or explain the earlier 33 s pending approval.

### Current Product cases and matched Coding performance

E1606 selected the 500 previously passing Product identities on the E1603
ELF and 17 actual Native packages. The first run passed 485 cases. Twelve
others faulted at offset `0x637f21` in `MapleRuntime::CheckAndPush`. Three
traces also name a GC phase. For the other nine, the fixed Runtime hash
matches E1509's four GC-phase call sites; this is static attribution of
the leaf, not a recovered stack or a diagnosis of the corrupt reference.
Evidence: `unit1606-final-nongc/{summary,current-crash-binding}.json`.

The remaining three failures were missing physical-child checkpoints.
The private target contained plugin fixtures but no Product executable for
the recursive `cjpm test --skip-build`. E1608 mounted the actual E1603
unit target. All three original tests passed: committed context boundary,
pending approval and prepared model recovery after real child death.
Each has its own qualified case output and closed parent/worker process
receipt in `unit1608-recursive-target/`. The first parser rejected CJPM's
additional summary; its worker-only receipt was not used to certify parent
return. No product recovery assertion, time limit or database was changed.
Including the separate E1603 Memory test gives 489 passes on this ELF,
12 GC-deferred current failures and 598 not run, out of 1,099.

E1607 used the same baseline and fixed SDK as E1586, the E1599 Coding
executable, unchanged fixture bytes, a fresh home per arm and an exclusive
measurement lock. Both arms passed the original gate and returned their
processes. Comparisons below are P95; times are milliseconds.

| Metric | Samples per arm | Baseline | Candidate |
| --- | ---: | ---: | ---: |
| Extension cold activation | 12 | 46.633 | 48.365 |
| First call | 12 | 2.277 | 9.788 |
| Steady IPC | 240 | 3.387 | 10.075 |
| Worker RSS (bytes) | 12 | 29,413,376 | 20,938,752 |
| Cancellation including the 100 ms trigger | 12 | 127.439 | 130.052 |
| Fixture `/help` | 20 | 139.866 | 422.809 |
| Fixture `/help` peak RSS (bytes) | 20 | 94,150,656 | 50,552,832 |
| Declarative plugin inspection | 20 | 129.774 | 444.538 |
| Inspection peak RSS (bytes) | 20 | 94,220,288 | 50,663,424 |

The two `matched1607-final-performance/` arm summaries contain the P50s,
P95s, executable hashes and process receipts. Lower RSS and passing
absolute ceilings do not offset the observed latency regressions.

### Native Program scheduler refusal

E1609 exposed a false success in the original one-call Program budget scenario. The scheduler refused the nested read before admitting a child. The root tool wrote a failed Receipt, but the Run made a second model attempt and completed. The seven-call, one-slot control succeeded.

At `69635e1a40`, the host preserves the scheduler's typed refusal separately from worker output. A worker-supplied error string cannot set it. Both real request callers retain the original request custody when substituting the test budget. Each caller acknowledges its DATA only after its frame returns; the check requires both the application and Core returns.

| E1610 focused Run | Model attempts | Operations | Derived admissions | Outcome |
| --- | ---: | ---: | ---: | --- |
| Seven calls, one slot | 2 | 7 | 6 | Run completed; all seven Receipts completed. |
| One call, one slot | 1 | 1 | 0 | Run failed; root Receipt records `budget.tool_calls_exceeded`, limit 1, observed 2. No retry or fallback. |

E1611 ran the original unsplit `--core-and-recovery-contract` on the same ELF (`33648ea2feb62e235e039a9692b00ddf1b0f0c814af587fdb29fdebe5b097a59`). It failed earlier: `host.process.readview` reported `read_view.output_capacity`, and the grep and Program ancestors both recorded failure. The two stores contained 35 Runs and 69 Operations, and one Run and four Operations, respectively. Both analysis copies passed `quick_check`; all six captured source images retained their hashes. No change to the bank or DATA return rules. Evidence: `core1609-budgeted-caller/`, `core1610-scheduler-budget/`, `core1611-complete-scheduler/`.

### Program cancellation and Registry copy ownership

E1615 ran `--program-cancellation-recovery-contract` with the E1610 executable and the original installed Workspace fixture. The cancelled Run retained four terminal Operations: the first workspace read and its read-view child completed; the second workspace read was rejected; the Program root failed. The command returned successfully in 6.989 s. Nine original SQLite files across three stores retained their hashes; `quick_check` passed on the analysis copies.

A separate debugger run of the unsplit contract aborted in libc on `schmon` with `double free or corruption (!prev)` before the export breakpoint. Its store contained 13 Runs and 15 Operations. No export observation or GC call chain was captured. This run neither supersedes E1611 nor establishes a cause. Evidence: `pressure1615/`.

E1616 examined the existing E1594 refusal core, not a rerun. With one Product live, 248 Registry copy payments matched open leases in two ledgers of the refusing bank. Using the E1594 ledger IDs: 177 payments declared 1,786,304 bytes on ledger 1; 71 declared 713,664 bytes on ledger 2. None had an attached error list. The bank had 146,961,488 bytes charged and refused 16,777,216 bytes of growth against a 150,994,944-byte limit. The 2,499,968 bytes of *live* copy invoices are neither available for refund nor a measurement of their contribution to historical high water. Evidence: `registry1616-frozen/census.json`.

### Workspace-only Skills and the five-second request

`3997ee51ac` changes fresh Coding and Full recipes; it does not rewrite installed configuration. The version-4 host can select directory resources without inspecting installed components. The Skills worker can exclude its own packaged Skills without falling back to the process working directory. Queries that omit `include_packaged` keep their prior behavior. See [operator configuration and opt-in](../context-read-scopes.md).

| Evidence | Observable result |
| --- | --- |
| E1613/E1614 | Nine production build stages passed. Fresh Minimal, Coding and Full packages contained 0, 9 and 17 plugins respectively. All passed the clean-environment probe. Coding and Full passed setup; Minimal passed its six offline/empty checks. Coding and Full host SHA-256: `433c2d5d73398c465b5af3b77a71e737805980fa040689b251253e4b6fe3cb31`; Minimal: `1715996fc257b13c8ab032a748db665152dd8a03c72af0a3d14a7a51719f7ce5`. |
| E1614/E1617 | Each shipped Skills executable (`b19571768426c32fdd22e9701cbd43adb89cad27e9bd0a0f930d018d3b26e823`) passed 46 wire cases. The previous worker rejected the new field; the separately built current worker passed the opt-out and legacy default. The selected packaging suite passed 23 tests. |
| E1621/E1622 | The packaged Coding CLI read two distinct real workspace Skill bodies without planning a read of either settings directory. Disabling Skills prevented another model attempt. After explicit managed-directory selection, a read-scope grant and re-enable, the staged request contained the managed body, with a completed `host.context.read` Receipt on that path. Both configuration files remained byte-identical to the operator's edits. |
| E1612/E1618/E1620 | Two build attempts exhausted the existing 900 s limit. The exclusive incremental build finished in 355 s. Its Native Product ELF `c1877ddc4d4f568b862329cb3c704644cadca172ee89db0a4742529d149a4d99` enumerated 1,099 cases. All six focused cases aborted in the pinned runtime's GC reference visitor paths. None passed; the other 1,093 were not run in this check. |
| E1619 | Core ELF `16416bdd8f8f4542d99f6f0e1dd710f0d6b372a112b1392db6b03223384c392f` passed the originating-card replay assertions in `64d5bbb481`. It subsequently failed the unsplit contract at `read_view.output_capacity`. Its two stores had 35 Runs/69 Operations and one Run/four Operations. All six preserved SQLite file hashes remained unchanged. Replay rejection is not a DATA return. |
| E1623 | Against a short private settings path and writable workspace, the packaged CLI installed all nine defaults and the original grant setter succeeded. The first real-profile invocation exceeded the unchanged five-second deadline (5.003 s); the second was not reached. The non-fixture store had one cancelled Run, a completed context read and one safe cut, but zero model attempts. Both loopback listeners saw zero requests and their threads returned. The bootstrap fixture's separate successful attempt does not count. |

E1624 compared base `4d88fa6072` (Coding SHA-256 `a85907b7df0bb579ceb9b68339eadbc1c43b165616571187921bd6debd3af498`) with E1614 Coding on the pinned SDK. The original runtime fixture, paths, per-arm fresh state, deadlines and seven absolute gates were unchanged. Both arms passed. Measured P95:

| Metric | Base | Candidate | Samples per arm |
| --- | ---: | ---: | ---: |
| Extension cold start | 89.467 ms | 48.679 ms | 12 |
| First call | 2.337 ms | 9.784 ms | 12 |
| Steady IPC | 5.928 ms | 10.056 ms | 240 |
| Extension host RSS | 29,343,744 B | 20,877,312 B | 12 |
| Cancellation after 100 ms trigger | 127.378 ms | 130.147 ms | 12 |

Lower worker RSS did not erase the first-call and steady-call regressions. Full Core, Product, application-flow and release acceptance remain open. Private evidence: `prod1613/`, `release1614/`, `skills1617/`, `core1619-originating-card/`, `unit1620/`, `cli1622/`, `profiles1623/`, `matched1624/`.

### Distribution preflight and the dispatch boundary

`ca37b52342` retires descriptors owned by distribution preflight, including early refusals. It compares fields in place, still verifies package bytes, and requires all five named workspace tools and the single `process.readview` capability. No cross-startup verification cache, capacity increase or DATA acknowledgement was added.

E1625–E1635 used the implementation with LF checkout bytes (distribution source SHA-256 `e7519980010b7c02be1451d5d7b50ab53a606fcec3b6f6965c1f8b58b8b1a83d`). The committed source preserves the existing mixed line endings and is byte-identical after CRLF-to-LF conversion. E1628 also contains a private import-lifetime change and does not certify the committed Core.

| Evidence | Result |
| --- | --- |
| E1625–E1626 | Nine pinned Native production stages passed. App SHA-256 `486904ecd5fb667958664e096c1e4d9505be203a1defde13a8288fa909a94eb0`; Coding and Full packaged ELF `f467c2bf91f2338fc64023766d2df6f0b11599d18ff96a77a6045b5eb62e4e99`; Minimal `1715996fc257b13c8ab032a748db665152dd8a03c72af0a3d14a7a51719f7ce5`. Coding/Minimal/Full shipped 9/0/17 plugins. All three clean launches passed; both Skills workers passed 46 wire checks each. Coding and Full setup and six offline Minimal checks passed. |
| E1628 | Unsplit Core still failed the model-selected Program inspection: the read-view child recorded `read_view.output_capacity`; grep failed and the root did not complete successfully. The preserved main store had 35 Runs/69 Operations, the artifact-failure store one Run/four Operations. Both analysis copies passed SQLite `quick_check`; all six original file hashes were unchanged. The private change was not adopted as a capacity fix. |
| E1629–E1630 | Product ELF `9265647571b2e4d7c24cd110d730980bb4c59ed84707781b93c362a497bf4b41`: 489 previously passing identities selected; 483 passed. One faulted in `GCTib::ForEachBitmapWord`; five faulted at `CheckAndPush` in the same Runtime binary as E1509's GC caller census. The latter is static attribution of an observed leaf, not a recovered call chain. The other 610 inventory entries were not run. Architecture, dependency pins, documentation and 131 Python regressions passed; the Python run required a writable fixture tree and the repository scripts on the import path. |
| E1632 | The actual packaged CLI rejected a changed package digest, a mismatched workspace interface, an absent policy provider and a wrong plan tool. Each returned its typed error before registry publication; no model attempt, Operation or approval was recorded. |
| E1634 | Coding read the first workspace, rebound to the second and honored disable. Re-enable returned `owner.peer_disconnected`; managed opt-in was not reached. The matching broker core has a faulting stack through `GCTib::ForEachBitmapWord`, `Mutator::GcPhaseEnum` and `TracingCollector::VisitStackRoots`. Only this crash is attributed here; the complete Coding flow did not pass. |
| E1631/E1635 | The first PTY setup lacked its compiled network bridge; no product pass was credited. With the verified bridge, ten original Linux tmux cases passed: three rich stream protocols, cancel, Ctrl-C, HTTP error, timeout, incomplete EOF, invalid UTF-8 and MCP tool. Real key input and local servers were used. No packaged CLI, mouse, resize or external-provider credit. |

E1627 and E1633 both failed the original first local profile request before dispatch. E1633 recorded the subprocess launch and SIGKILL without replacing the fixture's timeout. Relative to launch, the canonical Run started at **3,193.306 ms**, its model attempt was created at **4,973.306 ms**, and the fixture sent SIGKILL at **5,000.261 ms**. The Run recorded failure at **5,141.306 ms**. Database times have millisecond resolution. The attempt stayed `prepared`, its dispatch timestamp was null, and neither listener received a request. Recording `runtime.run_stale` after SIGKILL establishes order, not causation. The second profile was not invoked. All observed owned processes were reaped or gone and the listener threads returned.

Private evidence: `preflight1625/`, `release1626/`, `profiles1627/`, `import1628/`, `unit1629/gc-classification.json`, `static1630/`, `pty1631/`, `reject1632/`, `clocks1633/timeline.json`, `coding1634/enable-core/`, `pty1635/`. Full Core, Product, the five-second request and matched final release acceptance remain open.

### Extension watchdog and unsplit Core

E1636–E1638 replaced repeated record-list copies with a scalar namespace lookup in a private build. The Coding package passed assembly, clean launch, Skills wire and setup. With nine installed defaults and the original grants, the Run started 3,208 ms after launch. The first local request received SIGKILL at 5,000 ms with a completed context read but no model attempt or HTTP request. Both listeners returned. The lookup did not fix startup and is not in `8f5ccfa99a`.

E1639 rebuilt the original unsplit Core contract from `7bc60d33f5`, without private import or namespace changes. ELF SHA-256: `8bf18ddb8fae1468eedd47ef4a5d2e09e376801189c69a3dd01b299201a964f0`. At the locked output reservation, a 131,072-byte raw limit required 16,777,216 bytes; the 150,994,944-byte bank already held 146,541,976. The shortfall was 12,324,248; no fifth slot was created. The child Receipt reported `read_view.output_capacity`; grep and the root Program failed. The original contract exited one. Both SQLite analysis copies passed `quick_check` (35 Runs/69 Operations and one Run/four Operations); all six original images retained their hashes.

The frozen core contained one remaining plan-request owner with one Core frame and one consumer. All 55 Prepared owners had an unknown consumer. Of these, 48 had returned their producer and had no counted consumer, four had returned their producer but still had one counted consumer, and three had not returned their producer. These are not final DATA returns. The two inspected ledgers had high-water charges of 44,458,048 and 17,870,168 bytes and live invoice sums of 39,393,128 and 6,915,584. These ledgers do not identify the other 84,213,760 bytes in this capture. Compared with E1594, the first ledger high-water and total bank charge both fell by 419,512 bytes; the refusal remains.

E1640 failed dependency resolution before measurement. E1641 used separate homes with the pinned dependency cache for each arm; the original seven absolute gates passed on both. E1642 traced the candidate worker's response and host's next request; E1643 separately timed the host join after the response. Its median was 9.715 ms versus 0.201 ms for the response phase. The following uninstrumented P95s compare the original workload; E1644 covers only the five runtime metrics, not the packaged application.

| Metric | E1641 base | E1641 before fix | E1644 after fix | Samples per arm |
| --- | ---: | ---: | ---: | ---: |
| Cold activation | 63.978 ms | 44.894 ms | 44.272 ms | 12 |
| First call | 2.238 ms | 9.775 ms | 0.639 ms | 12 |
| Steady IPC | 11.115 ms | 10.067 ms | 0.241 ms | 240 |
| Worker RSS | 29,298,688 B | 20,692,992 B | 20,803,584 B | 12 |
| Cancellation including 100 ms trigger | 127.739 ms | 129.944 ms | 130.180 ms | 12 |

`8f5ccfa99a` wakes the active watchdog when its invocation finishes. It still joins the actual future, uses the original cancellation and ACK deadlines, and leaves result ownership and physical cleanup unchanged. E1645's Native extension test ELF (`492e0e6314114b74b6ad545bf93b738bbb703636ed8a65ca72de782cdad0e5d4`) enumerated 100 cases: 13 selected cases passed, 87 were not run. E1646 built all nine production stages from this commit. App SHA-256 `d6e18c88e77ff3be94bcff7df70a33b60ce2aca52e1262fc598b2e020583e00b`; Minimal host `f20ee346579e74af283d89090915297ada84e27948dabd972b46a83b6058f1eb`.

Private evidence: `scalar1636/`, `release1637/`, `profiles1638/`, `core1639/`, `matched1640/`, `matched1641/`, `wire1642/`, `phase1643/`, `wake1644/`, `ext1645/`, `prod1646/`. Full Core, Product, first profile response and release acceptance remain open.

### Physical cleanup, retained Core invoices and packaged response

E1647 compared base `4d88fa6072` with watchdog fix `8f5ccfa99a` using two overlapping real workers in separate homes, the pinned SDK and the same fixture. Each arm completed 12 pairs per size, with progress, exact echoes and physical PID checks. E1655 then timed teardown on 48 worker processes. Median/P95 in microseconds: close frame 31/65; grace wait 9,465/18,785; physical cleanup 165/1,198; cleanup done to waiter return 8,664/9,923. Waiting after cleanup was distinct from waiting for cleanup.

`107a75f2e9` notifies the bounded waiter on the existing cleanup lock after the process-close, drain-join and reader-release path. The waiter rechecks the predicate against its original deadline. This neither changes worker grace nor acknowledges DATA. E1656 compared the uninstrumented fix against the E1647 controls; all timings below are P95 in milliseconds.

| Measurement | Payload | Base | Watchdog fix | Both fixes |
| --- | ---: | ---: | ---: | ---: |
| Concurrent pair completion | 256 B | 10.081 | 0.646 | 0.689 |
| Concurrent pair completion | 32,768 B | 95.113 | 3.406 | 2.856 |
| Close through physical reap | 256 B | 10.755 | 27.050 | 10.427 |
| Close through physical reap | 32,768 B | 11.077 | 28.975 | 20.066 |

Large-output reap improved but did not reach base. E1647 separately observed cancellation-trigger to PID gone in 26.721/20.098 ms (base/watchdog, 12 each). E1657 passed all 13 selected Native extension cases out of 100; ELF `013043a86a6c40e517b65a3381ecfccc2c5b1a88f52083029b3499b5a8799fde`. Independent source binding uses the E1656/E1657 host SHA `f9a53f497e0d93e81c7a6d5525a3e9915840b7483fbc770cc259dd104ecac396`, identical to the delivered file; the E1657 driver's copied parent label is stale.

E1648 assembled Coding/Minimal/Full with 9/0/17 plugins from E1646. All three clean-environment checks passed, as did Coding/Full Skills (46 each), both setup checks and six empty/offline Minimal cases. Coding and Full ELF `25d6bb3184bc01bdf2006e364ffa2a32b85a248eebfb18801a558c6453c95ac6`; Minimal `2ac67a805008096424cccfd9166becb1dceee10a7db9613c53a506e439882e06`. E1649 failed the original five-second first authorized loopback model request on that Coding package. The Run started at +3,850 ms; one `host.context.read` completed, with no safe cut, model attempt or HTTP request in the actual session before cancellation. E1654 traced a separate setup: the broker crashed during `plugin list`, before the timed invocation, with `GCTib::ForEachBitmapWord → BaseObject::ForEachRefField → WCollector::TraceObjectRefFields`. This stack classifies that broker crash, not E1649's timeout.

E1650 passed all seven original absolute gates for both base and E1648 Coding. P95 base/candidate: cold extension 47.224/41.236 ms; first call 2.318/0.595 ms; steady IPC 8.995/0.248 ms; worker RSS 29,241,344/20,819,968 B; cancellation including the 100 ms trigger 128.444/129.800 ms. Product startup remained slower: `/help` 156.026/470.310 ms and inspection 155.561/476.703 ms (20 fresh starts per command per arm). These measurements precede the cleanup change.

E1652 attributed the full E1639 refusal without executing Core again. The same Run's started Program attachment retained its writer and evidence (67,108,864 B); its invoking checkpoint had no handoff or transfer (16,777,216 B). Shared ledgers held 44,458,048 and 17,870,168 B; 33 open fixed reservations held 327,680 B. Sum: 146,541,976 B. A 131,072 B output request required 16,777,216 B of incremental capacity and exceeded the 150,994,944 B bank by 12,324,248 B. Each of the 55 unknown Prepared consumers joined to a different SQL Operation. A final receipt, a different Operation or a shared parent already counted in this sum provides no refund.

E1651 failed to rebuild Native Product at the original 900 s limit after two setup errors; its old ELF earned no credit. E1653 completed a separate incremental build in 284 s with the real C fixture. ELF `e92603668203363104b73b6b3fdb24bc1648a0d7bc01d81700e94a11a93d6910` enumerated 1,099 cases. Of 483 previously eligible cases, 476 passed and seven failed in Runtime GC; 616 were not run. Three `CheckAndPush` leaves have pinned Runtime caller evidence, two reports reached `GCTib` from that leaf, and one stopped in `GCTib`. For the installed-model case, the saved core on the faulting LWP shows `BaseObject::GetSize → WCollector::ForwardObjectExclusive → Mutator::GCPhasePreForward`. No failed case counts as passed. This Product result applies before `107a75f2e9`.

Private evidence: `pair1647/`, `cancel1647/`, `release1648/`, `profiles1649/`, `matched1650/`, `unit1651/`, `frozen1652/`, `unit1653/`, `trace1654/`, `teardown1655/`, `close1656/`, `ext1657/`. Unsplit Core, the five-second model response, complete Product/application flows and final release acceptance remain open.

### Released-package controls and first-install interruption

E1658 rebuilt the nine production stages at `107a75f2e9`. E1659 assembled Coding, Minimal and Full (9, 0 and 17 plugins). All three clean-environment checks, both 46-Skill checks, both setup checks and the six Minimal empty/offline cases passed. Coding and Full packaged ELF: `e1bfcf97ef08efb40eed696075907fedd2082f912bfb1c0a7b4f513c8f0697e9`; Minimal: `cafd2c320c45cb78e149d0679d8f77a14a9b448315e5a1e37f2af3d19283bb8d`.

E1662 compared the E1659 Coding package with base `4d88fa6072` under the pinned SDK and the same fixture. Both passed the seven original absolute gates. Durations below are P95, in milliseconds; cancellation includes the 100 ms trigger.

| Measurement | Base | E1659 Coding |
| --- | ---: | ---: |
| Cold extension activation | 44.109 | 60.213 |
| First worker call | 2.151 | 0.638 |
| Steady worker IPC | 10.780 | 0.239 |
| Worker RSS (bytes) | 29,220,864 | 20,766,720 |
| Cancellation | 128.312 | 126.156 |
| Product `/help` | 136.488 | 423.232 |
| Product inspection | 125.991 | 441.727 |

E1660 traced a separate E1648 Coding invocation after successful setup: 1,051 opens of installed package files, including 68 manifest opens, from +420 to +4,900 ms. There was no Run, model attempt or HTTP request before the five-second deadline. Verification under the Registry writer fence is distinct from the constructor's earlier observation. E1661 on E1659 failed **before** the timer: the broker disconnected during the fresh `--fixture --mode json --print` bootstrap; the faulting thread reached `GCTib::ForEachBitmapWord` through `Mutator::GcPhaseEnum` and root tracing. The surviving User lock had all nine manifest defaults imported but none enabled or explicitly disabled. No policy, context, workspace or service grant was published. This isolates a durable import/enable gap, not the cause of E1649's timed failure. Existing imports without enablement are valid operator choices and cannot be retroactively distinguished from this interruption.

E1665 joined the E1639 captured static debt lists to 65 distinct reservations, totaling 14,098,896 bytes of declared custody **already included** in E1652. Thirteen catalog owners still had a live share, including one without the original configuration alias. The three tool snapshots had eight, one and one shares. No construction frame, outstanding construction work or failed backing in those lists established a return. E1668 rebuilt and ran unsplit Core on `107a75f2e9`, ELF `c9138eeadaee494ef6042542b799fbdc59a9fef8cfcdc428f1b583631d59cca8`. The complete contract failed at the Program inspection assertion. Six retained Store files exposed 69 and four Operations in the two Stores; the failing `workspace.grep` and nested `host.process.readview` both report `read_view.output_capacity`. These rows do not measure the incremental invoice at this refusal.

E1663's Native Product build exceeded the original 900 s deadline; its pre-existing ELF earned no credit. E1666 passed 131 Python tests, the architecture gate and dependency pins. E1667 passed ten real PTY scenarios, including all three provider wire formats, cancellations followed by reuse, timeout, malformed streams and MCP; mouse and resize were not exercised. E1671 separately failed the packaged Todo golden at the original 45 s deadline. No frame or new Run, approval, Operation or document reached its oracle. The frontend returned only after timeout, and the outer watcher had to reap a surviving process. There is no captured GC stack for this failure. A previous timeout after approval became pending was a different observation.

E1664 is a private encoder control, not a shipped fix. Eight runs per arm reproduced identical 41,548-byte canonical request bytes; median encode time fell from 24.119 to 2.514 ms. E1669 built all nine production stages with just this experimental encoder. Neither result demonstrates a packaged model response.

Private evidence: `prod1658/`, `release1659/`, `request1660/`, `profiles1661/`, `matched1662/`, `unit1663/`, `canon1664/`, `roots1665/`, `static1666/`, `pty1667/`, `core1668/`, `canonprod1669/`, `todo1671/`.

### One publication for an initially empty installed set

`ba99286bb6` removes the interval in which the first-install User lock was durable but every record was still disabled. Under the existing writer fence, Registry reloads both scopes, rejects a concurrent operator import, materializes every entry and compares it with its preflight descriptor. It checks dependencies for requested enables and rechecks disabled packages before publishing the final User lock once. Only then does Product mount the enabled set. Uninstall history is not a current record; it survives the write and remains available for an explicit rollback. This does not make policy, context or grants part of the registry transaction. No lock migration runs, and a previously imported, disabled record still requires an explicit operator choice.

E1674 first passed the changed-package/reopen test but exposed a generic error code on the stale-writer path. The finite diagnostic table now preserves `plugin.distribution_assembly_not_first`; E1676 passed 49 selected Registry cases. E1677 added the history-only control. On the five files matching `ba99286bb6` byte for byte, Native Registry passed all 50 selected cases (53 enumerated, three previously deferred). ELF `172d4e2daf0c5c2b33e170ddd9ea6744b002542bd86d615fe82f41a782c0d3e6`. The new tests reopen actual on-disk state: a changed second package publishes neither row and a corrected retry preserves mixed defaults; an intervening operator import leaves the lock byte-identical and disabled; the prior revision remains usable after uninstall, reinstall and restart.

E1672's separate pre-change Native Product rebuild again exceeded 900 s, and E1675's first integration build on an intermediate atomic-install source also exceeded 900 s. Neither old ELF counts. E1681 read the E1639 frozen bank again, without executing Core. One node on the actual `PlanRequestCustody204` debt list matched that bank: 409,600 bytes for DATA and 17,184 for metadata, with one active Core frame and one control consumer. An older run's 13 prompt-construction births do not identify 13 current holders. This list is not an inventory of all prompt allocations and supplies no refund.

Private evidence: `reg1674/`, `prod1675/`, `reg1676/`, `reg1677/`, `unit1672/`, `custody1681/`. Registry acceptance does not establish packaged startup, a five-second model reply, or complete Core/Product acceptance.

### Last-Product handoff and the original Core inspection

`3621283b9a` fixes an undercharge, not a capacity increase. Previously, the last Product decremented the count under one lock and detached the payment list under a second lock. A new Product could adopt its payment between the two. The count and list now change in the same critical section; only the detached list is drained, outside the lock.

E1689 used the real Native budget and reservation classes. A private scheduling control let a second task begin a Product and adopt a payment at the first unlock of `endProduct`. After the old close, the previous implementation charged the new owner zero bytes and admitted another allocation. The fix kept 16,777,216 bytes charged and rejected that allocation until the new owner closed. Both banks then returned to zero. The uninstrumented class also passed overlapping-owner and unmatched-close controls. This executable is not the Product unittest binary.

E1690 rebuilt the original unsplit `--core-and-recovery-contract` with all code and fixtures matching `3621283b9a`; only an evidence-document correction differed. ELF `4fe85078a04c9c37f946a441a6798ab38cf41abd5abb4549b865c60773b16bff` exited one at the Program inspection assertion. All six original Store images were retained; both analysis copies passed `quick_check` (69 and four Operations). The model-selected Program's `workspace.grep` and nested `host.process.readview` Receipts reported `read_view.output_capacity`. No numeric shortfall was measured in this run.

E1688 and E1692 inspected the older E1639 refusal, not E1690. With one Product live, the shared list held 248 copied-DATA payments; 13 escaped mounted descriptors had separate payments. Their 261 distinct entries declared 4,595,968 bytes **inside** the existing ledgers. The corrected optional-field decode shows the mount copy scratch had already been cleared. Registry's own two maps agreed on 24 live payments totaling 1,373,432 bytes; 16 record backings accounted for 639,088 and three descriptor backings for 90,120. The Host legacy graph list was empty. These are current declarations, not extra bank charges or evidence of a return.

On the earlier atomic-install source `ba99286bb6`, E1678 passed the nine original production stages; E1686 passed 131 Python regressions, architecture and dependency pins. E1679 timed out building a Native Product prerequisite at the original 900-second limit and ran no Product case. On `3621283b9a`, E1691 failed closed at the Host build: one `/proc` identity had state `R`, parent zero and negative group/session. Known descendants were reaped; this does not resolve the unknown identity. E1698 independently confirmed real clean return, detached-child rejection, timeout and malformed-identity rejection inside a private PID namespace with the unmodified watcher.

Private evidence: `prod1678/`, `static1686/`, `escaped1688/corrected.json`, `race1689-executable/`, `core1690/`, `registry1692/`, `prod1691/`, `custody1698/`.

### Temporary Registry views during import and enablement

On `3621283b9a`, importing a local package kept a 67,664-byte Registry descriptor after the caller had copied its namespace. The two-argument `setPluginEnabled` kept a 76,672-byte record after reading its scope. E1704 followed both payments through the original Product workflow: neither returned until `PluginRegistry.close`. At `17de1ffda2`, local and acquired imports close their inspection descriptor after making the namespace copy. Enablement closes the temporary lookup before calling the scoped overload. E1706 observed both returns inside the public calls. A record handed to an API caller still belongs to that caller.

E1707 exercised the acquired-source contract with pinned Git content and a loopback npm registry. After an idempotent disable and the caller's `close`, the live Registry invoice sum and lease count must equal their values before the lookup. The parent failed this assertion; `17de1ffda2` passed the whole contract, including the original source and receipt checks. E1703 and E1705 also passed all seven approved-plan Product process cases before and after the production change. E1710 passed the 131 selected Python tests, architecture checks and dependency pins. None of these runs exercises all Product cases.

E1708 used the same verified Native executable as E1707 (`c02f436edfc2eda30b8150665bbb1b7ba5ee8bb7287810fcdcd8764292a6e40c`) for the unsplit Core contract. Its crash thread entered `TransitionAllMutatorsToGCPhase` from `WCollector::TraceHeap` and `DoGarbageCollection` (SIGSEGV). The preserved database, WAL and SHM yielded 12 Runs, 11 Operations, 11 effect records, nine Receipts and 13 model attempts. In the one running Run, neither `workspace.grep` nor `host.process.readview` had a Receipt. This sample qualifies for GC deferral; it does not verify successful inspection or change E1690's capacity failure.

E1701 found additional live aliases in the older E1639 bank. An alias is not another charge or evidence of a last-owner return. E1702 grouped the installed-manifest opens in the older timed startup trace: two passes over all nine packages ended at 2,044 ms, and the model-provider worker started at 4,892 ms. This locates startup work inside the original five-second window. It does not show how much time any particular verification costs or establish that removing it is safe.

E1697 built all nine production stages at `3621283b9a`. E1693 assembled Coding, Minimal and Full from those builds. Each passed its clean-environment entrypoint and either the packaged Skills and setup checks or the empty-host check. These packages predate `17de1ffda2`. Private evidence: `prod1697/`, `release1693/`, `refs1701/`, `product1704/`, `product1706/`, `green1707/`, `core1708/disposition.json` and `static1710-bound/`.

E1709 passed all nine production stages for `17de1ffda2`, including App (`af33a619fa6208f433db723d4d8b4670015f48e1e3fc931538d8323d87629f19`) and Minimal (`dc088d8b1920453e87e180f2d065ab241256cfcf0674afa3e847b6689388515a`). All 2,985 tracked input hashes match the behavior snapshot. Every stage exited zero and passed its process-custody check. This proves the production build, not package assembly or model dispatch.

Two earlier failures now have narrower conclusions. On the older E1659 Coding package, E1680 sampled the Todo frontend and broker during the original 45-second wait. Neither sample identified the waiting application task. The fixture created no Run, Operation, approval, model attempt or Todo document, and the watcher had to reap the remaining broker. All nine installed package trees still matched their locks; the Todo selection and document grant matched the installed Workflow digest. In the separate E1673 private encoder experiment, the broker faulted during bootstrap in `GCTib::ForEachBitmapWord` through `Mutator::GcPhaseEnum` and `TracingCollector::VisitStackRoots`. Neither timed profile started. The encoder change is not included in `17de1ffda2`.

On the final E1707 executable, E1718 ran the independent Program budget and cancellation/recovery contracts. In the seven-call, one-slot control, grep, both reads, all three read-view children and their Program parent had completed Receipts. With one call allowed, the Run failed after one model attempt with `budget.tool_calls_exceeded`; no child was admitted. The cancellation Run had four Receipts: completed first read and read-view child, rejected second read, failed Program parent. The original three databases and their WAL and SHM files were retained, and `quick_check` passed on each analysis copy. These successes distinguish a working isolated read-view path from the failed aggregate Core scenario. Evidence: `budget1718/` and `cancel1718/`.

E1715's full Product test build reached its original 900-second deadline before enumeration; no selected case ran. The watcher reaped the compiler descendants. E1717 separately sent `/todo edit` through a real PTY on the E1659 Coding package. The pane returned normally but showed no editor in the captured frames, and no new Run or document was stored. This does not verify a successful save or identify where the command stopped.

E1720 checked the earlier paired-worker comparison against `17de1ffda2`. All 238 tracked files checked across the runtime dependency packages matched, as did the Native helper, pinned yjson revision, worker fixtures and both measured executable hashes. The [E1647/E1656 paired output and process-reap measurements](#physical-cleanup-retained-core-invoices-and-packaged-response) therefore still apply to this runtime path. The candidate's large-output close-to-reap P95 remained 20.066 ms against 11.077 ms on base. Issue #45 requires the comparison; it does not prescribe a fixed speedup. This source check does not establish packaged startup or end-to-end release performance.

E1721 checked the other database in the Todo operator. In both E1680 and E1717 its main database, WAL and SHM were byte-identical to the original. Each analysis copy passed `quick_check` and contained no Runs, Operations, approvals, attempts, Receipts or plugin documents. E1722 then separated input from submission: a real terminal showed the literal `/todo edit` draft before Enter and `loading todo` at 1, 4 and 12 seconds afterward. The editor was not visible. Escape and `/exit` returned status zero; the fixture Store still had six Runs and zero documents. This locates the wait after command submission, not in the input decoder. It does not establish that the backend returned or that an approval was requested.

### Frozen Todo selection and a stale terminal status

E1723–E1727 distinguished an actual rejection from a stuck editor request. On the E1659 Coding package the real broker entered `loadTodoEditor`, then the shared Registry startup transaction. Its workspace read-fence acquisition returned `-EROFS` before activation or Operation admission. The later `selectProductTodo` belonged to a separate `todoMarkdown` display lookup. With the same shipped library and pre-existing lock inode, the read-only mount returned `-EROFS` and a writable private mount succeeded. No lock, grant or integrity requirement was removed.

There was also a display bug. In E1729 the frontend received the result, applied `TodoController.open`, stopped the timer and rendered within 37 ms in the instrumented run. The terminal still displayed `loading todo` until a real resize at 12 seconds exposed the error. `d51eaef287` makes the completion repaint explicit when a timer or mailbox event has already dirtied only part of the frame. It preserves a requested full repaint; otherwise it includes the former spinner and status header. It does not retry the rejected action.

E1730 built the TUI and App with the fixed SDK. E1731 replayed the same command through separate real PTYs using source-matched Apps and copies of the same existing operator. On parent App `af33a619fa62` the error remained invisible for 12 s and appeared after resize. On rebuilt App `9f2057a0693a` it appeared without another key or resize in 66 ms, with no working indicator. Both processes exited normally and both operators' Run, Operation, approval, Receipt and document counts remained unchanged. These are observations from one run per arm, not performance percentiles.

The permanent `T016/todo-editor-unprovided` case checks a different rejection: the operator has no Todo selection. E1732 found that the matrix reader required a retired manifest field and never launched the TUI. With the reader checking the declared real-Provider-or-local-command contract, E1733 passed on both Apps with zero Provider requests. Only E1731 supplies the before/after proof for the stale status. A visible rejection is not a successful edit or save.

E1726 tested the other side of the Registry fence on the older E1659 Coding package (`e1bfcf97ef08`). The workspace stayed read-only except for a private writable copy of `.axyndra`. With the same operator state and no new grants, the original Todo first-save golden flow exited zero in 5.89 s. The Store gained two completed Runs. Each had completed Receipts for `host.context.read`, `plugin.axyndra:workflow.todo` and `host.plugin.document`. All four approvals were user decisions; the document was `todo` revision 1, and there were no model attempts or surviving owned processes. This establishes a working authorized save on that package, not on the final package. Evidence: `todo1726/todo-first-save/`.

E1734 ran the rebuilt, unbundled App (`9f2057a0693a`) through ten actual PTY flows. Responses, Completions and Messages streaming, cancellation and reuse, Ctrl-C, HTTP error, timeout, incomplete EOF, invalid UTF-8 and the MCP tool case each passed the fixture and process-custody checks. The servers were local. These cases do not measure a packaged Coding launch, mouse input or resize. Evidence: `pty1734/`.

E1719 built `agent_extension_runtime` and `agent_plugin_registry` separately in 118.52 s and 37.93 s. The original `cjpm test -m agent_product --incremental --no-run --jobs 1` build then reached its 900 s limit. The watcher cleaned up three processes. Production archives and a test interface had been written, but the remaining test executable still had the E1653 hash. No inventory or case is credited to this attempt. E1741 separately checked all 238 tracked inputs used by E1720 and both worker fixtures against `d51eaef287`; none differed. Thus the measured concurrency and physical-reap comparison remains applicable to that path, without a new benchmark sample. Evidence: `unit1719/` and `pair1741-bound/`.

### Packaged entrypoints and the Todo save approval

E1735 used the E1709 production builds and the E1730 rebuild of TUI and App for `d51eaef287`. All three distributions assembled and passed the clean-environment check. Coding and Full also passed Skills wire and setup; Minimal passed the empty offline host check. All eleven processes exited zero and passed custody checks. Coding and Full share the packaged host ELF `44251ff012f7dd0b8389acf62ef519224a9743f7fca4f614e932d727c7af0957`; their manifests identify their package selections. Minimal's ELF is `57b3c5ac8ee5b3073447d80067405acc4aa791dc4c22149630571c23536ea24f`. These are assembly and entrypoint results, not a complete release pass. Evidence: `release1735/`.

E1711–E1714 tested the **earlier** `17de1ffda2` package. All four invalid-distribution cases returned the expected diagnostic without partial publication. The original first local profile invocation timed out at five seconds; the second did not run. Both arms passed the original performance gate, but the candidate was slower to launch `/help` (P95 469.714 ms versus 163.534 ms on base) and `/plugins inspect` (477.572 ms versus 153.462 ms). Do not substitute these measurements for the final package.

On that earlier Coding package E1728 timed out at the original 45 s Todo golden deadline with the workspace Registry writable. E1744 compared its captured Store with the E1726 passing control. Both load Runs completed. In the failing save Run, `host.context.read` had a user approval and completed Receipt; `plugin.axyndra:workflow.todo` had **no approval decision** and its Receipt recorded cancellation before execution. No `host.plugin.document` child or Todo revision was created. The frontend's last recorded state had both the editor and an approval present. This locates the wait; it does not establish whether a key was offered or consumed. Nine surviving owned processes required cleanup and none remained afterwards. Both analysis copies passed `quick_check`. Evidence: `todo1728/todo-first-save/` and `todo1744-bound/`.

### The fullscreen Todo editor hid real approval controls

E1739 completed the original Todo golden flow on the unmodified `d51eaef287` Coding package in 6.627 s. The actual terminal exposed a different result: in E1745, load succeeded and the pasted task was visible, but after Ctrl-S the editor covered the save approval. In E1751 a resize still showed the editor; the Store had a `waiting_approval` context read, two earlier user decisions and no document. Neither test submitted an unseen decision.

The main render branch already paints the fullscreen editor and returns when editing is allowed. When an approval is pending, that branch must leave the screen to the approval card. A second, unconditional editor render painted over the card. Removing only that duplicate leaves the draft, keyboard routing, authorization and operation lifecycle unchanged.

E1752 rebuilt the Native TUI and App using the pinned SDK; App SHA-256 `3cf54157011c0328a73b6c92786063c4f237b122b77d74e4d321e1c5031b6a8d`. E1753 applied the production ELF packaging transformation and used that host in the otherwise unchanged Coding distribution. The actual PTY showed all four distinct pending approval cards. Each Enter was bound to the visible card and a unique pending canonical Operation. Two Runs completed; each had completed `host.context.read`, `plugin.axyndra:workflow.todo` and `host.plugin.document` Receipts. Four user approvals produced the edited text at `todo` revision 1. No model was called; the terminal exited normally and process custody closed. This is not evidence of a new release assembly.

E1755 ran the permanent `T016/todo-editor-save-approvals` matrix case with the same Workflow package in two fresh operator homes. It matched the title and pending state on **the same card**, not the name on an earlier decided transcript card. On the parent it stopped at the covered save-read approval; on the corrected App it saw both save approvals, the saved status, four durable user decisions and the actual document. Both arms closed process custody. E1754's earlier test oracle matched a stale title and is not credited.

### Matched package and worker measurements

E1738 compared base `4d88fa6072` and `d51eaef287` with the original fixture, pinned SDK, identical sample counts and separate package/operator roots. Both passed their absolute thresholds. Units below are microseconds unless marked bytes; pairs are P50 / P95. E1749 binds the measurements to the corresponding inputs and package hashes.

| Metric | Samples per arm | Base | Candidate |
| --- | ---: | ---: | ---: |
| `/help` startup | 20 | 136,507 / 163,534 | 413,128 / 420,107 |
| `/plugins inspect` startup | 20 | 137,741 / 153,462 | 433,604 / 444,136 |
| `/help` peak RSS (bytes) | 20 | 91,455,488 / 92,012,544 | 55,173,120 / 55,767,040 |
| `/plugins inspect` peak RSS (bytes) | 20 | 91,574,272 / 92,000,256 | 55,406,592 / 56,098,816 |
| Extension cold activation | 12 | 51,241 / 121,579 | 43,204 / 60,416 |
| Extension first call | 12 | 2,057 / 2,796 | 433 / 688 |
| Extension steady IPC | 240 | 2,059 / 5,981 | 185 / 260 |
| Extension host RSS (bytes) | 12 | 18,284,544 / 29,368,320 | 15,179,776 / 20,725,760 |
| Cancellation after 100 ms trigger | 12 | 125,473 / 129,979 | 119,851 / 126,218 |

E1741/E1749 also bound the separately measured overlapping two-worker path. At 256 and 32,768 output bytes, respectively, span P95 (12 pairs) changed from 10,081 to 689 µs and from 95,113 to 2,856 µs. Progress-delivery P95 (24 events) changed from 1,377 to 513 µs and from 2,155 to 1,200 µs. Physical reap P95 (24 workers) changed from 10,755 to 10,427 µs and from 11,077 to **20,066 µs**. An improved span is not a faster large-output reap or evidence of DATA return.

E1736 still failed the first local-model profile's original five-second deadline. E1740 preserved that deadline and the original operator installation without an extra bootstrap. The Run started about 4,150 ms after process launch; the fixture sent SIGKILL at 5,001 ms. A context read completed, but the Store had no model attempt and neither loopback listener received a request. The second profile did not start. E1737 separately passed all four invalid-package/policy controls with no partial registry or execution-state publication.

E1742 rebuilt Product without the old test ELF. It enumerated 1,100 cases and ran 477: 474 passed, three crashed, and 623 were not run. The passing subset includes the genuine 63 MiB seed, not the complete Memory workflow. Two crash logs directly showed Runtime GC root traversal. For `PluginRuntimeContractTests.piExtensionApiHostRestartsAfterPluginCrash`, E1748 bound the original worker's system core to Product ELF `22fa6ced9a832d3f724023cd76e329474c93e1e9f757273bd9741599ff4c6c39`; its faulting stack includes `GCTib::ForEachBitmapWord`, `Mutator::GcPhaseEnum` and `TracingCollector::VisitStackRoots`. All three samples are deferred GC failures, not passes. Private evidence: `unit1742/`, `product1748-core/`, `matched1749-bound/`, `profilephase1740/`, `todopty1753/` and `matrix1755/`.

### Published Todo host and scoped Core export evidence

E1756 assembled `c4cdd224f7` using the fixed SDK. Coding and Full have packaged host SHA-256 `7af6c6d0f5ea892192bb8c214d2439c15610bd9b7cdec6dc22ddc26664e4661b` (identical to E1753), with nine and seventeen bundled plugins respectively. Minimal has zero plugins and host SHA-256 `57b3c5ac8ee5b3073447d80067405acc4aa791dc4c22149630571c23536ea24f`. All three assembly and clean-environment checks, both Skills and setup checks, and the Minimal empty-offline check exited zero with closed process custody. Evidence: `release1756/summary.json`.

E1765 used a private diagnostic build of the same source, instrumenting only the two transitions that can first mark a Prepared metadata owner as having an unknown consumer. It ran `--program-budget-contract`, not unsplit Core. The original success and exhausted-budget assertions passed. All eight first-export stacks joined to distinct canonical Operation IDs:

| First export | Operations | Receipts |
| --- | --- | --- |
| Legacy executor reads the frozen plan | Two Program roots | One completed; the exhausted-budget root failed |
| Broker checks a readonly delegation child | One Workspace grep and two reads | Three completed |
| Broker checks the host service child | Three read-view children | Three completed |

No first transition came from the authorization-move exception path in this run. The original database, WAL and SHM retained their hashes; a separate copy passed `quick_check`. The capture thread and file descriptors closed. This identifies where the references were first handed out, not the last consumer, the size of a safe refund, or the cause of the unsplit run's rejection. Neither the observer nor a change to accounting was shipped. Evidence: `export1765/correlation.json`.

E1766 ran the actual E1756 Coding package without substituting its host. The private operator preserved all 249 regular files from the retained fixture. Four visible pending approval cards, each bound to a different canonical Operation, accepted real terminal input. Both Runs completed with one completed Receipt each for `host.context.read`, `plugin.axyndra:workflow.todo` and `host.plugin.document`. The first durable `todo` revision contained the pasted task; no model attempt occurred. The terminal exited normally with closed process custody. E1757 separately passed ten real Provider/MCP PTY cases on the unbundled App, including cancellation and reuse, Ctrl-C, timeout, malformed UTF-8 and incomplete EOF. Evidence: `todopty1766/` and `pty1757/`.

E1758 failed at the original five-second `profile-one/shared-model` invocation; profile two did not run. One owned process survived the test and required cleanup; none remained or needed reaping afterwards. E1759 passed all four original negative distribution controls on this Coding package. E1760 did not measure performance: benchmark compilation lacked the locked offline `yjson` checkout.

E1761 privately replaced full Registry list publication with a mutex-protected predicate for existence and emptiness. The experiment built Registry, Product and App, and E1763 assembled Coding and passed its Skills, clean-environment and setup checks. E1764 still timed out at the first profile's original five seconds. The fixture also encountered a nonempty plugin directory during timeout cleanup. E1769 read a separate copy of the three surviving SQLite files: one cancelled Run, one completed context read and no model attempts; the original files retained their hashes. This experiment is withdrawn, not a fix for startup. Evidence: `presence1761/`, `coding1763/`, `profiles1764/`, `profile1769-stored/`.

### Final Coding package measurements

E1768 reran the original performance gate on the E1756 Coding host (`7af6c6d0f5ea`), using the locked offline dependency. The fixture, benchmark source, SDK, workspace layout, clean operator state and time limits match the measured fixed base `4d88fa6072`. Both candidate stages exited normally with no surviving process. The base was not sampled again. Values are P50 / P95; times are milliseconds and memory is bytes.

| Measurement | Samples per arm | Fixed base | `c4cdd224f7` |
| --- | ---: | ---: | ---: |
| Extension cold start | 12 | 51.241 / 121.579 | 40.512 / 100.369 |
| First extension call | 12 | 2.057 / 2.796 | 0.418 / 0.556 |
| Steady extension IPC | 240 | 2.059 / 5.981 | 0.179 / 0.249 |
| Extension host RSS | 12 | 18,284,544 / 29,368,320 | 15,298,560 / 20,795,392 |
| Cancellation, including 100 ms trigger | 12 | 125.473 / 129.979 | 125.628 / 126.753 |
| `/help` cold start | 20 | 136.507 / 163.534 | 406.190 / 490.516 |
| `/help` peak RSS | same 20 | 91,455,488 / 92,012,544 | 52,084,736 / 52,518,912 |
| `/plugins inspect` cold start | 20 | 137.741 / 153.462 | 438.551 / 459.655 |
| `/plugins inspect` peak RSS | same 20 | 91,574,272 / 92,000,256 | 51,863,552 / 52,277,248 |

The lower CLI memory peaks did not translate to faster startup. E1772 matched all 238 tracked inputs for the earlier two-worker comparison; its slower large-output close-to-reap P95 (20.066 ms versus 11.077 ms) still applies. For E1742 Product, 1,495 tracked inputs in 26 dependency packages were unchanged. The five changed tracked files are outside that suite and the worker closure: one TUI source, two PTY harness files and two ledgers. The existing 474 Product passes, three directly attributed GC crashes and 623 unrun cases keep their original status. E1762 built the withdrawn Registry experiment only; the build hit its 900 s limit and no test ran. Evidence: `matched1768/`, `closure1772/`, `unit1762/`.

E1771 retained the actual failed profile's Store and watched the shipped and installed package directories during the original invocation. Run admission was 4.352 s after launch; the original timeout sent its signal at 5.000 s. Before admission the observer recorded 1,143 installed and 239 shipped file-open notifications. All nine shipped manifests were opened twice; the shipped notifications spanned 3.665–4.240 s. Installed opens continued after admission. Events can coalesce and are timestamped on collection: these are not hash counts, CPU samples or a causal allocation of the delay. The Store contained one cancelled Run, a rejected `host.context.read` Receipt and zero attempts; the local server received no HTTP request. One sleeping descendant required cleanup, after which none remained. Evidence: `phase1771/`.

E1767 passed architecture and dependency pins but omitted the import path needed by the selected Python tests. E1770 supplied the original selector's import path; all 131 tests passed on `c4cdd224f7`. None of these gates establishes full Core, Product or release acceptance.

### Packaged golden flows and profile fixture cleanup

E1774 ran `scripts/tui_golden_gate.py` against the unmodified E1756 Coding package with its original 45 s limit. Cards and ask passed on fresh homes. Initial prompt passed on an existing operator with one new completed Run, one completed local fixture model attempt, one committed context read and one completed Receipt. First Todo save used a separate existing operator: two completed Runs, six completed Receipts, four user decisions and revision 1 with no model attempt. All four processes exited zero with closed custody. These are headless golden results; E1766 is the real terminal evidence. The deferred fresh-operator and default failures were not rerun. Evidence: `golden1774/`.

On the E1771 Store, `host.context.read` committed a rejected Receipt with `context.read_owner_inactive`. Its persistence timestamp is 5 ms after the original timeout signal; the Run cancellation was recorded 16 ms after the signal. This does not date the actual loss of liveness or establish an independent permission defect. Evidence: `phase1771/receipt-timing.json`.

The profile fixture formerly removed its temporary operator while a detached descendant could still write there (E1758/E1764). In E1775 the fixture parent retained the operator until the dedicated Linux watcher and its parent both reported final cleanup. Unknown custody retains the directory; forced cleanup still fails the case. The original `invoke` command, five-second deadline, grants and two expected replies are unchanged. The first profile on the same Coding package still timed out, with exit 1 and no success marker; no operator directory remained, and the independent pre-change watcher had no descendant to kill or reap. Sixteen watcher regressions passed, including a real detached child that required cleanup but did not earn a pass. Evidence: `profilecustody1775/`. This fixes fixture teardown, not model latency or full release acceptance.

### Local model dispatch before and after plugin readiness

On the unchanged E1756 Coding package, a live RPC connection and a successful `get_state` response did not establish plugin readiness. E1780 copied all 242 installed-package and configuration files from the existing E1771 operator, excluding session state. The first print client timed out at five seconds. Its Run completed a context read, reached a context safe cut and claimed model dispatch, but the local HTTP listener saw no request. The Run and attempt were cancelled. The same broker answered `get_state` again; the second print client then disconnected. Its Run remained running with no attempt. No faulting stack was obtained for that disconnect. Separately, E1778 failed during fresh operator setup, **before either invocation**. Its reaped broker's saved core shows `GCTib::ForEachBitmapWord` from `Mutator::GCPhasePreForward` on the faulting thread. Only this fresh-setup sample is GC-deferred.

E1781 used another byte-identical copy of those 242 files and fresh session storage. With the RPC connection open, a separate public `plugin list --json` returned all nine enabled records with their installed digests. This command awaits `ensureExecutionReady`; it took 2.579 s **outside** the timed model calls. The original five-second `--print --model` invocations then returned `profile-one-ok` in 4.251 s and `profile-two-ok` in 4.157 s. Each local Messages endpoint checked its own credential, path and wire model. Both Runs, model attempts and context-read Receipts completed. The broker PID and start identity remained the same across both calls, the RPC client exited zero, both listeners returned, and the watcher confirmed physical custody. The operator lock and grants retained their hashes. These are two successful **ready-owner** calls, not a workaround or a pass for the original cold request. Evidence: `warmprofiles1778/`, `resident1780/`, `readyprofiles1781/`.

### Full package protocols and matched terminal gates

E1777 ran the fifteen remaining independent Native protocol checkers directly on the E1756 Full package. All 557 cases passed and all fifteen process trees closed naturally. With the 46 Skills cases already run on this same Full package at E1756, that is **603 cases across 16 endpoints**. Memory has no equivalent standalone checker; its application workflow, Product authorization and full release are not covered by this count. Evidence: `fullwire1777/summary.json`.

E1779 used byte-identical release scripts for the fixed base `4d88fa6072` and E1756 Coding, base first for each command, with no page-cache reset. Each entry below is from the original gate; both TUI arms met the 500 ms P95 ceiling. `--version` exits before Product configuration.

| Gate | Samples per arm | Base P50 / P95 (ms) | Coding P50 / P95 (ms) |
| --- | ---: | ---: | ---: |
| Fresh `--version` process | 100 | 55.613 / 61.293 | 48.424 / 55.633 |
| Headless fixture TUI journey | 40 | 213.8 / 263.8 | 413.8 / 414.0 |

The headless journey is slower than base despite passing the absolute gate. It is not a PTY, model startup or activation measurement. Evidence: `matchedterminal1779/summary.json` and both `cold-start.txt` sample sets.

E1776 inspected the retained E1639 Core refusal without running Core again. The three named fixture copy lists held 67 distinct ledger leases declaring 2,474,432 bytes: 52 leases on the first ledger and 15 on the second. All six record-payment links were aliases of those leases; none overlapped E1688's two other roots. This is part of the frozen charged amount, not an additional invoice, a current-Run measurement or a refund. It does not explain the full 12,324,248-byte shortfall. Evidence: `fixtureowners1776/summary.json`.

### Interrupted model client on a ready owner

E1782 used the E1756 Coding package and the same ready-owner setup as E1781. The first authenticated local endpoint flushed a valid SSE prefix before the print client's original five-second deadline. When the client timed out, SQLite recorded a cancelled Run and model attempt; the context-read Receipt remained completed. The broker answered a fresh state query from the surviving RPC connection with the same PID and start identity.

The second print client disconnected before its endpoint received a request. Its Run remained `running`, with no model attempt. The dedicated watcher's actual `waitpid` for that broker reported **exit 1**, not a terminating signal or core dump. All observed processes were reaped, without a cleanup signal from the watcher. The original operator lock and grants were unchanged. A ready owner thus handled two successful calls in E1781, but did not complete the second call after this interrupted stream. This result does not reclassify E1780 or imply that a failed client's DATA was returned. Evidence: `interruptedprofiles1782/receipt-correlation.json`.

E1783–E1785 tested one change: when joining a frontend, retain the same `AgentError` once instead of allocating another exception wrapper on each collection pass. Only the diagnostic package's host was replaced. After the first client timed out, the second client received its own endpoint's reply in 4.252 s on the same broker. Its Run and model attempt completed. **Process custody failed:** after the RPC client exited zero and its reader joined, nine processes, including the broker, needed forced cleanup. The candidate was withdrawn; it is not in the release. Evidence: `brokerpack1784/summary.json` and `brokercustody1785/receipt-correlation.json`.

E1788 stopped that candidate at the repeated frontend cleanup call **after** the second reply and the final RPC client's return. In the saved debugger snapshot, the concrete socket close had returned, but output frame 1 had no matching return (`expectedOutput=1`, `returnedOutput=0`). The peer still held the physical write frame, its payment and its original failure. The CLI still held its write payment; the frontend still held the exact error presented to the collector, with `failureConsumed180=false`. This is a missing output acknowledgement, not an unpaid *additional* request or evidence of a GC crash. The snapshot cannot establish how many bytes the disconnected client received. Evidence: `heldsnapshot1788/binding.json` and `heldsnapshot1788/verified-fields.json`.

E1789 preserves adopted-child termination evidence in the standard Linux case receipt. Each `adopted_wait_statuses` entry records the PID, original process start time, exit code (negative for a signal) and kernel core-dump flag from the watcher's existing `waitpid`. No new wait, signal or acceptance condition is used. `python3 -m unittest -v rpc_unit_isolation_test` from `scripts/` passed all 48 tests, including a successful leader with an adopted child that exited 1, and a detached live child that needed `SIGKILL`. Their outcomes remain distinct even though both trees were ultimately reaped. Evidence: `adoptedwait1789/final-green.txt`.

E1794 read the same E1788 snapshot offline. The retained physical frame was the ordinary `run.cancelled` error on output frame 1 (97 encoded bytes staged, not a count of bytes delivered). The CLI failure helper had no pending, staged or retiring caller share. The broker had since captured a separate failure consumer, and the peer retained a `SocketException`. Preventing a new offer before it starts is a different problem from releasing this already-staged output. Evidence: `callerflags1794/caller.json` and `callerflags1794/offer.json`.

### Matched real-terminal frame measurements

E1790 used the same trace-compatible PTY runner for the fixed base and the E1756 Coding package. Coding passed the original five 10,000-row scenarios, three runs each, with no silence fallback. Base timed out waiting for a frame-complete key event after Enter in search; it produced no complete five-scenario report. E1793 measured the four mutually observable scenarios separately on base, using the same harness and limits, and paired those results with E1790's candidate samples. The older trace identifies the completing event; the newer trace also identifies coalesced inputs. No active stalls or forced process cleanup occurred in either four-scenario arm.

| P95 (ms) | Fixed base | Coding |
| --- | ---: | ---: |
| First visible frame | 199.33 | 184.10 |
| Key repeat | 54.58 | 6.97 |
| Stream update | 47.92 | 7.95 |
| Resize | 67.44 | 11.75 |

Base exceeded the key-repeat and resize limits; Coding passed both. These are fixture PTY timings, not provider startup or a matched search result. Evidence: `matchedpty1790/summary.json` and `matchedframes1793/summary.json`.

### Memory rollback at the real precommit boundary

E1791 found that the standalone `support_tests/memory_actual_interrupt` build lacked a lock for its direct `yjson` dependency. E1792 supplied the existing reviewed pin and built the fixture, but seed failed before its first Memory call: successful Registry import had already created `settings/plugins`, which the fixture tried to create again. The fixture now carries its own lock for the same reviewed `yjson` commit and writes the configuration into the directory created by import. No production permission, journal code or SQL assertion changed.

E1795 rebuilt the fixture with the fixed SDK and ran the original seed/interruption/retry scenario against the E1756 Full package's Native Memory binary. E1796 ran the final checker on that same fixture ELF (`1daa0b0f45f1d18b9d61ae330d4c39a5ab367a47e424a73245176a11923fdcde`); it also requires the parent's `wait` to report `SIGKILL` at the precommit barrier. Inside the transaction the observer saw three events, revision 2 and the Completed Receipt. An independent SQL reader still saw the original history. After the kill the uncommitted Receipt was absent; a fresh canonical retry yielded two rows at revisions 1 and 2, three events, and two completed Derived Receipts including the seed. The checker made no SQL writes and the outer process watcher confirmed cleanup.

A copy of the final database, WAL and SHM passed `quick_check`. The interrupted Operation still had state `executing` and no Receipt after reopen; the retry was a **different** Operation. This proves atomic rollback and an independent successful retry, not automatic settlement of the interrupted Operation or the complete 63 MiB application workflow. Evidence: `memorycommit1796/operator/actual-evidence.json` and `memorycommit1796/durable-state.json`.

E1797 also ran the original release recipes for `memory_contract` and `prompt_memory_v3_contract`: clean, build, then run each executable with the unchanged 180 s limit and the Full package's Memory plugin. Both passed (7.12 s and 8.47 s) with no forced cleanup. They exercise installed plugin integration and the contracts' existing legacy oracles; they are not evidence that the entire large-context application workflow ran. Evidence: `memoryrelease1797/summary.json`.

### Unsplit Core: cost of the refused read-view request

E1798 decoded E1690's failed `host.process.readview` Operation from the retained database. Its canonical plan round-tripped byte-for-byte and matched the effect record. The `grep` contribution had no ordinary Tool payload profile, and its frozen request contained no `input`. Those select a 131,072-byte raw output bound and a 196,608-byte encoded service bound. Before opening a worker channel the unchanged code therefore requested the **16,777,216-byte floor**, not eight times the encoded bound and not the attachment invoice.

E1690 did not sample `charged` under the bank lock. Under the existing accounting invariants, a 144 MiB bank admits at most nine floor-priced transfers, so the transfer-count ceiling of 32 cannot explain this refusal. The byte limit implies more than 128 MiB charged, but does not give the exact balance, shortfall or owners at that instant. E1639's measured balance belongs to a different invocation. Evidence: `coreinvoice1798/summary.json`; no new Core run, quota change or release credit.

### Time inside successful resident-owner model calls

E1799 read E1781's completed store without making another request. The two Runs lasted 3,925 and 3,856 ms. Relative to each Run's start, the context safe cut was recorded at 1,223 and 1,181 ms; model dispatch was claimed at 1,992 and 1,908 ms; provider terminal state was recorded at 3,536 and 3,443 ms. Separately, the local listeners measured only 1.069 and 0.780 ms from HTTP arrival to return. The database and listener clocks were not aligned. This locates time both before and after dispatch in successful calls; it does not establish which function consumed it or remove the cold startup failure. Evidence: `runlatency1799/summary.json`.

E1800 rebuilt three standalone release contracts at `bc5598115a`. `operation_domain_vnext_contract`, `run_lifecycle_vnext_contract`, and `product_continuation_contract` each passed the original 180-second executable gate and process-custody check. The continuation fixture used the packaged Workflow plugin and a real SQLite store; its seeded approval and legacy records exercise recovery and migration, not a new model dispatch. Evidence: `recoveryrelease1800/summary.json`.

E1802 sampled the actual broker's process-wide CPU counters around both successful local requests. Before each HTTP arrival, the broker itself used 3.50 and 3.77 seconds of user CPU over 3.09 and 3.29 seconds of wall time; concurrent threads explain why CPU time can exceed wall time. Neither a slow listener nor a broker that was simply sleeping explains those intervals. E1803's separate debugger run found package reads and native SHA-256 underneath `ProductInitialContextSequence.validate`, a SQLite event commit, and a canonical-witness comparison under `SqliteModelProviderDispatchReader.readObserved`. Four stops identify work, not its fraction of elapsed time. Both runs used a prewarmed owner; neither counts toward the cold five-second gate. Evidence: `ownercpu1802/cpu-deltas.json` and `dispatchstacks1803/slice-{0,1,2,3}.json`.

### Comparing the durable model request without measuring it twice

`canonicalAgentValueMatches` still compares the actual canonical bytes, including raw number spellings, UTF-8 bytes, object ordering and child boundaries. The comparator now reads each decimal length from the frozen witness, rejects malformed or overflowing prefixes, and checks that comparison of that child ends at exactly the declared byte. It no longer walks the same subtree once per ancestor just to calculate its length. No digest substitutes for the witness; package verification, admission and payments are unchanged.

E1805 built Native Domain from the changed sources (ELF `6d4350f865e33188da7097e89e856f19899bb5c5c023d881d8dd39eb7aaaa759`). All five comparison cases passed out of 179 Domain cases enumerated. They include the full model history, malformed sibling boundaries and an 8 MiB value containing NUL bytes. A separate timing probe failed to compile with the pinned compiler (`begin of range is zero`); that probe produced no timing result. Evidence: `canonmatches1805/summary.json`.

E1804 independently passed four standalone release recipes at `bc5598115a`: Approval Reviewer, context projection, mailbox and child Run. The Task persistence fixture failed on the first launch before testing restart. The checkpoint fixture printed `cjpm build success`, but the watcher could not establish one process identity; its build gate failed and its executable did not run. Neither failure counts as a pass. Evidence: `persistrelease1804/summary.json`.

E1806 passed all nine production builds on the comparator source shipped in `9ef75bc7d8`. App SHA-256: `f98cff075b47e76cc32038c228fcfc6d82177fed03c4cd075daaac162968f3ad`; Minimal: `af829ba8500958059d4b6902e8a5ff73e9d36bdffb989f71c69780af9716912b`. E1810 measured both comparison implementations in one Native executable against the same 41,548-byte witness. Over 16 interleaved samples per implementation, median comparison time fell from 3.806 to 0.761 ms. This is a comparison measurement, not five-second cold-request evidence. See `canonprod1806/summary.json` and `canonbench1810/summary.json`.

### Restoring the Task persistence release check

E1812 exposed the first E1804 launch error: `tool.not_found`. The fixture called the retired bare `task` name without installing its provider. The repaired fixture imports the real Workflow package, pins its digest to `propose` and the `prepare_child`/`child.start` selection, then invokes `plugin.axyndra:workflow.task`. It verifies the returned batch contains exactly the requested job and releases the returned payload before waiting. It does not install a tool alias or write Task snapshots.

E1811 passed the original standalone clean/build/execute recipe, including its five-second job wait. Both independently named jobs completed, two positive-revision SQLite snapshots survived Product reopen, and deliberate corruption of the first snapshot produced a recovery warning and no guessed jobs for that root. The outer watcher confirmed process closure. The Native fixture ELF was `5973c0261f9a835f74683a0a83d6cad216e38ce72356fcb54f4347f5a4708dcf`; the E1756 Full Workflow ELF was `b2dcb1639a84c11231d12e479d1c2de97ddb6d8e82d4eabbbe66f07d14e0fc99`. Evidence: `tasktyped1812/execute.log` and `taskrelease1811/summary.json`.

E1809 rebuilt the unchanged checkpoint contract in a private PID namespace without changing the watcher. Build custody passed; execution failed the original combined checkpoint-projection/rewind assertion. This distinguishes an actual contract failure from E1804's unknown process identity. Evidence: `checkpointrelease1809/summary.json`.

### Public client custody, SQLite and the packaged cold request

E1814's public-client release build tried to resolve the `yjson` tag over the network because its standalone package had no lock. E1820 added only the SDK-format lock for the existing `54b4965dee0f0b96710cbc678ec5ec9a126b055c` commit. A fresh offline clean/build/run left that lock byte-identical. With the actual installed Workspace package and one fixture-model call, the request stayed billed after Core returned and was released only after the public caller acknowledged its own frame. ELF: `a9dd9466614ae2649504d5fbf287e545edc01a74aa1147e4e013128b2f255990`. This does not retire other Prepared references. Evidence: `storescale1814/public_client_request_custody_contract-build.log` and `clientcustody1820/summary.json`.

Two other E1814 standalone release contracts passed on `eb8ee68a37` with closed process custody: SQLite Run repository (including continuation and unsettled approval), and 100,000 Thread items / 256 Lanes. Evidence: `storescale1814/summary.json` and the two execution logs.

E1807 assembled the E1806 App as Coding host `64af1fac47f32317f7afae65ebdbb047fbc468d8195916f4fface92885260463`. The 46 Skills protocol cases, clean-environment startup and setup passed. The first original `--print --model profile-one/shared-model` call still exceeded five seconds; the second did not run. The fixture reported five surviving children at worker exit and none after cleanup. No successful cold response or natural shutdown is claimed. Evidence: `codingcanon1807/summary.json` and `coding-original-cold-profiles.log`.

E1813 split the checkpoint assertion and found that the original positive prefix did not cause unforced compaction (`removed == 0`). A candidate using a verified over-trigger prefix and actual installed checkpoint calls passed all three scenarios in E1817. Its byte-identical clean-build ELF (`1ca02a5537d8f65e9a3d975a32c1d05bf093a8867a7ab7900e96b1ab2c8a6ada`) failed at rewind in E1819 with `operation.owned_checkpoint_failure_pending`. No checkpoint release pass is credited. Evidence: `compaction1813/`, `checkpointcanonical1817/` and `checkpointrelease1819/`.

### Real checkpoints and failed-fixture cleanup

The standalone fixture installs the Compaction package and binds `checkpoint` and `rewind` to its current digest. It obtains the checkpoint ID from the persisted call and requires the matching successful result. The positive prefix crosses the original 80% trigger at 24,000 input tokens; the 60% target and oversized-branch refusal are unchanged.

E1828 passed the release clean/build/execute recipe using fixture source SHA-256 `d083089246c5e366f510856199ee5303233b2ef89d78343b07b155af18781a0d` and ELF `e7628a4041390f683c45171a2473d3afb59f463409de62a057af040152272b9d`. The fixture now closes Product when an assertion throws, and removes its state only if Product acknowledges closure. E1829 added a private failing assertion immediately after the real checkpoint. The original assertion reached the caller, exit status was 1, and the watcher found no survivors, forced cleanup or unknown identities. That demonstrates process cleanup, not DATA acknowledgement. Evidence: `checkpointcleanup1828/summary.json`, `checkpointfault1829/summary.json` and `execute.log`.

E1824 captured `thread.readback_failed` inside the original pending failure owner. The preserved database copy passed `quick_check` and contained contiguous ordinals 1–25 and completed checkpoint and rewind Tool receipts. Its only context checkpoint still ended at ordinal 16; completed Tool receipts do not prove a successful rewind projection. The bounded diagnostic in E1826 and all three independent E1827 homes passed, so no failing inner exception message was captured. The cause remains open. Evidence: `checkpointwindow1827/summary.json` and the E1824 `canonical-evidence.json`.

E1822 separately passed the Domain, v3 Domain, Ports, fixture Model Adapters, Tool Runtime, Thread Runtime and AppProtocol release contracts. Artifact built, but its legacy catalog did not produce approval for the bare `bash` invocation. The large dual-stream preview, complete blob, failure and export assertions after that point have no pass from this run. Evidence: `releasecore1822/summary.json`. None of these results qualify the full Product, Core, cold profile or release gate.

### Verified Shell output previews

The previous Shell package returned only a prefix after artifact retention. E1831's two-stream UTF-8 test failed on the old package and passed on the new one. The endpoint keeps only the suffix window of the already validated chunk stream, then combines it with the Host's prefix after the final digest acknowledgement. The omission count is in bytes, and the whole preview stays within 4,096 bytes. All 18 packaged protocol cases passed, including rejection of a forged acknowledgement. Shell ELF: `f27ce65527f57e5a8980929cce9bd330a97ef7aaabaa5f3b8b0e73fd85cae405`. Evidence: `shellpreview1831/old.log` and `shellpreview1831/package-validation/summary.json`.

E1833 used this package in a private Product executable with the original Artifact command and 30-second command timeout. The command required its own approval after separate service startup; the effect file did not exist before approval and contained exactly `x` afterwards. Both streams exceeded 1 MiB. Their byte counts, preview edges, full contents read back from the Host artifact store, and SHA-256 references matched. The caller had a completed Receipt and the process watcher found clean closure. This is store readback, not the public page/export API. The full Artifact contract, including Eval and persistence failure, is still unaccepted. Evidence: `shellhost1833/summary.json` and `execute.log`.

### Standalone Artifact stops at Eval

E1835 rebuilt Shell, cleaned and built `artifact_contract`, then ran its unchanged 180-second executable gate. It started the installed Shell service and separately approved the original command. The fixture verified both large blobs, UTF-8 previews, pages at the 1 MiB offset, export approval and file contents, and refusal of outside-workspace and sensitive exports. Those page/export assertions use the legacy Workspace fixture entry against the actual store. They do not qualify independently approved Native Workspace calls.

The executable (`5e3fbf9ff996af8ba59f5725a5932276e7b6381a210ab4eddf7135e39d75c37f`) failed at `oversized eval requests approval: did not request approval`; the later persistence-error scenario did not run. The bare Eval name does not select an installed service. The packaged Python runner serializes both whole streams into one hex-encoded response; the Native endpoint's bounded decoder is not a large-output artifact channel. No limit or assertion was relaxed. Evidence: `artifactrelease1835/summary.json` and its execute log.

### Standalone Testkit and selected Product results

E1830 passed the original Store executable gate in 178.72 s with clean process closure. Context projection, child Run and mailbox also passed; these are repeat checks, not three additional contracts. Testkit initially failed to compile. The extension import alone (E1834) did not resolve the receiver type; with both imports E1836 reached the actual `NoneValueException` in the fixture assertion. Testkit now checks the advertised action: the qualified Native `glob` receives the canonical business constraints without a `_plan` field; the compiled form must include its step and action. E1837 passed standalone clean, build and execute. ELF: `e5639dae1d9d91604d9093287bd3c9fbecbaf5ed5ba75e5a7e1f73fd7da20c56`; the generated lock was byte-identical. Evidence: `releaseboundaries1830/summary.json`, `testkitactions1837/summary.json`.

E1825's Product build exceeded the unchanged 900 s deadline: no executable and zero tests. E1832 rebuilt with exclusive access to the same budget, enumerated 1,100 cases, and ran the 474 previously passing cases in separate processes. On ELF `3170bb9e053af37b95362595bd7cf0433e71a59729350767be9aacd83c8daf30`, 470 passed and four crashed. The channel cancellation case faulted in `CheckAndPush → GCTib::ForEachBitmapWord` under `Mutator::GcPhaseEnum`. The HTTP parent deadline and startup quarantine cases faulted at the same `CheckAndPush` instruction; their next reported frame was `CJ_MCC_C2NStub`, not the full channel stack. The mixed-provider case faulted in the `GcPhaseEnum` reference-field callback. None of the four passed. The 626 excluded cases were not run. This uses the E1825 source closure at `18419eeac8` and the recorded package fixtures, not the new Shell. Evidence: `productexclusive1832/summary.json` and its four case logs.

E1823 did not measure the cold startup CPU distribution: the sandbox denied `cpu-clock:u` before invocation, and the trace contained zero bytes. No sampling privileges or deadlines were changed. Evidence: `profilecpu1823/summary.json`.

### Matched performance on the E1807 Coding host

E1821 ran the original seven-record performance gate on both packaged hosts, sequentially with exclusive access. Both arms used the same SDK, interpreter, echo fixtures, paths, and fresh state. The baseline's annotated yjson tag resolves to the same commit (`54b4965dee`); neither arm used the other's ELF. Baseline host: `a85907b7df0bb579ceb9b68339eadbc1c43b165616571187921bd6debd3af498`; candidate: `64af1fac47f32317f7afae65ebdbb047fbc468d8195916f4fface92885260463`.

| Metric | Samples/arm | Baseline p50 / p95 | Candidate p50 / p95 |
|---|---:|---:|---:|
| Extension activation (µs) | 12 | 40,972 / 101,400 | 40,270 / 41,975 |
| First extension call (µs) | 12 | 1,549 / 2,042 | 407 / 494 |
| Steady IPC (µs) | 240 | 1,360 / 3,922 | 167 / 233 |
| Extension host RSS (bytes) | 12 | 18,366,464 / 29,106,176 | 15,282,176 / 20,721,664 |
| Cancellation after 100 ms trigger (µs) | 12 | 123,436 / 127,948 | 122,075 / 125,974 |
| Disabled-plugin `/help` (µs; RSS bytes) | 20 | 105,856 / 144,554; 91,381,760 / 91,672,576 | 411,972 / 422,950; 52,584,448 / 53,211,136 |
| Declarative inspection (µs; RSS bytes) | 20 | 106,541 / 124,518; 91,312,128 / 91,725,824 | 433,607 / 438,803; 52,551,680 / 53,096,448 |

Both absolute gates passed. Candidate inspection and `/help` took about four times as long at the median despite lower RSS. Neither command dispatches a model request. These measurements qualify the named host pair only, not the later Shell package or a final release. Evidence: `matched1821/{baseline,candidate}/summary.json` and the original gate logs.

### Program fixture consumes installed identity without copying registry records

The Program fixture needs two package digests and one version, not the complete Workspace and Program records. It now checks the namespace and Native entry kind on each live imported record, copies those three fields under their original bank, and closes the record before enabling the package. A digest published into operator configuration still pays for each occurrence. Source checks compare the immutable copied fields without exporting another string. The fixture no longer serializes or retains a record graph. No production quota, capability, Source, SQL join or release rule changed.

E1838 built a fresh executable from fixture SHA-256 `298675cf1f1640bf9bda2c3436d28ca2d0a8dc525be0f38e45c2adb6960dff7f`. The original Program budget and cancellation/recovery modes passed on ELF `ae66d11231680e84d95929ee9217037144f485abbe326564a2f14935e2693254`. E1841 used a private entry to call the original file-plan suite, including the real storage fault. Generated Source, permissions, immutable preview, refusal and SQLite settlement assertions passed in 50.85 s on ELF `b14233ae9869954375cb17eb64e5ccbde8f618965aa32bc644a64badd7a0fe88`. Neither run required forced cleanup. The unsplit GC-blocked run was not repeated. E1776's historical copy invoices do not measure the new refusal-time balance or establish that the full Core capacity failure is fixed. Evidence: `coreprojection1838/summary.json`, `planprojection1841/summary.json`.

### Cold profile: measured broker reads during the five-second window

E1839 never reached `invoke`: the read-only fixture workspace rejected its registry lock during operator setup. E1840 provided a writable, isolated registry workspace and passively sampled the unmodified E1807 Coding binary. The first local profile timed out after 5.003 s; profile two did not run. Of 194 sampling rounds, the same broker appeared in 192. Between its first and last observations (51–4,988 ms), the broker accumulated 2,503,876,570 `rchar` bytes, 45,716 read syscalls and 6.41 s of process-wide user plus system CPU. The print client accumulated 106,052 bytes and 0.02 s of CPU. Package files were open on the broker in 121 samples, including installed libraries and files from all nine shipped packages.

`rchar` counts bytes read across file descriptors, not physical disk I/O or bytes uniquely attributable to verification; descriptor sightings are not hash counts. These measurements locate work in the broker but do not authorize skipping verification. Earlier one-companion and all-file two-reader assignments already failed the original deadline. The watcher required no forced cleanup here; this does not alter E1807's separate cleanup failure. Evidence: `coldobserved1840/summary.json`, `samples-profile-one.json` and `worker.log`.

### Which Product cases remain unexecuted on E1832?

E1846 joined the E1832 natural inventory to the original qualified results by exact case name. Of 1,100 names, 470 passed, four failed and 626 were not executed on that ELF. All 626 unexecuted names have prior failure classifications in the deferred set: 581 match E1523's ledger and 45 match later individual records. One old test name no longer occurs in the inventory; its result was not transferred to its replacement. No previously unclassified name was found in the excluded set.

This is a selection check, not a run. A historical GC frame or a static attribution of a historical `CheckAndPush` leaf does not diagnose a test that never ran on E1832. The private join retains each case's source record, including the separate E1487 portable-Skills crash and the limits of its attribution. Evidence: `inventory1846/summary.json`.

### Release assemblies from the verified host and revised Shell

E1842 assembled Minimal, Coding and Full from `313a867d04`, with the byte-checked E1806 host build inputs. Minimal packaged ELF `45627b04ece77cb6385f7e4082fba4b775b183cad873316eca16b9aad35bd9d1` passed clean-environment startup and six empty/offline cases. Coding and Full packaged host ELF `64af1fac47f32317f7afae65ebdbb047fbc468d8195916f4fface92885260463` passed clean startup, setup and all 46 Skills protocol cases in each distribution. The distributions contain 0, 9 and 17 plugins respectively. In both larger distributions the Shell checker received `--package` instead of its required `--binary` and exited with code 2 before testing; this receipt gives the Shell protocol no credit. Evidence: `releaseprojection1842/summary.json` and the per-distribution logs.

E1845 corrected only the checker invocation, passing `--binary` for each E1842 installed Shell. Coding and Full contained the same Shell ELF (`384657ff224370c0130bed3329a01734f46c3f1d3673c45d9e6b135ca6ea3074`); all 18 wire cases passed separately in each distribution with physical process custody closed. This corrects the missing protocol evidence, not the cold model or whole-distribution results. See `releasewire1845/summary.json`.

E1847 passed four standalone release recipes on `1a39dbe9ad`, each with a fresh clean/build and the original 180 s execution limit: Thread Runtime Integration, Testkit Extension, SDK and Extensions. Thread Runtime verified concurrent snapshot consistency; Extensions exercised the atomic installer retry and SDK authority boundary. These are consumer builds against the pinned SDK, not a rebuild of the SDK. Each watcher confirmed physical process closure. The four executable hashes and commands are in `standalone1847/summary.json`.

### Three model-selected Program Runs and a separate control failure

E1844 used one Product, the actual installed Program and Workspace packages, and the original inspection assertions. The model-selected Program completed once in the first Thread and twice in the second, each with a new Run ID. A hash-verified, read-only copy of the closed SQLite Store passed `quick_check`. Each Run had seven committed Operations with completed Receipts: the Program Root, one Workspace grep, two Workspace reads and three process read views. Run inspection also returned the expected SDK identifier and both 64-character digests.

The final WorkspaceRead-only direct control call did not satisfy the original `tool.capability_denied` return assertion. Its separate Run was `failed` with no Operation, effect or Receipt; that does not establish its returned error code. The original contract therefore failed. No source or owner refund is inferred from the three completions. Native consumer `234b6c9168b35e7b98bd29533ba127e9bfe191682adc1f5c3edae30310ce5ed7`; evidence: `programsequence1844/sequence.log` and `canonical-receipts.json`.

### Returning the installed record after a service-start lookup

`ProductRuntime.startPluginService` takes an owned record from the Registry. Its caller receives a service outcome or error, never that record. The method now closes the record in `finally` after its last use. Transport selection, current package and grant checks, caller cancellation and process cleanup are unchanged. This is not a refund for a service, its output or an unknown Prepared consumer.

E1848 reproduced the leak: three explicitly approved attempts to start a disabled Git-acquired plugin correctly returned `plugin.service_unavailable`, but the original retained Registry byte and lease-count comparison failed. E1849 exercised the same three refusals on the fix. Both counters matched their initial values, the full standalone acquisition mode passed and the watcher found no surviving process. RED ELF `dd1d801643ca2aaf1cf1868c2a59edb79169a493d9e5180e47043f74a0f67285`; GREEN ELF `db4e6df5d97a4b661943511ef952949d88c5ce8d14872ae013410f1835cd7f38`. Evidence: `redservicerecord1848/` and `greenservicerecord1849/`. These measurements do not close the historical Core bank refusal.

E1852 passed all nine production build stages on the service-fix source shipped in `1d3fe53a98`. App ELF `dd9ca61409b3d4fe4825b5e43573c3f43ee767c4fd0966641f463fe3463d239a`; Minimal remained `af829ba8500958059d4b6902e8a5ff73e9d36bdffb989f71c69780af9716912b`. The pinned SDK was used as installed. Evidence: `serviceprod1852/summary.json`. E1850 exercised a successful service start and dual-stream Shell command on that source, then failed: the independent blob read had a Receipt and no pending review under `AlwaysAsk`. That is not a pass for artifact disclosure.

### Static CLI registry and the installed MCP service

E1853 passed the original Skill Runtime, orchestration, client and scripted chaos release consumers on `1d3fe53a98`. The standalone CLI registry consumer failed at `/mcp`. Its list still expected the retired builtin and omitted `/view`; the count alone could not distinguish them. MCP is a plugin service, while `/view` is a builtin for discovering and opening installed Views.

E1855 updated only the expected command identity and added a negative check that `/mcp` has no builtin route. The original clean/build/run passed, including typed routing and completion, on ELF `c53fa52d2bd2da08f67ee209330a22663629aebc92203d928f4dfccfd9ca383b`. No production route was added. This checks the command parser and registry, not an end-to-end packaged CLI session. Evidence: `releaseconsumers1853/` and `clischema1855/`.

### Independent review for a retained Shell artifact

E1850 reproduced the disclosure: under `AlwaysAsk`, the Shell result's `blob:sha256:` reference opened a completed `read_resource` Receipt without a pending choice. The repair marks only Host-classified artifact references on the prepared read. It preserves capability checks, passes the authenticated caller's settings and cancellation to the new Root, and does not pass the Shell's approval. Ordinary resource URIs are unchanged.

E1860 exercised the stricter case: `AlwaysAsk` on the request, `Yolo` as the Product default. The real Shell produced two retained streams. Its Operation ID could not approve the read; before the read's own choice there was no page or Receipt, and session approval was unavailable. Approving the distinct Operation returned the exact first 1,048,576 bytes, with the original reference, offset and truncation flag. SQLite linked the completed Receipt to that `read_resource` Operation, not a Derived admission. The consumer then passed paging and export checks and failed later at `oversized eval requests approval`. Artifact disclosure passed; the complete artifact contract did not. Consumer ELF `df35c9e41b0dc8598c9c2a3458f5f0424c578b6c2642655cae0f3cb14fcb0e47`; evidence: `artifactoperator1860/`.

### Direct Program admission before durable Thread creation

E1854 returned `Completed`, not a typed capability refusal. The failed direct Run had no Operation or Receipt, but its Thread existed. Its frozen lane contained the qualified Program with `available_at_snapshot=false`. E1861 now rejects an explicitly unavailable ordinary direct route before acquiring a Thread. It uses the same frozen lane as the later consumer; a missing name is not this refusal, and a visible name is not an execution grant.

The original `tool.capability_denied` assertion and zero-Thread SQL passed. A separate caller with both required capabilities read the real file through the Program Root and its two completed Derived Receipts. The three model-selected Runs retained their 21 completed Receipts. A read-only Store copy passed `quick_check`; both file hashes were unchanged. Evidence: `programdenial1854/`, `programadmission1861/{summary,readback}.json`. Consumer ELF `83a3c5d35d1fe3881dee43f177bf4e0058c0544f1e0ee88a57572aeb3722bebf`. This was not the unsplit Core suite.

### Program request counts and partial Root recovery

E1859's reopened Store had the failed partial Root Receipt, the completed Workspace read and its nested readview Receipt. The denied write created no child or synthetic Item. The persisted output said `partial`, but `sub_call_count` was 1 for two requests. The base Host counted valid bridge requests **before** dispatch. The plugin-first package instead counted interpreter suboperations plus emitted previews, omitting readonly requests that the Host refused.

E1862 counts actual emitted requests for both services. A refused request counts; a preview blocked at the 32-call ceiling does not. Neither case implies a new Receipt. The wire assertion expecting zero after observing `program-call-1` was corrected; the original durable partial-result and child-Receipt assertions were unchanged. All 28 protocol cases passed on Program ELF `1a0d644152aa387d15b7d68a037c661ce04d5688ea7d31d5f8ec82058c1302ec`. The same E1859 Host consumer (`3cf88951a9b2ae347eeacdf56e0bdd2465b1c406a1456a4936150a0465b8fefb`) then passed the partial Root, original budgets, six refusal scenarios and reopened SQL with the new package. Evidence: `partialframes1859/` and `programcount1862/`. No DATA return was inferred from those outcomes.

Separately, E1856 assembled Minimal, Coding and Full on the earlier `1d3fe53a98` service-fix Host. The empty offline Minimal gate passed; Coding and Full passed clean startup, setup and the Skills and Shell protocols. E1857 reached the same oversized Eval failure as E1860 with `AlwaysAsk` as the Product default. These results do not qualify the later combined source or the complete application flows.

### Combined Program execution and production build

E1864 passed all nine production builds at `14ba84da7d` with the pinned SDK. App ELF: `e1125a5d62155e16fb1adf14c13c9a68972e0e0ffb48c92226be124f76bd33f0`. Minimal ELF: `751352764b7fc5773603d7fbf0babbd079b7d729f6967bbdeee7c952ef941623`. Evidence: `programhostprod1864/summary.json`.

E1865 built the Program package and passed all 28 wire cases. One Product then ran the three model-selected Programs, the direct capability refusal, the partial Root, the original budget cases and six forbidden operations. After Product close, the original SQL assertions verified the completed Root's source bytes and child receipts, and the partial Root's two requests with one admitted child. The process watcher found no surviving child. This sequence does not recreate the earlier unsplit Core bank balance. Consumer ELF: `4c21164c1ebb50ab935b9259f9f8f8a288dd2b6ad1e4239e6eed008ce4dc7735`. Evidence: `combinedprogram1865/summary.json`, `sequence.log` and the retained Store.

### Existing plugins during the cold profile timeout

E1863 found nine installed manifests before the first timed invocation on the E1856 Coding package. The local model request timed out after 5,003 ms; the second profile did not run. Between 77 and 4,995 ms the broker accumulated 2,343,840,782 `rchar` bytes, 41,980 read syscalls and 6.36 seconds of process-wide CPU. Installed package files were open in 105 samples and bundled files in 17. These are sampled open files, not counts of verifications. This was an existing registry, not an empty first install. The process watcher required no forced cleanup. Evidence: `coldregistry1863/summary.json` and `pre-invoke-profile-one.json`.

### Shell completion when the artifact root is unsafe

E1868 put a regular file at the disposable Product's blob-directory path after Shell requested approval. The write to the backend had a completed child Receipt, but the Root Receipt was `unknown` and the Run required recovery. The later Product-close error masked that distinction in the console. A separate SQLite analysis copy passed `quick_check`; the original DB, WAL and SHM kept their hashes. Evidence: `shellrootfaultred1868/readback.json`.

Only a Store refusal of `artifact.root_unsafe` before opening a file can now select observation without retention. An authorization or Source failure cannot select it. The Host charges its usual fixed observation buffer and verifies the Root, chunk offsets, total and digest. The plugin reports a per-stream storage error without a blob reference. No schema or stored-data migration is required.

E1873 passed the real storage-failure scenario on Host consumer `ef7043d722ac8d961c3a43771310ec169e0023ab03ae83b68d78b76485f0984b`: one approved command, one marker, exit 0, 1,049,000 stdout bytes and a completed Root Receipt. The blocking file was unchanged. SQLite had neither a blob of that size nor a retained observation for that Operation. The ordinary dual-stream case still passed its read and export assertions; the full executable failed later at the bare Eval approval assertion. Evidence: `hoststoragesource1873/summary.json` and its execution logs.

E1870 passed all 20 native wire cases on the same Shell package used by E1873 (`55728dc53b70b13652335590baaf545aaabda46326d33628916bde4fca6016ac`). An unretained stdout can coexist with a retained stderr and command exit 7; a wrong final digest keeps the outcome unknown. The first mixed-stream test exited the persistent shell before it could report completion. E1870 exits a subshell instead, leaving the real end-of-command marker intact. Evidence: `shellrootfault1869/package-validation/` and `shellapprovedfault1870/package-validation/`.

### Program admission persistence on a reopened Store

E1872 reopened a copy of the E1865 Store, then the fixture tried to import the installed Program a second time. `plugin.duplicate_namespace` stopped the test before the SQLite trigger. The fixture now reads the name from the installed, ready Native contribution; it does not import, enable or rewrite grants on reopen.

E1875 used the same starting database (`e89a1eff08798c6b19620a75e82655e5c5b3fe4f048085936c01962b5dfa7f29`) and the same packaged Program. The model selected `plugin.axyndra:program.run`; the original trigger refused Root admission. Submission returned an error and the execution probe recorded zero calls. After Product close, read-only SQLite inspection found exactly one canonical ToolCall for that request, zero Operation and derived-admission rows, no surviving trigger, and a `recovery_required` Run. `quick_check` passed; the original E1865 database kept its hash.

Evidence: `programreadyfault1875/{summary,readback}.json`; focused consumer SHA-256 `f5df262728d5abe3882cb1064893e175676952d2c7ffb7c929c181e28629679d`. This verifies the original fault block, not the complete Core executable or recovery from that fault.

### Cold requests with and without a duplicate startup check

E1874 compared two rebuilt hosts against the same nine sealed Coding packages, fixed SDK and original loopback profile fixture. Each had a fresh operator; all nine packages were installed before timing. Both timed out on `profile-one/shared-model`: 5,003 ms in each arm. Neither HTTP handler received a POST and profile two did not run.

E1880 read separate copies of each database, WAL and SHM after physical process cleanup. Both passed `quick_check`, kept their original file hashes and contained the `profile smoke` input and a completed `host.context.read` Receipt. The published host (`14ba84da7d`) reached the context safe cut 1,163 ms after Run start, with no model attempt recorded. The private host reached the cut at 1,237 ms, created an attempt at 1,860 ms and claimed dispatch at 2,018 ms. The attempt was cancelled, with no provider terminal state. Claiming dispatch is not evidence of an HTTP request. The private change was not shipped; one paired timeout does not establish a speedup. Evidence: `pairedlastpin1874/` and `coldstore1880/summary.json`.

### Matched concurrent output and physical cancellation

E1877 built each arm from its own source: base `4d88fa6072` and candidate `ddffdde933`. Both used the pinned SDK, the same JS echo fixtures and paths, and the same scheduler exclusion during measurement. For each payload, 12 pairs of overlapping calls on two distinct live workers returned the exact bodies and one progress event per call. At normal close, each worker PID disappeared. All 12 cancellation samples per arm observed the worker before the trigger, received `process.cancelled`, and found no live worker at return.

| Time in µs, P50 / P95 | Base | Candidate |
|---|---:|---:|
| Paired call span, 256-byte output | 2,873 / 10,088 | 603 / 855 |
| First progress, 256-byte output | 1,074 / 1,456 | 499 / 738 |
| Close and reap, 256-byte output | 8,028 / 10,204 | 9,711 / 19,632 |
| Paired call span, 32,768-byte output | 69,121 / 100,165 | 2,188 / 2,901 |
| First progress, 32,768-byte output | 1,631 / 2,082 | 1,025 / 1,245 |
| Close and reap, 32,768-byte output | 5,490 / 11,175 | 9,953 / 20,089 |
| Cancellation trigger to result | 16,650 / 17,406 | 15,943 / 23,014 |
| Cancellation trigger to observed PID absence | 16,664 / 17,416 | 15,955 / 23,023 |

The candidate returned output sooner, but both normal close and cancellation had higher P95. Physical return does not prove DATA release. Commands, four executable hashes, individual samples and watcher records: `matchedload1877/{baseline,candidate}-{output,cancel}/`. This measures the Extension runtime, not complete Product activation, memory or cold provider latency.

### Distribution and production build versions

E1867 passed real assembly and clean-environment checks on `14ba84da7d` for Minimal (0 plugins), Coding (9) and Full (17). Minimal passed the empty/offline gate; Coding and Full passed setup and their packaged Skills, Program and Shell protocols. Coding/Full packaged host SHA-256: `e121fda8a297dfc4edb38bce9317dd4cb477c5a401ce2791f145d9c00077428b`; Minimal: `43f0b07c03bb5800265a8ed29797983f58eb78f5c01c709841194872584797c1`. This predates the Shell storage-failure fix.

E1876 passed all nine production build stages after that fix (`a20c643ffc`): App `a8de4a85ea0b245df19e936bf2be25b09f73fe9d4146932b5a040308b7f46a12`, Minimal `7d1664eea982be4bd2242912fd7dea28118036375f11efe431a50faa05cd69f2`. Those are source build outputs, not a later distribution acceptance. Evidence: `combinedrelease1867/summary.json` and `typedstorageprod1876/summary.json`.

### Scoped enable refusals on a reopened installation

`setPluginEnabled(id, enabled, scope)` acquires separate target and effective records. The idempotent success hands the target to the caller. On a state change the Product now closes its lookup records after activation or rollback. It hands out the durable writer's result only after successful activation. It does not close an installed worker's execution pin or the caller's independently owned record.

E1883/E1884 installed a disabled Native package with a missing dependency, closed Product, reopened the same Registry, and requested enable three times. Every request returned `plugin.component_dependency_missing`; the caller closed each error. Before the fix, each refusal retained 73,568 declared bytes and two leases: 4,534,288 bytes / four leases became 4,754,992 / ten. On the fixed source the readings remained 4,534,288 / four after **each** refusal, and the caller could still read its disabled record. The bank floor remained 16 MiB in both arms. These are declared live invoices, not a physical-memory saving or a refund against a different Core Run.

E1881/E1882 used a newly imported record rather than a reopened one. In that setup the first writer reload also changed the live state's invoice, so it cannot isolate the lookup bytes. E1878/E1879 both reached the original 900-second full Product build deadline before executing a test. E1885 instead built the two affected suites against all production sources. Its Native ELF `f872ccc0d7ba5e20114958828bf8d59b732553281280957b0c9da3bb07c8b59c` enumerated 12 cases. Six were executed separately and passed: the refusal regression, three disabled/scope controls, same-worker reuse, and fresh install/disable/reopen/re-enable. No full Product or Core pass is claimed. Evidence: `reopenscopedred1883/`, `reopenscopedgreen1884/`, `scopedunits1885/`.

### Lane inbox recovery across process exit

E1889 ran the original Core inbox and fork assertions against `99cad28964` in two Native processes. The first installed the pinned Compaction policy, forked the seeded Thread, withdrew steering, queued a follow-up, and delivered a different follow-up inside a live Run. After that process exited, the second opened the same Product and recovered exactly the pending text and correlation ID. The SQLite copy passed `quick_check`: four completed Runs, one queued and one rejected main-Thread entry, and exactly one Step enclosing the delivered follow-up. Both processes were reaped. The earlier E1888 fork stopped without an installed Compaction policy and did not reach recovery. This verifies those clauses, not the unsplit Core capacity gate. Evidence: `pinnedinbox1889/summary.json`; consumer ELF `611509174e807031b606a1ef1ffdb6b8cbec41bfb80c4a57d4d7036888bf7c0f`.

### Production binaries after the scoped enable fix

On `99cad28964`, all nine E1886 production commands exited zero with confirmed process cleanup. Its post-build byte-comparison gate failed: CJPM wrote a target-specific `cjpm.lock` containing only `yjson`. E1890 started each terminal link with the reviewed lock, removed the previous output from the link destination, and verified the generated lock against CJPM's resolved checkout. Both links selected the reviewed `yjson` commit `54b4965dee0f0b96710cbc678ec5ec9a126b055c`; all other bound source inputs kept their hashes. Both executables reproduced E1886 byte-for-byte:

| Binary | SHA-256 |
| --- | --- |
| `agent_app` | `3f74a4f6ed0c682ea94c04c6a674f6552151066699eadfee8320088203da05d0` |
| `agent_minimal` | `7d1664eea982be4bd2242912fd7dea28118036375f11efe431a50faa05cd69f2` |

The reviewed lock was not changed in the repository. The dependency-pin gate passed on both the repository and the fresh release archive. This identifies the binaries; it does not establish a packaged release pass. Evidence: `scopedprod1886/summary.json`, `releaseclosurerecord1890/summary.json`.

### Packaged release and matched measurements on `99cad28964`

E1891 assembled Minimal, Coding, and Full from the E1890 binaries. All 15 selected checks exited zero with confirmed process cleanup. Minimal contained no plugins and passed offline empty-host and clean-environment checks. Coding (nine plugins) and Full (17) both passed clean-environment, setup, and packaged Skills, Program and Shell protocol checks. Coding and Full use the same packaged executable `24a2b0ef5defd9180982a896650f50d33ac0666978c383f560cf5e334ea22e43`; their manifests and plugin sets differ. Evidence: `scopedrelease1891/summary.json`.

E1892 ran the original performance gate sequentially on base `4d88fa6072` and that Coding package, with the same fixed SDK, fixture bytes, normalized paths and clean per-arm state. Both arms met all seven absolute gates. The two packaged CLI operations were slower on the candidate despite lower sampled peak RSS:

| P95 | Samples per arm | Base | Candidate |
| --- | ---: | ---: | ---: |
| Extension cold start (µs) | 12 | 77,020 | 60,540 |
| Extension first call (µs) | 12 | 3,780 | 854 |
| Extension steady IPC (µs) | 240 | 12,033 | 274 |
| Extension host RSS (bytes) | 12 | 29,339,648 | 20,709,376 |
| Extension cancellation after 100 ms trigger (µs) | 12 | 131,556 | 128,345 |
| Plugins-disabled CLI (µs / peak RSS bytes) | 20 | 271,617 / 90,554,368 | 469,181 / 51,228,672 |
| Declarative inspect CLI (µs / peak RSS bytes) | 20 | 191,939 / 90,796,032 | 490,088 / 51,322,880 |

E1893 exercised the original local HTTP profile oracle with nine installed packages. The first call timed out at 5,004 ms with no POST; the second was not invoked. The watcher confirmed process cleanup. E1895's read-only Store copy passed `quick_check`: one cancelled Run, one committed `host.context.read` with a completed Receipt at +678 ms from Run start, and **no model attempt**. Neither these rows nor the seven absolute performance gates establish a successful provider request. Evidence: `scopedmatched1892/{baseline,candidate}/summary.json`, `scopedprofile1893/summary.json`, `profiledb1895/summary.json`.

### Reproducing the read-view refusal on the final source

E1896 kept the same Product and bank through the three matched Program/native workflow pairs, the original file-plan success and fault cases, then the model-selected read-only Program. It used the E1891 packaged Workspace, Program and Compaction plugins. The last Run reached the original inspection assertion and failed. E1897's read-only Store copies passed `quick_check`: 25 Runs / 67 Operations in the main Store and one Run / four Operations in the artifact-failure Store. The inspected Run's `host.process.readview` and `workspace.grep` both have failed `read_view.output_capacity` receipts; the Program Root also has a failed Receipt. No previous refusal's numeric balance is attributed to this invocation. This reproduces the non-GC failure without running the unsplit GC sample. Evidence: `programpressure1896/trajectory.log`, `pressurestore1897/summary.json`; Native consumer `fa37e587776df699503450dfe99eba5c83f34abef274bc1a2461943fa2391ac4`.

E1898 stopped a separate execution at the locked bank refusal. The read-view request (131,072 raw bytes) needed a new 16,777,216-byte reservation. The bank already billed 144,767,072 of 150,994,944 bytes: the request was short by 10,549,344 bytes. The application reported the original failure after the debugger detached.

E1902 reconciled that stop, not the earlier E1896 invocation:

| Billed owner | Bytes | Same-stop evidence |
|---|---:|---|
| Main Product shared ledger | 43,415,560 | Live lease sum 38,333,448 |
| Fault-case Product shared ledger | 17,145,944 | Live lease sum 6,349,360 |
| Program input attachment | 67,108,864 | Writer and evidence present; started, not released |
| Application checkpoint | 16,777,216 | Same Run as attachment; invoking, not transferred |
| Fixed buffers | 319,488 | 32 reservations |

All 54 retained Prepared owners matched distinct Operation leases in the two Stores; every owner still marked its exported consumer unknown. A failed Receipt cannot return these references. The offline reader checked the fixed SDK's `TraceBarrier` and collector methods against this core rather than reusing the historical `IdleBarrier` reader. Evidence: `pressurecapture1898/locked-refusals.json`, `pressuretrace1902/{four-root-inventory,reconciliation}.json`. The shortfall is reproduced and accounted for, not fixed.

### Private cold-host experiment

E1894/E1899 combined the canonical JSON writer change and reduced duplicate unsigned-package inspection, retaining the final pin. The private Host built, but the first local profile timed out at 5,002 ms with no HTTP POST; the second was not called. E1903's read-only Store copy shows one completed `host.context.read` Receipt at +605 ms from Run start and one cancelled model attempt, with dispatch claimed at +1,643 ms. A claimed dispatch is not a provider arrival. Neither change was adopted. Evidence: `combinedprofile1899/summary.json`, `candidateprofiledb1903/summary.json`.

### Core accounting, matched load, and standalone Memory contracts

E1904 tested a private change to read-view row construction. The original model-selected Program still failed. Its two Stores retained 67 Operations across 25 Runs and four Operations in one Run, respectively. Both `host.process.readview` and `workspace.grep` recorded `read_view.output_capacity`. At E1906's separate refusal the bank held 144,696,384 bytes; the 16,777,216-byte request exceeded capacity by 10,478,656 bytes. Differences between invocations do not establish savings. The private change was not adopted. Evidence: `rowinvoice1904` and `rowrefusal1906`.

E1905 checked whether the E1877 output-concurrency and physical-cancellation comparison still applies. All 255 candidate inputs matched at `d4ff9fcd82`, as did the per-arm fixtures and four measured executables. The baseline was `4d88fa6072`, the measured candidate `ddffdde933`. This extends those two comparisons without claiming a new timing sample. Evidence: `loadbinding1905/summary.json`.

E1907 cleaned, built and executed both standalone Memory release contracts against the current Full package. `memory_contract` passed in 7.46 seconds and `prompt_memory_v3_contract` in 9.24 seconds. Both process trees closed without forced cleanup. Neither exercises the separate 63 MiB Product workflow or resolves the historical OOM. Evidence: `memoryrelease1907/summary.json`.

### Eval output: interpreter transport versus approved Product execution

E1908's private Eval package passed all 20 existing native wire tests. E1912 ran all 30 original interpreter tests with Python, Bun, Ruby and Julia; none skipped. Each interpreter also returned both output streams byte-for-byte, split a multibyte UTF-8 character safely at the chunk boundary, and accepted the next two cells in the same process. Evidence: `evalartifact1908/summary.json` and `evalframing1912/{interpreters.log,streams.json}`.

The actual Product boundary did not pass. E1911 built the aggregate release contract, then `ApplicationSession.decide(...).value().getOrThrow()` raised `NoneValueException` before the test could verify the terminal Receipt or read back either artifact. No approved oversized Eval result or aggregate-release pass is claimed. Evidence: `artifactproduct1911/{summary.json,execute.log}`.

E1913 retained the actual Store after a diagnostic replay with the same consumer ELF. The joined approval was `approve`; the channel write committed with its reserved completed Receipt. The parent observed stdout (1,049,028 bytes, matching the expected digest), but had no stderr observation. Its own reserved Receipt was `unknown` and the Run entered `recovery_required`. The cell was not retried. Evidence: `evalstore1913/{raw/index.json,projection.json}`.

E1914 changed the empty stderr poll to a nonblocking read with a local idle wait. The Host can now service stdout and artifact acknowledgements without waiting on a quiet diagnostic pipe. The decoder allocates the exact decoded length and validates both stream headers before requesting storage. The same aggregate consumer passed with the original 30-second cell, no workspace marker before approval, exactly one marker after approval, two byte-exact stored streams and both observations on the completed parent Operation.

The aggregate uses the baseline artifact contract's 16,777,216-byte output ceiling: at `4d88fa6072`, `LocalProcessPort.executeEval` took the effective limit from `defaultProductSandboxResourceLimits()` and the request. Opting into artifacts does not increase an operator's grant. The ordinary Eval contract profile still defaults to 1,048,576 bytes.

E1915 injected a wrong append offset and a wrong final reference into the actual native endpoint. Both calls returned `unknown` with one write and no stderr publication. The unsafe-root control returned observed bytes without references; the normal control returned both expected digests. E1916 then ran `bash support_tests/artifact_contract/check.sh` from a clean build snapshot. Both packages passed preparation (21 Eval and 20 Shell protocol cases, no skips), and the aggregate printed `artifact contract passed` with confirmed process cleanup. Eval ELF: `b561e87e11720b6109653a56550dc3e2731b9f6e1c1f7eae79430b7747932b04`. Aggregate ELF: `0395d819a8ce74e8111ff798dce6c8b6bad873d3241533c2f8ef9e5ed1de510f`. This closes the standalone artifact gate, not the full release. Evidence: `evalproduct1914/summary.json`, `evalack1915/cases.json`, `evalrelease1916/summary.json`.

### Packaged protocols, Minimal model, and the Todo approval path

E1918 assembled Full from `be555ae9bb` with the pinned SDK and the unchanged E1890 Host. The package contained 17 plugins. Its clean-environment and setup checks passed. The packaged Eval ELF reproduced E1916 byte-for-byte. E1918 and E1922 together exercised all 16 plugins that have independent protocol checkers: 606 cases passed, none skipped, and each checker closed its process tree. Memory has no equivalent checker; this result does not cover its 63 MiB workflow. Evidence: `evalfull1918/summary.json` and `fullwires1922/summary.json`.

E1923 paired the unchanged E1891 Minimal executable (`0834a3e1bbc9ab38191441e819980208f2b6effc7c7e1d81e1c97d0fc118811f`) with the final Full model-provider package. All ten `minimal_model_host_contract` cases passed: three local HTTP protocols committed canonical answers, history survived process reopen, missing credentials sent no request, and a partial reply or timeout produced no canonical decision. The watcher confirmed process closure. This was a local protocol fixture, not a public provider or a Coding cold-start test. Evidence: `minimalmodel1923/summary.json`.

E1928 tested Todo first save through the actual Coding TUI. The operator was a private copy of E1893's existing installation; all nine installed package trees matched the current Coding manifest. The fixture selected Workflow and its document grant through the existing operator helper. The PTY showed a separate approval card for the context read and for Workflow during both load and save. Four Allow-once inputs for four distinct pending Operations produced two completed Runs, six committed Operations with completed Receipts, four user decisions and `todo` revision 1 containing the pasted text. No model attempt or forced cleanup occurred. This qualifies the existing-operator flow, not fresh-operator GC cases. Evidence: `currenttodopty1928/{setup,summary}.json` and `terminal/{input.jsonl,terminal.ansi,exit.json}` in that directory.

### Cold profile and retained Core metadata

E1919–E1921 tested a private packaging change: remove only unneeded symbols from nine Axyndra plugin executables, leaving their allocated ELF sections and the SDK libraries unchanged. The nine sealed Coding entrypoints shrank by 18,822,272 bytes in total. E1920's read-only workspace rejected operator setup before timing. In E1921's writable workspace the first model invocation timed out after 5,003 ms, neither local HTTP handler received a POST, and the second invocation did not run. The watcher had to clean up five surviving processes and confirmed none remained. E1925 checked a detached SQLite copy: one cancelled Run, a completed `host.context.read` Receipt at +815 ms from Run start, and zero model attempts or decisions. The original database, WAL and SHM kept their hashes. The size change was not adopted. Evidence: `sizeprofile1920/package.json`, `sealedprofile1921/summary.json`, `trimmedstore1925/readback.json`.

E1926/E1927 inspected the **same** stopped E1898 Core process, without rerunning it. A typed traversal from actual Product, Host and model-runtime roots matched another 360 distinct payments to the two live ledger maps. They declared 15,303,024 bytes on the main ledger and 5,240,720 on the fault-case ledger, excluding per-lease headers. None duplicated the E1902 four-root inventory. The largest group was 46 tool-declaration payments (9,272,512 bytes); three shared tool-snapshot data payments accounted for 3,408,912. These are references inside the already reconciled bank, not extra charges, high-water savings, or proof that a consumer returned. Core still fails `read_view.output_capacity`. Evidence: `typedroots1926/roots.json`, `toolroots1927/roots.json`.

### Minimal invocation: a rejected request is not a persisted Run

E1930 passed all ten Minimal stdio service cases on the previous package, but its Runtime contract stopped at capability denial. E1932 isolated that denial through the packaged CLI. With `yolo` and no capability grant, `invoke` returned `tool.capability_denied` and a generated Run ID. SQLite had no such Run: three Runs and two Operations were unchanged, but a Thread had been created for the denied request. Evidence: `minimalhosts1930/minimal_host_contract.log`, `minimaldenial1932/summary.json`.

Minimal now lets the canonical gateway check capabilities before acquiring the Thread. It checks the acquired owner's workspace before starting a Run and looks up failed invocation IDs by both Run and Thread before publishing them. The fix does not backfill old IDs. E1933 rebuilt Runtime, Host and Minimal with the pinned SDK and assembled Minimal. The ten Runtime cases passed on packaged ELF `7f2ccda07b77020b73ccd58b36f89558b2412674ccea659336738c46582313ad`. A missing grant created neither a Thread nor a Run; a fully granted cross-workspace invocation was refused without a Run. An admitted unknown tool and an admitted worker timeout still exposed their real failed Runs.

E1934 ran the ten model and ten service cases on that same Minimal ELF with the sealed E1918 plugin fixtures. All passed, including actual local HTTP, stdio peer cancellation and physical process cleanup. This is 30 Minimal cases, not a complete Coding, Full, or release gate. Evidence: `minimalbind1933/summary.json`, `minimalpeers1934/{model,service}/summary.json`.

E1931 inspected thirteen tool-declaration owners in the retained E1898 Core process. Their construction frames had returned, but each still had a catalog DATA share. Twelve also carried the original configuration-alias marker. These observations establish no refund; the Core refusal remains open.

### Service-only Minimal installations

E1936 completed the six remaining production builds for `1da22c440f`; together with E1933 these covered all nine stages. E1938 assembled Full and passed Skills, Program, Shell, Eval, clean-environment and setup checks. Coding assembly did **not** pass: the process watcher saw an unreadable process identity (`parent=0`, process group and session `-1`), stopped the build and reaped the remaining processes. No Coding result is inferred from Full. Evidence: `sharedprod1936/summary.json`, `sharedpackages1938/summary.json`.

On the preceding Minimal package, E1937 passed nine management and six offline checks, but the service-only terminal case never reached its first backend call. E1939 captured `plugin.ingress_data_owner_missing`. The installed MCP client and server had completed discovery and tool listing; neither declares a static Tool. An ingress-only loan in a private build funded the parser but not fixed-export validation. E1942 traced the original exception through `fixedExportsCurrent` and `openExternalIngressConnection`. That private change was withdrawn.

E1943 fixed the shared catalog, not the permission checks: the first mounted package that declares no static Tools may supply its actual Registry snapshot payer and counted DATA share. It publishes no Tool, grants no capability and does not replace an existing payer. Both original terminal negatives passed on packaged Minimal ELF `72c60551c74b4c30da1ed65d2a01ba0b2b364f5ba4f4251123daa43d62fe02b8`. The uncancelled queued call never executed, and an operator change revoked the decoder even with a pending cancellation. Each case checked the peer transcript, canonical Receipts and process cleanup. E1944 passed Runtime 10, Service 10, Model 10, management 9 and offline 6 on that same ELF. Evidence: `terminalresponse1939/`, `ingressthrow1942/`, `servicecatalog1943/summary.json`, `minimalall1944/summary.json`. This does not establish a complete Product or release pass.

### Coding and Full at `802ee60f01`: containment, receipts and timing

E1943/E1946 completed all nine pinned production build stages. The native App SHA-256 was `ce16a3e8bfc990fd881ec580da38467cc91c44093a92c8908dcb31fb67878e84`. E1948 assembled both distributions; Coding (nine plugins) and Full (17) contained the same packaged App, `41219c7faa261e72a303a1c58776113de7898e1837c459d6b1a0229cb0be8bc9`. Both passed clean-environment and setup checks. E1948/E1954 passed all 606 cases in Full's 16 independent protocol checkers, none skipped. Memory has no such checker. These results do not qualify its 63 MiB Product path.

* **Core remains failed.** E1949 rebuilt the unsplit `--core-and-recovery-contract` (ELF `3e3f37a87917cb96c6dd2f04622e233522316712089687ad8751cfe6fe8bfb71`). The Program inspection never returned the expected content. E1952 queried detached copies of the main Store (35 Runs, 69 Operations) and fault-case Store (one Run, four Operations). In the completed inspection Run, `host.process.readview` and `workspace.grep` both failed with `read_view.output_capacity`; the committed parent Program Operation has a **failed** reserved Receipt. No numeric shortfall was captured in this execution. The analysis copies passed `quick_check`; all six original Store files retained their hashes.
* **Closed producer is not returned DATA.** E1947 inspected the retained E1898 stop, not the new E1949 execution. Fifty-four paid Prepared owners referred to 18 distinct Core Run controls. The 17 closed controls had 51 associated owners (14,136,728 billed bytes). All 51 marked an unknown export; four also had a counted consumer. The active control had three associated owners (1,165,448 bytes). These amounts were already in the ledger. Removing a producer reference would not prove that a raw export returned.
* **Cold local profiles remain failed.** E1950's first Coding invocation exceeded the original five seconds (5,003 ms). No HTTP POST arrived; the second profile did not execute. E1952's detached Store shows one failed Run, one completed `host.context.read` Receipt at +568 ms and no Model Attempt. At +1,775 ms from Run start the journal recorded `runtime.run_stale`; the diagnostic identifies a model-boundary owner change or cancellation, not which guard fired. The database, WAL and SHM were unchanged by analysis. Neither deadlock nor GC is established.
* **Product coverage is incomplete.** E1953 attempted a new test build for the previously eligible cases, without rerunning known GC paths. Compilation reached its unchanged 900-second deadline. The watcher reaped three workers; no new Product case ran in that attempt.
* **Actual TUI flows passed.** E1956 verified all nine installed Coding package trees before exercising Todo through the real PTY. Four Allow-once decisions produced two completed Runs, six committed Operations with completed Receipts, and `todo` revision 1. E1957 passed ten native-App PTY cases with sealed Full fixture plugins: three streaming protocols, cancel and Ctrl-C with follow-up, HTTP error, timeout, incomplete EOF, invalid UTF-8 and MCP tool use. The fixtures were local; the proof covers neither public providers nor mouse or resize behavior.

E1951 compared the pinned baseline `4d88fa6072` with `802ee60f01` under the same isolated performance gate. Both arms passed its absolute bounds. The relative results are mixed:

| P95 metric | Samples per arm | Baseline | Candidate |
|---|---:|---:|---:|
| Extension cold start (µs) | 12 | 61,405 | 41,024 |
| First extension call (µs) | 12 | 2,510 | 702 |
| Steady IPC (µs) | 240 | 8,156 | 239 |
| Extension host RSS (bytes) | 12 | 29,442,048 | 20,647,936 |
| Cancellation including 100 ms trigger (µs) | 12 | 126,279 | 134,262 |
| Plugins-disabled CLI startup (µs) | 20 | 158,544 | 421,036 |
| Plugins-disabled CLI peak RSS (bytes) | 20 | 94,572,544 | 50,847,744 |
| Declarative inspect startup (µs) | 20 | 156,032 | 443,513 |
| Declarative inspect peak RSS (bytes) | 20 | 94,183,424 | 50,667,520 |

E1955 checked the 255 candidate inputs, both fixture types and all four measured executables against E1877. Its existing 32 KiB output and physical cancellation comparisons therefore still apply; these are not new timing samples. Output-to-reap P95 went from 11,175 to 20,089 µs and cancellation-to-reap from 17,416 to 23,023 µs.

Evidence: `currentprod1946/`, `controlowners1947/roots.json`, `currentpackages1948/`, `fullcore1949/`, `currentprofile1950/`, `currentmatched1951/{baseline,candidate}/`, `lockedstores1952/`, `finalproduct1953/`, `currentwires1954/`, `loadclosure1955/`, `finaltodopty1956/`, `finalproviderpty1957/`. GC is deferred, not passed. Full Product and release acceptance remain open.

### Eligible Product cases and the Core producer-reference experiment

E1958 rebuilt Product from `802ee60f01` using the dependency-ready target, the original 900-second compilation limit and the pinned SDK. The build finished in 314 seconds. ELF `6f88ca3e2e29a6978316186631025471573c84b4ccec9fc7985617dd3ec9ab48` enumerated 1,101 cases. Of the 471 eligible identities, 430 passed in the first 434 invocations. E1962 ran only the 37 not yet started on the same ELF: all passed. Combined result: **467 passed, four failed, 630 previously deferred cases not executed**. The new scoped-enable record-lifetime regression passed.

| Failed Product case | Evidence from this execution |
|---|---|
| `realDirectRootWritesExactBinaryBytesWithOneChildReceiptAndOneSlot` | SIGSEGV at `CheckAndPush`; next frame `CJ_MCC_C2NStub`. GC deferred, not passed. |
| `cycleAndCorruptDependencyNeverPublishDependentRegistrations` | SIGSEGV in `GCTib::ForEachBitmapWord`, called through `BaseObject::ForEachRefField` by `Mutator::GcPhaseEnum`. GC deferred, not passed. |
| `expiryAfterTheModelPacketWasPreparedPreventsProviderDispatch` | SIGSEGV at `CheckAndPush`; next frame `CJ_MCC_C2NStub`. GC deferred, not passed. |
| `ordinaryEmptyEofPreservesItsOriginalDisconnectContract` | Assertion passed, process gate failed. One `/proc` identity had state `R`, parent `0`, group and session `-1`. No cleanup PID or unreaped child remained, but ancestry was unconfirmed. Not a GC classification or a pass. |

E1959 removed only the closed producer reference from a **private** Prepared DATA owner. The unknown-export and final consumer payment rules were unchanged. Its Tool ELF passed 75/75 individual cases. E1961 then rebuilt and ran the unsplit Core contract: the expected Program inspection content was still missing. E1963's detached Store copies show that both the read-view and grep Receipts failed with `read_view.output_capacity`; the parent committed a failed Receipt. Six original Store files retained their digests. The watcher observed 56 surviving processes at case exit, signalled 44 exact PIDs, and reported none remaining or unreaped after cleanup. The candidate was not adopted. Evidence: `readyproduct1958/`, `producttail1962/`, `productcustody1966/summary.json`, `detachedproducer1959/`, `detachedcore1961/`, `detachedstore1963/`.

### Reapplying unchanged distribution defaults

A real Product with an already imported, disabled Native plugin should be able to reapply its unchanged distribution without accumulating private validation storage. E1964 kept the same Product and measured its actual Registry ledger after one warm-up. Three successful applications added one live lease and 10,240 billed bytes **per application**, even though the defaults did not add or enable a plugin. Lease counts went from 7 to 8, 9 and 10. This is live logical custody, not a physical-memory measurement.

`applyProductDistributionDefaults` now owns its private collection payments until the validation and installation helper has returned and closed its descriptors. The same per-entry invoice is acquired before insertion. Exported strings, records, execution pins and their consumers retain their original owners. E1965 passed the new no-growth regression and all five existing Native distribution cases on ELF `223c87b564a7fef6e970c4b5f5e5fe75c3e3e7d93e33b434cc86cef2d4bd27e0`. This proves the reapplication fix, not a faster first model request or a remedy for Core capacity. Evidence: `distributioncells1964/`, `distributioncells1965/`.

### Product selection and unsplit Core after the distribution fix

E1965/E1970/E1975 covered the 469 previously eligible Product identities on one Native test ELF, `223c87b564a7fef6e970c4b5f5e5fe75c3e3e7d93e33b434cc86cef2d4bd27e0`. Of those, **459 passed** and ten crashed with a direct `MapleRuntime::CheckAndPush` frame. The other 633 of the 1,102 natural cases were already deferred and were not rerun. The ten new crashes are failures, not passes. This test build used the same distribution source tokens as `2eb0bd23da` with LF line endings. The previously unconfirmed empty-EOF process case and the real 63 MiB Memory **seed** both passed. The seed does not qualify the entire Memory application path.

Three of the 459 needed a corrected harness mount: their actual child invokes `cjpm test --skip-build`. Direct preflight on the read-only private source failed to change permissions on `./cjpm.lock`. With a writable disposable source, the same ELF passed all three original physical-child recovery cases (context boundary, approval and prepared model). Both the original failures and the corrected process receipts are retained. See `productselection1980/summary.json`, `recursiveproduct1975/recursive-readonly.json` and `recursiveproduct1975/summary.json`.

E1976 rebuilt the unsplit Core from the exact committed source `2eb0bd23da` after removing the prior Product archive, interface and fixture ELF. The new ELF, `5bcfc756669306329b47e322b91615cd5f3af364296d4d34ed9b0d5f99a459a1`, failed the Program inspection assertion. E1982 queried separate copies of the main Store (35 Runs / 69 Operations) and fault Store (one Run / four Operations). The main inspection Run completed, but read-view and grep returned `read_view.output_capacity` at +2,193 and +2,232 ms; the committed Program had a **failed** reserved Receipt at +2,555 ms. All six original Store images retained their hashes. Neither surviving nor unreaped processes were observed at case exit. No numeric shortfall was captured in this execution. See `distributioncore1976/summary.json` and `committedstores1982/summary.json`.

E1971 rebuilt the Product tests from the exact committed source, including the original line endings, after removing the prior unit ELF. The six distribution cases passed. Its ELF, all 1,102 inventory names and all 17 fixture package identities matched E1965 exactly. The 459 qualified passes and ten newly deferred GC failures therefore apply to the exact test binary; no deferred case was rerun for this comparison. E1974 rebuilt Product, RPC and App from the committed source with the prior Product interface, archive and App removed. The resulting App SHA-256 was `d74e63e53d086db873690789608ae8dc1ff6eb05226183c86d704df66116fcd9`. E1989 passed 132 selected Python regressions with their required scripts import root. Evidence: `committedproduct1992/`, `exactproduction1974/` and `selectedstatic1989/`.

E1983 observed field exports in a private, metering-neutral build of the failing Core test. At the first read-view refusal, 55 Prepared owners remained. **All 55 had exported both the display call and the normalized plan.** Of the 52 with a returned producer, four still had a counted consumer; the other 48 still had unknown raw exports. The cumulative traversal increments attributed 2,861,832 bytes to calls and 11,790,640 to plans. These are not bank balances or refundable bytes. This observation does not authorize early retirement; no diagnostic source was adopted. Evidence: `preparedfieldaudit1983/` and `preparedcomponents1987/summary.json`.

## Packaged first request, operator workflow and matched performance at `2eb0bd23da`

E1969 built both distributions from the same behavior source: the packaged App SHA-256 is `d9d10b74e3cee7db1028ac0758df01ddba56a48851cb46650d9c6ebafe6dc2ab` in Coding (nine plugins) and Full (17). Each passed its clean-environment and setup check, and its real Skills, Program and Shell wire checks; Full also passed the Eval wire check. E1978 rejected a changed package digest (`distribution.package_changed`), a wrong workspace interface (`distribution.workspace_invalid`), and two invalid policy declarations (`distribution.policy_invalid`). No registry lock or context configuration was published. E2006 verified on detached Store copies that each rejection left zero Runs, Operations, approvals and model attempts. These checks are not a complete release pass.

E1977 failed the original five-second first-request gate at 5,005.229 ms. The existing nine-plugin operator sent no POST to the local fixture; the second request did not run. No process required forced cleanup. E1993 verified the Store hashes and queried separate copies: one cancelled Run, one committed `host.context.read` with a completed receipt at +853 ms from admission, and no model attempt. This sample did enter Run admission.

E1981 independently observed package file opens, not bytes read or digest computations. At the 5,004.185 ms cutoff there was still no POST. Before durable Run admission (+3,739.66 ms), watches recorded 1,143 installed opens and 239 bundled opens, each group spanning all nine packages. After admission, all 435 observed opens were on the installed Skills package (22 distinct inodes). E1994 verified the unchanged Store images; this sample also had a cancelled Run, one completed context-read receipt (+724 ms), and zero attempts. Five surviving processes required cleanup; none remained unreaped. This narrows the phase, not the cause: it does not establish a deadlock, a GC failure, the number of full hashes, or permission to reuse validation across transactions.

E1985 passed a complete Todo flow on the packaged Coding executable in a real PTY with an independent copy of the quiescent installed operator. The fixture preserved package digests, used four distinct pending IDs and four actual Allow-once keystrokes, and observed two completed Runs and six committed Operations with completed receipts (twice each: `host.context.read`, `workflow.todo`, and `host.plugin.document`). The published Todo revision was 1; no external model or forced reap was needed. This qualifies this sample, not all historical intermittent failures.

E1979/E1996 ran the same seven-stage performance gate against the base and candidate. P95 values below are measured; lower CLI resident memory coexists with slower CLI startup.

| Metric | Samples per arm | Base | Candidate | Unit |
| --- | ---: | ---: | ---: | --- |
| `extension_cold_start` | 12 | 65,141 | 60,302 | us |
| `extension_first_call` | 12 | 12,283 | 892 | us |
| `extension_steady_ipc` | 240 | 10,049 | 285 | us |
| `extension_host_rss` | 12 | 29,224,960 | 20,742,144 | bytes |
| `extension_cancel_after_100ms_trigger` | 12 | 130,084 | 128,026 | us |
| `plugins_disabled_cold_start_us` | 20 | 163,749 | 459,990 | us |
| `plugins_disabled_peak_rss_bytes` | 20 | 94,384,128 | 51,163,136 | bytes |
| `declarative_plugin_inspect_cold_start_us` | 20 | 174,524 | 489,049 | us |
| `declarative_plugin_inspect_peak_rss_bytes` | 20 | 94,265,344 | 51,388,416 | bytes |

E1995 separately bound the previously measured 32 KiB output and physical-cancellation/reap comparisons to the unchanged production closure (255 source files), fixture types and four measured executables. This was **not** a new load run. Its P95 values were 11,175 → 20,089 µs for output and 17,416 → 23,023 µs for cancellation to reap. Neither comparison replaces the unsuccessful packaged model-request gate or the full release gate.

E1986 passed all ten real Linux PTY cases on the rebuilt production App and the sealed Full model-provider/MCP fixtures: three rich SSE protocols, cancel, Ctrl-C, HTTP error, timeout, incomplete EOF, invalid UTF-8, and an MCP tool call. Each had its own retained terminal evidence and physical process receipt. This does not qualify Coding first-request latency, external providers, mouse or resize.

E1991 combined twelve independent Full wire checkers with the four Full checkers already run in E1969. All **606 cases across 16 checkers** passed on the same package: skills 46, shell 20, program 28, eval 21, compaction 30, workflow 172, workspace 44, shell_readonly 20, model_providers 51, ast 26, web_search 30, github 10, lsp 19, dap 18, mcp 51, mcp_server 20. No checker reported a skip, forced cleanup, surviving or unreaped process. Memory has no equivalent wire checker; neither this total nor the separate 63 MiB seed qualifies the deferred full Memory application flow.

### Minimal release, package dependencies and all observed Prepared export sites

E1999 assembled Minimal again with the official package script. The production closure covers 1,053 source, manifest and lock files in 19 local packages; the Product-only changes since `802ee60f01` are outside it. The unchanged Minimal input ELF and the freshly packaged executable matched E1943 (`72c60551c74b4c30da1ed65d2a01ba0b2b364f5ba4f4251123daa43d62fe02b8` packaged). Assembly and clean startup passed. With E1969’s Full fixture plugins, Runtime 10, Service 10, Model 10, management 9, offline 6 and the two terminal negative cases all passed. These 47 current cases include real local peers and process checks, not public provider connections. See `minimalfinal1999/summary.json`.

E2002 checked whether removing the bundled SDK AST library would preserve the current Coding executables. **All nine executables import three symbols** (`_CGPaxifHv`, `_CGPaxiiHv`, `_CGPaxilHv`) that only `libcangjie-std-ast.so` supplies among their packaged libraries. Every entrypoint and shipped library matched its provenance. Removing that library is not a valid way to shorten verification. See `codingsymbols2002/summary.json`.

E2001/E2005 observed every actual raw Prepared getter on E1983’s private ELF up to the first read-view output refusal, without changing production source or retaining application objects. The debugger returned normally; the original unsplit fixture exited 1. At that stop the 150,994,944-byte bank held 144,010,936 bytes. A raw request of 131,072 bytes needed a new 16,777,216-byte reservation: **9,793,208 bytes short**. No output reservation was created. All 3,363 observed getter calls belonged to 55 unretired owners, across 76 field/call-site pairs in 24 immediate caller functions. The legacy executor touched 37 owners and child-plan validation touched 30, with 12 in both sets. No owner was touched at just one code location. These counts are neither retained byte counts nor consumer acknowledgements.

Both detached Stores passed `quick_check`; all six source files retained their hashes. The main Store had 35 Runs and 69 Operations, the fault Store one Run and four Operations. In the completed inspection Run, read-view and grep had failed reserved receipts at +1,905 and +1,959 ms. The committed Program had a **failed** reserved receipt at +2,000 ms. No forced cleanup or unreaped processes were recorded. The fixed quota, floor, SQL/Source and final-consumer rules remain unchanged. Evidence: `preparedsites2001/`, `preparedsitegroups2005/summary.json`.

E1997’s **private** regression with the shipped Skills package crashed on `gc-main-thread` at `MapleRuntime::CheckAndPush` before it produced an accounting assertion. This was neither a RED accounting result nor a pass. It is not an extra case in the published Product inventory and was not rerun. See `codingcontextred1997/summary.json`.

### Rejecting an invalid distribution recipe without retaining registry copies

E2000 reproduced a distinct **non-GC** failure through the public Product API. The same Product already had a disabled Native record. Its distribution named a real, verified package, but the context recipe declared `resources` as an object instead of a list. Each rejection returned `context.initial_configuration_invalid` and published no context file. Nevertheless, each added **24,896 billed bytes and two live leases**: 4,562,192 → 4,587,088 → 4,611,984 bytes; six → eight → ten leases. The two assertions on accounting failed; the error code and non-publication assertions did not.

The recipe preflight used to export two new Registry-backed strings solely to fill its private validation template. It now uses the namespace and digest from the unique manifest entry **after** comparing both against the freshly inspected package. No bank refund or cached inspection was added. If the host needs to publish the initial configuration, it still selects the operator’s actual installed record and its current content lock; the bundle digest does not override that record.

E2003 rebuilt the Native Product tests after removing the old test interface and executable. On ELF `6ddf7180882f78a349cb5feb888c1bd1eba0658f343c70c4100694e68c6e364c`, the same rejection stayed at its initial billed amount and lease count on both iterations. This regression and the six existing real distribution controls all passed (seven selected, 1,103 enumerated). No full Product, Core, packaged first-request or release pass is implied. Evidence: `rejectedcontext2000/summary.json` and `rejectedcontextgreen2003/summary.json`.

### Final Product inventory and production App at `6c5a8e1124`

E2003 and E2009 used the same rebuilt Product test ELF, `6ddf7180882f78a349cb5feb888c1bd1eba0658f343c70c4100694e68c6e364c`. Of 1,103 naturally enumerated cases, 460 were eligible. The seven distribution cases passed; the other 453 had 448 passes and five failures. All 460 selected cases actually ran, with no remaining or unreaped child. The 643 previously deferred cases were not rerun. **455 passes; no complete Product pass.** The 63 MiB SQLite seed passed, not the deferred end-to-end journal application.

E2013 binds each of the five failing logs to the pinned Runtime. Both direct read/mutation continuation cases, the Workflow contribution predicate, the reflected HTTP response and the installed Plan restriction case faulted at `MapleRuntime::CheckAndPush` (PC `0x637f21`). The changed-document-rights case also recorded `GCTib::ForEachBitmapWord` and `GCPhasePreForward`. For the other four, E1488's pinned Runtime disassembly identifies the GC visitor caller; it does not provide a dynamic parent frame. All five failed. No older crash is reclassified.

E2004 rebuilt Product, RPC and App with the fixed SDK; all three stages returned zero and closed process custody. The production App is `b72e4a1e3394a54c4b255fb3799075f0a055be05358215fbd1231d5f1e246784`. The 1,053 inputs from E1999's Minimal dependency closure are unchanged. This does not qualify Coding or Full on the new App. Evidence: `rejectrecipeproduction2004/`, `finalproducteligible2009/`, `eligibleproduct2013/` and `memory1600-oracle-seed/original-oom.log`.

E2014 joins only owner IDs and measurements from the same E2001 Core process. At refusal, 25 surviving owners had entered the legacy executor only, 18 child validation only, and 12 both. The four still-counted consumers belonged to the child-only group. That group also crossed concrete catalog, read-view or serialized verification boundaries; it was not a temporary validation frame. These are getter observations, not evidence that DATA returned. Core capacity, the cold first request, complete application flows and final release acceptance remain open. See `corecohorts2014/summary.json`.

### Final packages, real frontends and the original Core refusal

E2010 assembled Coding (nine enabled default entries) and Full (17) on `6c5a8e1124`. Both packaged executables have SHA-256 `c3ee50e7b6cc48032af4ea2f8498ae5a6cae31dcb3b173e466ea9c2ac1a4f2e2`; clean launch and setup passed. On Full, Skills, Program, Shell and Eval ran 115 wire checks. E2024 compared all 456 regular files, their relative paths and permissions across the 17 old and new plugin trees. They were identical, as were the checker sources. The other 12 previously measured endpoints account for 491 checks; these were not rerun. E2026 also binds the unchanged 1,053-input Minimal closure and 255-input matched output/cancellation closure to this source. These results do not establish a complete release pass.

E2016 passed all ten original real-PTY Provider/MCP scenarios on the rebuilt App and final Full fixture plugins: three streaming protocols, cancellation and Ctrl-C followed by another request, HTTP error, timeout, incomplete EOF, invalid UTF-8 and MCP. All ten exited without forced cleanup. E2025 used the final Coding executable with a copy of a real nine-plugin operator from the previous package. Four distinct user approvals led to two completed Todo Runs, six committed Operations with completed reserved Receipts, one Todo document at revision 1 and no model attempts. No external model, mouse or resize coverage is claimed.

E2020 rebuilt the original continuous Core fixture (ELF `817d4ecb8341c83172cc33d2ee05e9ea60b7303d811e62e86fc00fb79fd12a9b`). The debugger returned zero; the fixture returned **one**. At the locked read-view refusal, the bank held 144,010,928 of 150,994,944 bytes. The 131,072-byte raw request required 16,777,216 additional bytes and missed by **9,793,200 bytes**. Four of 32 slots were used; the refusal was for bytes, not slots. E2027 preserved the main DB/WAL/SHM unchanged and queried a separate copy: 35 Runs, 69 Operations and 69 Receipts. In the inspection Run, read-view and grep had failed reserved Receipts at +2,149/+2,391 ms; Program was committed but its reserved Receipt failed at +2,622 ms. The Run's completed state was not a successful Program result.

The observer failed to save a core (`Couldn't get registers: No such process`); its file watcher stopped after retaining the main database family. There is no second-store image or full same-stop owner reconciliation for E2020. Earlier captures do not fill that gap. Evidence: `rejectedrecipepackages2010/`, `currentproviderspty2016/`, `finalwireclosure2024/`, `finalupgradetodo2025/`, `unchangedloadminimal2026/` and `currentcorefacts2027/`.

### Cold local provider request, package integrity and matched measurements

On `6c5a8e1124`, E2022 ran the original writable Coding `provider_profiles_blackbox` fixture with its five-second limit. The first model request timed out at 5,002.9 ms; all nine plugins were installed, neither local handler received a POST and the second request did not run. Process custody closed without forced cleanup. E2030 found one actual model attempt in the retained DB: `created` / `prepared` at Run +1,741 ms, with no dispatch start, provider terminal or completion. The Run later failed with `runtime.run_stale`; its terminal diagnostic was written **after** the fixture recorded the timeout. This does not establish that the stale-owner error caused the timeout. E2011 and E2017 had a read-only registry setup error and are not provider measurements.

E2023/E2028 traced four files in a separate five-second diagnostic. The installed Skills executable and AST library returned 149,246,988 and 117,655,840 bytes respectively. After that diagnostic's Run admission, the corresponding counts were 87,060,743 and 68,631,976. These are bytes returned by successful reads, not physical I/O. E2029 separately symbolized 14 opens of the AST library against the final Coding ELF: one from bundled inspection, four from installed registry load/startup/activation/pin, and nine from installed context identity checks across request preflight, input preparation and read validation. All 14 contained `pluginPackageFileDigest`. Neither trace measures individual hash latency or permits dropping freshness checks across authorization boundaries.

E2012 rejected four separately corrupted packages through the final executable (package content, workspace and two policy cases); all four stores contained zero Runs, Operations, approvals or attempts. E2015 passed the seven original absolute probes on both matched arms. Extension P95 cold activation was 81,033 → 47,155 μs (baseline → candidate), first invocation 2,399 → 806 μs, steady invocation 8,769 → 238 μs and cancellation 127,749 → 127,454 μs including the 100 ms trigger. Extension host RSS was 29,138,944 → 20,717,568 bytes. CLI help and inspect were slower: 139,299 → 420,875 and 141,864 → 449,782 μs, respectively. Passing these limits does not turn the cold provider timeout, the continuous Core failure, or the deferred Runtime failures into release passes.

### Complete Native Store on the final behavior source

E2031 built `agent_store` from `6c5a8e1124` with CJC `1.3.0-alpha.20261104001050` and CJPM `1.3.0-alpha.09`, after removing the old test executable, test interface, production archive and interface from a private target. The natural no-run inventory contained 261 distinct cases. Running `cjpm test -m agent_store --target-dir <isolated-target> --skip-build --parallel 1 --timeout-each=60s --no-color --no-progress` passed **261/261**, zero skips, errors or failures. Build, inventory and suite all exited zero with closed process custody. Store test ELF: `a0053f1d7d7aa4eca54187d0470db58ca6d31ada2edd44dae52e45e8e29f1aa0`. The suite includes exact canonical Receipt/Source requirements on failed derived completion and real SQLite rollback cases. The earlier 259-case result was not reused. A preflight that detected an implicitly remapped target executed no tests. Evidence: `finalstore2031/summary.json`. This does not qualify the continuous Core or complete release.

### Live owners at the final Core refusal

E2033 ran the same unsplit Core ELF as E2020. The breakpoint identified the actual read-view refusal, then returned control to the debugger before decoding any owner. All 16 inferior threads were stopped; the raw bank balance still matched. The 131,072-byte read-view requested 16,777,216 bytes with 144,011,024 of 150,994,944 already charged: **9,793,296 bytes short**. This is a different execution from E2020. No whole-process dump or application getter was needed.

The four inspected roots held one plan request, 55 Prepared owners, one Core model input and one fixture snapshot. All 55 Prepared owners matched distinct open leases and recorded unknown raw exports. Producers had returned for 52; four owners still had counted consumers. The two ledgers in this bank had high-water / live SUM / live lease counts of **43,020,048 / 37,872,912 / 384** and **16,777,216 / 6,208,448 / 109**. The second ledger was already at the original floor. Even if all other charges stayed unchanged, admitting the output by reducing the first ledger alone would require its high-water to be at most 33,226,752 bytes, 4,646,160 below its *current live SUM*. Spare headroom in a high-water invoice cannot be treated as returned DATA. These four roots are not an exhaustive inventory of all bank holders.

The original fixture exited 1; the debugger exited 0 and process custody closed. All six main and artifact-failure DB/WAL/SHM images retained their hashes; detached copies passed `quick_check`. The main Store contained 35 Runs / 69 Operations / 69 Receipts; the fault Store contained 1 / 4 / 4. In the main inspection Run, read-view and grep had failed reserved Receipts at +1,661 and +1,776 ms; Program was committed with a **failed** reserved Receipt at +1,854 ms. E2032 also retained both Stores, but its breakpoint-callback decoder failed and receives no owner attribution credit. Evidence: `livecoreroots2032/detached/receipt.json` and `stoppedcoreroots2033/detached/qualified.json`. No quota, Source rule or ACK changed.

### Prepared metadata comparisons and lifetime (partial migration)

E2038 adds comparisons for call ID/name and plan name/binding digest without returning a String, ToolCall or plan. A returned producer cannot read through another live reader. Returning one reader leaves the other usable and paid. Host cancellation identity, child parent-binding checks and service selection now use scalar comparisons. Descriptor callbacks still receive their original inputs.

The pinned Native Tool suite passed 76/76, including the two-reader regression and both raw-export counterexamples. Host enumerated 279 cases: six isolated canonical Source/handoff cases, the process cancellation-context case and the Task wait-reader case passed. Two empty-Catalog custody cases failed independently. The earlier E2035 continuous Host run passed 208, errored 67 and failed four. The approved breaking SDK migration remains incomplete: raw getters and generic callbacks still exist. No prior debt was refunded. Earlier Core, provider and Product evidence remains bound to its recorded source and ELF.

E2040 corrected the two empty-Catalog fixtures against the service-only snapshot contract. An empty batch publishes no Tool but retains the real Registry snapshot owner. Dropping the local catalog variable never returned that owner. Both fixtures now test that retirement is refused while construction is active, retire the actual Catalog after construction returns, and require the original bank balance. The staging case also checks the intermediate one-lease reduction. E2038 failed both cases in isolation; E2040 passed both with the same limits. No production behavior changed from `cbceb4c307`.

The full E2040 Native Host run on ELF `2439d1495b41c1bc246a2d48fb3af4e4b3ca10834b1dc812f0ce34794652ae18` passed 269/279, with five errors, five failures and no skips. The staging case that passed independently crashed in `MapleRuntime::CheckAndPush` in this full run. The other nine non-passes have no such classification: three reported capacity errors, six reported failed child preparation/approval, fence or pin assertions. The full Host gate remains failed.

### Rebuilt unsplit Core and retained physical evidence

E2041 rebuilt the continuous Core/recovery fixture from `cbceb4c307` with the pinned SDK after excluding its old executable and the Tool, Host and Product archives/interfaces. ELF `30a49a4bd8ad463b2184664a48f5585914ebd9c302d4481d3b9248cfabc8dfe4` exited 1 without timeout. The Program inspection assertion failed. All six original main/fault DB, WAL and SHM images kept their SHA-256; both detached copies passed `quick_check`. The main Store had 35 Runs, 69 Operations and 69 Receipts; the fault Store had 1/4/4. The actual read-view and grep had failed reserved Receipts with `read_view.output_capacity` at +2,738 and +2,947 ms. Program was committed with a failed reserved Receipt at +3,379 ms. No amount from an earlier refusal is assigned to this run.

The watcher observed 379 processes and four surviving owned processes at the case boundary. None remained after cleanup; there were no unknown process observations or FD watcher errors. Physical custody was **not** accepted and cleanup does not acknowledge DATA. Receipts: `preparedcore2041/detached/qualified.json` and `preparedcore2041/unsplit.log.process.json`.

E2043 ran the seven remaining non-GC Host failure identities separately on the E2040 ELF. Each single selected case passed and the other 278 were filtered out. Two other Source cases passed separately on the E2038 Host ELF, not this ELF. These results do not replace or reclassify the ten non-passes in the E2040 complete Host run.

### Core fixture teardown after a failed assertion

E2045 closes the actual Product when a contract throws before normal shutdown. A failed close is reported separately; the fixture rethrows the original assertion. The denial-query database now closes on both success and failure. Production archives and the capacity contract are unchanged. With the pinned SDK, fixture source `16e2062f3ff9df1abeb66b53d594ee478b23a3e69c2954a9d6c3e347aacb0253` produced ELF `a66389e409157cbb2238fd108e2911beb6eb210963efd95c20b856c6e4e4f1cd`. `--program-budget-contract` passed. On `--core-and-recovery-contract`, the watcher observed 375 processes: none survived the case boundary or required forced cleanup. This qualifies physical teardown in this sample only, not DATA return.

The unsplit gate still exited 1 on the original Program inspection assertion. Both detached Stores passed `quick_check` and all six original image hashes stayed unchanged. The main Store contained 35 Runs / 69 Operations / 69 Receipts; the fault Store contained 1 / 4 / 4. Read-view and grep produced failed `read_view.output_capacity` reserved Receipts at +1,709 and +1,774 ms. The Program Operation was committed with a failed reserved Receipt at +1,990 ms. Evidence: `corefixtureclose2045/detached/qualified.json` and `corefixtureclose2045/unsplit.log.process.json`.

### Derived Receipt settlement: a scoped comparison, not a raw plan export

E2046 migrates `OperationRuntimePort.settleDerivedOperation` to a four-argument SPI. The host passes the prepared child’s live `DerivedReceiptBinding`. Both stores compare child identity and their own admitted plan digest. The in-memory store checks the binding before accepting an identical retry. SQLite performs that check inside the existing transaction with the Run, parent, handoff and reserved Receipt checks. When verification requests `request_digest`, the Store supplies its own stored digest; it does not mutate the caller’s verification object. No schema or Native wire version changed. See the [custom Store migration](../compatibility.md#migrate-a-derived-operation-store).

Returning or throwing from the scoped call revokes the handle before the reader returns its DATA reference. A port may retain the inert shell, not the frozen digest. This changes two JavaScript broker verification paths; it does not clear a raw alias previously exported by another path, certify arbitrary callbacks, or supply execution authority. Source identity for the new handle: `fc373b42115df714`; SQLite implementation: `9273f5487f236db5` (SHA-256 prefixes).

The external Native derived-context contract passed all 19 scenarios, including a real Store round trip and rejection of expired, foreign-child or conflicting bindings. ELF: `4479e76ae3e9645398b4d8b3d002f21a8f01820db69aa6d72104cd6e6b783334`. The complete `support_tests/agent_store_contract` executable passed all 51 phases, including 52 readonly-tree scenarios, the in-memory handoff/settlement case and an actual 5,000-item SQLite append/restore. ELF: `da598d2bf53240dd1bd73c937bea184d184944fce2059ce99047082e3253f778`. Both used CJC `1.3.0-alpha.20261104001050` and CJPM `1.3.0-alpha.09`. Neither contract qualifies the continuous Core gate, the broader public Prepared API or the cold provider request.

E2048 rebuilt the unsplit Core/recovery fixture and six affected modules from the SPI candidate. ELF `d72d6f9890c69ea3de850f1bad7044c0d7dfc3557012bbcf7e791d0ec0475bf6` passed `--program-budget-contract` but exited 1 in `--core-and-recovery-contract` at the original Program inspection assertion. Of 398 observed processes, none survived the case boundary; no timeout or unknown process observation occurred. Both retained Store families passed `quick_check` on detached copies, and all six original images kept their hashes. Main: 35 Runs / 69 Operations / 69 Receipts; artifact-failure Store: 1 / 4 / 4. The main read-view and grep reserved Receipts failed with `read_view.output_capacity` at Run +2,838 / +2,905 ms. Program was committed but its reserved Receipt failed at +3,085 ms. The migration has not fixed continuous Core capacity. No earlier refusal amount is attributed to this run. Evidence: `derivedbindingcore2048/detached/receipt.json`.

E2047 passed the full Native Tool (77/77) and Store (261/261) suites with no skips, failures or errors. The new Tool case returns the real producer while the port is comparing: its counted reader keeps DATA paid, the retained shell cannot compare after scope exit, and the original bank balance returns. Tool ELF: `9c84ebbbb95e8a508ade500040d34cb1b5dcf2cdd78c732a5ee6de270d2fc414`; Store ELF: `77bf39529c71d309af1561d17a1cd6b961523e6959562d728c6f4d136a6a7a09`. Host enumerated 279; ten separate Source, handoff, cancellation, Catalog and wait-reader cases passed, each with 278 filtered out, on ELF `d17393158f00fd3cf2728373b9bb5b9a204a61df8a534ca8b8ec7fa73bdfb3c5`. Host totals come from its individual case records, not the driver’s inherited Store summary. No full Host pass. Evidence: `derivedbindingunits2047/qualified-units.json`. The dependency-pin and architecture gates also passed.

### Production and eligible Product tests after the derived Store SPI change

E2049 passed all nine pinned production build stages on the `b307e032a2` behavior source. The fresh App is `6dd09f543459bff6ca50f5a1c7ac9929b117fb2fd4b64ab35f5d38cd511ef059`; Minimal is `5323574f1d0ccad706b8dea36827d06082de837c93002c64164e20d87543efa5`. E2056 rechecked the paired output/cancellation benchmark’s 255 candidate inputs, both fixture sets and all four measured executables. None of this commit’s changes entered that closure. Those original relative measurements remain applicable, not newly sampled. Neither result qualifies packaging or the cold provider request.

E2052 reached the unchanged 900-second Product test build limit. Two owned compiler processes required cleanup; no test executable was produced and no tests ran. E2053 used the twelve interface/archive files actually produced in that build and rebuilt with the same SDK and limit. Fresh Product test ELF: `9ec4e95365491195194c3881b91efd099d2add6c1be163a63bf3014673266078`. All 455 eligible cases ran individually; **445 passed, 10 crashed**, and 648 previously deferred identities out of 1,103 naturally enumerated cases were not rerun. No process survived a case boundary.

Six new failures have a dynamic GC visitor frame. The other four stopped at `MapleRuntime::CheckAndPush` at Runtime PC `0x637f21`; E1488 identifies its GC caller on this same Runtime binary, not an observed dynamic parent in those four cases. All ten remain failures, now within the approved deferral. The 63 MiB Memory seed passed, not the full Memory application path. Private receipts: `derivedbindingprod2049/summary.json`, `derivedbindingproduct2052/summary.json`, `derivedbindingproduct2053/qualified.json` and `derivedbindingloadclosure2056/summary.json`. **No full Product or release pass.**

### Packaged entry points, cold dispatch and matched performance after the Store SPI change

E2050 assembled Coding (nine plugins), Minimal (none) and Full (seventeen) from the E2049 hosts. All 16 selected checks passed: each profile assembled and ran in a clean environment; Coding and Full passed setup and Skills, Program and Shell wire checks; Full also passed Eval, and Minimal ran offline without plugins. Coding/Full packaged ELF: `ee5d0de7a23856b78299648f49be7af6666da7f383b024bba028d53fdde69469`; Minimal: `c2e01336294007449a5c118b54fa8b0d94fe117f21d653bef72841191ac4ae27`. This is not a complete frontend pass.

E2051 failed the original first-request limit on that Coding ELF: 5,003 ms, nine installed plugins and **no local HTTP arrival**. The three original SQLite files were retained unchanged. A detached copy passed `quick_check`: one cancelled Run, one model attempt, one Operation and one Receipt, no approval. Relative to Run start, the attempt was created at +1,618 ms, claimed dispatch at +1,759 ms and completed cancellation at +1,957 ms; no provider-terminal timestamp. Wall time for the original call and time relative to Run start are different clocks. This run got past admission and the dispatch claim; it does not locate the remaining delay or establish a GC failure. Physical custody closed; no DATA acknowledgement is inferred.

E2055 ran the same seven original performance cases on baseline and candidate with the fixed toolchain. Both absolute gates passed. Baseline → candidate p95: extension cold start 60,901 → 43,657 µs, first call 1,817 → 469 µs, steady IPC 9,316 → 244 µs, host RSS 29,331,456 → 20,865,024 bytes, cancellation after the 100 ms trigger 128,376 → 126,755 µs. CLI `/help` **regressed** 124,274 → 415,343 µs, and `/plugins inspect` 121,146 → 438,831 µs, despite lower peak RSS in both. This paired sample neither proves performance parity nor qualifies full release. Private evidence: `derivedbindingpackages2050/summary.json`, `derivedbindingcold2051/detached/receipt.json` and the two `derivedbindingmatched2055` summaries.

E2060 ran all ten original PTY flows against the **E2049 App and E2050 Full model/MCP packages** (before the Catalog change). All passed: three rich-response protocols, cancellation, Ctrl-C, HTTP error, timeout, incomplete EOF, invalid UTF-8 and an actual MCP tool request. Real tmux input, per-case artifacts and process receipts are in `derivedbindingpty2060`. No external model was used. This does not qualify the Coding default, full CLI/ACP, resize or mouse.

### Catalog lookups compare names without cloning a definition

For a bound contribution, reading `ToolDescriptor.definition` copies the public definition, including its input schema. Catalog lookup, activation, revocation and identity checks only need equality of two names. They now compare the private immutable names directly. Public copies, registration visibility, revocation, executor identity, resolver inputs and all capability checks stay unchanged. No counter, cache or new authority was introduced.

E2054 used two independently built external Native callers with the same fixture. Each of five samples performed 120 public lookups across 12 frozen descriptors with 24-field schemas: 40 correct executor matches, 40 foreign executors and 40 missing names. Old elapsed times were 146, 133, 120, 110 and 113 ms; new times were 0, 1, 0, 0 and 0 ms at millisecond resolution. Zero means below that timer’s resolution, not zero runtime. Activation, deactivation and revocation controls passed without executing a tool. E2058 rebuilt and passed the complete unmodified Native Tool suite (77/77), ELF `f89b765a2c43629d7a30d93ddaa5f9e2859a6fb615e6e50586d29b330c01d701`.

E2057 rebuilt all seven affected production modules. The other two E2049 production modules had identical artifacts. App: `6e995eefcab4b4f6c70babe495a4aaf533043db1022db9d0f086ec3ca4ce3bc6`; Minimal: `74f8f099b1b93a5070d0c8de9a32fc36d9f0c0e69058031fae4826de0a6e3e71`. The lookup measurements do not establish a first-request or Core capacity fix. Private evidence: `cataloglookup2054-before/summary.json`, `cataloglookup2054-after/summary.json`, `cataloglookupunits2058/tool_runtime-summary.json` and `cataloglookupprod2057/summary.json`.

### Catalog package: Todo save and first model request

E2059 packaged the name-only Catalog change (`d1095bfe6776`) as Coding, Minimal and Full. All 16 assembly and selected entrypoint checks passed. Coding and Full carried ELF `441619b0c42548ec4f9afa041ec15d25c5c87d6b7df21884b43ad1eabce479ae`; Minimal carried `8d3dc97833bb28a2a53f53068eabc301395564cbd7abd594f409f512982c35db`. This does not qualify all package entrypoints.

E2069 exercised the Coding executable in a real PTY with the original 45-second Todo workflow deadline. All nine installed plugin trees matched the release manifest. The operator opened `/todo edit`, approved each distinct pending operation once, edited and saved. The detached database contained two completed Runs, six committed Operations with six completed Receipts, four user approvals, one `todo` document at revision 1, and no model attempts. The case exited zero and the process watcher reported complete custody. This accepts the Todo path for this artifact and fixture, not the whole TUI.

E2064 used the same Coding executable and the original five-second local provider test. With nine plugins installed, the first call timed out at 5,002.57 ms; no request reached the local HTTP handler. The detached database passed `quick_check` and contained one failed Run, no model attempt, one Operation, one Receipt and no approvals. Five processes survived the case boundary; the harness subsequently reaped all five. The case failed. This is not the earlier E2051 dispatch claim or proof of a deadlock, GC cause, or DATA return.

A separate, unpublished package comparison candidate (E2061/E2063/E2066) preserved full installed-package verification and passed two Native controls. E2068 failed at `/plugins inspect` **before** the request timer. The core matched that candidate's executable (`27fa0950f73c33f8b4718cf0d10d275afc2cd7d7f9d78cd16d74b81a8d95781b`); its stack included `GCTib::ForEachBitmapWord`, `Mutator::GcPhaseEnum` and `TracingCollector::VisitStackRoots`. Only that setup crash is deferred as GC; no first-request measurement or speedup is available from it. E2065's private scoped-input experiment passed 79 Native Tool tests. It is not an accepted SDK/Host migration or a Core capacity result.

Private receipts: `cataloglookuppackages2059/summary.json`, `catalogcurrenttodo2069/summary.json`, `cataloglookupcold2064`, `currentpackagecomparecold2068/qualified.json`, and `resolverinput2065/tool_runtime-summary.json`.

### Host descriptor policy inputs: breaking SDK migration

The primary capability, additional capabilities, network policy, side-effect and approval metadata callbacks now receive `ToolResolverInput`, not a raw `ToolCall`. Each configured policy is still invoked and its return value used. A descriptor may compare fields or copy selected bytes. On return or exception the input releases its reference to the argument graph; retaining that input does not retain access. This is not an execution grant or an acknowledgement of any other Prepared data. Canonicalization and tool preparation retain their separate contracts. Rebuild custom host descriptors and clients together; see [the migration example](../compatibility.md#migrate-a-host-tool-descriptor-resolver). No stored plan or Native plugin wire format changed.

E2071/E2073 built Domain, Tool, Host and Product with CJC `1.3.0-alpha.20261104001050` and CJPM `1.3.0-alpha.09`. The external SDK extension contract ran successfully. The Product contract with the workspace and LSP oracle clients compiled; it was not executed. E2077 built and ran the separate Tool contract after restoring its canonicalizer's raw `ToolCall` signature. E2074 passed **79/79** Native Tool cases, including all five policies and invalidation on exception, and **11 selected** Native Host cases out of 279 enumerated. E2075 compiled a positive external client and confirmed that four external clients cannot call `domainProjection`, `projectNode`, `current`, or `revoke`. E2078 passed the architecture, inventory and compatibility-document checks. Evidence: `resolverhost2071/`, `resolverproducts2073/`, `resolvertoolhostunits2074/`, `resolverexternalaccess2075/`, `resolvertoolcontract2077/`, `resolverstatic2078/`.

E2079 rebuilt the Core contract executable (`f6f92c13a543180262b2f48e5f2e1930c1914f871bc14f5c3dc790a9350ce595`). The budget control passed; `--core-and-recovery-contract` exited 1 at Program inspection with closed process custody. Detached copies of both databases passed `quick_check`; the six captured original database/WAL/SHM files retained their hashes. The main Store had 35 Runs, 69 Operations and 69 Receipts. The selected read-view and grep failed with `read_view.output_capacity`; the enclosing Program was committed with a failed Receipt. In the separate file-plan fault Store (1/4/4), read-view and workspace read completed, file-plan failed, and the enclosing Program had a failed Receipt. See `resolverunsplitcore2079/detached/receipt.json`.

E2076 and E2081 hit the original 900-second Product test compilation limit before producing an executable or running a case. The watcher physically reaped two and three survivors respectively. Earlier executable results do not transfer. A private child-policy projection (E2080, not shipped) passed the budget control but its continuous run failed earlier in the matched workflow: 16 Runs, 41 Operations and 41 Receipts, with `read_view.terminal_missing` on the reserved read-view and the outer workspace read. That sample did not reach the subsequent capacity assertion and establishes neither a capacity fix nor a new GC classification. Evidence: `resolverproductunits2076/`, `resolverproducteligible2081/`, `preparedchildfacts2080/detached/receipt.json`.

### Resolver migration: rebuilt release inputs, Product inventory and first request

E2082 rebuilt Domain and all nine original production targets on the source shipped in `9821b4f1da`, using CJC `1.3.0-alpha.20261104001050` and CJPM `1.3.0-alpha.09`. The App SHA-256 is `efa73c3e0bd4b9a6933848a4bbc88b80ab4171990ee86aee64d431e9e475a6c9`; Minimal is `9700cdbcc9d340a5a5aeda7714c917ce22b26cb379b3b7f6bab8dfff2d39eb1a`. E2085 passed six Coding checks (assembly, Skills/Program/Shell wire, clean launch and setup), and three Minimal checks (assembly, clean launch and empty/offline). Packaged Coding: `a4affbfc06e5dd720560276a9b0f5025c23551ff0f3672696abb24f5108b6d41`. Full assembly was interrupted by the outer job deadline; E2085 supplies no Full pass.

E2083's four ordinary production-mode dependency builds passed, but Product test compilation still hit its original 900-second limit. No case ran. E2091 used the repository's eight `prepare_workspace_dependencies` test-profile stages instead: dependencies must export their test interfaces. All eight bounded compilation stages passed, with no test credit. The new Product ELF `d59d6d6f9ac6457eabace5ce01ea0c11388391916ef5e8796522b88b96920c1a` naturally enumerated 1,103 cases. Of 445 previously eligible cases, **443 passed and two crashed**; 658 previously deferred cases were not rerun. Both new crashes had SIGSEGV at `MapleRuntime::CheckAndPush` (Runtime PC `0x637f21`). The first-start/disable/reopen case also had `GCTib::ForEachBitmapWord` and `Mutator::GCPhasePreForward` on the faulting stack. For the Artifact cancellation/revocation case only the leaf was recorded; E1488 identifies its caller statically on the same Runtime, not dynamically in that case. Both are now in the approved GC deferral, not passes. Each selected case ran in its own process with no survivors. No older crash is reclassified.

E2089 ran the original five-second local provider fixture on the E2085 Coding package with nine plugins installed. The first call timed out at 5,006 ms, before the local HTTP handler received a request. A detached copy of the database passed `quick_check`; all three original DB/WAL/SHM hashes remained unchanged. One Run failed, `host.context.read` committed with a completed Receipt, one model attempt remained `created`, and no approval was recorded. Five processes survived the case boundary and were subsequently reaped. This is a deadline failure, not proof that no Run or attempt existed; no external model was used.

Private receipts: `resolverproduction2082/summary.json`, `resolverpackages2085/summary.json`, `resolverproductstaged2083/summary.json`, `resolverproducttestprofile2091/qualified.json`, and `resolvercold2089/detached/receipt.json`. Complete Core, Prepared ownership, first request and release acceptance remain open.

### Counted call readers and the Core refusal

E2093 and E2097 replaced the counted reader's raw `ToolCall` callback with a revocable `ToolResolverInput`. It expires before the active read ends, including on exception. The producer's canonical reader preserves the original call ID and name but reads arguments from the frozen plan. Product command probing uses that reader before launch. File-plan consumers copy the result identifiers they need and retain their actual reader through result acknowledgement. Error return does not acknowledge the result. The producer and counted **plan** interfaces still have raw consumers; this change does not prove all Prepared DATA can be released.

E2093 passed the full Tool suite (81/81) and 11 selected Host cases out of 279. E2097 built Tool, Host and Product production libraries, ran the external Tool contract (`468f748ac1f78b0b69cdf7f20aacf85fd05f2a72f245cf5fa15bb8bf788313f8`), and confirmed an external use of the removed raw counted-call method failed compilation. E2100 ran the existing Product file-plan contract against a real Store, including its artifact-failure path. Its private entrypoint selected that contract; it did not run the whole Product suite. Receipts: `preparedcallprojection2093/{tool_runtime,agent_host_runtime}-summary.json`, `preparedcallclients2097/summary.json`, `preparedfileplans2100/summary.json`.

E2094 was a diagnostic build on the preceding resolver source, not an acceptance run of the new readers. The continuous Core fixture again failed during read-only Program execution. At the refusal, the bank held 144,032,408 of 150,994,944 bytes; a 131,072-byte read-view request needed an actual 16,777,216-byte increase. The shortfall was **9,814,680 bytes**. The four open ledger charges plus the fixed 327,680-byte charge reconcile exactly. Even eliminating unused high-water capacity from the largest variable ledger would still leave its active child sum 4,671,640 bytes above the amount available for that ledger.

All 55 outstanding Prepared owners joined uniquely to Operations in the same fixture's SQLite image by actual Operation ID: 15 Program, 12 read-view, 15 workspace read, seven workspace grep and six file-plan proposal. All 55 had exported both call and plan. Of these, 52 producers had returned; four counted file-plan readers were still outstanding. Neither a producer return nor an Operation or Receipt terminal state establishes return of an exported DATA reference. No Task owner was present in this refusal. Both detached databases passed `quick_check`; the six source DB/WAL/SHM files retained their capture hashes. Receipt: `resolverownerbindings2094/detached/qualified.json`. No change to budget, approval, Source or settlement was made from this observation.

E2099 built the Product test executable `7998736745f035d7c0d5ea2729a16b93a21faa64712b627d5c1e5afd8056b65f` on the counted-reader source. All 20 selected non-deferred command-probe, file-plan Source and installed data-only cases passed with closed process custody. This does not carry the earlier 443 Product passes onto a later binary. E2102 passed the architecture, documentation, dependency-pin and SDK compatibility gates. Receipts: `preparedcallproduct2099/summary.json`, `callclientstatic2102/architecture.log`.

Separately, E2101 exercised the E2085 packaged Coding Todo entry at its original 45-second deadline. Two Runs completed; six Operations had matching completed Receipts, four decisions recorded user approval, and the `todo` document was persisted at revision 1. No model request was recorded and the watcher closed without surviving processes. Receipt: `resolvercodingtodo2101/summary.json`. This is evidence for the preceding packaged source, not the new Product test ELF.

### Counted-reader Core and matched release controls

E2103 built the uninstrumented continuous Core contract from `3405693335`. The launcher stopped before execution: its final archive check still expected the seed Host and Product archives, which the external package had recompiled. E2110 preserved that failure and ran the newly linked ELF only after verifying its hash (`faa1c4bf4593284dc85d0ee6f5f271bf14ebd3a65eef0595e4403b7d3b5a5c62`), actual linked archive hashes, compiler log, dependency source paths and original fixture. The budget positive passed. Continuous Core exited 1 at the Program inspection assertion. The main Store contained 35 Runs, 69 Operations and 69 Receipts; the separate artifact-failure Store contained 1, 4 and 4. The main Store's reserved Receipts for `workspace.grep` and `host.process.readview` both reported `read_view.output_capacity`. Both database copies passed `quick_check`; all six original DB/WAL/SHM hashes were unchanged. No surviving process or cleanup diagnostic. E2110 did not measure new refusal-time bank totals. Receipts: `preparedcallcore2103/summary.json`, `countedcallcorerun2110/detached-projection/receipt.json`.

E2095 completed Full packaging on the preceding resolver source `9821b4f1da`: 17 plugins, all seven original assembly, wire, clean and setup checks passed. E2096 compared base `4d88fa6072` to the E2085 Coding package using the same pinned SDK, fixture inputs and original deadlines in clean, serialized namespaces. Both arms passed all seven absolute gates. These are matched results, not a claim of latency parity:

| P95 | Base | E2085 Coding |
| --- | ---: | ---: |
| Extension activation (ms) | 61.568 | 42.574 |
| First worker call (ms) | 2.228 | 0.673 |
| Steady IPC (ms) | 10.104 | 0.233 |
| Worker peak RSS (bytes) | 29,237,248 | 20,774,912 |
| Cancellation including 100 ms trigger (ms) | 128.257 | 126.761 |
| `/help` (ms) | 180.587 | 419.141 |
| `/plugins inspect` (ms) | 136.755 | 442.269 |

E2087/E2088 removed the Skills executable's unnecessary Domain dependency in a private experiment and ran the real Skills protocol and Coding assembly. Its package shrank by 5,173,520 bytes. E2090 still timed out at 5,002.59 ms with nine installed plugins and no local HTTP arrival. Its detached Store recorded one cancelled Run, a completed context read and a cancelled model attempt; this watcher closed without survivors. No external model was called. The experiment was not promoted. Receipts: `resolverfull2095/summary.json`, `resolvermatched2096/{baseline,candidate}/summary.json`, `skillsneutral2087/{base,source}.json`, `skillsneutralcold2090/detached/receipt.json`.

E2106 built all ten production roots from `3405693335` using the pinned SDK, without rebuilding any toolchain component. App ELF `7ef9d2b54c5aeeef4064b20eba32d08991f55423bc17e631242400e928eee3f8`; Minimal ELF `e1f317f86e2f7e81215f50b5a12285eb0215c28cc3e52c2865e98b6702f77d20`. Production builds are not application acceptance. E2108 used the preceding `9821b4f1da` native App and sealed Full fixture packages: all ten real PTY cases passed (three rich-response protocols, cancel, Ctrl-C, HTTP error, timeout, incomplete EOF, invalid UTF-8 and MCP). The fixture preserved key input and terminal observations and checked process cleanup. Local HTTP/MCP only; not a test of current Coding startup, mouse or resize.

E2105's private service-predicate candidate passed the original Core budget positive. Its unsplit Core still failed; the join through the actual effect record and its reserved Receipt on a detached Store copy identified `read_view.output_capacity` for both `plugin.axyndra:workspace.grep` and `host.process.readview`. E2109's stronger private predicate also rejected a wrong service, changed implementation and reduced ceiling in the real external Tool contract. Neither experiment is a Core fix or a public API on this revision. Evidence: `countedcallproduction2106/summary.json`, `resolverfullpty2108/summary.json`, `closedservicefacts2105/detached-projection/receipt.json`, `servicefactcontracts2109/summary.json`.

### Counted-reader release packages, terminal flows and local first request

E2112–E2114 used the ten production roots from E2106 (`3405693335`) and independent fresh destinations. Coding (9 plugins), Minimal (0) and Full (17) passed their 6, 3 and 7 selected packaging/entry checks. Coding and Full packaged ELF: `75bfe0ae43dec1864d4b31d13be4a9933ea106f637e5bea70f0efd6696826e7d`. Minimal: `af8d9fd90c1cad0bc151b0721daeb1f39cbf516a7dcf01085e43ca6154a19358`. E2123 ran all ten real PTY cases on the E2106 App with sealed Full fixtures: three rich protocols, cancellation, Ctrl-C, HTTP error, timeout, incomplete EOF, invalid UTF-8 and MCP. This covers local fixture requests and the observed terminal flows, not public providers, mouse or resize. Receipts: `countedcoding2112`, `countedminimal2113`, `countedfull2114` and `countedpackagepty2123` (`summary.json` in each).

E2119's first local Coding request did **not** pass: nine installed packages, 5,002.321 ms to timeout, zero HTTP arrivals. Detached SQLite recorded one cancelled Run, one completed context read (+582 ms), one cancelled model attempt and zero approvals. The three captured DB/WAL/SHM hashes remained unchanged; no owned process survived cleanup. No second profile or external provider was called. E2115/E2118 separately built and packaged a private paired-inspection candidate. It passed the six Coding checks but E2120 still timed out at 5,002.687 ms with zero HTTP arrivals; it was not promoted. Receipts: `countedcold2119/detached/receipt.json`, `pairinspectioncold2120/detached/receipt.json` and the corresponding `summary.json` files.

E2122 compared the same inputs, fixed SDK and original bounds on base `4d88fa6072` and the E2112 Coding package. Both passed all seven absolute gates. The extension worker was faster at P95; both CLI paths used less peak RSS but started more slowly.

| P95 | Base | Counted-reader Coding |
| --- | ---: | ---: |
| Extension activation (ms) | 86.607 | 46.823 |
| First worker call (ms) | 2.309 | 0.517 |
| Steady IPC (ms) | 2.012 | 0.237 |
| Worker peak RSS (bytes) | 29,216,768 | 20,852,736 |
| Cancellation including 100 ms trigger (ms) | 127.689 | 125.926 |
| `/help` (ms) | 125.035 | 417.606 |
| `/plugins inspect` (ms) | 123.187 | 440.430 |

See `countedmatched2122/{baseline,candidate}/summary.json` for the raw samples and limits. These absolute gates and PTY results do not establish latency parity, complete Core, whole Product or release acceptance. E2111's private readonly-delegation projection also passed its budget positive but retained the unsplit `read_view.output_capacity` failure. Neither producer return nor process cleanup establishes return of escaped Prepared DATA. PR remains Draft; GC is deferred, not passed.

E2126 extended the private service checks to both readonly Program delegation branches. Tool, Host, Product and the external Native fixture built; the original Program budget case passed. The unchanged continuous Core fixture exited 1. The main Store had 35 Runs, 69 Operations and 69 Receipts; the file-plan-failure Store had 1/4/4. The reserved grep and `host.process.readview` Receipts again both report `read_view.output_capacity`. Both detached databases passed `quick_check`; all six raw files retained their hashes. This candidate is not a Core fix. Receipt: `delegatedchildfacts2126/detached-projection/receipt.json`.

### Distribution selection: release only the Registry results this lookup owns (E2127–E2137)

A real workspace package exposed a repeatable custody increase. E2127 started with 4,565,680 charged bytes and six leases. After writing `workspace-tools.json` once, the same Registry bank held 4,648,464 bytes and 11 leases; after deleting the file and reseeding, it held 4,731,248 bytes and 16 leases. Both writes selected the correct digest. E2128 kept the original byte and lease counts after both writes. The test measures live Registry custody before Product shutdown, not RSS or process exit.

Distribution seeding now closes each owned snapshot after selecting the effective record. It reuses verified manifest text only when the effective content lock equals it; an independently updated record supplies its own paid digest. Partial installs close their import and enable results on both success and failure. This changes neither the first-install mount path nor scope precedence: an explicitly disabled User record outranks Workspace, which otherwise outranks User. Existing operator files still win.

E2132: eight Native Product cases passed on `3dc86986b9e77595b20427f15add65804d133c7500690ac9440fe0f995219a65` (1,105 naturally enumerated). The changed-digest case imported two real packages and checked the persisted Workspace lock, then disabled User and checked that its lock won. This is independent of the larger sealed-fixture probe, which did not reach its post-seed assertions in either arm. E2135 rebuilt the affected Product and App production roots. E2137 assembled Coding from App `ebabfcc2d79fe4947d616d264e38b9c5433cf3d36cd23fef375003d0b2bf26ac`; packaged ELF `2d73876cd5598e47d37bd0d8861f8aef0cd2b618a27c1b740dce50104a9455ba` passed assembly, Skills/Program/Shell wire, clean environment and setup. Evidence: `localseedred2127`, `localseedgreen2128`, `distributioncustodyfinal2132`, `distributioncustodycoding2137`.

On the **preceding** `3405693335` Product ELF, E2129 passed 421/423 additional cases. Together with 20 earlier passes on that image: 441 passed, two failed, 660 previously deferred and not rerun (1,103 total). Both new failures faulted in `MapleRuntime::CheckAndPush`. The exact mapped runtime and its four static GC-phase caller paths support GC deferral; no dynamic caller stack was recovered. The same distinction applies to both private sealed-fixture probes. These classifications give no pass credit. Core capacity, the five-second first model request and complete release acceptance remain open.

### Final distribution image: Product partition and first-request boundary (E2139, E2142–E2144)

On `9053902911`, the E2132 Product image had 1,105 natural cases. Its eight earlier passes and E2139's 435 distinct remaining eligible cases used the same ELF. E2139 passed 432 and failed three: `PluginHttpTransportTests.stricterParentProcessLimitsFailBeforeAnyHttpEffect`, `ProductPluginLifecycleManagerTests.sameThreadConfiguredServicesWithEqualLocalToolNamesRemainIndependent`, and `PluginRuntimeContractTests.piExtensionApiHostDeniesDirectSystemAccess`. All three faulted at `MapleRuntime::CheckAndPush+0xc1` (PC `0x637f21`). The matched runtime's static callers are GC-phase paths; no dynamic caller was recovered. They are failed samples within the GC deferral, not passes. Total: **440 passed, three failed, 662 previously deferred and not run**. Exact cases and per-log hashes: `distributioneligible2139/qualified.json`.

E2142 failed the original first local provider request at 5,002.753 ms. Nine plugins were installed, neither HTTP handler received a request, and the second profile was not invoked. A read-only detached SQLite snapshot passed `quick_check`; the three original file hashes remained unchanged. From Run start, the context read completed at +530 ms, the model attempt started at +1,642 ms and dispatch was claimed at +1,799 ms. The attempt was cancelled at +2,103 ms and the Run ended at +2,112 ms. A durable claim is not provider receipt. There were zero approvals and no unreaped owned process. See `distributioncold2142/detached/{receipt,dispatch-phase}.json`.

E2143 passed Minimal's three selected gates (empty distribution, packaged ELF `af8d9fd90c1cad0bc151b0721daeb1f39cbf516a7dcf01085e43ca6154a19358`). E2144 passed Full's seven, including the Eval wire check (17 bundled plugins, ELF `2d73876cd5598e47d37bd0d8861f8aef0cd2b618a27c1b740dce50104a9455ba`). The Coding/Full ELF is identical; each package's own manifest, provenance and entrypoints were checked. This does not clear the first-request deadline or the Core capacity refusal.

E2148 exercised ten real PTY flows on the E2135 App and installed Full fixtures: three streaming protocols, cancellation and Ctrl-C, HTTP error, timeout, incomplete EOF, invalid UTF-8 and MCP. All ten passed (`distributionpty2148/summary.json`). E2149 ran the unchanged performance harness with separate fresh homes under the fixed SDK. Both arms passed the seven absolute gates. P95 results:

| Measurement | PR base | `9053902911` |
|---|---:|---:|
| Extension cold start (ms) | 61.292 | 60.152 |
| First call (ms) | 2.648 | 0.475 |
| Steady IPC (ms) | 3.361 | 0.230 |
| Worker peak RSS (bytes) | 29,265,920 | 20,754,432 |
| Cancellation including 100 ms trigger (ms) | 127.126 | 126.404 |
| `/help` (ms) | 144.643 | 419.845 |
| `/plugins inspect` (ms) | 133.869 | 437.939 |

Both CLI commands remained slower than base. Samples and package identities: `distributionmatched2149/{baseline,candidate}/summary.json`. Separately, the private paired Registry row candidate built and passed six Coding gates but failed its original first local request at 5,002.788 ms with zero HTTP arrivals (E2145–E2146); it was not promoted. E2150's private ordinary-child comparison preserved the Core budget positive but not the unsplit Core: both reserved grep/read-view Receipts still recorded `read_view.output_capacity`. Both SQLite copies passed integrity checks and all six original file hashes stayed unchanged. No projected metadata was credited as returned simply because a scope or process finished.

### Task selection on retained Prepared DATA (E2147, E2151)

The Host selects the configured child generation and matches a retained wait against its live start without exporting the frozen plan for either read. The counted reader uses the original call identity and frozen arguments. Its borrowed input is revoked before the loan count falls; the counted reader remains outstanding until its owner returns it. This does not return any earlier raw export. Source, budget identity, capabilities, generation and the completed launch Receipt are still checked in their original paths.

On these exact changes, the full native Tool suite passed 82/82. Twelve selected Host cases passed out of 279 enumerated; this is not a full Host result. The retained wait regression distinguishes display from frozen input, rejects a different start and binding, and observes zero billed bytes and leases only after the last reader returns. Four production dependency roots built. The external Tool SDK contract compiled from a public `ToolPipeline.prepare` consumer and ran successfully (ELF `608e8cf7a19287047c8e487a7bdd7b456f755f9141d124a9ad76df983df54bda`). The separate durable-child port experiment is not part of this cutover. The last full Core attempt still failed `read_view.output_capacity`; these checks do not qualify the release image.

### Scoped child verification at the durable Store boundary (E2153, E2158, E2160, E2163)

The execution and launch-Receipt ports now compare a scoped witness with their own durable child row. SQLite selects that row by child and Run inside the transaction, compares its exact encoded bytes, decodes it once, and binds those same bytes in the existing execution query. The active Source, parent, lane, thread, epoch, handoff, effect and Receipt checks still apply. No saved row, authorization rule or budget changes. A typed backend can compare its own plan with the same Store codec without reading the caller’s plan.

The final Store ELF `6b875c4f4206864574b7e1318b851a8a37f26b1606366fb08a70a0adc963bbfe` passed all 262 naturally enumerated cases. The real child fixture accepts the original against both its encoded and typed row, rejects changed `cwd` with the same binding digest, and rejects the saved witness after scope exit. It leaves two Operations and zero Receipts. The external Tool SDK contract exercised both new port methods through an attested Direct source (ELF `232593220f6a17c89374b6ae73b07833e7d21d118e8f95af480a8e922358d8e3`): even matching data did not authorize the unsupported backend. The external check exercised the SPI, not the later Store-local row reuse. On the SPI image, Tool passed 82/82 and 12 selected Host cases passed out of 279. Receipts: `childplanstoreunits2153`, `childplansdk2158`, `childplanrowunits2160`, `typedchildplan2163`.

Release scope: E2156 passed the real 45-second Coding Todo save and replay on **`9053902911`**, with four visible operator approvals, two completed Runs, six committed Operations and six completed Receipts, one document at revision 1, no model call and closed process custody. E2159/E2162 built and assembled Coding on the later **`a7f86fd86b`**; its six selected gates passed (packaged ELF `138473a6ce5ce13a898e069c50b5e80d21d673f3fd2774b2e26904645482a4f1`). Neither image contains the subsequent child-port cutover. The unpublished paired-row startup candidate also passed 50 eligible Registry cases (three previously deferred, not run); this does not change its failed five-second result. No whole-Core, Product or release pass.

### The first request can time out before a model attempt exists

E2167 ran the unchanged `provider_profiles_blackbox` on the published `a7f86fd86b` Coding package. All nine plugins were installed. The first `--print` timed out at 5,002.43 ms. Neither local handler received a request; the second profile did not run. The detached database passed `quick_check`. It contained one cancelled Run, one completed `host.context.read` Receipt at +641 ms, no approval, and **no model attempt**. The Run ended at +1,037 ms. The watcher reaped the process tree but needed to clean up five processes. This is not natural cleanup or a DATA acknowledgement. The original database, WAL, and SHM hashes did not change. Evidence: `taskreadercold2167/detached/receipt.json`.

E2142 reached a dispatch claim on a different image. Its retained request provides an independent workload for two private changes, not an explanation for E2167. Core computes the durable semantic digest with `canonicalAgentValueSha256`. Later, `SqliteModelProviderDispatchReader.observe` builds a canonical string and compares current inputs against those exact bytes. Neither check substitutes for the other.

| Native work on E2142's 41,876-byte canonical request | Original median | Private candidate median |
|---|---:|---:|
| Produce the complete string | 57.82 ms | 6.16 ms |
| Compare an existing string with the complete input | 5.13 ms | 3.12 ms |

Each pair used one executable, three alternating samples per arm, and independently generated expected bytes. The SHA-256 matched the original attempt. E2165's wide synthetic control initially failed in the **original** implementation: the expected bytes retained `-0`, but the pinned parser reads that integer as `0`. E2176 kept the input and executable, corrected the parsed-integer oracle, and passed both arms for the wide and Unicode controls. The private writer passed ten selected Domain cases; the separate comparison candidate passed eleven, including duplicate, out-of-order, missing, and split-UTF-8 keys. Evidence: `canonicalmeasure2165`, `canonicalgrammar2168`, `observedmalformedunits2175`, `canonicalparsedcorpus2176`, and `parsedcompare2177`. These are function measurements, not an end-to-end speedup. E2166 built eleven production roots for the writer candidate. Neither private change is in this release checkpoint.

### E2178–E2184: local dispatch, continuous Core and current Product cases

E2178 packaged the E2166 source (`33450dd5f7` plus the private canonical writer, **without** the comparator). Coding assembly, the Skills/Program/Shell wire checks, clean-environment startup and setup passed. Coding ELF: `fb3dd7bba8fbea3c4df836e8f0b8b509cfaa4175f01d1fda809fccef1954b455`.

The faster writer did **not** fix cold dispatch. On that package, E2180’s first original `--print` timed out after 5,003.02 ms. Nine plugins were installed; neither local HTTP handler saw a request, and profile two did not run. The watcher found no remaining or unreaped process and sent no cleanup signal. A detached copy of the DB/WAL/SHM passed `quick_check`: one cancelled Run (1,193 ms), one committed `host.context.read` with its reserved completed Receipt at +745 ms, zero approvals and zero model attempts. The three original hashes stayed unchanged. This sample does not measure the writer on the dispatch path; the candidate remains private. Evidence: `releaseboundcoding2178/summary.json` and `releaseboundcold2180/detached/receipt.json`.

E2179 linked the original external Core executable from those same sources. Its external project rebuilt sixteen archives/interfaces rather than reusing the workspace products byte-for-byte. E2184 bound those actual build outputs and reused the unchanged ELF `3c7b14fc75542d3a4e2fedf9ddaa35d3640e0dc14fd2519d975b4f3d8e424c16`. The positive budget control passed; the original continuous Core/recovery contract exited one. Its two detached stores passed `quick_check`: 35 Runs / 69 Operations / 69 Receipts and one Run / four Operations / four Receipts. The first store’s reserved `host.process.readview` and workspace grep Receipts reported `read_view.output_capacity`. All six raw files retained their hashes. This sample did not observe the bank balance at refusal; earlier samples’ figures do not belong to it. Evidence: `linkedcore2184/detached-projection/receipt.json`.

E2182 used **published behavior** `33450dd5f7`, with neither private serialization change. Product ELF `de93eb763b0980688e3540723b43495b4a1c7cfca8e18505a4229ea2546cff9d` enumerated all 1,105 cases. The 440 previously passing cases ran once each: **438 passed, two crashed**. The other 665 were not rerun. `scopedImportRevokesPreviouslyEffectivePlugin` faulted at `MapleRuntime::CheckAndPush` (PC `0x637f21`); the same Runtime’s static caller census supports a GC-site classification, not a recovered dynamic caller. `protocolFailureNeverRespawnsOldSelector` faulted directly at `GCTib::ForEachBitmapWord` (PC `0x620780`). Both are deferred failures, not passes or proof of the origin of corruption. The exact case identities, individual logs and runtime/ELF hashes are in `publishedeligible2182/qualified.json` and `publishedeligible2182/summary.json`.

### E2181 / E2185: derive child identifiers without exporting the parent call

Task dispatch checks the exact parent tool name through `textEquals`. Both Task and other child-service dispatchers use `resolverChildServiceIds` inside the original scoped call reader to derive the child call ID and idempotency key. No parent argument DOM crosses that read. The existing plan, Source, grant, generation, child admission and Receipt checks still run. An older raw export is not refunded by this change.

E2181 passed the complete Tool suite (82/82) and 12 selected Host cases from a natural inventory of 279. The counted-reader regression retained the exact UTF-8 IDs after the reader returned, rejected access through a saved closed view, and verified that the last counted reader returned its own charge. E2185 built and ran the original `task_persistence_contract` with the installed Workflow plugin. Both completed jobs restored under their original roots; deliberately corrupting the first snapshot then produced a recovery warning and no guessed job. The final detached **main file only** passed `quick_check`: two rows, revisions 34 and 36, the first with the fixture's corrupt bytes and the second with `second-job`. All eleven captured files retained their hashes; different WAL generations were not combined. The executable exited zero in 11.07 seconds without forced cleanup. Task contract ELF: `ae5f7a6be2a8b012b4a1a88cb331d1c2726a70f359c7aee2b8f07e1b7889d5be`. Evidence: `childidentityscope2181/` and `taskchildrelease2185/main-only-observation/receipt.json`. Raw Prepared call and plan users remain; this is not full migration or Core acceptance.

### E2186: read only the descriptive call ID when retaining Task history

Task admission no longer passes the entire parent `ToolCall` to the history constructor. Only a retained history requests the call ID. Its temporary producer pays for a separate UTF-8 copy before allocation and keeps that charge alongside the encoder invoice until the producer frame returns. The historical snapshot remains independently paid. The plan, generation, Source and capability checks, actual consumer return and raw-export debts are unchanged. No wire or stored format changes.

On this additional Host change, the original Native `task_persistence_contract` built and exited zero in 10.40 seconds, with no forced cleanup. It verified both completed jobs after reopening their roots and rejected the deliberately broken first snapshot. In the final immutable main image, the two snapshots had revisions 34 and 36, with the expected corruption only in the first payload; six Runs, four Operations and four Receipts were present. The eleven captured files remained unchanged. ELF: `e64d3c4bd83358576c5c8e16a134ec563b50e20cc53863e9be88b4c8df20e363`. Evidence: `taskhistorycallinput2186/summary.json` and `taskhistorycallinput2186/main-only-observation/receipt.json`. No full Core, Product or release credit is inferred.

### E2192: verify read-only delegation without exporting its display call

The service-selection and file-plan checks need success or an error, not the parent input. They now compare the displayed name in place, verify Source and compare the original canonical arguments against a freshly prepared grant. The DATA-returning path still marks the plan exported and returns the exact input that was checked. The service selector still reads its frozen target from the plan; this does not retire that separate export.

The original Native Program budget and cancellation/recovery contracts passed (7.79 s and 5.58 s). The continuous Core run still exited 1 after 71.38 s: `host.process.readview` and grep recorded failed Receipts with `read_view.output_capacity`. At source `43bdecee9c` plus this Host change, the external fixture ELF was `a74ca0f1f31711b5208004d59720b326e06c1df364e267b5588a2f09b6363f94`. Detached SQLite copies passed `quick_check`; the six original files did not change. Main: 35 Runs / 69 Operations / 69 Receipts. Artifact-failure: 1 / 4 / 4. Fourteen attachment events joined to their original item/provenance, stored plan, input digest and reserved Receipt; four Receipts completed and ten failed. These joins verify staging, not a DATA refund. Evidence: `readonlyvalidationprojection2192/summary.json` and `detached-projection/{receipt,attachments}.json` in that evidence directory.
