package product_continuation_contract

import agent_core.*
import agent_domain.*
import agent_product.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.env.*
import std.io.*
import process4cj as process
import agent_plugin_registry
import agent_app_protocol.*
import yjson.*
import yjson_support.*

// Real Native task -> task -> per-call owned process dispatch must retain one immutable approval and
// shared action budget. The unsatisfied final check deliberately keeps it open.
func planChildInheritanceContract(parent: String): Unit {
    // Resource close preserves paid historical descriptions. The original
    // aggregate has a nonrefundable high-water mark while those values live;
    // separate scenarios therefore use complete real process lifecycles.
    childPlanRunCaseProcess204("positive", parent)
    childPlanRunCaseProcess204("strict", parent)
}

func childPlanWorkerMode204(): ?String {
    match (getVariable("AXYNDRA_PLAN_CHILD_CASE204")) {
        case Some(value) =>
            if (value != "positive" && value != "strict") { throw IllegalArgumentException("unknown child contract case") }
            Some(value)
        case None => None<String>
    }
}
func childPlanWorkerMain204(mode: String): Int64 {
    let parent = getVariable("AXYNDRA_PLAN_CHILD_ROOT204").getOrThrow()
    let root = Directory.createTemp(parent).toString()
    let observationBank = LogicalJsonOwnerBudget()
    let observer = observationBank.acquire(1048576)
    let observationPayments = ArrayList<LogicalJsonOwnerReservation>()
    try { childPlanCaseLifecycle204(mode, root, observer, observationPayments) }
    finally {
        // Complete historical-observation helper has returned; no copied
        // header or snapshot alias survives in this payment-only list.
        for (payment in observationPayments) { payment.close() }
        observationPayments.clear()
        observer.close(); let _ = removeIfExists(root, recursive: true)
    }
    expect(observationBank.usage()[0] == 0 && observationBank.usage()[1] == 0,
        "the complete independent fixture observer frame returns its own DATA")
    0
}
private func childPlanRunCaseProcess204(mode: String, parent: String): Unit {
    let environment = HashMap<String, String>()
    for ((name, value) in getVariables()) { environment[name] = value }
    environment["AXYNDRA_PLAN_CHILD_CASE204"] = mode
    environment["AXYNDRA_PLAN_CHILD_ROOT204"] = canonicalize(Path(parent)).toString()
    let child = process.startProcess(process.ProcessCommand(canonicalize(Path("/proc/self/exe")).toString(),
        workingDirectory: canonicalize(Path(".")).toString(), environment: environment, maxOutputBytes: 16384))
    let output = spawn { childPlanDrainPipe204(child.stdout) }
    let error = spawn { childPlanDrainPipe204(child.stderr) }
    let code = child.wait().code
    let stdout = output.get()
    let stderr = error.get()
    child.close()
    if (code != 0) {
        println(String.fromUtf8(stdout).replace(parent, "<fixture>"))
        println(String.fromUtf8(stderr).replace(parent, "<fixture>"))
    }
    expect(code == 0, "independent real child contract process " + mode + " completed with status " + code.toString())
}
private func childPlanDrainPipe204(stream: InputStream): Array<Byte> {
    let buffer = Array<Byte>(4096, repeat: 0)
    let output = ArrayList<Byte>()
    while (true) {
        let count = stream.read(buffer)
        if (count <= 0) { break }
        for (index in 0..count where output.size < 16384) { output.add(buffer[index]) }
    }
    output.toArray()
}
private class ChildPlanHeader204 {
    let id: String
    let parent: SessionId
    let session: String
    let status: String
    let description: String
    let task: String
    let assignment: String
    init(value: ProductSubagentSnapshot, parent: SessionId, payment: LogicalJsonOwnerReservation) {
        var bytes: Int64 = 32768
        for (text in [value.id, parent.value, value.sessionId.value, value.status, value.description, value.task, value.assignment]) {
            if (text.size > (Int64.Max - bytes) / 8) { throw IllegalStateException("fixture historical observation invoice overflow") }
            bytes += text.size * 8 + 8192
        }
        payment.ensureRetainedPeak(bytes)
        this.id = String.fromUtf8(value.id.toArray()); this.parent = SessionId(String.fromUtf8(parent.value.toArray()))
        this.session = String.fromUtf8(value.sessionId.value.toArray()); this.status = String.fromUtf8(value.status.toArray())
        this.description = String.fromUtf8(value.description.toArray()); this.task = String.fromUtf8(value.task.toArray())
        this.assignment = String.fromUtf8(value.assignment.toArray())
    }
}
private func childPlanHistoricalHeaders204(product: ProductRuntime, session: SessionId,
    observer: LogicalJsonOwnerReservation, payments: ArrayList<LogicalJsonOwnerReservation>): Array<ChildPlanHeader204> {
    let values = ArrayList<ChildPlanHeader204>()
    for (value in product.allSubagents(session)) {
        // Each retained observer copy gets a distinct same-test-bank child;
        // the original is observation-only and cannot fund production.
        let payment = observer.deriveRetainedLease()
        payments.add(payment)
        values.add(ChildPlanHeader204(value, session, payment))
        for (leaf in product.allSubagents(value.sessionId)) {
            let leafPayment = observer.deriveRetainedLease()
            payments.add(leafPayment)
            values.add(ChildPlanHeader204(leaf, value.sessionId, leafPayment))
        }
    }
    values.toArray()
}
private func childPlanCaseLifecycle204(mode: String, root: String, observer: LogicalJsonOwnerReservation,
    payments: ArrayList<LogicalJsonOwnerReservation>): Unit {
    let workspace = root + "/workspace"
    Directory.create(workspace, recursive: true)
    let stateRoot = root + "/state"
    let product = match (openProduct(config: ProductConfig(settingsRoot: root + "/config", stateRoot: stateRoot,
        workspaceRoot: workspace, fixture: true, approvalMode: ApprovalMode.Yolo, asyncEnabled: true))) {
        case Result.Err(error) => println("child-product-open-error-code=" + error.code)
            throw IllegalStateException("child Product cannot open")
        case Result.Ok(value) => value
    }
    let session = try {
        if (mode == "positive") { childPlanInheritanceFrame204(product, root, workspace, stateRoot) }
        else { childPlanStrictLifecycleFrame204(product, workspace, stateRoot) }
    } catch (error: Exception) {
        println("child-body-returned=false")
        try { childPlanCloseProductFrame204(product) }
        catch (closure: Exception) { println("child-close-after-body-error=true"); throw closure }
        throw error
    }
    println("child-body-returned=true")
    let expected = childPlanHistoricalHeaders204(product, session, observer, payments)
    expect(expected.size == (if (mode == "positive") { 2 } else { 1 }),
        "actual contract preserves the expected ordinary historical descriptions")
    if (mode == "strict") {
        childPlanConservativeDepthFault204(product, session, stateRoot, workspace, expected, observer)
        return
    }
    childPlanBeforeCloseCounts204(product, session, stateRoot)
    childPlanCloseProductFrame204(product)
    println("child-close-data catalog=" + product.closedCatalogDataReturned204().toString())
    for (header in expected) {
        println("child-close-data request=" + product.planChildRequestDataReturned204(header.id).toString() +
            " transient=" + product.planChildTransientDataReturned204(header.id).toString() +
            " header=" + product.planChildDescriptionHeaderPaid204(header.id).toString())
    }
    expect(product.actualCatalogTransientConsumersReturned204(),
        "all actual new execution-scope Catalog consumers return after full product closure")
    expect(product.originalCatalogLegacyAliasPaymentHeld204() && !product.closedCatalogDataReturned204(),
        "original target legacy Catalog aliases keep their real DATA payment and block full retirement")
    for (header in expected) {
        expect(product.planChildTransientDataReturned204(header.id),
            "actual Context, Prepared, history, worker and private projection consumers return after complete helpers")
        expect(product.planChildDescriptionHeaderPaid204(header.id),
            "retained ordinary Task descriptions keep their original real DATA payment")
        var found = false
        for (value in product.allSubagents(header.parent)) {
            if (value.id == header.id) {
                found = value.sessionId.value == header.session && value.status == header.status &&
                    value.description == header.description && value.task == header.task && value.assignment == header.assignment
            }
        }
        expect(found, "ordinary post-close snapshots preserve their original readable descriptions")
    }
}

// This fault occurs after the real derived handoff. A depth refusal proves
// no child Run was launched, but supplies no execution-effect receipt for that
// already executing Operation. Preserve the original Unknown/recovery debt.
private func childPlanConservativeDepthFault204(product: ProductRuntime, session: SessionId, stateRoot: String,
    workspace: String, expected: Array<ChildPlanHeader204>, observer: LogicalJsonOwnerReservation): Unit {
    let database = SqliteDatabase(stateRoot + "/state.db")
    try {
        childPlanKnownDepthFaultRows204(database, observer)
        let runs = database.scalarInt("SELECT COUNT(*) FROM runs")
        let operations = database.scalarInt("SELECT COUNT(*) FROM operations")
        let admissions = database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions")
        let receipts = childPlanFaultReceiptFingerprint204(database, observer)
        for (_ in 0..2) {
            match (product.close()) {
                case Result.Err(error) => expect(error.kind == AgentErrorKind.Internal && error.code == "task.worker_join_failed" &&
                    error.message == "plugin child completion or budget custody remains unsettled" && error.fields.isEmpty(),
                    "known post-handoff fault preserves the exact unsettled Task completion error")
                case Result.Ok(_) => throw IllegalStateException("unknown child effects cannot fabricate Product closure")
            }
            childPlanKnownDepthFaultRows204(database, observer)
            expect(database.scalarInt("SELECT COUNT(*) FROM runs") == runs &&
                database.scalarInt("SELECT COUNT(*) FROM operations") == operations &&
                database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions") == admissions &&
                childPlanFaultReceiptFingerprint204(database, observer) == receipts &&
                !exists(Path(workspace + "/bounded-depth-unreachable.txt")),
                "repeated real close cannot replay a Run/action or rewrite the exact unknown receipts")
            for (header in expected) {
                expect(header.status == "recovery_required" && product.planChildRequestDataPaid204(header.id) &&
                    !product.planChildRequestDataReturned204(header.id) && !product.planChildTransientDataReturned204(header.id) &&
                    product.planChildDescriptionHeaderPaid204(header.id),
                    "actual unknown child DATA and readable historical headers remain paid without false ACK")
                var found = false
                for (value in product.allSubagents(header.parent)) {
                    if (value.id == header.id) {
                        found = value.status == "recovery_required" && value.sessionId.value == header.session &&
                            value.description == header.description && value.task == header.task && value.assignment == header.assignment
                    }
                }
                expect(found, "conservative close failure preserves ordinary historical snapshot semantics")
            }
        }
    } finally { database.close() }
}
private func childPlanKnownDepthFaultRows204(database: SqliteDatabase, observer: LogicalJsonOwnerReservation): Unit {
    let actions = "SELECT operation_id FROM plan_action_admissions WHERE action_id IN ('bounded-first','bounded-second')"
    expect(database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions WHERE action_id IN ('bounded-first','bounded-second')") == 2 &&
        database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions WHERE action_id='bounded-leaf'") == 0,
        "only the two actual bounded Task actions are admitted, with no leaf execution")
    expect(database.scalarInt("SELECT COUNT(*) FROM operations o JOIN operation_receipts r ON r.operation_id=o.id " +
        "JOIN runs run ON run.id=o.run_id WHERE o.id IN (" + actions + ") AND o.state='recovery_required' " +
        "AND r.outcome='unknown' AND run.state='recovery_required'") == 2,
        "both actual canonical Task parents preserve Unknown and their real Run recovery state")
    let query = " FROM operation_receipts r JOIN derived_operation_admissions d ON d.operation_id=r.operation_id " +
        "JOIN operations o ON o.id=r.operation_id WHERE d.parent_operation_id IN " +
        "(SELECT operation_id FROM plan_action_admissions WHERE action_id='bounded-second')"
    expect(database.scalarInt("SELECT COUNT(*)" + query) == 1 &&
        database.scalarInt("SELECT COUNT(*)" + query + " AND r.outcome='unknown' AND o.state='recovery_required'") == 1,
        "the exact depth-refused derived child has its own immutable Unknown receipt")
    let bytes = database.scalarInt("SELECT length(CAST(r.detail AS BLOB))" + query)
    expect(bytes > 0 && bytes <= 8192, "known depth refusal has bounded canonical diagnostic data")
    observer.ensureRetainedPeak(1048576 + bytes * 2048)
    childPlanKnownDepthDetailFrame204(database, query)
}
private func childPlanKnownDepthDetailFrame204(database: SqliteDatabase, query: String): Unit {
    // The raw row and complete decoded value stay within this prepaid helper.
    let rows = database.query("SELECT r.detail" + query)
    let detail = decodeStoredValue(rows[0].required(0))
    expect(detail.field("error_code").isSome() && detail.field("error_code").getOrThrow().text == "subagent.budget_exceeded",
        "the actual typed depth-budget refusal, rather than another generic failure, caused the unknown child effect")
}
private func childPlanFaultReceiptFingerprint204(database: SqliteDatabase, observer: LogicalJsonOwnerReservation): String {
    let bytes = database.scalarInt("SELECT COALESCE(SUM(length(CAST(id AS BLOB))+length(CAST(operation_id AS BLOB))+" +
        "length(CAST(outcome AS BLOB))+length(CAST(detail AS BLOB))+length(CAST(verification AS BLOB))+" +
        "length(CAST(created_at_millis AS BLOB))),0) FROM operation_receipts")
    let count = database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
    if (bytes < 0 || count < 0 || count > (Int64.Max - 1048576) / 4096 ||
        bytes > (Int64.Max - 1048576 - count * 4096) / 32) { throw IllegalStateException("receipt observation invoice overflow") }
    observer.ensureRetainedPeak(1048576 + bytes * 32 + count * 4096)
    childPlanFaultReceiptHashFrame204(database)
}
private func childPlanFaultReceiptHashFrame204(database: SqliteDatabase): String {
    var source = ""
    for (row in database.query("SELECT id,operation_id,outcome,detail,verification,created_at_millis FROM operation_receipts ORDER BY id")) {
        for (column in 0..6) { let value = row.required(column); source += value.size.toString() + ":" + value }
    }
    // Only this fixed-size paid scalar leaves; raw receipt strings never do.
    modelPolicySha256Text(source)
}

private func childPlanBeforeCloseCounts204(product: ProductRuntime, session: SessionId, stateRoot: String): Unit {
    // Scalars only; do not open a full plan projection and alter the actual
    // production bank's historical charge during this failure observation.
    for (child in product.allSubagents(session)) {
        println("child-preclose status=" + child.status + " error-bytes=" + child.error.size.toString() +
            " request=" + product.planChildRequestDataReturned204(child.id).toString())
    }
    let database = SqliteDatabase(stateRoot + "/state.db")
    try {
        for (row in database.query("SELECT state,COUNT(*) FROM runs GROUP BY state")) {
            println("child-preclose run-state=" + row.required(0) + " count=" + row.required(1))
        }
        for (row in database.query("SELECT o.state,COALESCE(r.outcome,''),COUNT(*) FROM operations o " +
            "LEFT JOIN operation_receipts r ON r.operation_id=o.id GROUP BY o.state,r.outcome")) {
            println("child-preclose operation-state=" + row.required(0) + " outcome=" + row.required(1) + " count=" + row.required(2))
        }
    } finally { database.close() }
}

private func childPlanCloseProductFrame204(product: ProductRuntime): Unit {
    match (product.close()) {
        case Result.Err(error) =>
            println("child-product-close-error-code=" + error.code)
            throw IllegalStateException("actual child Product closure failed")
        case Result.Ok(_) => ()
    }
}

private func childPlanStrictLifecycleFrame204(product: ProductRuntime, workspace: String, stateRoot: String): SessionId {
    installChildPlanNativePolicy(product)
    childPlanPrelaunchDepthBudget204(product, workspace, stateRoot)
}

private func childPlanInheritanceFrame204(product: ProductRuntime, parent: String, workspace: String,
    stateRoot: String): SessionId {
        installChildPlanNativePolicy(product)
        let fixture = product.fixtureProbe.getOrThrow()
        let application = product.applicationSession()
        let rootTask = childPlanTask("child", "Delegate the approved leaf write")
        let nestedTask = childPlanTask("leaf", "Write the approved file")
        let write = childPlanWriteProbe(workspace, "child-proof.txt", "approved child\n")
        let finalCheck = childPlanWriteProbe(workspace, "final-proof.txt", "final\n")
        let contract = PlanContract([workspace], [
            PlanExecutionStep(PlanStepId("delegate"), [], true,
                [childPlanAction("root-task", "plugin.axyndra:workflow.task", rootTask, delegated: ["child-task", "leaf-write"])]),
            PlanExecutionStep(PlanStepId("nested"), [], true,
                [childPlanAction("child-task", "plugin.axyndra:workflow.task", nestedTask, delegated: ["leaf-write"])]),
            PlanExecutionStep(PlanStepId("source"), [], true,
                [childPlanAction("leaf-write", "command_probe", write)]),
            PlanExecutionStep(PlanStepId("final"), [], true,
                [childPlanAction("final-write", "command_probe", finalCheck)])
        ])
        expect(application.handle("/plan").isOk(), "child fixture enters planning")
        fixture.enqueueToolCallReply("child-plan", "plugin.axyndra:workflow.plan_write", objectValue([
            ValueField("content", textValue("Delegate one nested child, write approved source, then final check.")),
            ValueField("contract", planContractValue(contract))]))
        match (application.handle("record child plan")) {
            case Result.Err(error) => throw IllegalStateException(
                "contract failed: child plan records its executable contract: " + error.describe())
            case Result.Ok(_) => ()
        }
        let premature = application.approveLatestPlan()
        expect(premature.isError(), "unexecuted child plan cannot complete")
        childPlanConsumeApplicationFailure(product, application, premature)
        fixture.enqueueToolCallReply("root-task", "plugin.axyndra:workflow.task", childPlanBound(rootTask, "delegate", "root-task"))
        fixture.enqueueToolCallReply("nested-task", "plugin.axyndra:workflow.task", childPlanBound(nestedTask, "nested", "child-task"))
        fixture.enqueueToolCallReply("leaf-write", "command_probe", childPlanBound(write, "source", "leaf-write"))
        let execution = application.handle("execute the approved child work")
        expect(execution.isError(),
            "owner remains incomplete while independent required final evidence is absent")
        childPlanConsumeApplicationFailure(product, application, execution)
        if (!exists(Path(workspace + "/child-proof.txt")) ||
            String.fromUtf8(File.readFrom(workspace + "/child-proof.txt")) != "approved child\n") {
            println((match (execution) { case Result.Err(error) => error.describe(); case Result.Ok(_) => "unexpected success" })
                .replace(workspace, "<workspace>").replace(stateRoot, "<state>").replace(parent, "<temporary>"))
            childPlanPrintDiagnostics(product, application.id(), stateRoot, parent, workspace)
            throw IllegalStateException("contract failed: grandchild executes the approved write through the real product pipeline; see borrowed canonical diagnostics")
        }
        let children = product.allSubagents(application.id())
        if (children.size != 1 || children[0].status != "completed") {
            childPlanPrintDiagnostics(product, application.id(), stateRoot, parent, workspace)
            throw IllegalStateException("contract failed: child completes without requiring owner-only evidence; see complete borrowed diagnostics")
        }
        let leaves = product.allSubagents(children[0].sessionId)
        if (leaves.size != 1 || leaves[0].status != "completed") {
            childPlanPrintDiagnostics(product, application.id(), stateRoot, parent, workspace)
            throw IllegalStateException("contract failed: nested child inherits the same execution; see complete borrowed diagnostics")
        }
        expect(product.planChildRequestDataReturned204(children[0].id) &&
            product.planChildRequestDataReturned204(leaves[0].id),
            "both independent child requests retire only after actual Core, Product and worker frames return")
        expect(product.asyncJobs(application.id()).isEmpty() && product.asyncJobs(children[0].sessionId).isEmpty(),
            "supervised batch delegation settles inline even when product asynchronous execution is enabled")
        let database = SqliteDatabase(stateRoot + "/state.db")
        try {
            expect(database.scalarInt("SELECT COUNT(DISTINCT execution_id) FROM plan_execution_runs") == 1 &&
                database.scalarInt("SELECT COUNT(*) FROM plan_execution_sessions") == 3 &&
                database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions WHERE action_id='leaf-write'") == 1,
                "parent, child and grandchild use one execution with one spent leaf budget")
            for (child in [children[0], leaves[0]]) {
                childPlanCanonicalDepth204(database, child.runId.value, "4")
            }
            var settledTasks: Int64 = 0
            for (row in database.query("SELECT o.normalized_plan,r.detail FROM operations o " +
                "JOIN operation_receipts r ON r.operation_id=o.id WHERE r.outcome='completed'")) {
                if (decodeStoredValue(row.required(0)).field("tool").getOrThrow().text != "plugin.axyndra:workflow.task") { continue }
                let result = decodeStoredValue(row.required(1))
                expect(result.field("async").isNone(), "supervised task receipt never fabricates an asynchronous-start result")
                let childrenResult = result.field("results").getOrThrow().items
                expect(childrenResult.size == 1 && childrenResult[0].field("status").getOrThrow().text == "completed",
                    "canonical task success records the settled child before owner completion")
                settledTasks += 1
            }
            expect(settledTasks == 2, "both nesting levels settle through canonical task receipts")
        } finally { database.close() }
        // A fresh Run in the leaf session is still supervised. New Run identity
        // does not restore the exhausted action allowance.
        fixture.enqueueToolCallReply("leaf-retry", "command_probe", childPlanBound(write, "source", "leaf-write"))
        let leafApplication = product.applicationSession(sessionId: Some(leaves[0].sessionId))
        let exhausted = leafApplication.handle("retry exhausted action")
        expect(exhausted.isError(), "child session continuation cannot replenish the root approved action budget")
        childPlanConsumeApplicationFailure(product, leafApplication, exhausted)
        fixture.enqueueToolCallReply("leaf-sibling", "command_probe", childPlanBound(finalCheck, "final", "final-write"))
        let sibling = leafApplication.handle("try a sibling action")
        expect(sibling.isError() && !exists(Path(workspace + "/final-proof.txt")),
            "child cannot consume a sibling action outside its immutable delegated subrange")
        childPlanConsumeApplicationFailure(product, leafApplication, sibling)
        fixture.enqueueToolCallReply("owner-final", "command_probe", childPlanBound(finalCheck, "final", "final-write"))
        expect(application.handle("complete the approved final owner action").isOk() &&
            childPlanIsSealed(product, application.id()),
            "owner seals only after both child tasks and the final required action have settled")
        application.id()
}

// runs.budget deliberately stores only cumulative Runtime dimensions.
// The real immutable request projection carries the complete ResourceBudget;
// validate that source through the public durable continuation codec.
func childPlanCanonicalDepth204(database: SqliteDatabase, run: String, expected: String): Unit {
    // Fixture-only independent observation. This local default bank cannot
    // fund production, grant a Source or replace the actual request payer.
    let bank = LogicalJsonOwnerBudget()
    let observer = bank.acquire(131072)
    let observed = try { database.readTransaction<Bool> { tx: SqliteTransaction =>
        let parameters = [SqlParameter.Text(run)]
        let count = Int64.parse(tx.query("SELECT COUNT(*) FROM run_continuation_facts WHERE run_id=?", parameters)[0].required(0))
        if (count < 0 || count > (Int64.Max - 131072) / 4096) {
            throw IllegalStateException("depth observation row invoice overflow")
        }
        let metadata = 131072 + count * 4096
        observer.ensureRetainedPeak(metadata)
        let revisions = tx.query("SELECT revision,length(CAST(payload AS BLOB)) FROM run_continuation_facts WHERE run_id=? ORDER BY revision", parameters)
        var found = false
        for (revision in revisions) {
            let bytes = Int64.parse(revision.required(1))
            if (bytes < 0 || bytes > (Int64.Max - metadata) / 4) {
                throw IllegalStateException("depth observation raw invoice overflow")
            }
            if (childPlanObserveFactRow204(tx, run, Int64.parse(revision.required(0)), bytes, expected, observer, metadata)) {
                found = true
            }
        }
        found
    } } finally { observer.close() }
    expect(observed, "accepted child has a real canonical full-request budget projection")
    expect(bank.usage()[0] == 0 && bank.usage()[1] == 0,
        "the complete fixture observation returns before its independent local data payment")
}
// The entire raw SQL/byte/decoder helper returns before the next row is
// selected. No raw payload or graph escapes this actual observation frame.
func childPlanObserveFactRow204(tx: SqliteTransaction, run: String, revision: Int64, bytes: Int64,
    expected: String, observer: LogicalJsonOwnerReservation, metadata: Int64): Bool {
    let raw = metadata + bytes * 4
    observer.ensureRetainedPeak(raw)
    let rows = tx.query("SELECT payload FROM run_continuation_facts WHERE run_id=? AND revision=?",
        [SqlParameter.Text(run), SqlParameter.Int64Value(revision)])
    expect(rows.size == 1, "the same read snapshot retains its exact immutable continuation fact")
    let source = rows[0].required(0)
    let framed = source.toArray()
    expect(framed.size == bytes, "the prepaid canonical payload extent is unchanged in the same transaction")
    let graph = preparedFramedValueCopyPeak204(framed)
    if (graph > (Int64.Max - raw) / 2) { throw IllegalStateException("depth observation graph invoice overflow") }
    // Complete durable decode, its request projection, canonical
    // re-encoding/checksum work and original raw cells overlap here.
    observer.ensureRetainedPeak(raw + graph * 2)
    childPlanObserveDepthFrame204(source, expected)
}
func childPlanObserveDepthFrame204(source: String, expected: String): Bool {
    let durable = decodeDurableRunContinuation(source)
    match (optionalRunRequestSnapshotFromDurableContinuation(durable)) {
        case Some(snapshot) => match (snapshot.field("budget")) {
            case Some(budget) => match (budget.field("max_depth")) {
                case Some(depth) =>
                    expect(depth.unifiedKind == ValueKind.Number && depth.asNumberText() == expected,
                        "actual immutable accepted request retains the complete inherited depth ceiling")
                    true
                case None => throw IllegalStateException("actual request budget omitted its depth field")
            }
            case None => throw IllegalStateException("actual request projection omitted its full ResourceBudget")
        }
        case None => false
    }
}

// Actual prelaunch regression: tighten the real parent budget to depth=1.
// Native role defaults, the shared original payer and every permission stay
// unchanged; the second child reaches the same production admission guard.
func childPlanPrelaunchDepthBudget204(product: ProductRuntime, workspace: String, stateRoot: String): SessionId {
    let application = product.applicationSession()
    let fixture = product.fixtureProbe.getOrThrow()
    let first = childPlanTask("bounded-parent", "Delegate only the approved bounded child")
    let second = childPlanTask("bounded-rejected", "Do not exceed the inherited parent depth")
    let unreachable = childPlanWriteProbe(workspace, "bounded-depth-unreachable.txt", "unreachable")
    let contract = PlanContract([workspace], [
        PlanExecutionStep(PlanStepId("bounded-first"), [], true,
            [childPlanAction("bounded-first", "plugin.axyndra:workflow.task", first,
                delegated: ["bounded-second", "bounded-leaf"])]),
        PlanExecutionStep(PlanStepId("bounded-second"), [], true,
            [childPlanAction("bounded-second", "plugin.axyndra:workflow.task", second, delegated: ["bounded-leaf"])]),
        PlanExecutionStep(PlanStepId("bounded-leaf"), [], true,
            [childPlanAction("bounded-leaf", "command_probe", unreachable)])])
    match (application.handle("/plan")) {
        case Result.Err(error) => println("child-bounded-plan-error-code=" + error.code)
            throw IllegalStateException("bounded depth fixture cannot enter planning")
        case Result.Ok(_) => ()
    }
    fixture.enqueueToolCallReply("bounded-plan", "plugin.axyndra:workflow.plan_write", objectValue([
        ValueField("content", textValue("Preserve the actual parent's stricter depth and revoke only true unstarted child bindings.")),
        ValueField("contract", planContractValue(contract))]))
    match (application.handle("record the bounded child plan")) {
        case Result.Err(error) => println("child-bounded-record-error-code=" + error.code)
            childPlanConsumeApplicationFailure(product, application, Result<ApplicationResponse>.Err(error))
            throw IllegalStateException("bounded depth fixture cannot record its contract")
        case Result.Ok(_) => ()
    }
    let approved = application.approveLatestPlan()
    expect(approved.isError(), "unexecuted bounded depth plan remains incomplete")
    childPlanConsumeApplicationFailure(product, application, approved)
    fixture.enqueueToolCallReply("bounded-first", "plugin.axyndra:workflow.task", childPlanBound(first, "bounded-first", "bounded-first"))
    fixture.enqueueToolCallReply("bounded-second", "plugin.axyndra:workflow.task", childPlanBound(second, "bounded-second", "bounded-second"))
    let custody = childPlanStrictDepthFrame204(product, application.id())
    expect(!custody.isDataReturned204(), "actual caller still owns the bounded root request before its complete frame ACK")
    custody.returnApplicationFrame204()
    expect(custody.isDataReturned204(), "bounded original request DATA returns only after actual owned Core and Product frames")
    let database = SqliteDatabase(stateRoot + "/state.db")
    try {
        let execution = database.query("SELECT execution_id FROM plan_execution_sessions WHERE session_id=" +
            sqliteText(application.id().value))[0].required(0)
        let grants = database.query("SELECT session_id,parent_run_id,parent_operation_id,allowed_actions FROM plan_execution_members " +
            "WHERE execution_id=" + sqliteText(execution) + " AND parent_operation_id IS NOT NULL")
        println("child-bounded-grants=" + grants.size.toString())
        expect(grants.size == 2, "both actual delegated members preserve their immutable original grant")
        var unstarted: Int64 = 0
        var started: Int64 = 0
        for (grant in grants) {
            let session = sqliteText(grant.required(0))
            let runs = database.query("SELECT id FROM runs WHERE thread_id=" + session)
            if (runs.isEmpty()) {
                unstarted += 1
                expect(database.scalarInt("SELECT COUNT(*) FROM plan_execution_sessions WHERE session_id=" + session) == 0 &&
                    database.scalarInt("SELECT COUNT(*) FROM plan_execution_runs WHERE session_id=" + session) == 0,
                    "actual depth rejection leaves no canonical Run or active binding after true prelaunch cleanup")
                expect(grant.required(1) != "" && grant.required(2) != "" &&
                    decodeStoredValue(grant.required(3)).items.size == 1,
                    "unstarted cleanup retains its actual immutable parent lineage and exact delegated leaf allowance")
            } else {
                started += 1
                for (run in runs) { childPlanCanonicalDepth204(database, run.required(0), "1") }
            }
        }
        expect(started == 1 && unstarted == 1 && !exists(Path(workspace + "/bounded-depth-unreachable.txt")),
            "second real child is rejected by depth admission before worker creation and cannot execute the leaf")
    } finally { database.close() }
    application.id()
}

// This whole helper returns before its caller acknowledges the real Product
// request frame. The clone changes only maxDepth; no parent custody is used.
func childPlanStrictDepthFrame204(product: ProductRuntime, session: SessionId): PlanRequestCustody204 {
    let base = match (product.prepareRequest("execute only the approved bounded child work", sessionId: Some(session))) {
        case Result.Err(error) => println("child-bounded-prepare-error-code=" + error.code)
            throw IllegalStateException("bounded actual request preparation failed")
        case Result.Ok(value) => value
    }
    let source = base.budget
    let budget = ResourceBudget(maxInputTokens: source.maxInputTokens, maxOutputTokens: source.maxOutputTokens,
        requestOutputBudget: Some(source.requestOutputBudget), maxTotalInputTokens: source.maxTotalInputTokens,
        maxTotalOutputTokens: source.maxTotalOutputTokens, maxModelRequests: source.maxModelRequests, maxTurns: source.maxTurns,
        maxDrainModelRequests: source.maxDrainModelRequests, maxDrainTurns: source.maxDrainTurns,
        maxToolCalls: source.maxToolCalls, maxWallMillis: source.maxWallMillis, maxIdleMillis: source.maxIdleMillis,
        maxChildren: source.maxChildren, maxDepth: 1, maxConcurrentChildren: source.maxConcurrentChildren,
        maxContextMessages: source.maxContextMessages, maxConcurrentTools: source.maxConcurrentTools,
        maxCostMicros: source.maxCostMicros, deadlineMillis: source.deadlineMillis, processLimits: source.processLimits)
    let request = AgentRunRequest(base.runId, base.sessionId, base.model, base.prompt,
        system: base.system, thinking: base.thinking, userRequestedThinking: base.requestedPolicy.userRequestedThinking,
        thinkingSource: base.requestedPolicy.thinkingSource, modelCapabilitiesSnapshot: Some(base.modelCapabilitiesSnapshot),
        resolverVersion: base.resolverVersion, capabilities: base.capabilities, budget: budget, interactions: base.interactions,
        approvalModeOverride: base.approvalModeOverride, callerCancellation180: base.callerCancellation180, autoRetry: base.autoRetry,
        serviceTier: base.serviceTier, pricing: base.pricing, imageInputs: base.imageInputs, structuredOutput: base.structuredOutput,
        cachePolicy: base.cachePolicy, cacheKey: base.cacheKey, parallelToolCalls: base.parallelToolCalls,
        toolContext: base.toolContext, contextSnapshot: base.contextSnapshot, initializeContext: base.initializeContext,
        ownedEvents: base.ownedEvents, contextWindow: base.contextWindow, providerSafetyMargin: base.providerSafetyMargin,
        executionLaneId: base.executionLaneId, queuedInitiator113: base.queuedInitiator113, queuedInputPayment113: base.queuedInputPayment113,
        planContextFacts: base.planContextFacts, planRequestCustody204: base.planRequestCustody204)
    let custody = request.planRequestCustody204.getOrThrow()
    expect(request.planContextFacts.field("approval_hash").isSome(), "bounded actual request retains its approved scope facts")
    let actual = product.client.startOwnedCheckpointFailure113(request, { _ => () })
    match (actual) {
        case OwnedAgentRunResult113.Existing(result) => expect(result.isError(), "bounded depth cannot satisfy its unreachable required leaf")
        case OwnedAgentRunResult113.Held => throw IllegalStateException("bounded actual caller is still held")
        case _ =>
            childPlanConsumeOwnedFailure(actual)
            let refreshed = product.client.takeOwnedCheckpointFailure113(request.runId)
            expect(match (refreshed) { case OwnedAgentRunResult113.Existing(_) => true; case _ => false },
                "bounded actual owned failure queue drains only after complete caller consumption")
    }
    custody
}

// Optional diagnostic only: the original five-level Native experiment hit
// the unchanged 144-MiB aggregate / 16-MiB IPC floors before depth=5. It is not
// a default-depth admission proof and must not fabricate missing grants.
func childPlanNativeDepthQuotaDiagnostic204(product: ProductRuntime, workspace: String, stateRoot: String): Unit {
    let application = product.applicationSession()
    let fixture = product.fixtureProbe.getOrThrow()
    let steps = ArrayList<PlanExecutionStep>()
    let calls = ArrayList<AgentValue>()
    for (index in 1..6) {
        let id = "depth-" + index.toString()
        let delegated = ArrayList<String>()
        for (descendant in (index + 1)..6) { delegated.add("depth-" + descendant.toString()) }
        delegated.add("depth-leaf")
        let call = childPlanTask(id, "Continue only the approved depth-limited delegation " + id)
        calls.add(call)
        steps.add(PlanExecutionStep(PlanStepId(id), [], true,
            [childPlanAction(id, "plugin.axyndra:workflow.task", call, delegated: delegated.toArray())]))
    }
    let unreachable = childPlanWriteProbe(workspace, "depth-unreachable.txt", "unreachable")
    steps.add(PlanExecutionStep(PlanStepId("depth-leaf"), [], true,
        [childPlanAction("depth-leaf", "command_probe", unreachable)]))
    match (application.handle("/plan")) {
        case Result.Ok(_) => ()
        case Result.Err(error) =>
            // Observe only this scalar code inside the actual returned-error
            // frame. Do not retain its complete state or any borrowed graph.
            println("child-depth-plan-error-code=" + error.code)
            throw IllegalStateException("contract failed: depth fixture enters planning; see scalar error code")
    }
    fixture.enqueueToolCallReply("depth-plan", "plugin.axyndra:workflow.plan_write", objectValue([
        ValueField("content", textValue("Respect the installed child depth budget and preserve no-start lineage.")),
        ValueField("contract", planContractValue(PlanContract([workspace], steps.toArray())))]))
    match (application.handle("record the depth-limited plan")) {
        case Result.Ok(_) => ()
        case Result.Err(error) =>
            println("child-depth-record-error-code=" + error.code)
            childPlanConsumeApplicationFailure(product, application, Result<ApplicationResponse>.Err(error))
            throw IllegalStateException("contract failed: depth contract records through Product; see scalar error code")
    }
    let approved = application.approveLatestPlan()
    expect(approved.isError(), "unexecuted depth contract remains incomplete")
    childPlanConsumeApplicationFailure(product, application, approved)
    for (index in 1..6) {
        let id = "depth-" + index.toString()
        fixture.enqueueToolCallReply(id, "plugin.axyndra:workflow.task", childPlanBound(calls[index - 1], id, id))
    }
    let result = application.handle("execute the approved depth-limited delegation")
    expect(result.isError(), "actual depth budget cannot satisfy the unreachable leaf")
    childPlanConsumeApplicationFailure(product, application, result)
    let database = SqliteDatabase(stateRoot + "/state.db")
    try {
        let execution = database.query("SELECT execution_id FROM plan_execution_sessions WHERE session_id=" +
            sqliteText(application.id().value))[0].required(0)
        let grants = database.query("SELECT session_id FROM plan_execution_members WHERE execution_id=" +
            sqliteText(execution) + " AND parent_operation_id IS NOT NULL AND parent_operation_id<>''")
        println("child-depth-grants=" + grants.size.toString())
        for (grant in grants) {
            let selected = sqliteText(grant.required(0))
            println("child-depth-grant runs=" + database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id=" + selected).toString() +
                " active=" + database.scalarInt("SELECT COUNT(*) FROM plan_execution_sessions WHERE session_id=" + selected).toString() +
                " bindings=" + database.scalarInt("SELECT COUNT(*) FROM plan_execution_runs WHERE session_id=" + selected).toString())
        }
        childPlanPrintDiagnostics(product, application.id(), stateRoot, "", workspace)
        expect(grants.size > 0 && grants.size <= 5,
            "Native quota diagnostic reports only actual immutable grants, never five fabricated children")
        var unstarted: Int64 = 0
        for (grant in grants) {
            let session = grant.required(0)
            if (database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id=" + sqliteText(session)) != 0) { continue }
            unstarted += 1
            expect(database.scalarInt("SELECT COUNT(*) FROM plan_execution_sessions WHERE session_id=" + sqliteText(session)) == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM plan_execution_runs WHERE session_id=" + sqliteText(session)) == 0,
                "true prelaunch budget failure revokes only active binding without creating a canonical Run")
        }
        expect(unstarted <= 1 && !exists(Path(workspace + "/depth-unreachable.txt")),
            "Native quota diagnostic cannot execute the unreachable leaf or fabricate an unstarted depth rejection")
    } finally { database.close() }
}

// Every borrowed projection is fully consumed by the helper before the real
// Product consumer frame returns. Only the final Bool leaves its callback.
func childPlanIsSealed(product: ProductRuntime, session: SessionId): Bool {
    let sealed = [false]
    product.withPlanExecutionInspectionForSession204(session, { projection =>
        sealed[0] = projection.field("sealed").getOrThrow().asBool()
        Result<Unit>.Ok(())
    }).value().getOrThrow()
    sealed[0]
}
func childPlanPrintInspection204(projection: AgentValue, temporary: String,
    workspace: String, stateRoot: String): Result<Unit> {
    // Consume only fixed scalar status and counts in the complete borrowed
    // frame. Never serialize the full contract, arguments, fields or receipts.
    println("inspection-scalar complete=" + projection.field("complete").getOrThrow().asBool().toString() +
        " sealed=" + projection.field("sealed").getOrThrow().asBool().toString() +
        " recovery=" + projection.field("recovery_required").getOrThrow().asBool().toString() +
        " steps=" + projection.field("steps").getOrThrow().items.size.toString())
    Result.Ok(())
}
func childPlanPrintDiagnostics(product: ProductRuntime, session: SessionId,
    stateRoot: String, temporary: String, workspace: String): Unit {
    let inspected = product.withPlanExecutionInspectionForSession204(session, { projection =>
        childPlanPrintInspection204(projection, temporary, workspace, stateRoot)
    })
    match (inspected) {
        case Result.Ok(_) => ()
        case Result.Err(error) => println("inspection_error=" + error.code)
    }
    let sessions = ArrayList<SessionId>()
    sessions.add(session)
    var index: Int64 = 0
    while (index < sessions.size && index < 16) {
        for (child in product.allSubagents(sessions[index])) {
            println("child-status=" + child.status + " depth=" + child.depth.toString() +
                " error-bytes=" + child.error.size.toString())
            sessions.add(child.sessionId)
        }
        index += 1
    }
    let database = SqliteDatabase(stateRoot + "/state.db")
    try {
        for (row in database.query("SELECT state,COUNT(*) FROM runs GROUP BY state")) {
            println("canonical-run-state=" + row.required(0) + " count=" + row.required(1))
        }
        for (row in database.query("SELECT o.state,COALESCE(r.outcome,'')," +
            "CASE WHEN a.action_id IS NULL THEN 0 ELSE 1 END,COALESCE(length(CAST(r.detail AS BLOB)),0) FROM operations o " +
            "LEFT JOIN operation_receipts r ON r.operation_id=o.id " +
            "LEFT JOIN plan_action_admissions a ON a.operation_id=o.id ORDER BY o.id")) {
            println("operation-state=" + row.required(0) + " outcome=" + row.required(1) +
                " admitted=" + row.required(2) + " detail-bytes=" + row.required(3))
        }
    } finally { database.close() }
}

func childPlanTask(name: String, task: String): AgentValue {
    objectValue([ValueField("context", textValue("Use the approved contract and inherited capabilities.")),
        ValueField("tasks", listValue([objectValue([ValueField("name", textValue(name)),
            ValueField("agent", textValue("task")), ValueField("task", textValue(task))])]))])
}
func childPlanWriteProbe(workspace: String, path: String, content: String): AgentValue {
    objectValue([ValueField("executable", textValue("/usr/bin/python3")),
        ValueField("argv", listValue([textValue("-c"), textValue(
            "import pathlib,sys;pathlib.Path(sys.argv[1]).write_text(sys.argv[2],encoding='utf-8')"),
            textValue(path), textValue(content)])),
        ValueField("cwd", textValue(workspace)), ValueField("timeout", integerValue(30)),
        ValueField("readonly_workspace", boolValue(false)),
        ValueField("network", objectValue([ValueField("mode", textValue("denied"))]))])
}
func childPlanAction(id: String, tool: String, arguments: AgentValue,
    delegated!: Array<String> = []): PlanAction {
    // Both Native coordination and a ProcessSpawn invocation are classified
    // ExternalMutation by the actual normalizer. The command remains exact,
    // offline, per-call sandboxed and bounded to the approved write roots.
    if (tool != "plugin.axyndra:workflow.task" && tool != "command_probe") {
        throw IllegalArgumentException("child fixture action has no reviewed actual effect classification")
    }
    PlanAction(id, [tool], ["denied"], OperationEffectClass.ExternalMutation,
        arguments, 1, exactArguments: true, delegatedActionIds: delegated)
}
func childPlanBound(arguments: AgentValue, step: String, action: String): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(all: arguments.fields)
    fields.add(ValueField("_plan", objectValue([ValueField("step_id", textValue(step)),
        ValueField("action_id", textValue(action))])))
    objectValue(fields.toArray())
}

func planUnadmittedControlContract(parent: String): Unit {
    let database = SqliteDatabase(parent + "/unadmitted-control.db")
    let bank = LogicalJsonOwnerBudget()
    let original = bank.acquire(4096)
    let allocate = { bytes: Int64 =>
        let value = original.deriveRetainedLease()
        try { value.ensureRetainedPeak(bytes); value }
        catch (error: Exception) { value.close(); throw error }
    }
    try {
        let threadId = ThreadId("plan-control-session")
        let turnId = SemanticTurnId("plan-control-turn")
        let runId = RunId("plan-control-run")
        let sink = SqliteThreadCommitSink(database, knownParentAllocation: Some(allocate))
        let coordinator = ThreadCoordinator(sink.createThread(threadId, "workspace"), sink)
        let active = coordinator.startTurn(turnId, runId, ItemId("plan-control-user"),
            ThreadItemContent.UserMessage(textMessageParts("supervised control")), createdAtMillis: 1).value().getOrThrow()
        let itemId = ItemId("plan-control-call")
        expect(match (coordinator.commit(ResultEnvelope(threadId, turnId, runId, active.activeEpoch, 1,
            ThreadItemDraft(itemId,
                ThreadItemContent.ToolCall(CanonicalToolCallId("control-call"), "read", objectValue([])),
                ItemProvenance("control", runId: Some(runId)), createdAtMillis: 2)))) {
            case SemanticCommitDecision.Committed(_, _) => true
            case _ => false
        }, "trusted control ToolCall commits through the canonical coordinator")
        let plan = NormalizedOperationPlan("read", objectValue([]), [Capability(CapabilityKind.WorkspaceRead)],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Safe, "control-binding", cwd: "/workspace",
            toolVersion: "1", implementationFingerprint: "implementation", schemaDigest: "schema")
        let operationId = OperationId("unadmitted-control")
        let operations = DurableOperationStore(database, documentPayloadAllocation: Some(allocate))
        expect(operations.prepareTrustedControlOperation(operationId, runId, itemId, plan).isOk(),
            "trusted direct control has a canonical prepared Operation")
        let supervisor = DurablePlanExecutionStore(database, knownParentAllocation: Some(allocate))
        let action = PlanAction("read", ["read"], ["denied"], OperationEffectClass.ReadOnly,
            objectValue([]), 1, toolIdentities: objectValue([ValueField("read", objectValue([
                ValueField("version", textValue("1")), ValueField("fingerprint", textValue("implementation")),
                ValueField("schema_digest", textValue("schema"))]))]))
        let contract = PlanContract(["/workspace"], [PlanExecutionStep(PlanStepId("inspect"), [], true, [action])])
        expect(supervisor.activate("control-execution", threadId.value, contract).isOk() &&
            operations.markExecuting(operationId, runId, plan, 3, false).isError(),
            "new direct control Run cannot evade an approved session by omitting plan binding")
        expect(supervisor.bindRun("control-execution", threadId.value, runId).isOk(),
            "direct control Run is bound to its approved supervisor")
        expect(operations.markExecuting(operationId, runId, plan, 3, false).isError(),
            "prepared direct control without approved action admission cannot cross pre-effect boundary")
        expect(supervisor.admit(runId, operationId, "inspect", "read", plan).isOk() &&
            operations.markExecuting(operationId, runId, plan, 3, false).isOk(),
            "matching canonical admission permits the approved pre-effect transition")
        database.execute("UPDATE plan_action_admissions SET binding_digest='different' WHERE operation_id='unadmitted-control'")
        expect(operations.markExecutionHandoff(operationId, runId, threadId, 4).isError() &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0,
            "handoff independently checks the exact approved binding before any executor receives it")
    } finally { database.close(); original.close() }
}

// Select the ordinary installed Native package and its actual child channel.
// No legacy Task alias, synthetic child executor or fabricated owner is added.
func installChildPlanNativePolicy(product: ProductRuntime): Unit {
    let copiedData = ArrayList<LogicalJsonOwnerReservation>()
    try { installChildPlanNativePolicyFrame204(product, copiedData) }
    finally {
        // The complete reader frame has returned: no exported namespace or
        // digest alias can outlive its original same-bank copy payment.
        for (payment in copiedData) { payment.close() }
        copiedData.clear()
    }
}

private func installChildPlanNativePolicyFrame204(product: ProductRuntime,
    copiedData: ArrayList<LogicalJsonOwnerReservation>): Unit {
    let packagePath = getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow()
    let record = match (product.importLocalPlugin(packagePath)) {
        case agent_plugin_registry.PluginRegistryResult.Ok(value) => value
        case agent_plugin_registry.PluginRegistryResult.Err(error) => throw IllegalStateException(
            "child fixture package import: " + childPlanRegistryErrorCode(error))
    }
    let namespace: String
    let digest: String
    try {
        namespace = childPlanRegistryCopy(record.descriptor.copyText(agent_plugin_registry.PluginDescriptorText.Namespace), copiedData)
        digest = childPlanRegistryCopy(record.descriptor.copyText(agent_plugin_registry.PluginDescriptorText.ContentDigest), copiedData)
    } finally { record.close() }
    // Import can activate the package's original default publication. Revoke
    // it before installing the exact operator selection; enabling afterwards
    // must build a fresh descriptor from that selection, not reuse defaults.
    match (product.setPluginEnabled(namespace, false)) {
        case agent_plugin_registry.PluginRegistryResult.Ok(value) => value.close()
        case agent_plugin_registry.PluginRegistryResult.Err(error) => throw IllegalStateException(
            "child fixture package disable before configuration: " + childPlanRegistryErrorCode(error))
    }
    let directory = product.settingsRoot + "/plugins"
    if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
    let policy = objectValue([ValueField("version", integerValue(1)), ValueField("bindings", objectValue([
        ValueField("workflow", objectValue([ValueField("namespace", textValue(namespace)),
            ValueField("provider", textValue("propose")), ValueField("package_digest", textValue(digest)),
            ValueField("plan_tool", textValue("plan_write"))]))]))])
    let primitives = objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([
        objectValue([ValueField("namespace", textValue(namespace)), ValueField("package_digest", textValue(digest)),
            ValueField("tools", listValue([objectValue([ValueField("name", textValue("task")),
                ValueField("profile", textValue("frozen-primitives-v1")),
                ValueField("services", listValue([textValue("child.start"), textValue("child.wait")])),
                ValueField("invocation_capability", textValue("delegate")),
                ValueField("preparation_provider", textValue("prepare_child"))])]))])]))])
    // This fixture owns a fresh settings root; refuse to overwrite a selection.
    for ((file, value) in [("policies.json", policy), ("primitives.json", primitives)]) {
        let path = directory + "/" + file
        if (exists(Path(path))) { throw IllegalStateException("child fixture settings already selected") }
        File.writeTo(Path(path), stringifyUnifiedJson(value).toArray())
    }
    match (product.setPluginEnabled(namespace, true)) {
        case agent_plugin_registry.PluginRegistryResult.Ok(value) => value.close()
        case agent_plugin_registry.PluginRegistryResult.Err(error) => throw IllegalStateException(
            "child fixture package enable after configuration: " + childPlanRegistryErrorCode(error))
    }
}

// Copy only real public descriptor bytes. The setup wrapper roots each
// same-bank payment until its complete consumer frame has actually returned.
func childPlanRegistryCopy(result: agent_plugin_registry.PluginRegistryResult<agent_plugin_registry.OwnedRegistryUtf8>,
    copiedData: ArrayList<LogicalJsonOwnerReservation>): String {
    let source = match (result) {
        case agent_plugin_registry.PluginRegistryResult.Ok(value) => value
        case agent_plugin_registry.PluginRegistryResult.Err(error) => throw IllegalStateException(childPlanRegistryErrorCode(error))
    }
    try {
        let count = source.byteCount
        if (count > (134217728 - 8192) / 64) { throw IllegalStateException("descriptor copy invoice exceeds its actual bank") }
        let payment = source.deriveCopiedDataPayment(count * 64 + 8192)
        copiedData.add(payment)
        String.fromUtf8(Array<UInt8>(count, { index => source.byteAt(index) }))
    } finally { source.close() }
}
func childPlanRegistryErrorCode(error: agent_plugin_registry.PluginRegistryOwnedError): String {
    try { error.code } finally { error.close() }
}
func childPlanConsumeOwnedFailure(value: OwnedAgentRunResult113): Unit {
    match (value) {
        case OwnedAgentRunResult113.Failed(caller) =>
            expect(caller.withError({ error, fund =>
                fund(65536).value().getOrThrow()
                expect(error.code != "" && error.code != "application.owned_failure_pending",
                    "observe the original child fixture failure in its funded frame")
                println("child fixture original failure: " + error.code)
                Result<Unit>.Ok(())
            }).isOk(), "actual failed caller observation succeeds")
            expect(caller.acknowledgeAfterConsumption().isOk(), "acknowledge the consumed actual failure")
        case OwnedAgentRunResult113.Pending(caller) =>
            expect(caller.withError({ error, fund =>
                fund(65536).value().getOrThrow()
                expect(error.code != "" && error.code != "application.owned_failure_pending",
                    "observe the original pending child fixture failure")
            }).isOk(), "actual pending caller observation succeeds")
            expect(caller.acknowledgeAfterConsumption().isOk(), "acknowledge the consumed pending failure")
        case OwnedAgentRunResult113.Existing(_) => ()
        case OwnedAgentRunResult113.Held => throw IllegalStateException("actual child fixture caller is still held")
    }
}
func childPlanConsumeApplicationFailure(product: ProductRuntime, application: ApplicationSession,
    result: Result<ApplicationResponse>): Unit {
    match (result) {
        case Result.Err(marker) => if (application.hasOwnedCheckpointFailure113(marker)) {
            let run = product.latestRunId(ThreadId(application.id().value)).value().getOrThrow()
            let same = [false]
            let identity = application.withOwnedCheckpointRunIdentity113(marker, { actual =>
                same[0] = actual.value == run.value
                Result<Unit>.Ok(())
            })
            expect(identity.isOk() && identity.value().getOrThrow() && same[0],
                "actual child fixture failure retains its exact canonical Run identity")
            let actual = application.takeOwnedCheckpointFailure113(run)
            var consumed = false
            match (actual) {
                case OwnedAgentRunResult113.Existing(_) => ()
                case OwnedAgentRunResult113.Held => throw IllegalStateException("actual child fixture caller is still held")
                case _ => childPlanConsumeOwnedFailure(actual); consumed = true
            }
            application.collectOwnedCheckpointFailure113()
            if (consumed) {
                let refreshed = application.takeOwnedCheckpointFailure113(run)
                expect(match (refreshed) { case OwnedAgentRunResult113.Existing(_) => true; case _ => false },
                    "actual child fixture caller queue drains after the real consumption ACK")
                application.collectOwnedCheckpointFailure113()
            }
            expect(!application.hasOwnedCheckpointFailure113(marker), "actual application failure debt retires after consumption")
        }
        case Result.Ok(_) => ()
    }
}
