package agent_store_contract

import std.fs.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

func hostOriginValue(request!: String = "host-request-1"): HostServiceOrigin {
    HostServiceOrigin("service.tools", "axyndra:contract",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "host-instance-1", HostServiceAction.Start, request)
}

class HostOriginFixture {
    let root: String
    let database: SqliteDatabase
    let sink: SqliteThreadCommitSink
    let coordinator: ThreadCoordinator
    let runtime: AgentThreadRuntime
    let admission: HostServiceRunAdmission
    let store: DurableOperationStore
    let thread = ThreadId("host-service-thread")
    let turn = SemanticTurnId("host-service-turn")
    let run = RunId("host-service-run")
    let item = ItemId("host-service-call-item")
    let operation = OperationId("host-service-operation")
    let call: ToolCall
    let plan: NormalizedOperationPlan

    init() {
        root = Directory.createTemp("/tmp").toString()
        database = SqliteDatabase(root + "/host-origin.db")
        sink = SqliteThreadCommitSink(database)
        coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        runtime = AgentThreadRuntime(coordinator, ContextProjector("host-origin", StoreEstimator()), { => 10 })
        admission = runtime.startHostServiceTurn(turn, run, ItemId("host-service-initiator"),
            hostOriginValue(), recoveryLane(), InvocationContextProjection()).value().getOrThrow()
        store = DurableOperationStore(database)
        // Reserved-looking values are plugin input. They cannot replace the
        // origin supplied separately by the actual live host owner.
        call = ToolCall("host-service-call", "plugin.host.service", objectValue([
            ValueField("source", textValue("external")), ValueField("principal", textValue("administrator")),
            ValueField("run_id", textValue("different-run")),
            ValueField("origin", directCallOriginValue(DirectCallOrigin.HostService(hostOriginValue(request: "forged"))))
        ]))
        plan = NormalizedOperationPlan(call.name, call.arguments,
            [Capability(CapabilityKind.ExtensionInvoke), Capability(CapabilityKind.WorkspaceRead)],
            OperationEffectClass.WorkspaceMutation, OperationRetryDisposition.Never, "host-origin-root")
    }

    func commit(): DirectToolCallRef {
        runtime.commitHostServiceToolCall(admission, item, operation, call, run, admission.run.epoch)
            .value().getOrThrow()
    }

    func prepare(): Unit {
        store.prepareTrustedControlOperation(operation, run, item, plan).value().getOrThrow()
    }

    func close(): Unit { database.close(); remove(root, recursive: true) }
}

func hostServiceOriginContract(): Unit {
    hostServiceOriginCodecContract()
    hostServiceOriginOwnedEntryContract()
    hostServiceOriginGrantAndReceiptContract()
    hostServiceOriginRecoveryContract()
    for (scenario in ["call", "initiator", "both", "downgrade", "epoch", "payload", "missing-proof", "handoff"]) {
        hostServiceOriginDurableFenceContract(scenario)
    }
    println("Host service canonical origin contract passed: codec, sealed entry, approval, receipt, recovery, 8 durable fences")
}

func hostServiceOriginCodecContract(): Unit {
    let source = ItemProvenance("direct_tool", runId: Some(RunId("run")),
        operationId: Some(OperationId("operation")))
    let legacy = encodeStoredProvenance(source)
    expect(!decodeStoredValue(legacy).field("direct_origin").isSome() &&
        sameDirectCallOrigin(effectiveDirectCallOrigin(decodeStoredProvenance(legacy)), DirectCallOrigin.UserDirect),
        "legacy direct_tool retains exactly its old encoding and means only UserDirect")
    let origin = DirectCallOrigin.HostService(hostOriginValue())
    expect(sameDirectCallOrigin(directCallOriginFromValue(directCallOriginValue(origin)), origin),
        "host origin strictly round trips all immutable identity fields")
    let good = stringifyUnifiedJson(directCallOriginValue(origin))
    for (malformed in ["null", "{}", good.replace("axyndra.direct-origin/v1", "axyndra.direct-origin/v2"),
        good.replace("host_service", "external_principal"), good.replace("\"start\"", "\"execute\""),
        good.replace("\"host-request-1\"", "null"),
        good.replace("\"host-request-1\"", "\"host-request-1\",\"principal\":\"root\""),
        good.replace("sha256:", "SHA256:")]) {
        let rejected = try { let _ = directCallOriginFromValue(parseUnifiedJson(malformed)); false }
            catch (_: Exception) { true }
        expect(rejected, "malformed, extended, external and unsupported-version origins are rejected")
    }
    let explicitNull = encodeStoredValue(objectValue([
        ValueField("source", textValue("direct_tool")), ValueField("run_id", textValue("run")),
        ValueField("operation_id", textValue("operation")), ValueField("direct_origin", nullValue())]))
    expect(try { let _ = decodeStoredProvenance(explicitNull); false } catch (_: Exception) { true },
        "an explicit null origin cannot silently become legacy UserDirect")
}

func hostServiceOriginOwnedEntryContract(): Unit {
    let fixture = HostOriginFixture()
    let other = HostOriginFixture()
    try {
        let active = fixture.admission.run
        let initial = fixture.coordinator.snapshot().items[0]
        expect(isHostServiceInitiator(initial) && initial.kind == ItemKind.SystemNote &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'") == 0 &&
            fixture.database.query("SELECT kind FROM lane_inbox_entries")[0].required(0) == "host_service" &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0,
            "real maintenance Run begins from SystemNote and the existing transactional inbox/Step with no fake user or Decision")
        expect(fixture.runtime.projectContext().isError(), "maintenance Run cannot project a model request")
        let provenance = ItemProvenance("direct_tool", runId: Some(fixture.run),
            operationId: Some(fixture.operation), directOrigin: Some(DirectCallOrigin.HostService(hostOriginValue())))
        let forged = ThreadItemDraft(fixture.item, ThreadItemContent.ToolCall(
            CanonicalToolCallId(fixture.call.callId), fixture.call.name, fixture.call.arguments), provenance)
        expect(match (fixture.runtime.commitResult(ResultEnvelope(fixture.thread, fixture.turn,
            fixture.run, active.epoch, 1, forged))) {
            case SemanticCommitDecision.Rejected(_) => true
            case _ => false
        }, "raw worker envelope cannot claim a complete host-origin value")
        expect(match (fixture.runtime.commitBatch(ResultBatchEnvelope(fixture.thread, fixture.turn,
            fixture.run, active.epoch, 1, [forged]))) {
            case SemanticBatchCommitDecision.Rejected(_) => true
            case _ => false
        }, "model/worker batch cannot claim host-origin authority")
        expect(fixture.runtime.commitHostServiceToolCall(other.admission, fixture.item,
            fixture.operation, fixture.call, fixture.run, active.epoch).isError(),
            "same textual Thread/Run/origin from another runtime does not possess this owner's seal")
        expect(fixture.runtime.commitHostServiceToolCall(fixture.admission, fixture.item,
            fixture.operation, fixture.call, RunId("wrong-run"), active.epoch).isError() &&
            fixture.runtime.commitHostServiceToolCall(fixture.admission, fixture.item,
                fixture.operation, fixture.call, fixture.run, active.epoch + 1).isError(),
            "sealed service entry checks actual Run and epoch before committing")
        expect(fixture.coordinator.snapshot().items.size == 1,
            "all rejected entry attempts leave no canonical ToolCall")
        let source = fixture.commit()
        expect(source.canonicalItemId.value == fixture.item.value &&
            sameDirectCallOrigin(source.origin, DirectCallOrigin.HostService(fixture.admission.origin)) &&
            canonicalAgentValue(source.call.arguments) == canonicalAgentValue(fixture.call.arguments),
            "sealed source records actual host origin while preserving untrusted input as input")
        let canonical = fixture.coordinator.snapshot().items[1]
        expect(sameDirectCallOrigin(effectiveDirectCallOrigin(canonical.provenance), source.origin),
            "canonical Item and live Direct reference carry exactly the same origin")
    } finally { other.close(); fixture.close() }
}

func hostServiceOriginGrantAndReceiptContract(): Unit {
    let fixture = HostOriginFixture()
    try {
        let source = fixture.commit()
        fixture.prepare()
        fixture.prepare()
        expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_host_origin_bound'") == 1,
            "idempotent preparation retains one immutable host-origin binding")
        expect(fixture.store.markExecuting(fixture.operation, fixture.run, fixture.plan, 11, true).isError() &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0,
            "legitimate host origin alone grants no exact approval and causes no effect handoff")
        fixture.store.waitForApproval(fixture.operation, fixture.run).value().getOrThrow()
        expect(fixture.store.recordApproval("service-insufficient", fixture.operation, fixture.run, fixture.plan,
            CapabilitySet(values: []), true, "operator", None).isError(),
            "host-service origin cannot expand an empty operator capability ceiling")
        fixture.store.recordApproval("service-approved", fixture.operation, fixture.run, fixture.plan,
            CapabilitySet(values: fixture.plan.requiredCapabilities), true, "operator", None).value().getOrThrow()
        fixture.store.markExecuting(fixture.operation, fixture.run, fixture.plan, 12, true).value().getOrThrow()
        fixture.store.markExecutionHandoff(fixture.operation, fixture.run, fixture.thread, 13).value().getOrThrow()
        let escalated = NormalizedOperationPlan("host.process.readonly", objectValue([]),
            [Capability(CapabilityKind.WorkspaceWrite)], OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Safe, "host-origin-escalated-child")
        expect(fixture.store.prepareDerivedOperation(OperationId("host-origin-escalation"), fixture.operation,
            fixture.run, OperationRootSource.Direct(source), "javascript-service:" + fixture.call.callId + ":escalate",
            escalated).isError(), "service origin does not widen its parent's child capability/effect boundary")
        let childPlan = NormalizedOperationPlan("host.process.readonly", objectValue([]),
            [Capability(CapabilityKind.WorkspaceRead)], OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Safe, "host-origin-child")
        let child = fixture.store.prepareDerivedOperation(OperationId("host-origin-child"), fixture.operation,
            fixture.run, OperationRootSource.Direct(source), "javascript-service:" + fixture.call.callId + ":read",
            childPlan).value().getOrThrow()
        fixture.store.markExecuting(child, fixture.run, childPlan, 14, false).value().getOrThrow()
        fixture.store.markExecutionHandoff(child, fixture.run, fixture.thread, 15).value().getOrThrow()
        expect(fixture.store.prepareDerivedOperation(OperationId("host-origin-grandchild"), child,
            fixture.run, OperationRootSource.Direct(source), "javascript-service:" + fixture.call.callId + ":grandchild",
            childPlan).isError(), "a service child cannot become a second-level parent or borrow its root's source")
        fixture.store.settleDerivedOperation(fixture.run, fixture.operation, VNextOperationReceipt(
            "receipt-" + child.value, child, OperationOutcome.Completed, objectValue([]), objectValue([]), 16))
            .value().getOrThrow()
        let execution = Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(
            ToolResult(fixture.call.callId, objectValue([ValueField("ok", boolValue(true))]))))
        let result = fixture.runtime.resolveOperation(ItemId("host-origin-result"), fixture.operation,
            CanonicalToolCallId(fixture.call.callId), fixture.plan, OperationAttemptStage.Executing,
            execution, "host-origin-receipt", 17,
            expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.admission.run.epoch)).value().getOrThrow()
        expect(result.semanticCommit.isSome() && isStoreCommitted(result.semanticCommit.getOrThrow()),
            "host service settles through the same canonical ToolResult plus Receipt transaction")
        let _ = fixture.runtime.resolveOperation(ItemId("host-origin-duplicate"), fixture.operation,
            CanonicalToolCallId(fixture.call.callId), fixture.plan, OperationAttemptStage.Executing,
            execution, "host-origin-receipt", 18,
            expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.admission.run.epoch))
        expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='host-service-operation'") == 1 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'") == 1 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM decision_operations") == 0,
            "retrying host settlement cannot create another Receipt, ToolResult or model operation")
        expect(fixture.runtime.finish(RunState.Completed, 1000).isOk(),
            "maintenance Run completes only after its root and derived child have durable terminal receipts")
        expect(fixture.database.query("PRAGMA foreign_key_check").isEmpty(), "host-origin transaction preserves relational integrity")
    } finally { fixture.close() }
}

func hostServiceOriginRecoveryContract(): Unit {
    let fixture = HostOriginFixture()
    try {
        let _ = fixture.commit()
        fixture.prepare()
        let snapshot = fixture.sink.loadThread(fixture.thread)
        let active = fixture.runtime.activeRun().getOrThrow()
        let recovered = AgentThreadRuntime(ThreadCoordinator(snapshot, fixture.sink),
            ContextProjector("host-origin", StoreEstimator()), RecoveredRunSpec(fixture.turn, fixture.run,
                active.epoch, RunState.Running, active.transitionSequence, recoveryLane(), InvocationContextProjection()), { => 20 })
        expect(sameDirectCallOrigin(effectiveDirectCallOrigin(snapshot.items[1].provenance),
            DirectCallOrigin.HostService(hostOriginValue())), "recovery retains readable typed host-origin history")
        expect(recovered.commitHostServiceToolCall(fixture.admission, ItemId("recovered-call"),
            OperationId("recovered-operation"), fixture.call, fixture.run, active.epoch).isError() &&
            recovered.attestDirectToolCall(fixture.item, fixture.operation, fixture.run, active.epoch).isError() &&
            recovered.projectContext().isError(),
            "recovery preserves origin data but cannot mint service authority, revive Direct execution or invoke the model")
        expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items") == 2 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0 &&
            fixture.database.query("SELECT state FROM operations")[0].required(0) == "prepared",
            "rejected recovery paths leave original operation state and historical facts untouched")
        fixture.database.execute("UPDATE items SET provenance=? WHERE id='host-service-initiator'", [
            SqlParameter.Text(encodeStoredProvenance(ItemProvenance("host_service", runId: Some(RunId("different-run")),
                directOrigin: Some(DirectCallOrigin.HostService(hostOriginValue())))))])
        let wrongRunRejected = try {
            let _ = AgentThreadRuntime(ThreadCoordinator(fixture.sink.loadThread(fixture.thread), fixture.sink),
                ContextProjector("host-origin", StoreEstimator()), RecoveredRunSpec(fixture.turn, fixture.run,
                    active.epoch, RunState.Running, active.transitionSequence, recoveryLane(), InvocationContextProjection()), { => 20 })
            false
        } catch (_: Exception) { true }
        expect(wrongRunRejected, "recovery cannot reinterpret a mismatched service initiator as an ordinary user Run")
    } finally { fixture.close() }
}

func hostServiceOriginDurableFenceContract(scenario: String): Unit {
    let fixture = HostOriginFixture()
    try {
        let source = fixture.commit()
        fixture.prepare()
        if (scenario == "handoff") {
            fixture.store.markExecuting(fixture.operation, fixture.run, fixture.plan, 11, false).value().getOrThrow()
        }
        let changed = DirectCallOrigin.HostService(hostOriginValue(request: "changed-host-request"))
        if (scenario == "call" || scenario == "both" || scenario == "handoff" || scenario == "downgrade") {
            let origin: ?DirectCallOrigin = if (scenario == "downgrade") { None } else { Some(changed) }
            fixture.database.execute("UPDATE items SET provenance=? WHERE id='host-service-call-item'", [
                SqlParameter.Text(encodeStoredProvenance(ItemProvenance("direct_tool", runId: Some(fixture.run),
                    operationId: Some(fixture.operation), directOrigin: origin)))])
        }
        if (scenario == "initiator" || scenario == "both" || scenario == "downgrade") {
            let sourceName = if (scenario == "downgrade") { "user" } else { "host_service" }
            let origin: ?DirectCallOrigin = if (scenario == "downgrade") { None } else { Some(changed) }
            fixture.database.execute("UPDATE items SET provenance=? WHERE id='host-service-initiator'", [
                SqlParameter.Text(encodeStoredProvenance(ItemProvenance(sourceName,
                    runId: Some(fixture.run), directOrigin: origin)))])
        }
        if (scenario == "epoch") { fixture.database.execute("UPDATE runs SET epoch=epoch+1") }
        if (scenario == "payload") { fixture.database.execute("UPDATE items SET payload=? WHERE id='host-service-call-item'",
            [SqlParameter.Text(encodeStoredThreadContent(ThreadItemContent.ToolCall(CanonicalToolCallId(fixture.call.callId),
                fixture.call.name, objectValue([ValueField("changed", boolValue(true))]))))]) }
        if (scenario == "missing-proof") {
            fixture.database.execute("DELETE FROM audit_events WHERE kind='operation_host_origin_bound'")
        }
        let rejected = if (scenario == "handoff") {
            fixture.store.markExecutionHandoff(fixture.operation, fixture.run, fixture.thread, 12).isError()
        } else { fixture.store.markExecuting(fixture.operation, fixture.run, fixture.plan, 12, false).isError() }
        expect(rejected && fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0,
            scenario + " cannot alter or remove frozen source evidence before execution/handoff")
        let childPlan = NormalizedOperationPlan("host.process.readonly", objectValue([]),
            [Capability(CapabilityKind.WorkspaceRead)], OperationEffectClass.ReadOnly, OperationRetryDisposition.Safe, "child")
        expect(fixture.store.prepareDerivedOperation(OperationId("changed-origin-child"), fixture.operation,
            fixture.run, OperationRootSource.Direct(source), "javascript-service:" + fixture.call.callId + ":changed",
            childPlan).isError(), scenario + " cannot use a stale sealed reference to open a child operation")
    } finally { fixture.close() }
}
