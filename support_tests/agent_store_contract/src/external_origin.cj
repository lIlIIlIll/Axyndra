package agent_store_contract

import std.fs.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

// Explicit trusted test authorizer, not a network authentication substitute.
class ExternalContractAuthorizer <: ExternalIngressAuthorizer {
    let initial: ExternalIngressBinding
    var allowed = true
    var changed: ?ExternalIngressBinding = None
    init(binding: ExternalIngressBinding) { initial = binding }
    public func currentBinding(): Result<ExternalIngressBinding> {
        if (!allowed) { return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "fixture.denied", "denied")) }
        Result.Ok(match (changed) { case Some(value) => value; case None => initial })
    }
}
class ExternalContractClock { var now = agentUtcMillis() }

class ExternalOriginFixture {
    let root: String
    let database: SqliteDatabase
    let sink: SqliteThreadCommitSink
    let coordinator: ThreadCoordinator
    let runtime: AgentThreadRuntime
    let store: DurableOperationStore
    let clock = ExternalContractClock()
    let authorizer: ExternalContractAuthorizer
    let connection: ExternalIngressConnection
    let frame: ?ExternalReceivedFrame
    let decoder: ?ExternalDecoderIdentity
    let admission: ExternalCallAdmission
    let thread = ThreadId("external-thread")
    let turn = SemanticTurnId("external-turn")
    let run = RunId("external-run")
    let item = ItemId("external-call-item")
    let operation = OperationId("external-operation")
    let call = ToolCall("external-call", "external_test", objectValue([
        ValueField("principal", textValue("untrusted-admin")), ValueField("source", textValue("host_service"))]))
    let plan: NormalizedOperationPlan
    init(withFrame!: Bool = false) {
        decoder = if (withFrame) { Some(ExternalDecoderIdentity("fixture.decoder", "sha256:" + modelPolicySha256Text("code"),
            modelPolicySha256Text("operator-file"), "instance-one", "decoder")) } else { None }
        root = Directory.createTemp("/tmp").toString()
        database = SqliteDatabase(root + "/external.db"); sink = SqliteThreadCommitSink(database)
        coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        runtime = AgentThreadRuntime(coordinator, ContextProjector("external", StoreEstimator()), { => agentUtcMillis() })
        store = DurableOperationStore(database)
        plan = NormalizedOperationPlan(call.name, call.arguments, [Capability(CapabilityKind.WorkspaceWrite)],
            OperationEffectClass.WorkspaceMutation, OperationRetryDisposition.Never, "external-plan",
            toolVersion: "1", implementationFingerprint: "external-fixture-v1", schemaDigest: "external-schema-v1")
        let localClock = clock
        authorizer = ExternalContractAuthorizer(ExternalIngressBinding("external-grant", "external-connection",
            "authenticated-reader", 1, thread, modelPolicySha256Text("contract-domain"),
            [ExternalExportBinding(call.name, "1", "external-fixture-v1", "external-schema-v1")],
            [Capability(CapabilityKind.WorkspaceWrite)], localClock.now + 600000, [], decoder: decoder))
        connection = openExternalIngressConnection(authorizer, { => localClock.now }).value().getOrThrow()
        frame = if (withFrame) { Some(connection.captureFrame("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"external_test\"}}").value().getOrThrow()) } else { None }
        admission = runtime.startExternalTurn(connection, ExternalRequestId(ExternalRequestIdKind.Number, value: "1"),
            call, turn, run, ItemId("external-initiator"), recoveryLane(), InvocationContextProjection(), receivedFrame: frame).value().getOrThrow()
    }
    func binding(principal!: String = "authenticated-reader", expiry!: ?Int64 = None): ExternalIngressBinding {
        ExternalIngressBinding("external-grant", "external-connection", principal, 1, thread,
            modelPolicySha256Text("contract-domain"), [ExternalExportBinding(call.name, "1", "external-fixture-v1", "external-schema-v1")],
            [Capability(CapabilityKind.WorkspaceWrite)], match (expiry) { case Some(value) => value; case None => clock.now + 600000 }, [], decoder: decoder)
    }
    func commit(): DirectToolCallRef { runtime.commitExternalToolCall(admission, item, operation, call, run,
        admission.run.epoch).value().getOrThrow() }
    func prepare(source: DirectToolCallRef): Unit { store.prepareDirectOperation(source, plan).value().getOrThrow() }
    func close(): Unit { connection.revoke(); database.close(); remove(root, recursive: true) }
}

func externalOriginContract(): Unit {
    externalReceivedFrameContract()
    externalOriginCodecAndAdmissionContract()
    externalOriginApprovalReceiptContract()
    externalOriginRecoveryContract()
    for (stage in ["before-commit", "prepare", "execute", "handoff", "after-handoff", "expiry", "binding-change"]) {
        externalOriginRevocationContract(stage)
    }
    for (change in ["principal", "connection", "request-kind", "epoch", "thread", "payload", "audit", "downgrade"]) {
        externalOriginTamperContract(change)
    }
    println("External origin contract passed: typed codec/seal, approval/receipt, read-only recovery, 7 revocation fences, 8 durable fences")
}

func externalOriginCodecAndAdmissionContract(): Unit {
    let fixture = ExternalOriginFixture()
    let foreignOwner = ExternalOriginFixture()
    try {
        let origin = DirectCallOrigin.External(fixture.admission.origin)
        expect(sameDirectCallOrigin(directCallOriginFromValue(directCallOriginValue(origin)), origin), "External v2 origin strictly round trips")
        expect(ExternalRequestId(ExternalRequestIdKind.Number, value: "1e2").key() ==
            ExternalRequestId(ExternalRequestIdKind.Number, value: "100.00").key() &&
            ExternalRequestId(ExternalRequestIdKind.Number, value: "-0").key() == ExternalRequestId(ExternalRequestIdKind.Number, value: "0.0").key() &&
            ExternalRequestId(ExternalRequestIdKind.Text, value: "1").key() != ExternalRequestId(ExternalRequestIdKind.Number, value: "1").key(),
            "typed IDs preserve text/number/null and exact numeric equivalence without float rounding")
        let encoded = stringifyUnifiedJson(directCallOriginValue(origin))
        for (bad in [encoded.replace("axyndra.direct-origin/v2", "axyndra.direct-origin/v1"),
            encoded.replace("\"external\"", "\"user_direct\""),
            encoded.replace("authenticated-reader", "bad principal"), encoded.replace("\"generation\":1", "\"generation\":0")]) {
            expect(try { let _ = directCallOriginFromValue(parseUnifiedJson(bad)); false } catch (_: Exception) { true },
                "malformed/downgraded External origin cannot silently become UserDirect")
        }
        expect(isExternalInitiator(fixture.coordinator.snapshot().items[0]) &&
            fixture.database.query("SELECT kind FROM lane_inbox_entries")[0].required(0) == "external" &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'") == 0,
            "actual External turn uses SystemNote plus the same durable inbox, without fake model/user source")
        expect(fixture.runtime.projectContext().isError(), "External turn is not a model lane")
        expect(fixture.runtime.commitExternalToolCall(foreignOwner.admission, fixture.item, fixture.operation,
            fixture.call, fixture.run, fixture.admission.run.epoch).isError(), "equal textual bindings do not transfer another owner seal")
        expect(fixture.runtime.commitExternalToolCall(fixture.admission, fixture.item, fixture.operation,
            fixture.call, fixture.run, fixture.admission.run.epoch + 1).isError() &&
            fixture.runtime.commitExternalToolCall(fixture.admission, fixture.item, fixture.operation,
                ToolCall(fixture.call.callId, fixture.call.name, objectValue([])), fixture.run, fixture.admission.run.epoch).isError(),
            "request bytes and actual epoch remain bound before canonical commit")
        let forged = ThreadItemDraft(fixture.item, ThreadItemContent.ToolCall(CanonicalToolCallId(fixture.call.callId),
            fixture.call.name, fixture.call.arguments), ItemProvenance("direct_tool", runId: Some(fixture.run),
                operationId: Some(fixture.operation), directOrigin: Some(origin)))
        expect(match (fixture.runtime.commitResult(ResultEnvelope(fixture.thread, fixture.turn, fixture.run,
            fixture.admission.run.epoch, 1, forged))) { case SemanticCommitDecision.Rejected(_) => true; case _ => false },
            "ordinary worker cannot mint External from complete descriptive fields")
        expect(match (fixture.runtime.commitBatch(ResultBatchEnvelope(fixture.thread, fixture.turn, fixture.run,
            fixture.admission.run.epoch, 1, [forged]))) { case SemanticBatchCommitDecision.Rejected(_) => true; case _ => false },
            "batch path cannot claim External authority")
        expect(fixture.runtime.startExternalTurn(fixture.connection, ExternalRequestId(ExternalRequestIdKind.Number, value: "1.0"),
            fixture.call, SemanticTurnId("replay"), RunId("replay"), ItemId("replay"), recoveryLane(), InvocationContextProjection()).isError(),
            "decimal alias of consumed request ID is rejected before a second turn")
        expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items") == 1, "rejected entries leave only the real initiator")
        let source = fixture.commit()
        let memory = InMemoryOperationRuntimePort()
        expect(memory.prepareDirectOperation(source, fixture.plan).isError() &&
            memory.markExecutingWithSource(Some(OperationRootSource.Direct(source)), fixture.operation, fixture.run, fixture.plan, agentUtcMillis(), false).isError() &&
            memory.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)), fixture.operation, fixture.run, fixture.thread, agentUtcMillis()).isError(),
            "ports without explicit External support fail closed by default")
    } finally { foreignOwner.close(); fixture.close() }
}

func externalOriginApprovalReceiptContract(): Unit {
    let fixture = ExternalOriginFixture()
    try {
        let source = fixture.commit(); let sealedSource = Some(OperationRootSource.Direct(source))
        expect(fixture.store.prepareTrustedControlOperation(fixture.operation, fixture.run, fixture.item, fixture.plan).isError() &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 0, "primitive IDs cannot prepare External")
        fixture.prepare(source); fixture.prepare(source)
        expect(fixture.store.markExecuting(fixture.operation, fixture.run, fixture.plan, agentUtcMillis(), false).isError(),
            "legacy primitive execution cannot bypass a sealed External source")
        expect(fixture.store.markExecutingWithSource(sealedSource, fixture.operation, fixture.run, fixture.plan, agentUtcMillis(), true).isError(),
            "External connection does not imply user approval")
        fixture.store.waitForApproval(fixture.operation, fixture.run).value().getOrThrow()
        expect(fixture.store.recordApproval("empty-ceiling", fixture.operation, fixture.run, fixture.plan,
            CapabilitySet(), true, "operator", None).isError(), "approval cannot expand capability ceiling")
        fixture.store.recordApproval("external-approved", fixture.operation, fixture.run, fixture.plan,
            fixture.connection.binding.ceiling, true, "operator", None).value().getOrThrow()
        fixture.store.markExecutingWithSource(sealedSource, fixture.operation, fixture.run, fixture.plan, agentUtcMillis(), true).value().getOrThrow()
        expect(fixture.store.markExecutionHandoff(fixture.operation, fixture.run, fixture.thread, agentUtcMillis()).isError(),
            "primitive handoff refuses External even after legitimate execution admission")
        fixture.store.markExecutionHandoffWithSource(sealedSource, fixture.operation, fixture.run, fixture.thread, agentUtcMillis()).value().getOrThrow()
        let result = fixture.runtime.resolveOperation(ItemId("external-result"), fixture.operation, CanonicalToolCallId(fixture.call.callId),
            fixture.plan, OperationAttemptStage.Executing, Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(
                ToolResult(fixture.call.callId, objectValue([])))), "external-receipt", agentUtcMillis(),
            expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.admission.run.epoch)).value().getOrThrow()
        expect(result.semanticCommit.isSome() && isStoreCommitted(result.semanticCommit.getOrThrow()), "same canonical transaction commits External ToolResult and Receipt")
        expect(fixture.runtime.finish(RunState.Completed, 1000).isOk() && source.validateLiveSource().isError(),
            "completion invalidates live source even while ingress connection remains open")
        expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 1 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_host_origin_bound'") == 1 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0 && fixture.database.query("PRAGMA foreign_key_check").isEmpty(),
            "single immutable origin audit and Receipt preserve the existing relational invariants")
        let reopened = openExternalIngressConnection(fixture.authorizer, { => fixture.clock.now }).value().getOrThrow()
        expect(fixture.runtime.startExternalTurn(reopened, ExternalRequestId(ExternalRequestIdKind.Number, value: "1.00"), fixture.call,
            SemanticTurnId("reopened-turn"), RunId("reopened-run"), ItemId("reopened-input"), recoveryLane(), InvocationContextProjection()).isError(),
            "a newly minted seal with identical connection generation cannot replay the durable typed request key")
        reopened.revoke()
        let second = fixture.runtime.startExternalTurn(fixture.connection, ExternalRequestId(ExternalRequestIdKind.Text, value: "1"), fixture.call,
            SemanticTurnId("external-text-turn"), RunId("external-text-run"), ItemId("external-text-input"), recoveryLane(), InvocationContextProjection())
        expect(second.isOk(), "text 1 is distinct from previously consumed numeric 1 on the same connection")
        expect(fixture.runtime.finish(RunState.Failed, 1000).isOk(), "empty second test request can settle without effect")
    } finally { fixture.close() }
}

func externalOriginRevocationContract(stage: String): Unit {
    let fixture = ExternalOriginFixture()
    try {
        if (stage == "before-commit") {
            fixture.connection.revoke()
            expect(fixture.admission.cancellationToken.isCancelled() && fixture.runtime.commitExternalToolCall(fixture.admission,
                fixture.item, fixture.operation, fixture.call, fixture.run, fixture.admission.run.epoch).isError() &&
                fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'") == 0, "connection revocation cancels real Run and blocks commit")
            return
        }
        let source = fixture.commit(); let sealedSource = Some(OperationRootSource.Direct(source))
        if (stage != "prepare") { fixture.prepare(source) }
        if (stage == "handoff" || stage == "after-handoff") {
            fixture.store.markExecutingWithSource(sealedSource, fixture.operation, fixture.run, fixture.plan, agentUtcMillis(), false).value().getOrThrow()
        }
        if (stage == "after-handoff") {
            fixture.store.markExecutionHandoffWithSource(sealedSource, fixture.operation, fixture.run, fixture.thread, agentUtcMillis()).value().getOrThrow()
        }
        if (stage == "expiry") { fixture.clock.now = fixture.connection.binding.expiresAtMillis }
        else if (stage == "binding-change") { fixture.authorizer.changed = Some(fixture.binding(principal: "different-principal")) }
        else { fixture.connection.revoke() }
        expect(source.validateLiveSource().isError() && fixture.admission.cancellationToken.isCancelled(), stage + " invalidates source and propagates cancellation")
        let refused = if (stage == "prepare") { fixture.store.prepareDirectOperation(source, fixture.plan).isError() }
            else if (stage == "handoff" || stage == "after-handoff") {
                fixture.store.markExecutionHandoffWithSource(sealedSource, fixture.operation, fixture.run, fixture.thread, agentUtcMillis()).isError()
            } else { fixture.store.markExecutingWithSource(sealedSource, fixture.operation, fixture.run, fixture.plan, agentUtcMillis(), false).isError() }
        expect(refused && fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") ==
            (if (stage == "after-handoff") { 1 } else { 0 }), stage + " cannot advance another effect frontier")
        if (stage == "after-handoff" || stage == "handoff") {
            let cancelled = Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.Cancelled, "external.connection_revoked", "revoked"))
            let _ = fixture.runtime.resolveOperation(ItemId("cancelled-result"), fixture.operation, CanonicalToolCallId(fixture.call.callId),
                fixture.plan, OperationAttemptStage.Executing, cancelled, "cancelled-receipt", agentUtcMillis(),
                expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.admission.run.epoch)).value().getOrThrow()
            expect(fixture.database.query("SELECT outcome FROM operation_receipts")[0].required(0) == "unknown",
                "durable Executing cancellation keeps conservative Unknown, with or without a handoff marker")
        }
    } finally { fixture.close() }
}

func externalOriginRecoveryContract(): Unit {
    let fixture = ExternalOriginFixture()
    try {
        let source = fixture.commit(); fixture.prepare(source)
        let snapshot = fixture.sink.loadThread(fixture.thread); let active = fixture.runtime.activeRun().getOrThrow()
        let recovered = AgentThreadRuntime(ThreadCoordinator(snapshot, fixture.sink), ContextProjector("external", StoreEstimator()),
            RecoveredRunSpec(fixture.turn, fixture.run, active.epoch, RunState.Running, active.transitionSequence,
                recoveryLane(), InvocationContextProjection()), { => agentUtcMillis() })
        expect(isExternalInitiator(snapshot.items[0]) && sameDirectCallOrigin(effectiveDirectCallOrigin(snapshot.items[1].provenance), source.origin),
            "history retains External origin bytes and canonical readback")
        expect(recovered.attestDirectToolCall(fixture.item, fixture.operation, fixture.run, active.epoch).isError() &&
            recovered.commitExternalToolCall(fixture.admission, ItemId("recovered"), OperationId("recovered"), fixture.call, fixture.run, active.epoch).isError() &&
            recovered.projectContext().isError(), "recovered owner cannot mint External admission, Direct source or fake model execution")
        expect(fixture.store.markExecuting(fixture.operation, fixture.run, fixture.plan, agentUtcMillis(), false).isError() &&
            fixture.database.query("SELECT state FROM operations")[0].required(0) == "prepared", "historical plan plus primitive IDs is not execution authority")
    } finally { fixture.close() }
}

func externalOriginTamperContract(change: String): Unit {
    let fixture = ExternalOriginFixture()
    try {
        let source = fixture.commit(); fixture.prepare(source)
        if (change == "principal" || change == "connection" || change == "request-kind") {
            let old = encodeStoredProvenance(fixture.coordinator.snapshot().items[1].provenance)
            let mutable = decodeStoredValue(old)
            let origin = mutable.field("direct_origin").getOrThrow()
            if (change == "principal") { origin.put("principal_id", textValue("other-reader")) }
            else if (change == "connection") { origin.put("connection_id", textValue("other-connection")) }
            else { origin.field("request_id").getOrThrow().put("kind", textValue("text")) }
            let modified = encodeStoredValue(mutable)
            expect(modified != old, change + " mutation must alter the stored bytes")
            let decoded = decodeStoredProvenance(modified)
            let targetChanged = match (effectiveDirectCallOrigin(decoded)) {
                case DirectCallOrigin.External(value) =>
                    if (change == "principal") { value.principalId == "other-reader" }
                    else if (change == "connection") { value.connectionId == "other-connection" }
                    else { value.requestId.kind == ExternalRequestIdKind.Text && value.requestId.value == "1" }
                case _ => false
            }
            expect(targetChanged, change + " mutation must remain decodable with the intended External field changed")
            fixture.database.execute("UPDATE items SET provenance=? WHERE id='external-call-item'", [SqlParameter.Text(modified)])
            expect(fixture.database.query("SELECT provenance FROM items WHERE id='external-call-item'")[0].required(0) == modified,
                change + " mutation must be present in the actual canonical Item")
        } else if (change == "epoch") { fixture.database.execute("UPDATE runs SET epoch=epoch+1") }
        else if (change == "thread") { fixture.database.execute("UPDATE threads SET active_turn_id=NULL") }
        else if (change == "payload") { fixture.database.execute("UPDATE items SET payload=? WHERE id='external-call-item'", [
            SqlParameter.Text(encodeStoredThreadContent(ThreadItemContent.ToolCall(CanonicalToolCallId(fixture.call.callId), fixture.call.name, objectValue([]))))]) }
        else if (change == "audit") { fixture.database.execute("DELETE FROM audit_events WHERE kind='operation_host_origin_bound'") }
        else if (change == "downgrade") {
            fixture.database.execute("UPDATE items SET provenance=? WHERE id='external-call-item'", [SqlParameter.Text(encodeStoredProvenance(
                ItemProvenance("direct_tool", runId: Some(fixture.run), operationId: Some(fixture.operation))))])
        }
        expect(fixture.store.markExecutingWithSource(Some(OperationRootSource.Direct(source)), fixture.operation, fixture.run,
            fixture.plan, agentUtcMillis(), false).isError() &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0,
            change + " tampering cannot advance execution or create a false Receipt")
    } finally { fixture.close() }
}

func externalReceivedFrameContract(): Unit {
    let fixture = ExternalOriginFixture(withFrame: true)
    let other = ExternalOriginFixture(withFrame: true)
    try {
        let frame = fixture.frame.getOrThrow()
        let origin = fixture.admission.origin
        expect(origin.frameEvidence.isSome() && origin.frameEvidence.getOrThrow().rawFrameDigest == modelPolicySha256Text(frame.raw) &&
            origin.requestDigest == externalToolCallDigest(fixture.call) &&
            origin.frameEvidence.getOrThrow().decoder.packageDigest == fixture.decoder.getOrThrow().packageDigest,
            "real receiver captures raw frame separately from proposed canonical call and fixed decoder identity")
        let encoded = directCallOriginValue(DirectCallOrigin.External(origin))
        expect(encoded.field("schema").getOrThrow().text == "axyndra.direct-origin/v3" &&
            sameDirectCallOrigin(DirectCallOrigin.External(origin), directCallOriginFromValue(encoded)), "v3 source readback retains frame and proposed-call proof")
        let absentFrame = fixture.runtime.startExternalTurn(fixture.connection, ExternalRequestId(ExternalRequestIdKind.Text, value: "without-frame"),
            fixture.call, SemanticTurnId("no-frame"), RunId("no-frame"), ItemId("no-frame"), recoveryLane(), InvocationContextProjection())
        expect(absentFrame.isError() && absentFrame.error().getOrThrow().code == "external.received_frame_required",
            "decoder-bound connection rejects missing seal before any unrelated active-Run conflict")
        let unconsumedForeign = other.connection.captureFrame("{\"unconsumed_foreign\":true}").value().getOrThrow()
        for (seal in [frame, unconsumedForeign]) {
            let deniedFrame = fixture.runtime.startExternalTurn(fixture.connection, ExternalRequestId(ExternalRequestIdKind.Text, value: "replayed-frame"),
                fixture.call, SemanticTurnId("no-frame"), RunId("no-frame"), ItemId("no-frame"), recoveryLane(), InvocationContextProjection(),
                receivedFrame: Some(seal))
            expect(deniedFrame.isError() && deniedFrame.error().getOrThrow().code == "external.frame_consumed",
                "own consumed and foreign fresh seals are independently rejected before active-Run checks")
        }
        expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items") == 1, "rejected frame bindings do not create canonical work")
        let source = fixture.commit(); fixture.prepare(source)
        let sealedSource = Some(OperationRootSource.Direct(source))
        let originalProvenance = fixture.database.query("SELECT provenance FROM items WHERE kind='tool_call'")[0].required(0)
        for (tampered in [originalProvenance.replace(frame.digest, modelPolicySha256Text("different received bytes")),
            originalProvenance.replace("instance-one", "instance-two")]) {
            expect(tampered != originalProvenance, "tamper changes real persisted v3 evidence")
            fixture.database.execute("UPDATE items SET provenance=? WHERE kind='tool_call'", [SqlParameter.Text(tampered)])
            expect(fixture.store.markExecutingWithSource(sealedSource, fixture.operation, fixture.run, fixture.plan, agentUtcMillis(), false).isError() &&
                fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0,
                "forged raw frame digest or decoder instance cannot cross the Store execution boundary")
            fixture.database.execute("UPDATE items SET provenance=? WHERE kind='tool_call'", [SqlParameter.Text(originalProvenance)])
        }
        fixture.store.markExecutingWithSource(sealedSource, fixture.operation, fixture.run, fixture.plan, agentUtcMillis(), false).value().getOrThrow()
        fixture.store.markExecutionHandoffWithSource(sealedSource, fixture.operation, fixture.run, fixture.thread, agentUtcMillis()).value().getOrThrow()
        let _ = fixture.runtime.resolveOperation(ItemId("frame-result"), fixture.operation, CanonicalToolCallId(fixture.call.callId),
            fixture.plan, OperationAttemptStage.Executing, Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(
                ToolResult(fixture.call.callId, objectValue([])))), "frame-receipt", agentUtcMillis(),
            expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.admission.run.epoch)).value().getOrThrow()
        fixture.runtime.finish(RunState.Completed, 1000).value().getOrThrow()
        let persisted = decodeStoredProvenance(fixture.database.query("SELECT provenance FROM items WHERE kind='tool_call'")[0].required(0))
        expect(sameDirectCallOrigin(effectiveDirectCallOrigin(persisted), DirectCallOrigin.External(origin)) &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 1,
            "actual SQLite ToolCall, source audit, handoff and Receipt preserve the captured frame origin")
        let cancelled = fixture.connection.captureFrame("{\"cancelled_before_queue\":true}").value().getOrThrow()
        let id = ExternalRequestId(ExternalRequestIdKind.Text, value: "queued")
        fixture.connection.cancelRequest(id).value().getOrThrow()
        expect(fixture.runtime.startExternalTurn(fixture.connection, id, fixture.call, SemanticTurnId("queued"), RunId("queued"),
            ItemId("queued"), recoveryLane(), InvocationContextProjection(), receivedFrame: Some(cancelled)).isError() &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 1,
            "known queued cancellation is remembered before Run admission and creates no effect")
        let emptyBinding = ExternalIngressBinding("empty-grant", "empty-connection", "reader", 1, fixture.thread,
            modelPolicySha256Text("empty"), [], [], agentUtcMillis() + 10000, [], decoder: fixture.decoder)
        let emptyConnection = openExternalIngressConnection(ExternalContractAuthorizer(emptyBinding), { => agentUtcMillis() }).value().getOrThrow()
        let emptyFrame = emptyConnection.captureFrame("{}").value().getOrThrow()
        expect(fixture.runtime.startExternalTurn(emptyConnection, ExternalRequestId(ExternalRequestIdKind.Null), fixture.call,
            SemanticTurnId("empty"), RunId("empty"), ItemId("empty"), recoveryLane(), InvocationContextProjection(),
            receivedFrame: Some(emptyFrame)).isError(), "empty export snapshot is valid for discovery but cannot invoke anything")
        emptyConnection.revoke()
        println("External received frame contract passed: captured v3 origin, exact seal, real Receipt, queued cancellation, empty exports")
    } finally { other.close(); fixture.close() }
}
