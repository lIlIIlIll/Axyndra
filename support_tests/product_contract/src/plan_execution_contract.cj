package product_contract

import agent_core.*
import agent_cli.*
import agent_app_protocol.*
import agent_history.runInspectionValue
import agent_history.RunInspectionProjection
import agent_host_runtime.HOST_PLUGIN_LIFECYCLE_TOOL
import agent_domain.*
import agent_product.*
import agent_runtime.*
import agent_store.*
import model_adapters.*
import shell_native_contract.*
import std.collection.*
import std.fs.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// Only the dependency failure is deterministic. Source writes, canonical
// admissions/receipts, continuation and Node verification use production paths.
class PlanContractDependencyTimeout <: ToolExecutor {
    public var calls: Int64 = 0
    public func execute(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> {
        calls += 1
        Result.Err(AgentError(AgentErrorKind.Timeout, "fixture.dependency_timeout",
            "The deterministic dependency acquisition fixture timed out",
            fields: [ErrorField("failure_class", "timeout"), ErrorField("started", "true")]))
    }
}

func runPlanExecutionPrimaryContract204(parent: String): Unit {
    let beforeSetup = productControlMetadataUsage113()
    println("plan-fixture-native-bank boundary=before-primary owners=" + beforeSetup[0].toString() + " charged=" + beforeSetup[1].toString())
    let workspacePath = parent + "/plan-execution-workspace"
    if (!exists(Path(workspacePath))) { Directory.create(workspacePath, recursive: true) }
    let root = canonicalize(Path(workspacePath)).toString()
    let product = openProduct(config: ProductConfig(
        stateRoot: parent + "/plan-execution-state", settingsRoot: parent + "/plan-execution-settings", workspaceRoot: root,
        fixture: true, approvalMode: ApprovalMode.Yolo, asyncEnabled: false
    )).value().getOrThrow()
    try {
        expect(product.hasPublishedTool159e("command_probe"),
            "default startup publishes the actual controlled process probe")
        installWorkflowContractPolicyScoped204(product)
        let dependency = PlanContractDependencyTimeout()
        expect(product.registerTool(ToolDescriptor(ModelToolDefinition(
            "dependency_probe_fixture", "Deterministic dependency timeout fixture",
            objectValue([ValueField("type", textValue("object")),
                ValueField("properties", objectValue([])), ValueField("required", listValue([]))])),
            Capability(CapabilityKind.WorkspaceRead), supervisedExecutionSafe: true
        ), dependency).isOk(), "register deterministic dependency fixture through the normal catalog")
        let fixture = product.fixtureProbe.getOrThrow()
        let application = product.applicationSession()
        let canary = "PLAN_ARGUMENT_SECRET_CANARY"
        let engine = "const fixtureArgumentCanary = '" + canary + "';\n" +
            "export function rotate(v, axis, q) {\n" +
            " if (!Number.isInteger(q) || !['x','y','z'].includes(axis)) throw new TypeError('discrete rotation');\n" +
            " let [x,y,z]=v; for(let i=0,n=((q%4)+4)%4;i<n;i++){\n" +
            "  [x,y,z]=axis==='x'?[x,-z,y]:axis==='y'?[z,y,-x]:[-y,x,z];\n" +
            " } return [x,y,z];\n}\nexport const faceTurns = layer => -Math.sign(layer);\n" +
            "// Controlled lifecycle fixture; browser rendering is outside this contract.\n" +
            "export class MoveQueue {\n" +
            " constructor(){this.generation=0;this.value=0;this.history=[];this.pending=[];this.active=null;}\n" +
            " enqueue(q){if(!Number.isInteger(q))throw new TypeError('discrete move');this.pending.push(q);}\n" +
            " commit(q){this.value=((this.value+q)%4+4)%4;this.history.push(q);}\n" +
            " cancelPending(){this.generation++;this.pending=[];this.active=null;}\n" +
            " async animateNext(completion){\n" +
            "  if(this.active!==null||this.pending.length===0)return false;\n" +
            "  const q=this.pending.shift(),ticket={generation:this.generation};this.active=ticket;\n" +
            "  await completion;\n" +
            "  if(this.generation!==ticket.generation||this.active!==ticket)return false;\n" +
            "  this.active=null;this.commit(q);return true;\n" +
            " }\n" +
            " reset(){this.cancelPending();this.value=0;this.history=[];}\n" +
            " scramble(moves){this.cancelPending();for(const q of moves)this.commit(q);}\n" +
            " undo(){this.cancelPending();const q=this.history.pop();if(q!==undefined)this.value=((this.value-q)%4+4)%4;}\n" +
            "}\n"
        let test = "import test from 'node:test'; import assert from 'node:assert/strict';\n" +
            "import {rotate,faceTurns,MoveQueue} from './cube-state.mjs';\n" +
            "test('signed face turns are nonzero and discrete rotations preserve group identities',()=>{\n" +
            " for(const axis of ['x','y','z']) for(const layer of [-1,1]){\n" +
            "  const q=faceTurns(layer),v=[1,1,1]; assert.notEqual(q,0);\n" +
            "  assert.notDeepEqual(rotate(v,axis,q),v); let r=v;\n" +
            "  for(let i=0;i<4;i++)r=rotate(r,axis,q); assert.deepEqual(r,v);\n" +
            "  assert.deepEqual(rotate(rotate(v,axis,q),axis,-q),v);\n" +
            " } assert.throws(()=>rotate([1,0,0],'x',Math.PI/4),TypeError);\n});\n" +
            "function deferred(){let release;const promise=new Promise(resolve=>{release=resolve;});return {promise,release};}\n" +
            "test('controlled pending-animation reset rejects stale commit and clears queued moves',async()=>{\n" +
            " const q=new MoveQueue(),latch=deferred();q.enqueue(1);q.enqueue(2);const old=q.animateNext(latch.promise);\n" +
            " q.reset();assert.equal(q.pending.length,0);latch.release();assert.equal(await old,false);\n" +
            " assert.equal(q.value,0);assert.deepEqual(q.history,[]);assert.equal(q.active,null);\n});\n" +
            "test('controlled scramble invalidates old animation without clearing its replacement',async()=>{\n" +
            " const q=new MoveQueue(),oldLatch=deferred(),newLatch=deferred();q.enqueue(1);\n" +
            " const old=q.animateNext(oldLatch.promise);q.scramble([1,2]);q.enqueue(1);\n" +
            " const current=q.animateNext(newLatch.promise);oldLatch.release();assert.equal(await old,false);\n" +
            " assert.equal(q.value,3);assert.notEqual(q.active,null);newLatch.release();assert.equal(await current,true);\n" +
            " assert.equal(q.value,0);assert.deepEqual(q.history,[1,2,1]);\n});\n" +
            "test('controlled undo cancels active animation and reverses only committed history',async()=>{\n" +
            " const q=new MoveQueue(),latch=deferred();q.scramble([1,2]);q.enqueue(1);\n" +
            " const old=q.animateNext(latch.promise);q.undo();assert.equal(q.value,1);latch.release();\n" +
            " assert.equal(await old,false);assert.deepEqual(q.history,[1]);q.undo();assert.equal(q.value,0);\n" +
            " q.enqueue(1);assert.equal(await q.animateNext(Promise.resolve()),true);assert.equal(q.value,1);\n});\n"
        let app = "import * as THREE from 'three';\n" +
            "import {rotate} from './cube-state.mjs';\n" +
            "const scene=new THREE.Scene(); scene.userData.discreteRotation=rotate;\n" +
            "document.querySelector('#status').textContent='Scene source loaded';\n"
        let html = "<!doctype html><meta charset='utf-8'><title>Offline source fixture</title>\n" +
            "<script type='importmap'>{\"imports\":{\"three\":\"https://cdn.jsdelivr.net/npm/three@0.170.0/build/three.module.js\"}}</script>\n" +
            "<p id='status'>Browser dependency load is not verified by the offline contract.</p>\n" +
            "<script type='module' src='./app.mjs'></script>\n"
        let probeArguments = objectValue([])
        let engineArguments = planFixtureWriteArguments(root + "/cube-state.mjs", engine)
        let testArguments = planFixtureWriteArguments(root + "/cube-state.test.mjs", test)
        let appArguments = planFixtureWriteArguments(root + "/app.mjs", app)
        let cdnArguments = planFixtureWriteArguments(root + "/index.html", html)
        let nodeArguments = objectValue([
            ValueField("executable", textValue("/usr/bin/node")),
            ValueField("argv", listValue([textValue("--test"), textValue("cube-state.test.mjs")])),
            ValueField("cwd", textValue(root)), ValueField("timeout", integerValue(30)),
            ValueField("readonly_workspace", boolValue(true)),
            ValueField("network", objectValue([ValueField("mode", textValue("denied"))]))
        ])
        let contract = PlanContract([root], [
            PlanExecutionStep(PlanStepId("acquire"), [], true,
                [planFixtureAction("probe-once", "dependency_probe_fixture", probeArguments,
                    OperationEffectClass.ReadOnly)], fallbackStepId: Some("cdn")),
            PlanExecutionStep(PlanStepId("cdn"), [], false,
                [planFixtureAction("write-cdn", "command_probe", cdnArguments, OperationEffectClass.ExternalMutation)]),
            PlanExecutionStep(PlanStepId("source"), [], true, [
                planFixtureAction("write-engine", "command_probe", engineArguments, OperationEffectClass.ExternalMutation),
                planFixtureAction("write-tests", "command_probe", testArguments, OperationEffectClass.ExternalMutation),
                planFixtureAction("write-app", "command_probe", appArguments, OperationEffectClass.ExternalMutation)
            ]),
            PlanExecutionStep(PlanStepId("verify"), ["acquire", "source"], true,
                [planFixtureAction("node-tests", "command_probe", nodeArguments,
                    OperationEffectClass.ReadOnly, evidence: "exit_zero")]),
            PlanExecutionStep(PlanStepId("verify-independent"), ["acquire", "source"], true,
                [planFixtureAction("node-tests-independent", "command_probe", nodeArguments,
                    OperationEffectClass.ReadOnly, evidence: "exit_zero")])
        ])
        let contractValidation = parsePlanContract(planContractValue(contract), requireToolIdentities: false)
        let contractDetail = match (contractValidation) {
            case Result.Err(error) => error.describe()
            case _ => "validated"
        }
        expect(contractValidation.isOk(), "fixture contract is structurally valid: " + contractDetail)
        expect(application.handle("/plan").isOk(), "enter read-only planning mode")
        fixture.enqueueToolCallReply("reliability-plan", "plugin.axyndra:workflow.plan_write", objectValue([
            ValueField("content", textValue("Acquire dependency once; on timeout use the approved CDN, write offline source, and run Node tests.")),
            ValueField("contract", planContractValue(contract))
        ]))
        let recorded = application.handle("record reliability contract")
        planFixtureConsumeApplicationFailure(product, application, recorded)
        let recordDetail = match (recorded) {
            case Result.Err(error) => error.describe()
            case Result.Ok(response) => response.text
        }
        expect(recorded.isOk(), "record the complete structured plan: " + recordDetail)
        let review = application.handle("/plan-review").value().getOrThrow()
        expect(planFixtureReviewContains(application, review, ["tool_identities", "probe-once", canary]),
            "review exposes the host-pinned contract before approval")
        // No queued calls: the fixture tries to end immediately. Approval is
        // consumed, but completion must fail without any canonical evidence.
        let callsBeforePremature = fixture.observedCallCount11318()
        let premature = application.approveLatestPlan()
        planFixtureConsumeApplicationFailure(product, application, premature)
        let prematurePlan = planFixtureReadInspection204(product, application.id())
        let prematureThread = ThreadId(application.id().value)
        let prematurePage = product.runInspection(prematureThread,
            product.latestRunId(prematureThread).value().getOrThrow()).value().getOrThrow()
        expect(premature.isError() && application.workMode() == "none" && dependency.calls == 0 &&
            fixture.observedCallCount11318() == callsBeforePremature + 1 && prematurePage.runState == "failed" &&
            prematurePlan.active && !prematurePlan.complete && !prematurePlan.sealed,
            "one evidence-free terminal reply fails canonically without no-progress re-prompting or sealing the active plan")
        prematurePage.returnPlanProjectionAfterConsumption204()
        expect(fixture.withLastRequest159({ request =>
            request.systemContains159("runnable_actions") && request.systemContains159(canary) &&
                !request.systemContains159("tool_identities") && !request.systemContains159("contract_view")
        }), "current source action remains executable without repeating frozen tool pins or the whole contract")
        fixture.enqueueToolCallReply("forged-host-probe", "command_probe", planFixtureBoundArguments(
            objectValue([
                ValueField("executable", textValue("/usr/bin/npm")),
                ValueField("argv", listValue([textValue("view"), textValue("three"), textValue("version")])),
                ValueField("network", objectValue([ValueField("mode", textValue("host"))]))
            ]), "acquire", "probe-once"))
        let forged = application.handle("switch the approved probe to host mode")
        planFixtureConsumeApplicationFailure(product, application, forged)
        expect(forged.isError() && dependency.calls == 0,
            "a different tool and HostNetwork request cannot borrow the approved dependency action")
        fixture.enqueueToolCallReply("dependency-once", "dependency_probe_fixture",
            planFixtureBoundArguments(probeArguments, "acquire", "probe-once"))
        fixture.enqueueToolCallReply("dependency-again", "dependency_probe_fixture",
            planFixtureBoundArguments(probeArguments, "acquire", "probe-once"))
        let exhaustedRetry = application.handle("use the approved dependency probe once then try its exhausted action")
        planFixtureConsumeApplicationFailure(product, application, exhaustedRetry)
        let retryDetail = match (exhaustedRetry) {
            case Result.Err(error) => error.describe()
            case Result.Ok(value) => value.text
        }
        expect(exhaustedRetry.isError() && dependency.calls == 1,
            "the active execution cannot replenish its exhausted dependency attempt: " + retryDetail)
        fixture.enqueueToolCallReply("offline-engine", "command_probe",
            planFixtureBoundArguments(engineArguments, "source", "write-engine"))
        fixture.enqueueToolCallReply("approved-cdn", "command_probe",
            planFixtureBoundArguments(cdnArguments, "cdn", "write-cdn"))
        fixture.enqueueToolCallReply("offline-tests", "command_probe",
            planFixtureBoundArguments(testArguments, "source", "write-tests"))
        fixture.enqueueToolCallReply("offline-app", "command_probe",
            planFixtureBoundArguments(appArguments, "source", "write-app"))
        fixture.enqueueToolCallReply("node-verify", "command_probe",
            planFixtureBoundArguments(nodeArguments, "verify", "node-tests"))
        fixture.enqueueToolCallReply("node-verify-independent", "command_probe",
            planFixtureBoundArguments(nodeArguments, "verify-independent", "node-tests-independent"))
        let completed = application.handle("continue approved offline work")
        planFixtureConsumeApplicationFailure(product, application, completed)
        let continuedDetail = match (completed) {
            case Result.Err(error) => error.describe()
            case Result.Ok(response) => response.text
        }
        println("plan-fixture-offline-flow completed=" + completed.isOk().toString())
        let continuedInspection = planFixtureReadInspection204(product, application.id(),
            diagnostics: completed.isError()).stepsDigest
        expect(completed.isOk(), "typed dependency timeout falls back and completes through production tool dispatch: " +
            continuedDetail + "; prior_completion=" + (match (premature) {
                case Result.Err(error) => error.describe()
                case _ => "unexpected success"
            }) + "; prior_forgery=" + (match (forged) {
                case Result.Err(error) => error.describe()
                case _ => "unexpected success"
            }) + "; inspection=" + continuedInspection)
        expect(dependency.calls == 1 && String.fromUtf8(File.readFrom(root + "/cube-state.mjs")) == engine &&
            String.fromUtf8(File.readFrom(root + "/cube-state.test.mjs")) == test &&
            String.fromUtf8(File.readFrom(root + "/index.html")).contains("three@0.170.0") &&
            exists(Path(root + "/app.mjs")), "one probe produces all approved offline sources and the fixed CDN fallback")
        let inspection = planFixtureReadInspection204(product, application.id())
        expect(inspection.complete && !inspection.containsCanary && !inspection.hasContractView,
            "both independent read-only Node receipts remain current and verify every required step")
        expect(fixture.withLastRequest159({ request =>
            request.systemContains159("runnable_actions") && !request.systemContains159(canary) &&
                !request.systemContains159("tool_identities") && !request.systemContains159("contract_view")
        }), "verified source bodies stop being repeated in the model system context")
        let database = SqliteDatabase(parent + "/plan-execution-state/state.db")
        try {
            expect(database.scalarInt("SELECT COUNT(*) FROM plan_executions WHERE instr(contract," + sqliteText(canary) + ")>0") == 1,
                "inspection redaction preserves the full approved arguments in canonical contract storage")
        } finally { database.close() }
        let rendered = application.handle("/inspect").value().getOrThrow().text
        expect(rendered.contains("Plan execution") && rendered.contains("fallback_verified") &&
            rendered.contains("remaining_attempts=0") && rendered.contains("request_visible_tools") &&
            rendered.contains("receipts=") && !rendered.contains(canary),
            "inspect exposes canonical fallback decisions, spent attempts and exact request tool views")
        let threadId = ThreadId(application.id().value)
        let runId = product.latestRunId(threadId).value().getOrThrow()
        let event = product.appCommand(AppCommand(AppCommandMeta(AppCommandId("approved-plan-inspect"), 1),
            AppCommandPayload.InspectRun(threadId, runId, 0, 25)))
        expect(match (event) {
            case Result.Ok(value) => match (value.payload) {
                case AppEventPayload.RunInspection(page) =>
                    page.planExecution.field("complete").getOrThrow().asBool() && !page.contexts.isEmpty() &&
                        !page.planExecution.toJson().contains(canary) && page.planExecution.field("contract_view").isNone() &&
                        !runInspectionValue(page).toJson().contains(canary) &&
                        runInspectionValue(page).field("plan_execution").getOrThrow().field("complete").getOrThrow().asBool()
                case _ => false
            }
            case _ => false
        }, "typed application inspection carries the canonical plan projection through the public app protocol")
        match (event) {
            case Result.Ok(value) => match (value.payload) {
                case AppEventPayload.RunInspection(page) => page.returnPlanProjectionAfterConsumption204()
                case _ => ()
            }
            case _ => ()
        }
        runPlanInspectionBankLifecycle204(parent, threadId, runId)
    } finally { planFixtureCloseProduct204(product) }
}

// Observe the real close result; callback return or OS shutdown alone is
// never substituted for a caller ACK or allocation retirement witness.
func planFixtureCloseProduct204(product: ProductRuntime, workflowLegacy!: Bool = true): Unit {
    let closed = product.close()
    let usage = productControlMetadataUsage113()
    println("plan-fixture-native-bank boundary=after-product-close owners=" + usage[0].toString() + " charged=" + usage[1].toString())
    expect(closed.isOk(), "actual plan fixture Product.close succeeds: " + (match (closed) {
        case Result.Err(error) => error.code
        case Result.Ok(_) => "closed"
    }))
    expect(product.actualCatalogTransientConsumersReturned204(),
        "actual Catalog raw aliases, publication, Host/Core source frames, pending metadata and active executions return")
    if (workflowLegacy) {
        expect(!product.closedCatalogDataReturned204() && product.originalCatalogLegacyAliasPaymentHeld204() &&
            usage[0] > 0 && usage[1] > 0,
            "the actual original workflow legacy alias blocks Catalog retirement and keeps its real payment")
    } else {
        expect(product.closedCatalogDataReturned204() && !product.originalCatalogLegacyAliasPaymentHeld204(),
            "a caller with no retained legacy source retires its actual Catalog DATA")
    }
}

func runPlanProcessScopeContract(parent: String): Unit {
    let root = canonicalize(Path(parent)).toString()
    let target = root + "/bash-approved-target"
    if (!exists(Path(target))) { Directory.create(target, recursive: true) }
    let inside = target + "/inside.txt"
    let relativeOutside = root + "/bash-outside-relative.txt"
    let absoluteOutside = root + "/bash-outside-absolute.txt"
    File.writeTo(inside, "before".toArray())
    File.writeTo(relativeOutside, "protected-relative".toArray())
    File.writeTo(absoluteOutside, "protected-absolute".toArray())
    let product = openProduct(config: ProductConfig(stateRoot: parent + "/plan-bash-scope-state", settingsRoot: parent + "/plan-bash-scope-settings",
        workspaceRoot: root, fixture: true, approvalMode: ApprovalMode.Yolo, asyncEnabled: false
    )).value().getOrThrow()
    try {
        installWorkflowContractPolicyScoped204(product)
        let application = product.applicationSession()
        let command = "printf inside-approved > inside.txt\n" +
            "if printf escaped > ../bash-outside-relative.txt; then printf relative-escape; fi\n" +
            "if printf escaped > " + planFixtureShellQuote(absoluteOutside) + "; then printf absolute-escape; fi\n" +
            "exit 0"
        let arguments = planFixtureProcessArguments(command, target)
        let contract = PlanContract([target], [PlanExecutionStep(PlanStepId("scoped-shell"), [], true,
            [planFixtureAction("approved-shell", "command_probe", arguments, OperationEffectClass.ExternalMutation, evidence: "exit_zero")])])
        planFixtureActivate(product, application.id(), contract)
        product.fixtureProbe.getOrThrow().enqueueToolCallReply("scoped-real-process", "command_probe",
            planFixtureBoundArguments(arguments, "scoped-shell", "approved-shell"))
        let executed = application.handle("execute the approved shell inside its narrow target root")
        planFixtureConsumeApplicationFailure(product, application, executed)
        let detail = match (executed) {
            case Result.Err(error) => error.describe()
            case Result.Ok(_) => "completed"
        }
        expect(executed.isOk() && String.fromUtf8(File.readFrom(inside)) == "inside-approved" &&
            String.fromUtf8(File.readFrom(relativeOutside)) == "protected-relative" &&
            String.fromUtf8(File.readFrom(absoluteOutside)) == "protected-absolute",
            "controlled process probe honors approved cwd and denies relative/absolute writes outside target roots: " + detail)
        let thread = ThreadId(application.id().value)
        let page = product.runInspection(thread, product.latestRunId(thread).value().getOrThrow()).value().getOrThrow()
        var completedReceipt = false
        for (operation in page.operations) {
            if (operation.toolName == "command_probe" && operation.receiptOutcome == "completed") { completedReceipt = true }
        }
        expect(completedReceipt && page.planExecution.field("complete").getOrThrow().asBool() &&
            page.planExecution.field("sealed").getOrThrow().asBool(),
            "the successful scoped controlled process probe has canonical completion evidence and a sealed approved plan")
        page.returnPlanProjectionAfterConsumption204()
    } finally { planFixtureCloseProduct204(product) }
}

// A persistent Native channel retains its startup sandbox. Approval of a
// narrow plan cannot convert it into the per-call controlled process adapter.
func runPlanNativeShellRefusalContract(parent: String): Unit {
    // The actual Native package is installed under stateRoot. Keep that
    // immutable package outside the writable workspace, as required by the
    // original lifecycle mount-overlap guard.
    let workspace = parent + "/plan-native-refusal-workspace"
    if (!exists(Path(workspace))) { Directory.create(workspace, recursive: true) }
    let root = canonicalize(Path(workspace)).toString()
    let marker = root + "/native-shell-supervised-must-not-run.txt"
    let product = openProduct(config: ProductConfig(stateRoot: parent + "/plan-native-refusal-state",
        settingsRoot: parent + "/plan-native-refusal-settings", workspaceRoot: root,
        fixture: true, approvalMode: ApprovalMode.Yolo, asyncEnabled: false)).value().getOrThrow()
    var setupOwners: Int64 = 0
    var setupCharge: Int64 = 0
    try {
        expect(product.actualCatalogTransientConsumersReturned204(),
            "before any plugin setup the fresh Product has no counted Catalog consumer or raw publication")
        // Structured review uses the real installed Workflow/Catalog DATA
        // owner, just as the ordinary Product plan frontend does. The legacy
        // service publication alone is not a modern snapshot payment source.
        installWorkflowContractPolicyScoped204(product)
        let shell = NativeShellContractBinding(product)
        let application = product.applicationSession()
        shell.start(application.id()) // normal explicit startup is separately authorized
        expect(product.hasPublishedTool159e(shell.name, threadId: Some(ThreadId(application.id().value))) &&
            shell.count("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") > 0 &&
            !product.actualCatalogTransientConsumersReturned204(),
            "real plugin setup and completed Native startup already retain Catalog data before the supervised request")
        let setupUsage = productControlMetadataUsage113()
        setupOwners = setupUsage[0]; setupCharge = setupUsage[1]
        expect(setupOwners > 0 && setupCharge > 0,
            "the original Native Registry bank is funded before any supervised model request")
        let arguments = objectValue([ValueField("command", textValue("printf forbidden > " + planFixtureShellQuote(marker))),
            ValueField("cwd", textValue(root)), ValueField("timeout", integerValue(30))])
        let contract = PlanContract([root], [PlanExecutionStep(PlanStepId("native-shell"), [], true,
            [planFixtureAction("persistent-command", shell.name, arguments, OperationEffectClass.ExternalMutation)])])
        let document = planFixtureDocument204(contract)
        expect(planFixtureReviewUnavailable204(product.reviewExecutionPlan(document)) &&
            planFixtureReviewUnavailable204(product.reviewExecutionPlan(document,
                sessionId: Some(SessionId("foreign-plan-review-session")))),
            "a real thread-scoped Native tool remains unavailable to global or foreign-session plan review")
        let internalContract = PlanContract([root], [PlanExecutionStep(PlanStepId("internal-control"), [], true,
            [planFixtureAction("hidden-control", HOST_PLUGIN_LIFECYCLE_TOOL, objectValue([]),
                OperationEffectClass.ExternalMutation)])])
        expect(planFixtureReviewUnavailable204(product.reviewExecutionPlan(planFixtureDocument204(internalContract),
            sessionId: Some(application.id()))),
            "the actual host startup control remains absent from same-session model plan identities")
        planFixtureActivate(product, application.id(), contract)
        product.fixtureProbe.getOrThrow().enqueueToolCallReply("reject-persistent-native-shell", shell.name, arguments)
        let result = application.handle("execute the supervised persistent Native Shell action")
        planFixtureConsumeApplicationFailure(product, application, result)
        let thread = ThreadId(application.id().value)
        let page = product.runInspection(thread, product.latestRunId(thread).value().getOrThrow()).value().getOrThrow()
        var rejected = false
        var receiptCode = "missing"
        var unsupported = false
        var handoffs: Int64 = 0
        let observerBank = LogicalJsonOwnerBudget()
        let observer = observerBank.acquire(65536)
        let database = SqliteDatabase(parent + "/plan-native-refusal-state/state.db")
        try {
            for (operation in page.operations where operation.toolName == shell.name) {
                if (operation.receiptOutcome == "rejected") {
                    rejected = true
                    let refusal = planFixtureNativeReceiptCode204(database, operation.operationId, observer)
                    receiptCode = refusal[0]; unsupported = refusal[1]
                }
                handoffs += database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id=" +
                    sqliteText(operation.operationId.value) + " AND kind='operation_execution_handoff'")
            }
        } finally { database.close(); observer.close() }
        expect(observerBank.usage()[0] == 0 && observerBank.usage()[1] == 0,
            "the complete bounded receipt observer returns its independent history-reader payment")
        let resultCode = match (result) { case Result.Err(error) => planFixtureFixedRefusalCode204(error.code)
            case Result.Ok(_) => "ok" }
        let markerExists = exists(Path(marker))
        let complete = page.planExecution.field("complete").getOrThrow().asBool()
        let state = planFixtureFixedRunState204(page.runState)
        println("plan-native-refusal result_error=" + result.isError().toString() + " result_code=" + resultCode +
            " rejected=" + rejected.toString() + " receipt_code=" + receiptCode +
            " unsupported=" + unsupported.toString() + " handoffs=" + handoffs.toString() +
            " marker_exists=" + markerExists.toString() + " run_state=" + state + " complete=" + complete.toString())
        expect(result.isError(), "the supervised persistent Native Shell request fails: " + resultCode)
        expect(rejected, "the persistent Native Shell call has its canonical rejected receipt")
        expect(unsupported, "the precise persistent Native Shell rejection is unsupported: " + receiptCode)
        expect(handoffs == 0, "the persistent Native Shell refusal has zero execution handoffs")
        expect(!markerExists, "the persistent Native Shell refusal has no file side effect")
        expect(state != "running" && state != "other", "the actual failure Run is canonically settled: " + state)
        expect(!complete, "the rejected Native Shell action does not falsely complete its approved plan")
        match (result) { case Result.Err(error) =>
            expect(!application.hasOwnedCheckpointFailure113(error),
                "the actual returned failure consumer has acknowledged its same paid caller")
            case Result.Ok(_) => () }
        page.returnPlanProjectionAfterConsumption204()
    } finally {
        // This is a conservative legacy-source fault case, not a normal
        // all-consumers-returned case. The real setup already retained Catalog
        // data before supervision, and the generic resolver remains unclosed.
        let closed = product.close()
        expect(closed.isOk(), "the actual conservative Native refusal closes its OS resources")
        if (setupOwners > 0) {
            let usage = productControlMetadataUsage113()
            // Startup totals include OS and transient owners that should
            // return at close. Aggregate remaining charge is not proof about
            // any particular surviving Catalog/source allocation.
            expect(!product.closedCatalogDataReturned204() && usage[0] > 0 && usage[1] > 0,
                "Catalog retirement remains conservatively refused while Native DATA charges still exist")
        }
    }
}

// A separate bounded history-reader invocation, never a replacement Tool or
// Run payer. Only a fixed code literal and an exact-cause Bool leave the frame.
func planFixtureNativeReceiptCode204(database: SqliteDatabase, operation: OperationId,
    observer: LogicalJsonOwnerReservation): (String, Bool) {
    let query = " FROM operation_receipts WHERE operation_id=" + sqliteText(operation.value)
    let bytes = database.scalarInt("SELECT length(CAST(detail AS BLOB))" + query)
    expect(bytes > 0 && bytes <= 65536, "the canonical Native refusal has bounded diagnostic data")
    observer.ensureRetainedPeak(1048576 + bytes * 2048)
    planFixtureNativeReceiptCodeFrame204(database, query)
}
private func planFixtureNativeReceiptCodeFrame204(database: SqliteDatabase, query: String): (String, Bool) {
    let rows = database.query("SELECT detail" + query)
    let detail = decodeStoredValue(rows[0].required(0))
    let error = match (detail.field("error_detail")) {
        case Some(value) => value
        case None => match (detail.field("error")) {
            case Some(value) => if (value.unifiedKind == ValueKind.Object) { value } else { detail }
            case None => detail
        }
    }
    // The actual preparation-read guard rejects before binding/schema code.
    // CorePreparationReadInput.deny wraps that fixed code, and the batch
    // coordinator persists tool.hook_denied via operationErrorValue. Require
    // both exact fields; an arbitrary hook denial is not this contract proof.
    let code = match (error.field("code")) {
        case Some(value) => if (value.unifiedKind == ValueKind.Text) { planFixtureFixedRefusalCode204(value.text) }
            else { "missing" }
        case None => "missing"
    }
    let sameCause = match (error.field("message")) {
        case Some(value) => value.unifiedKind == ValueKind.Text &&
            value.text == "preparation read did not complete: plan.tool_contract_required"
        case None => false
    }
    (code, code == "tool.hook_denied" && sameCause)
}
func planFixtureFixedRefusalCode204(actual: String): String {
    for (code in ["tool.hook_denied", "plan.tool_contract_required", "plan.binding_required", "plan.binding_invalid", "plan.binding_ambiguous",
        "plan.evidence_incomplete", "plan.admission_denied", "tool.arguments_invalid", "tool.not_found",
        "run.owned_checkpoint_failure_pending", "application.owned_failure_pending"]) {
        if (actual == code) { return code }
    }
    "other"
}
func planFixtureFixedRunState204(actual: String): String {
    for (state in ["running", "completed", "failed", "cancelled", "recovery_required", "awaiting_approval", "paused"]) {
        if (actual == state) { return state }
    }
    "other"
}

func planFixtureShellQuote(value: String): String {
    "'" + value.replace("'", "'\\''") + "'"
}

func runPlanRevisionControlContract(parent: String): Unit {
    let root = canonicalize(Path(parent)).toString()
    let product = openProduct(config: ProductConfig(stateRoot: parent + "/plan-revision-state", settingsRoot: parent + "/plan-revision-settings",
        workspaceRoot: root, fixture: true, approvalMode: ApprovalMode.Yolo, asyncEnabled: false
    )).value().getOrThrow()
    try {
        installWorkflowContractPolicyScoped204(product)
        let application = product.applicationSession()
        let oldPath = root + "/old-plan-budget-must-not-be-spent.txt"
        let oldArguments = planFixtureWriteArguments(oldPath, "old approved source")
        let oldContract = PlanContract([root], [PlanExecutionStep(PlanStepId("old-source"), [], true,
            [planFixtureAction("old-write", "command_probe", oldArguments, OperationEffectClass.ExternalMutation)])])
        planFixtureActivate(product, application.id(), oldContract)
        // Create actual durable, incomplete execution history without spending
        // an action. The finalization guard must reject the fixture's answer.
        let oldFailed = planFixtureRunBounded204(product, application.id(),
            "leave the old approved source pending", { _ => () })
        expect(oldFailed, "old plan remains incomplete without falsely completing its pending action")
        let oldRunId = product.latestRunId(ThreadId(application.id().value)).value().getOrThrow()
        let before = planFixtureReadInspection204(product, application.id())
        let oldExecutionId = before.executionDigest
        let oldSteps = before.stepsDigest
        expect(application.handle("/plan").isOk(), "user explicitly enters review while an incomplete plan is active")
        let fixture = product.fixtureProbe.getOrThrow()
        fixture.enqueueToolCallReply("forged-review-write", "command_probe",
            planFixtureBoundArguments(oldArguments, "old-source", "old-write"))
        // After the canonical refusal, the real Plan frontend may require its
        // one protocol-correction turn to record a plan. Supply an explicit
        // known contract instead of asking the generic fixture to invent an
        // action from a review catalog that intentionally has no glob tool.
        // Recording this proposal never approves or executes its source action.
        fixture.enqueueToolCallReply("review-after-refusal", "plugin.axyndra:workflow.plan_write", objectValue([
            ValueField("content", textValue("Goal: retain the pending approved source. Constraints: review is read-only. " +
                "Approach: keep the source pending for explicit approval. Acceptance: no source dispatch. Unresolved: none.")),
            ValueField("contract", planContractValue(oldContract))
        ]))
        let refused = application.handle("attempt a mutation during plan review")
        planFixtureConsumeApplicationFailure(product, application, refused)
        let refusedDetail = match (refused) {
            case Result.Err(error) => error.describe()
            case Result.Ok(_) => "the model turn returned normally after its denied tool call"
        }
        let reviewDatabase = SqliteDatabase(parent + "/plan-revision-state/state.db")
        var deniedReceipt = false
        var handoffs: Int64 = 0
        var receiptOutcome = "missing"
        try {
            let page = SqliteThreadPageStore(reviewDatabase).loadItemsPage(ThreadId(application.id().value), 0, 1000)
            let writes = ArrayList<String>()
            for (item in page.items) {
                match (item.content) {
                    case ThreadItemContent.ToolCall(callId, name, _) => if (name == "command_probe") { writes.add(callId.value) }
                    case _ => ()
                }
            }
            for (item in page.items) {
                match (item.content) {
                    case ThreadItemContent.ToolResult(callId, operationId, receiptId, _, isError) =>
                        if (!writes.contains(callId.value)) { continue }
                        let rows = reviewDatabase.query("SELECT outcome FROM operation_receipts WHERE id=" +
                            sqliteText(receiptId) + " AND operation_id=" + sqliteText(operationId.value))
                        if (rows.size == 1) {
                            receiptOutcome = rows[0].required(0)
                            deniedReceipt = isError && receiptOutcome == "rejected"
                        }
                        handoffs += reviewDatabase.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id=" +
                            sqliteText(operationId.value) + " AND kind='operation_execution_handoff'")
                    case _ => ()
                }
            }
        } finally { reviewDatabase.close() }
        let afterRefusal = planFixtureReadInspection204(product, application.id())
        expect(deniedReceipt && handoffs == 0 && !exists(Path(oldPath)) &&
            afterRefusal.executionDigest == oldExecutionId &&
            afterRefusal.stepsDigest == oldSteps,
            "review control canonically rejects forged writes without handoff or old budget consumption: " +
                refusedDetail + "; receipt=" + receiptOutcome + "; handoffs=" + handoffs.toString() +
                "; file_exists=" + exists(Path(oldPath)).toString() +
                "; inspection=" + afterRefusal.stepsDigest)
        let newPath = root + "/new-plan-user-approved-source.txt"
        let newArguments = planFixtureWriteArguments(newPath, "new reviewed source")
        let newContract = PlanContract([root], [PlanExecutionStep(PlanStepId("new-source"), [], true,
            [planFixtureAction("new-write", "command_probe", newArguments, OperationEffectClass.ExternalMutation)])])
        fixture.enqueueToolCallReply("revised-plan-write", "plugin.axyndra:workflow.plan_write", objectValue([
            ValueField("content", textValue("Goal: replace the pending plan. Constraints: review is read-only. " +
                "Approach: write new approved source. Acceptance: canonical write receipt. Unresolved: none.")),
            ValueField("contract", planContractValue(newContract))
        ]))
        let recorded = application.handle("record the replacement execution plan")
        planFixtureConsumeApplicationFailure(product, application, recorded)
        let recordedDetail = match (recorded) {
            case Result.Err(error) => error.describe()
            case Result.Ok(value) => value.text
        }
        expect(recorded.isOk(), "new plan_write is a genuine review control operation: " + recordedDetail)
        expect(fixture.withLastRequest159({ request =>
            request.hasOnlyTool159("plugin.axyndra:workflow.plan_write")
        }), "review requests expose only the authenticated review-safe workflow plan tool")
        let whileReviewing = planFixtureReadInspection204(product, application.id())
        expect(whileReviewing.executionDigest == oldExecutionId &&
            whileReviewing.stepsDigest == oldSteps && !exists(Path(newPath)),
            "recording a replacement does not switch active execution or spend the old action budget")
        let review = application.handle("/plan-review").value().getOrThrow()
        let approvedIdentity = planFixtureReviewIdentity(application, review)
        fixture.enqueueToolCallReply("new-approved-write", "command_probe",
            planFixtureBoundArguments(newArguments, "new-source", "new-write"))
        let approved = application.approveLatestPlan(expectedHash: approvedIdentity, contextMode: "keep")
        planFixtureConsumeApplicationFailure(product, application, approved)
        let approvedDetail = match (approved) {
            case Result.Err(error) => error.describe()
            case Result.Ok(value) => value.text
        }
        expect(approved.isOk() && String.fromUtf8(File.readFrom(newPath)) == "new reviewed source" &&
            !exists(Path(oldPath)), "only fresh user approval activates the new contract: " + approvedDetail)
        let after = planFixtureReadInspection204(product, application.id(), expectedApproval: approvedIdentity)
        expect(after.executionDigest != oldExecutionId && after.matchesApproval && after.complete,
            "new execution binds the exact displayed review identity and canonical completion evidence")
        let executedPage = product.runInspection(ThreadId(application.id().value),
            product.latestRunId(ThreadId(application.id().value)).value().getOrThrow()).value().getOrThrow()
        let database = SqliteDatabase(parent + "/plan-revision-state/state.db")
        try {
            let manifests = SqliteContextManifestStore(database)
            var identityPreserved = false
            for (context in executedPage.contexts) {
                let manifest = manifests.load(ContextManifestId(context.manifestId)).value().getOrThrow()
                match (manifest.namedFactVersions.field("task_context")) {
                    case Some(facts) => match (facts.field("approval_hash")) {
                        case Some(identity) => if (identity.text == approvedIdentity && manifest.isSealed()) {
                            identityPreserved = true
                        }
                        case None => ()
                    }
                    case None => ()
                }
            }
            expect(identityPreserved, "executed model context durably preserves the exact review approval identity")
        } finally { database.close() }
        executedPage.returnPlanProjectionAfterConsumption204()
        let scopeRequest = product.request("start a later unrelated task", sessionId: Some(application.id()))
        expect(scopeRequest.planContextFacts.field("approval_hash").isNone(),
            "a sealed execution does not lend its approval or task scope to a later task")
        let history = product.runInspection(ThreadId(application.id().value), oldRunId).value().getOrThrow()
        expect(modelPolicySha256Text(history.planExecution.field("execution_id").getOrThrow().text) == oldExecutionId &&
            modelPolicySha256Text(history.planExecution.field("steps").getOrThrow().toJson()) == oldSteps && history.runState != "completed",
            "superseding approval preserves old execution history and its unspent action budget")
        history.returnPlanProjectionAfterConsumption204()
    } finally { planFixtureCloseProduct204(product) }
}

func runPlanHardBudgetDrainContract(parent: String): Unit {
    let root = canonicalize(Path(parent)).toString()
    let product = openProduct(config: ProductConfig(stateRoot: parent + "/plan-drain-state", settingsRoot: parent + "/plan-drain-settings",
        workspaceRoot: root, fixture: true, approvalMode: ApprovalMode.Yolo, asyncEnabled: false
    )).value().getOrThrow()
    try {
        installWorkflowContractPolicyScoped204(product)
        let application = product.applicationSession()
        let glob = objectValue([])
        expect(product.registerTool(ToolDescriptor(ModelToolDefinition("plan_observe_fixture",
            "Deterministic read-only observation for hard-budget drain", objectValue([
                ValueField("type", textValue("object")), ValueField("properties", objectValue([])),
                ValueField("required", listValue([]))])), Capability(CapabilityKind.WorkspaceRead),
            supervisedExecutionSafe: true), PlanContractObservation()).isOk(),
            "register the observation through the production catalog")
        let output = root + "/drain-required-source.txt"
        let contract = PlanContract([root], [PlanExecutionStep(PlanStepId("drain-step"), [], true, [
            planFixtureAction("drain-observe", "plan_observe_fixture", glob, OperationEffectClass.ReadOnly),
            planFixtureAction("drain-required-write", "command_probe", planFixtureWriteArguments(output, "required"),
                OperationEffectClass.ExternalMutation)
        ])])
        planFixtureActivate(product, application.id(), contract)
        product.fixtureProbe.getOrThrow().enqueueToolCallReply("drain-one-observation", "plan_observe_fixture",
            planFixtureBoundArguments(glob, "drain-step", "drain-observe"))
        let events = ArrayList<AgentEvent>()
        let failed = planFixtureRunBounded204(product, application.id(),
            "reach hard drain with required source still pending", { event => events.add(event) })
        var exhausted = false
        var completed = false
        for (event in events) {
            match (event.payload) {
                case AgentEventPayload.RunCompleted => completed = true
                case _ => ()
            }
            match (eventProtocolDetail(event).field("code")) {
                case Some(code) => if (code.text == "budget.exhausted") { exhausted = true }
                case None => ()
            }
        }
        expect(failed && exhausted && !completed && !exists(Path(output)),
            "hard-budget drain cannot bypass required plan evidence or emit successful completion")
        let thread = ThreadId(application.id().value)
        let page = product.runInspection(thread, product.latestRunId(thread).value().getOrThrow()).value().getOrThrow()
        expect(page.runState != "completed" && !page.planExecution.field("complete").getOrThrow().asBool(),
            "hard-budget partial work remains durably incomplete in canonical inspection")
        page.returnPlanProjectionAfterConsumption204()
    } finally { planFixtureCloseProduct204(product) }
}

class PlanContractObservation <: ToolExecutor {
    public func execute(_: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        Result.Ok(ToolResult(prepared.call.callId, objectValue([])))
    }
}

class PlanContractUnknownMutation <: ToolExecutor {
    private let marker: String
    public var calls: Int64 = 0
    init(marker: String) { this.marker = marker }
    public func execute(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> {
        calls += 1
        File.writeTo(marker, "effect occurred before transport failure".toArray())
        Result.Err(AgentError(AgentErrorKind.Transport, "fixture.response_lost_after_effect",
            "A deterministic transport failure occurred after the approved mutation"))
    }
}

func runPlanUnknownMutationStopsContract(parent: String): Unit {
    let root = canonicalize(Path(parent)).toString()
    let product = openProduct(config: ProductConfig(stateRoot: parent + "/plan-unknown-state", settingsRoot: parent + "/plan-unknown-settings",
        workspaceRoot: root, fixture: true, approvalMode: ApprovalMode.Yolo, asyncEnabled: false
    )).value().getOrThrow()
    try {
        installWorkflowContractPolicyScoped204(product)
        let marker = root + "/unknown-effect.txt"
        let independentPath = root + "/must-not-follow-unknown.txt"
        let tool = PlanContractUnknownMutation(marker)
        expect(product.registerTool(ToolDescriptor(ModelToolDefinition("unknown_mutation_fixture",
            "Deterministic loss of mutation response", objectValue([
                ValueField("type", textValue("object")), ValueField("properties", objectValue([])),
                ValueField("required", listValue([]))])), Capability(CapabilityKind.WorkspaceWrite, resource: marker),
            sideEffecting: true, supervisedExecutionSafe: true), tool).isOk(),
            "register the mutating transport-failure fixture through the normal tool catalog")
        let application = product.applicationSession()
        let empty = objectValue([])
        let independentArguments = planFixtureWriteArguments(independentPath, "must not dispatch")
        let contract = PlanContract([root], [
            PlanExecutionStep(PlanStepId("uncertain"), [], true,
                [planFixtureAction("unknown-once", "unknown_mutation_fixture", empty,
                    OperationEffectClass.WorkspaceMutation)]),
            PlanExecutionStep(PlanStepId("independent"), [], true,
                [planFixtureAction("independent-write", "command_probe", independentArguments,
                    OperationEffectClass.ExternalMutation)])
        ])
        planFixtureActivate(product, application.id(), contract)
        let fixture = product.fixtureProbe.getOrThrow()
        fixture.enqueueToolCallReply("unknown-effect", "unknown_mutation_fixture",
            planFixtureBoundArguments(empty, "uncertain", "unknown-once"))
        fixture.enqueueToolCallReply("must-not-dispatch", "command_probe",
            planFixtureBoundArguments(independentArguments, "independent", "independent-write"))
        let result = application.handle("execute the approved mutation then independent work")
        planFixtureConsumeApplicationFailure(product, application, result)
        expect(result.isError() && tool.calls == 1 && exists(Path(marker)) && !exists(Path(independentPath)),
            "unknown mutation outcome requires recovery and prevents independent work from dispatching")
        let thread = ThreadId(application.id().value)
        let page = product.runInspection(thread, product.latestRunId(thread).value().getOrThrow()).value().getOrThrow()
        var sawUnknown = false
        var sawIndependent = false
        for (operation in page.operations) {
            if (operation.toolName == "unknown_mutation_fixture" && operation.receiptOutcome == "unknown") {
                sawUnknown = true
            }
            if (operation.toolName == "command_probe") { sawIndependent = true }
        }
        expect(sawUnknown && !sawIndependent && page.runState == "recovery_required",
            "canonical receipt preserves the unknown outcome without a second dispatched write")
        page.returnPlanProjectionAfterConsumption204()
    } finally { planFixtureCloseProduct204(product) }
}

// The request and the Core outcome remain inside this complete consuming
// frame. Only the separate custody handle survives to acknowledge the actual
// Product caller return; no request alias or fabricated task witness escapes.
func planFixtureRunScopedRequestFrame204(product: ProductRuntime, session: SessionId,
    expectedFile: String): PlanRequestCustody204 {
    let request = product.prepareRequest("execute the approved controlled source write", sessionId: Some(session))
        .value().getOrThrow()
    let custody = request.planRequestCustody204.getOrThrow()
    expect(request.planContextFacts.field("approval_hash").isSome(),
        "actual Product preparation attaches the approved task scope and its original-bank custody")
    var selectedInstruction = false
    for (source in request.planContextFacts.field("instruction_sources").getOrThrow().items) {
        if (source.field("source").getOrThrow().text.endsWith("/AGENTS.md") &&
            source.field("selected").getOrThrow().asBool() &&
            source.field("hash").getOrThrow().text == modelPolicySha256Text("Scoped fixture guidance: preserve canonical operation receipts.\n")) {
            selectedInstruction = true
        }
    }
    expect(selectedInstruction && request.system.contains("Scoped fixture guidance: preserve canonical operation receipts."),
        "the real original-bank request pays for selected instruction text and its independently copied audit facts")
    let completed = product.client.startOwnedCheckpointFailure113(request, { _ => () })
    match (completed) {
        case OwnedAgentRunResult113.Existing(result) =>
            expect(result.isOk(), "the actual managed Core request completes its approved source action")
        case _ =>
            planFixtureConsumeOwnedFailure(completed)
            throw IllegalStateException("scoped request did not complete through its actual owned Core caller")
    }
    expect(exists(Path(expectedFile)), "the lifecycle proof includes the actual scoped process side effect")
    expect(planFixtureReadInspection204(product, session).sealed,
        "the canonical completed plan is sealed before its actual request frame returns")
    expect(!custody.isDataReturned204(),
        "terminal Core completion alone cannot refund a still-live Product request frame")
    custody
}

// An initial planning request has no approved scope yet. Its real Registry
// payer must still follow the same whole Product/Core caller lifecycle.
func planFixtureRunUnscopedReviewRequestFrame204(product: ProductRuntime,
    session: SessionId): PlanRequestCustody204 {
    let request = product.prepareRequest("observe the initial planning context", sessionId: Some(session),
        planReviewControl: true).value().getOrThrow()
    let custody = request.planRequestCustody204.getOrThrow()
    expect(request.planContextFacts.field("approval_hash").isNone() &&
        request.system.contains("Scoped fixture guidance: preserve canonical operation receipts."),
        "initial planning keeps ordinary selected instructions without inventing approved scope facts")
    let completed = product.client.startOwnedCheckpointFailure113(request, { _ => () })
    match (completed) {
        case OwnedAgentRunResult113.Existing(result) =>
            expect(result.isOk(), "the real initial planning request completes its actual managed Core caller")
        case _ =>
            planFixtureConsumeOwnedFailure(completed)
            throw IllegalStateException("initial planning request did not return through its actual owned Core caller")
    }
    expect(!custody.isDataReturned204(),
        "initial planning DATA remains charged while its actual Product request frame is live")
    custody
}

func runPlanRequestCustodyProductContract204(parent: String): Unit {
    let workspace = parent + "/plan-request-custody-workspace"
    if (!exists(Path(workspace))) { Directory.create(workspace, recursive: true) }
    let root = canonicalize(Path(workspace)).toString()
    File.writeTo(root + "/AGENTS.md", "Scoped fixture guidance: preserve canonical operation receipts.\n".toArray())
    let product = openProduct(config: ProductConfig(stateRoot: parent + "/plan-request-custody-state",
        settingsRoot: parent + "/plan-request-custody-settings", workspaceRoot: root,
        fixture: true, approvalMode: ApprovalMode.Yolo, asyncEnabled: false)).value().getOrThrow()
    try {
        installWorkflowContractPolicyScoped204(product)
        let application = product.applicationSession()
        let session = application.id()
        let planningCustody = planFixtureRunUnscopedReviewRequestFrame204(product, session)
        expect(!planningCustody.isDataReturned204(),
            "the returned initial planning helper still requires its true Product caller acknowledgement")
        planningCustody.returnApplicationFrame204()
        expect(planningCustody.isDataReturned204(),
            "the initial planning request retires only after both real Core and Product frames return")
        let path = root + "/owned-source.txt"
        let arguments = planFixtureWriteArguments(path, "actual managed request")
        let contract = PlanContract([root], [PlanExecutionStep(PlanStepId("request-source"), [], true, [
            planFixtureAction("request-write", "command_probe", arguments, OperationEffectClass.ExternalMutation)
        ])])
        planFixtureActivate(product, session, contract)
        product.fixtureProbe.getOrThrow().enqueueToolCallReply("owned-request-source", "command_probe",
            planFixtureBoundArguments(arguments, "request-source", "request-write"))
        let custody = planFixtureRunScopedRequestFrame204(product, session, path)
        expect(!custody.isDataReturned204(),
            "the returned complete helper still requires the actual Product caller acknowledgement")
        custody.returnApplicationFrame204()
        expect(custody.isDataReturned204(),
            "actual Core task return and whole Product frame acknowledgement retire the original request DATA payment")
        // Reuse the actual installed Product and its unchanged original bank.
        // Each complete handle publishes a distinct scoped approval and real
        // source receipt; no alternate allocator or manual collector is used.
        for (index in 1..4) {
            let repeatedPath = root + "/repeated-source-" + index.toString() + ".txt"
            let repeatedArguments = planFixtureWriteArguments(repeatedPath, "repeated canonical source")
            let repeatedContract = PlanContract([root], [PlanExecutionStep(PlanStepId("repeat-source"), [], true, [
                planFixtureAction("repeat-write", "command_probe", repeatedArguments, OperationEffectClass.ExternalMutation)
            ])])
            planFixtureActivate(product, session, repeatedContract)
            product.fixtureProbe.getOrThrow().enqueueToolCallReply("repeated-source-" + index.toString(), "command_probe",
                planFixtureBoundArguments(repeatedArguments, "repeat-source", "repeat-write"))
            let repeated = application.handle("execute the next independently approved source action")
            planFixtureConsumeApplicationFailure(product, application, repeated)
            expect(repeated.isOk() && exists(Path(repeatedPath)) && planFixtureReadInspection204(product, session).sealed,
                "repeated whole Application.handle calls retain real scope, source evidence and original-bank capacity")
        }
    } finally { planFixtureCloseProduct204(product) }
}

// This is an independent history-reader invocation, exactly as the minimal
// CLI owns its first DATA bank. No alternate execution or Tool bank is used.
func runPlanInspectionBankLifecycle204(parent: String, thread: ThreadId, run: RunId): Unit {
    let original = LogicalJsonOwnerBudget()
    let baseline = original.usage()
    let database = SqliteDatabase(parent + "/plan-execution-state/state.db")
    try {
        let projection = RunInspectionProjection(database, knownParentAllocation204: Some({ invoice => original.acquire(invoice) }))
        let page = projection.inspect(thread, run, 0, 25).value().getOrThrow()
        expect(original.usage()[1] > baseline[1], "an unreturned actual history page retains its original-bank projection payment")
        expect(planFixtureSerializeInspection204(page), "the actual complete inspection serializer consumes a redacted completed plan")
        expect(original.usage()[1] > baseline[1], "ordinary serialization return does not substitute for its caller acknowledgement")
        page.returnPlanProjectionAfterConsumption204()
        expect(original.usage() == baseline, "the complete reader return and actual Page ACK refund the independent projection")
        var refused = false
        try { let _ = page.planExecution } catch (_: Exception) { refused = true }
        expect(refused, "a retired actual page refuses a stale projection getter")
    } finally { database.close() }
}

func planFixtureSerializeInspection204(page: AppRunInspectionPage): Bool {
    let serialized = runInspectionValue(page).toJson()
    serialized.contains("plan_execution") && serialized.contains("complete") &&
        !serialized.contains("PLAN_ARGUMENT_SECRET_CANARY") && page.planExecution.field("complete").getOrThrow().asBool()
}

// Closed fixture observations retain only fixed-size digests and booleans,
// never a borrowed canonical projection, source string or argument graph.
class PlanFixtureInspection204 {
    var active = false
    var complete = false
    var sealed = false
    var containsCanary = false
    var hasContractView = false
    var matchesApproval = false
    var executionDigest = ""
    var stepsDigest = ""
}
func planFixtureReadInspection204(product: ProductRuntime, session: SessionId,
    expectedApproval!: String = "", diagnostics!: Bool = false): PlanFixtureInspection204 {
    let observed = PlanFixtureInspection204()
    let result = product.withPlanExecutionInspectionForSession204(session, { state =>
        observed.active = state.field("active").getOrThrow().asBool()
        observed.complete = state.field("complete").getOrThrow().asBool()
        observed.sealed = state.field("sealed").getOrThrow().asBool()
        observed.containsCanary = state.toJson().contains("PLAN_ARGUMENT_SECRET_CANARY")
        observed.hasContractView = state.field("contract_view").isSome()
        let execution = state.field("execution_id").getOrThrow().text
        observed.executionDigest = modelPolicySha256Text(execution)
        observed.stepsDigest = modelPolicySha256Text(state.field("steps").getOrThrow().toJson())
        let identity = execution.split("-")
        observed.matchesApproval = identity.size > 3 && identity[1] == expectedApproval
        if (diagnostics) {
            var stepIndex: Int64 = 0
            for (step in state.field("steps").getOrThrow().items) {
                var actionIndex: Int64 = 0
                for (action in step.field("actions").getOrThrow().items) {
                    // Only closed enum literals and ordinal counts enter logs.
                    let safeState = match (action.field("state").getOrThrow().text) {
                        case "pending" => "pending"
                        case "runnable" => "runnable"
                        case "verified" => "verified"
                        case "blocked" => "blocked"
                        case "failed" => "failed"
                        case "skipped" => "skipped"
                        case _ => "other"
                    }
                    println("plan-fixture-action step=" + stepIndex.toString() +
                        " action=" + actionIndex.toString() + " state=" + safeState)
                    actionIndex++
                }
                stepIndex++
            }
        }
        Result<Unit>.Ok(())
    })
    expect(result.isOk(), "actual closed paid plan inspection succeeds: " + (match (result) {
        case Result.Err(error) => error.code
        case Result.Ok(_) => "observed"
    }))
    observed
}

// A failed actual Run retains its paid caller publication in this target.
// Read the original error in its funded closed frame before acknowledging the
// same publication; neither this helper nor a plain Err clears a guard.
func planFixtureConsumeOwnedFailure(value: OwnedAgentRunResult113): Unit {
    match (value) {
        case OwnedAgentRunResult113.Failed(caller) =>
            expect(caller.withError({ error, fund =>
                fund(65536).value().getOrThrow()
                expect(error.code != "" && error.code != "application.owned_failure_pending",
                    "consume the original paid failure, not a pending caller marker")
                println("plan fixture original failure: " + error.code)
                Result<Unit>.Ok(())
            }).isOk(), "the original caller observes its actual paid failure")
            expect(caller.acknowledgeAfterConsumption().isOk(), "acknowledge only the fully consumed actual caller")
        case OwnedAgentRunResult113.Pending(caller) =>
            expect(caller.withError({ error, fund =>
                fund(65536).value().getOrThrow()
                expect(error.code != "" && error.code != "application.owned_failure_pending",
                    "consume the original pending paid error")
            }).isOk(), "observe the actual pending failure consumer")
            expect(caller.acknowledgeAfterConsumption().isOk(), "acknowledge the consumed pending caller")
        case OwnedAgentRunResult113.Existing(_) => ()
        case OwnedAgentRunResult113.Held => throw IllegalStateException("actual failure caller is still held")
    }
}

class PlanFixtureScalarFlag204 {
    var value = false
}

func planFixtureConsumeApplicationFailure(product: ProductRuntime, application: ApplicationSession,
    result: Result<ApplicationResponse>): Unit {
    match (result) {
        case Result.Err(marker) =>
            if (application.hasOwnedCheckpointFailure113(marker)) {
                let run = match (product.latestRunId(ThreadId(application.id().value))) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => throw IllegalStateException("actual failure Run lookup: " + error.code)
                }
                let sameIdentity = PlanFixtureScalarFlag204()
                let matched = application.withOwnedCheckpointRunIdentity113(marker, { actual =>
                    sameIdentity.value = actual.value == run.value
                    Result<Unit>.Ok(())
                })
                expect(matched.isOk() && matched.value().getOrThrow() && sameIdentity.value,
                    "canonical failure Run must match the original Session-held identity before handoff")
                // This overload distinguishes a real ready consumer from Held
                // and Existing. The marker overload deliberately cannot do so.
                let actual = application.takeOwnedCheckpointFailure113(run)
                var consumed = false
                match (actual) {
                    case OwnedAgentRunResult113.Existing(original) =>
                        match (original) {
                            case Result.Err(error) => println("plan fixture failure handoff=existing error=" + error.code)
                            case Result.Ok(_) => println("plan fixture failure handoff=existing outcome=ok")
                        }
                    case OwnedAgentRunResult113.Held =>
                        throw IllegalStateException("actual failure handoff remains Held at its exact canonical Run")
                    case _ =>
                        planFixtureConsumeOwnedFailure(actual)
                        consumed = true
                }
                application.collectOwnedCheckpointFailure113()
                if (consumed) {
                    let settled = application.takeOwnedCheckpointFailure113(run)
                    expect(match (settled) {
                        case OwnedAgentRunResult113.Existing(_) => true
                        case _ => false
                    }, "the actual consumed caller settles to Existing after its real ACK")
                    application.collectOwnedCheckpointFailure113()
                }
                expect(!application.hasOwnedCheckpointFailure113(marker), "the actual application caller debt is retired")
                let page = match (product.runInspection(ThreadId(application.id().value), run)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => throw IllegalStateException("actual failure inspection refused: " + error.code)
                }
                expect(page.runState != "running", "a returned failure must have canonical terminal or recovery state: " + page.runState)
                page.returnPlanProjectionAfterConsumption204()
            } else if (marker.code == "application.owned_failure_pending") {
                throw IllegalStateException("actual fixed pending marker has no consumable application failure slot")
            }
        case Result.Ok(_) => ()
    }
}

// The whole request consumer frame returns before its caller ACKs custody.
// The cloned bounded request shares the actual Product payment and preserves
// its managed owned113 Core path; no second DATA pool or fake return witness.
func planFixtureRunBounded204(product: ProductRuntime, session: SessionId,
    prompt: String, sink: AgentEventSink): Bool {
    let observed = planFixtureRunBoundedFrame204(product, session, prompt, sink)
    match (observed[0]) { case Some(custody) => custody.returnApplicationFrame204(); case None => () }
    observed[1]
}
func planFixtureRunBoundedFrame204(product: ProductRuntime, session: SessionId,
    prompt: String, sink: AgentEventSink): (?PlanRequestCustody204, Bool) {
    let base = product.prepareRequest(prompt, sessionId: Some(session)).value().getOrThrow()
    let request = AgentRunRequest(base.runId, base.sessionId, base.model, base.prompt,
        system: base.system, capabilities: base.capabilities,
        modelCapabilitiesSnapshot: Some(base.modelCapabilitiesSnapshot),
        budget: ResourceBudget(maxTurns: 1, maxTotalOutputTokens: 2),
        toolContext: base.toolContext, planContextFacts: base.planContextFacts,
        planRequestCustody204: base.planRequestCustody204)
    let result = product.client.startOwnedCheckpointFailure113(request, sink)
    let failed = match (result) {
        case OwnedAgentRunResult113.Existing(value) => value.isError()
        case OwnedAgentRunResult113.Held =>
            throw IllegalStateException("bounded request actual caller remains held")
        case _ =>
            planFixtureConsumeOwnedFailure(result)
            let refreshed = product.client.takeOwnedCheckpointFailure113(request.runId)
            expect(match (refreshed) { case OwnedAgentRunResult113.Existing(_) => true; case _ => false },
                "bounded request original paid caller settles only after its actual consumption ACK")
            true
    }
    (request.planRequestCustody204, failed)
}

// Consume the actual frontend View source inside its existing closed
// observation frame. ApplicationResponse.text is intentionally empty here.
func planFixtureReviewContains(application: ApplicationSession, response: ApplicationResponse,
    required: Array<String>): Bool {
    let route = match (response.action) {
        case ApplicationAction.OpenPluginView(value) => value
        case _ => return false
    }
    application.withJavaScriptPluginViewDocument<Bool>(route, "{}", "views-v1", { _, _, primary =>
        var present = true
        for (text in required where !primary.contains(text)) { present = false }
        Result.Ok(present)
    }).value().getOrThrow()
}

func planFixtureReviewIdentity(application: ApplicationSession, response: ApplicationResponse): String {
    let route = match (response.action) {
        case ApplicationAction.OpenPluginView(value) => value
        case _ => throw IllegalStateException("actual Native plan review View required")
    }
    application.withJavaScriptPluginViewDocument<String>(route, "{}", "views-v1", { _, _, primary =>
        Result.Ok(planReviewHash(primary))
    }).value().getOrThrow()
}

func planFixtureDocument204(contract: PlanContract): String {
    "Deterministic approved execution contract.\n\n<plan-contract>\n" +
        planContractValue(contract).toJson() + "\n</plan-contract>"
}
func planFixtureReviewUnavailable204(reviewed: Result<String>): Bool {
    match (reviewed) {
        case Result.Err(error) =>
            if (error.code != "plan.tool_unavailable") {
                throw IllegalStateException("unexpected plan review refusal code: " + error.code) }
            true
        case Result.Ok(_) => false
    }
}
func planFixtureActivate(product: ProductRuntime, sessionId: SessionId, contract: PlanContract): Unit {
    let document = planFixtureDocument204(contract)
    let reviewed = match (product.reviewExecutionPlan(document, sessionId: Some(sessionId))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException("fixture plan review rejected: " + error.code)
    }
    let open = "\n\n<plan-contract>\n"
    let close = "\n</plan-contract>"
    let start = reviewed.indexOf(open).getOrThrow() + open.size
    let pinned = match (parsePlanContract(parseUnifiedJson(reviewed[start..reviewed.size - close.size]))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException("fixture pinned contract rejected: " + error.code)
    }
    expect(product.activateExecutionPlan(planReviewHash(reviewed), sessionId, pinned).isOk(),
        "activate the reviewed immutable plan contract through the product approval boundary")
}

func planFixtureAction(id: String, tool: String, arguments: AgentValue,
    effect: OperationEffectClass, evidence!: String = "receipt_completed"): PlanAction {
    PlanAction(id, [tool], ["denied"], effect, arguments, 1, exactArguments: true, evidence: evidence)
}

func planFixtureWriteArguments(path: String, content: String): AgentValue {
    planFixtureProcessArguments("printf %s " + planFixtureShellQuote(content) + " > " + planFixtureShellQuote(path),
        Path(path).parent.toString())
}

func planFixtureProcessArguments(command: String, cwd: String): AgentValue {
    objectValue([ValueField("executable", textValue("/bin/sh")),
        ValueField("argv", listValue([textValue("-c"), textValue(command)])),
        ValueField("cwd", textValue(cwd)), ValueField("timeout", integerValue(30)),
        ValueField("network", objectValue([ValueField("mode", textValue("denied"))]))])
}

func planFixtureBoundArguments(arguments: AgentValue, stepId: String, actionId: String): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(all: arguments.fields)
    fields.add(ValueField("_plan", objectValue([
        ValueField("step_id", textValue(stepId)), ValueField("action_id", textValue(actionId))
    ])))
    objectValue(fields.toArray())
}
