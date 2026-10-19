package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.fs.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

func documentServiceValue(read: Bool, epoch: Int64, scenario: String): AgentValue {
    let digest = modelPolicySha256Text("document-fixture")
    let previous = "{\"tasks\":[]}"
    let binding = objectValue([ValueField("namespace", textValue("axyndra:workflow")),
        ValueField("package_digest", textValue("sha256:" + digest)), ValueField("generation", textValue("7")),
        ValueField("configuration_digest", textValue(digest)), ValueField("thread_id", textValue("document-thread")),
        ValueField("lane_id", textValue("main")), ValueField("run_id", textValue("document-run")),
        ValueField("epoch", integerValue(epoch)), ValueField("parent_call_id", textValue("document-call")),
        ValueField("contribution", textValue("plugin.axyndra:workflow.todo")),
        ValueField("implementation_fingerprint", textValue("owned-v1:" + digest)), ValueField("schema_digest", textValue(digest))])
    match (scenario) {
        case "foreign-thread" => binding.put("thread_id", textValue("other-thread"))
        case "foreign-lane" => binding.put("lane_id", textValue("other-lane"))
        case "foreign-run" => binding.put("run_id", textValue("other-run"))
        case "foreign-epoch" => binding.put("epoch", integerValue(epoch + 1))
        case "wrong-parent-call" => binding.put("parent_call_id", textValue("unrelated-call"))
        case _ => ()
    }
    objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_INTENT_SCHEMA)), ValueField("binding", binding),
        ValueField("intent", objectValue([ValueField("id", textValue("document-1")), ValueField("key", textValue("todo")),
            ValueField("mode", textValue(if (read) { "read" } else { "compare_exchange" })),
            ValueField("expected_revision", integerValue(1)), ValueField("expected_json", textValue(previous)),
            ValueField("expected_sha256", textValue(modelPolicySha256Text(previous))),
            ValueField("next_json", if (read) { nullValue() } else { textValue("null") })]))])
}
func documentServicePlan(child: Bool, value: AgentValue): NormalizedOperationPlan {
    let intent = parsePluginDocumentIntent(value).value().getOrThrow()
    let binding = intent.binding()
    let args = if (child) { value } else { objectValue([ValueField("input", objectValue([])),
        ValueField("configuration", objectValue([])), ValueField("host_plan", objectValue([
            ValueField("version", textValue(PLUGIN_DOCUMENT_PARENT_SCHEMA)), ValueField("binding", binding),
            ValueField("intents", listValue([value.field("intent").getOrThrow()]))]))]) }
    NormalizedOperationPlan(if (child) { HOST_PLUGIN_DOCUMENT_TOOL } else { httpIntentText(binding, "contribution") }, args,
        [Capability(CapabilityKind.ExtensionInvoke, resource: "axyndra:workflow")],
        if (intent.compareExchange) { OperationEffectClass.ExternalMutation } else { OperationEffectClass.ReadOnly },
        OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(args)),
        toolVersion: if (child) { HOST_PLUGIN_DOCUMENT_FINGERPRINT } else { "workflow-v1" },
        implementationFingerprint: if (child) { HOST_PLUGIN_DOCUMENT_FINGERPRINT } else { httpIntentText(binding, "implementation_fingerprint") },
        schemaDigest: httpIntentText(binding, "schema_digest"))
}

func pluginDocumentServiceContracts(): Unit {
    for (committed in [false, true]) {
        for (read in [false, true]) {
            for (scenario in ["completed", "receipt-rollback", "missing-parent-handoff", "missing-child-handoff",
                "foreign-thread", "foreign-lane", "foreign-run", "foreign-epoch", "root-bypass",
                "changed-before-admission", "changed-before-execute", "changed-before-handoff", "changed-before-settle",
                "wrong-result", "missing-proof", "changed-generation", "cancelling-complete", "cancelling-unknown", "cancelling-prepared-rejected", "wrong-parent-call", "unguarded-completed", "guard-before-cas", "guard-after-cas", "participant-completed", "participant-rollback", "cancel-at-final-guard", "cancel-after-commit"]) {
                documentServiceScenario(committed, read, scenario)
            }
        }
    }
    println("Plugin document canonical Store contract passed: 108 scenarios")
}

func documentServiceScenario(committed: Bool, read: Bool, scenario: String): Unit {
    let directory = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(directory + "/document-service.sqlite")
    let label = (if (committed) { "Committed " } else { "Direct " }) + (if (read) { "read " } else { "write " }) + scenario
    try {
        let sink = SqliteThreadCommitSink(database)
        let thread = ThreadId("document-thread"); let turn = SemanticTurnId("document-turn"); let run = RunId("document-run")
        let parent = OperationId("document-parent"); let child = OperationId("document-child"); let item = ItemId("document-call")
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        let runtime = AgentThreadRuntime(coordinator, ContextProjector("document", StoreEstimator()), { => 10 })
        let cancellation = CancellationSource()
        let active = httpContractRequire(runtime.startTurn(turn, run, ItemId("document-user"),
            ThreadItemContent.UserMessage(textMessageParts("update my document")), recoveryLane(), InvocationContextProjection(), parentCancellation: Some(cancellation.token)), label + " actual Run")
        let repository = SqlitePluginDocumentRepository(database)
        let empty = httpContractRequire(repository.read(thread, LaneId("main"), "axyndra:workflow", "todo"), label + " initial row")
        let original = httpContractRequire(repository.compareExchange(empty,
            objectValue([ValueField("tasks", listValue([]))]), { _ => Result.Ok(()) }), label + " initial document")
        let intentValue = documentServiceValue(read, active.epoch, scenario)
        let intent = parsePluginDocumentIntent(intentValue).value().getOrThrow()
        let rootPlan = documentServicePlan(false, intentValue)
        let childPlan = documentServicePlan(true, intentValue)
        let call = ToolCall("document-call", rootPlan.toolName, objectValue([]))
        let store = DurableOperationStore(database)
        let source: OperationRootSource
        if (committed) {
            let reference = commitDurableToolCall(database, coordinator, thread, turn, run, active.epoch, 1,
                item, call.callId, call.name, call.arguments, 10)
            source = OperationRootSource.Committed(reference)
            httpContractRequire(store.prepare(parent, run, reference, rootPlan), label + " actual Committed preparation")
        } else {
            expect(isStoreCommitted(runtime.commitResult(ResultEnvelope(thread, turn, run, active.epoch, 1,
                ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
                    ItemProvenance("direct_tool", runId: Some(run), operationId: Some(parent)))))), label + " actual Direct call")
            source = OperationRootSource.Direct(httpContractRequire(runtime.attestDirectToolCall(item, parent, run, active.epoch), label + " actual seal"))
            httpContractRequire(store.prepareTrustedControlOperation(parent, run, item, rootPlan), label + " Direct preparation")
        }
        httpContractRequire(store.markExecuting(parent, run, rootPlan, 11, false), label + " root executing")
        if (scenario != "missing-parent-handoff") { httpContractRequire(store.markExecutionHandoff(parent, run, thread, 12), label + " root handoff") }
        if (scenario == "changed-before-admission") {
            let _ = httpContractRequire(repository.compareExchange(original, textValue("competitor"), { _ => Result.Ok(()) }), label + " competing CAS") }
        if (scenario == "root-bypass") {
            httpContractRequire(store.prepareTrustedControlOperation(child, run, item, childPlan), label + " primitive DTO")
            expect(store.markExecuting(child, run, childPlan, 13, false).isError(), label + " cannot execute primitive document root")
            expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0, label + " no fabricated Receipt")
            return
        }
        let admitted = store.prepareDerivedOperation(child, parent, run, source, exactServiceRequestKey(call.callId, childPlan), childPlan)
        if (scenario.startsWith("foreign-") || scenario == "changed-before-admission" || scenario == "missing-parent-handoff" || scenario == "wrong-parent-call") {
            expect(admitted.isError() && database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 0,
                label + " rejects before child admission")
            return
        }
        httpContractRequire(admitted, label + " admitted exact child")
        if (scenario == "cancelling-prepared-rejected") {
            documentBeginCancellation(runtime, cancellation, run, active.epoch, database, label)
            httpContractRequire(store.settleDerivedOperation(run, parent, VNextOperationReceipt("receipt-document-child", child,
                OperationOutcome.Rejected, objectValue([]), objectValue([]), 13)), label + " close unexecuted obligation")
            expect(repository.read(thread, LaneId("main"), "axyndra:workflow", "todo").value().getOrThrow().encoded == original.encoded &&
                store.markExecuting(child, run, childPlan, 14, false).isError(), label + " rejection writes no document and cannot reexecute")
            return
        }
        var executionPlan = childPlan
        if (scenario == "missing-proof") {
            database.execute("DELETE FROM audit_events WHERE operation_id='document-child' AND kind='operation_parent_intent_authorized'")
        }
        if (scenario == "changed-generation") {
            let changedValue = parseUnifiedJson(stringifyUnifiedJson(intentValue))
            changedValue.field("binding").getOrThrow().put("generation", textValue("8"))
            executionPlan = documentServicePlan(true, changedValue)
            let encoded = documentTamperStoredPlan(database, store, child, run, executionPlan)
            database.execute("UPDATE operations SET normalized_plan=? WHERE id='document-child'", [SqlParameter.Text(encoded)])
            database.execute("UPDATE operation_effect_records SET normalized_plan=? WHERE operation_id='document-child'", [SqlParameter.Text(encoded)])
            let changedRoot = documentTamperStoredPlan(database, store, parent, run, documentServicePlan(false, changedValue))
            database.execute("UPDATE operations SET normalized_plan=? WHERE id='document-parent'", [SqlParameter.Text(changedRoot)])
            database.execute("UPDATE operation_effect_records SET normalized_plan=? WHERE operation_id='document-parent'", [SqlParameter.Text(changedRoot)])
        }
        if (scenario == "changed-before-execute") {
            let _ = httpContractRequire(repository.compareExchange(original, textValue("competitor"), { _ => Result.Ok(()) }), label + " competing CAS") }
        let execution = store.markExecuting(child, run, executionPlan, 13, false)
        if (["missing-proof", "changed-generation", "changed-before-execute"].contains(scenario)) {
            expect(execution.isError() && database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='document-child' AND kind='operation_execution_handoff'") == 0,
                label + " no execution after preparation drift")
            return
        }
        httpContractRequire(execution, label + " child executing")
        if (scenario == "changed-before-handoff") {
            let _ = httpContractRequire(repository.compareExchange(original, textValue("competitor"), { _ => Result.Ok(()) }), label + " competing CAS")
            expect(store.markExecutionHandoff(child, run, thread, 14).isError(), label + " no handoff after drift")
            return
        }
        if (scenario != "missing-child-handoff") { httpContractRequire(store.markExecutionHandoff(child, run, thread, 14), label + " actual child handoff") }
        if (scenario == "changed-before-settle") {
            let _ = httpContractRequire(repository.compareExchange(original, textValue("competitor"), { _ => Result.Ok(()) }), label + " competing CAS") }
        if (scenario.startsWith("cancelling-")) { documentBeginCancellation(runtime, cancellation, run, active.epoch, database, label) }
        if (scenario == "receipt-rollback") {
            database.execute("CREATE TRIGGER document_receipt_fail BEFORE INSERT ON operation_receipts WHEN NEW.operation_id='document-child' BEGIN SELECT RAISE(ABORT,'fixture Receipt insertion failure'); END") }
        let outcome = if (scenario == "cancelling-unknown") { OperationOutcome.Unknown } else { OperationOutcome.Completed }
        let result = if (scenario == "wrong-result" || scenario == "cancelling-unknown") { objectValue([]) } else { intent.result() }
        let receipt = VNextOperationReceipt("receipt-document-child", child, outcome, result, objectValue([]), 15)
        let actualToken = httpContractRequire(runtime.childCancellationToken(expectedRunId: Some(run),
            expectedEpoch: Some(active.epoch)), label + " actual parent token")
        let cancellationBoundary = AtomicBool(false)
        let cancellationObserved = AtomicBool(false)
        let cancellationWorker: ?Future<Unit> = if (scenario == "cancel-at-final-guard" || scenario == "cancel-after-commit") {
            let worker = spawn {
                let deadline = agentUtcMillis() + 3000
                while (!cancellationBoundary.load() && agentUtcMillis() < deadline) { sleep(Duration.millisecond) }
                expect(cancellationBoundary.load(), label + " actual transaction boundary was reached")
                let _ = cancellation.cancel()
                expect(actualToken.isCancelled(), label + " real source cancellation reached the original Run token")
                cancellationObserved.store(true)
            }
            httpContractRequire(runtime.ownTask("document-cancellation-barrier", worker), label + " owned cancellation worker")
            Some(worker)
        } else { None }
        let calls = AtomicInt64(0)
        let participant = DocumentCommitProbe(scenario == "participant-rollback")
        let settle = { =>
            if (outcome != OperationOutcome.Completed || scenario == "unguarded-completed") {
                return store.settleDerivedOperation(run, parent, receipt) }
            if (scenario.startsWith("participant-")) {
                return store.settlePluginDocumentOperation(run, parent, receipt, { => Result.Ok(()) }, participant) }
            store.settlePluginDocumentOperation(run, parent, receipt, { =>
                let ordinal = calls.fetchAdd(1)
                if (scenario == "cancel-at-final-guard" && ordinal > 0) {
                    // The actual document and Receipt INSERT have occurred in
                    // this still-open transaction. Cancel from another task;
                    // the final live guard must roll both writes back.
                    cancellationBoundary.store(true)
                    let deadline = agentUtcMillis() + 3000
                    while (!cancellationObserved.load() && agentUtcMillis() < deadline) { sleep(Duration.millisecond) }
                    expect(cancellationObserved.load(), label + " cancellation arrived before final admission")
                    if (actualToken.isCancelled()) { return Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,
                        "document.fixture_cancelled", "actual caller cancelled before commit")) }
                }
                if (scenario == "guard-before-cas" || (scenario == "guard-after-cas" && ordinal > 0)) {
                    Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied, "document.fixture_guard_revoked", "actual transaction callback revoked"))
                } else { Result<Unit>.Ok(()) }
            })
        }
        let settled = settle()
        if (scenario == "cancel-at-final-guard" || scenario == "cancel-after-commit") {
            if (scenario == "cancel-after-commit") { cancellationBoundary.store(true) }
            cancellationWorker.getOrThrow().get()
            documentBeginCancellation(runtime, cancellation, run, active.epoch, database, label)
            let current = httpContractRequire(repository.read(thread, LaneId("main"), "axyndra:workflow", "todo"), label + " race outcome")
            if (scenario == "cancel-at-final-guard") {
                expect(settled.isError() && settled.error().getOrThrow().code == "document.fixture_cancelled",
                    label + " final guard keeps actual cancellation")
                expect(current.revision == original.revision && current.encoded == original.encoded &&
                    database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0,
                    label + " cancelled transaction rolls back document and completed Receipt together")
                httpContractRequire(store.settleDerivedOperation(run, parent, VNextOperationReceipt("receipt-document-child", child,
                    OperationOutcome.Unknown, objectValue([]), objectValue([]), 16)), label + " close the existing handed obligation as Unknown")
                expect(store.loadDerivedOperationReceipt(child, run).value().getOrThrow().getOrThrow().outcome == OperationOutcome.Unknown,
                    label + " cancellation cannot turn the handed child into a known failure")
            } else {
                httpContractRequire(settled, label + " committed before later cancellation")
                expect(current.revision == (if (read) { 1 } else { 2 }) &&
                    store.loadDerivedOperationReceipt(child, run).value().getOrThrow().getOrThrow().outcome == OperationOutcome.Completed,
                    label + " later cancellation cannot erase the completed transaction")
                expect(settle().isError(), label + " cancellation cannot replay the earlier mutation")
            }
            expect(store.markExecuting(child, run, childPlan, 17, false).isError(), label + " neither race outcome can execute again")
            return
        }
        if (scenario.startsWith("participant-")) {
            if (read || scenario == "participant-rollback") {
                expect(settled.isError() && database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0,
                    label + " participant failure or read-only child cannot commit a user control")
                expect(repository.read(thread, LaneId("main"), "axyndra:workflow", "todo").value().getOrThrow().revision == original.revision,
                    label + " participant rejection rolls document revision back")
                expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='document_fixture_control'") == 0,
                    label + " participant audit rolls back with CAS and Receipt")
            } else {
                httpContractRequire(settled, label + " supplied-transaction participant")
                expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='document_fixture_control'") == 1 &&
                    database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 1,
                    label + " actual control audit and canonical Receipt commit atomically")
                expect(repository.read(thread, LaneId("main"), "axyndra:workflow", "todo").value().getOrThrow().revision == 2,
                    label + " same transaction actual CAS")
            }
            expect(participant.calls.load() == (if (read) { 0 } else { 1 }), label + " read-only child cannot call the control consumer")
            if (!read) {
                expect(participant.retained.getOrThrow().withTransaction({ _ => Result.Ok(()) }).isError(),
                    label + " retained transaction proof cannot be reused after the finite callback") }
            return
        }
        if (["missing-child-handoff", "changed-before-settle", "wrong-result", "receipt-rollback", "cancelling-complete", "unguarded-completed", "guard-before-cas", "guard-after-cas"].contains(scenario)) {
            expect(settled.isError() && database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0, label + " no contradictory Receipt")
            let actual = httpContractRequire(repository.read(thread, LaneId("main"), "axyndra:workflow", "todo"), label + " retained row")
            expect(actual.encoded == (if (scenario == "changed-before-settle") { "\"competitor\"" } else { original.encoded }),
                label + " no service mutation survived failed settlement")
            if (scenario == "guard-before-cas" || scenario == "guard-after-cas" || scenario == "unguarded-completed") {
                expect(actual.revision == original.revision, label + " missing/revoked live guard rolls back exact document revision")
                expect(calls.load() == (if (scenario == "guard-before-cas") { 1 } else if (scenario == "guard-after-cas") { 2 } else { 0 }),
                    label + " real transaction guard executes at the intended pre/post mutation boundary")
                if (scenario != "unguarded-completed") { expect(settled.error().getOrThrow().code == "document.fixture_guard_revoked", label + " typed guard failure retained") }
            }
            if (scenario == "receipt-rollback") {
                expect(actual.revision == original.revision, label + " same Tx rolls back CAS revision")
                database.execute("DROP TRIGGER document_receipt_fail")
                httpContractRequire(settle(), label + " retry atomic settlement only; no new execution")
            }
            if (scenario == "changed-before-settle") {
                httpContractRequire(store.settleDerivedOperation(run, parent, VNextOperationReceipt("receipt-document-child", child,
                    OperationOutcome.Unknown, objectValue([]), objectValue([]), 16)), label + " close old uncertainty after competing CAS")
                expect(repository.read(thread, LaneId("main"), "axyndra:workflow", "todo").value().getOrThrow().encoded == "\"competitor\"",
                    label + " Unknown does not erase competing committed document")
            }
            return
        }
        httpContractRequire(settled, label + " actual Receipt settlement")
        let actual = httpContractRequire(repository.read(thread, LaneId("main"), "axyndra:workflow", "todo"), label + " result row")
        let written = !read && scenario == "completed"
        expect(actual.revision == (if (written) { 2 } else { 1 }) && actual.encoded == (if (written) { "null" } else { original.encoded }),
            label + " only completed CAS advances document; read and cancellation leave bytes unchanged")
        expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 1 &&
            store.loadDerivedOperationReceipt(child, run).value().getOrThrow().getOrThrow().outcome == outcome,
            label + " one canonical Receipt")
        expect(settle().isError(), label + " no second canonical settlement or double mutation")
        expect(store.markExecuting(child, run, childPlan, 16, false).isError(), label + " terminal never reexecutes")
        expect(database.query("PRAGMA foreign_key_check").isEmpty(), label + " real SQL references")
    } finally { database.close(); remove(directory, recursive: true) }
}

// Signal the real parent and persist its owned transition, retaining the active
// Turn until canonical obligations finish. A SQL state rewrite is not cancellation.
func documentBeginCancellation(runtime: AgentThreadRuntime, cancellation: CancellationSource,
    run: RunId, epoch: Int64, database: SqliteDatabase, label: String): Unit {
    let token = httpContractRequire(runtime.childCancellationToken(), label + " actual cancellation token")
    let _ = cancellation.cancel()
    expect(token.isCancelled(), label + " live owner cancellation observed")
    httpContractRequire(runtime.beginCancellationSettlement(run, epoch), label + " real cancellation transition")
    expect(database.scalarInt("SELECT COUNT(*) FROM runs r JOIN turns t ON t.id=r.turn_id JOIN threads th ON th.id=t.thread_id WHERE r.id='document-run' AND r.state='cancelling' AND t.state='active' AND t.thread_id=r.thread_id AND t.active_run_id=r.id AND th.active_turn_id=t.id") == 1,
        label + " cancellation keeps the original Turn and Run enclosure for late settlement")
}

// This is a trusted fixture participant, not an IPC field or a plugin-built
// proof. The actual Store mints it only after its same-Tx Receipt exists.
class DocumentCommitProbe <: PluginDocumentCommitParticipant {
    let fail: Bool
    let calls = AtomicInt64(0)
    var retained: ?SqlitePluginDocumentCommitProof = None
    init(fail: Bool) { this.fail = fail }
    public func consume(proof: PluginDocumentCommitProof): Result<Unit> {
        let selected = match (proof as SqlitePluginDocumentCommitProof) {
            case Some(value) => value
            case None => return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "document.proof_foreign", "foreign proof")) }
        retained = Some(selected); let _ = calls.fetchAdd(1)
        expect(proof.runId.value == "document-run" && proof.parentOperationId.value == "document-parent" &&
            proof.operationId.value == "document-child", "participant sees original canonical identities")
        let plan = proof.plan(); plan.canonicalArguments.put("forged", boolValue(true))
        expect(proof.plan().canonicalArguments.field("forged").isNone(), "proof plan getter is defensive")
        let receipt = proof.receipt(); receipt.detail.put("forged", boolValue(true))
        expect(proof.receipt().detail.field("forged").isNone(), "proof Receipt getter is defensive")
        return selected.withTransaction({ transaction =>
            expect(transaction.query("SELECT id FROM operation_receipts WHERE operation_id='document-child' AND outcome='completed'").size == 1,
                "participant runs after real Receipt insertion")
            transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                "VALUES('document-thread','document-run','document-child','document_fixture_control','fixture',15)")
            if (fail) { Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied, "document.participant_failed", "fixture rollback")) }
            else { Result<Unit>.Ok(()) }
        })
    }
}
