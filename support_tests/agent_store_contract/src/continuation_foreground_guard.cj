package agent_store_contract

import agent_domain.*
import agent_ports.*
import agent_store.*
import yjson.*
import yjson_support.*

func foregroundModelContinuation(f: ApprovalContinuationFixture): RunContinuation {
    let checkpoint = RunningModelCheckpoint(SemanticModelRequestId("next-model"), objectValue([]),
        "semantic-digest", "wire-digest", ModelAttemptId("next-attempt"), ModelAttemptId("next-attempt"),
        f.cut.turn.value, "next-request", 40)
    RunContinuation(RunContinuationKind.RunningModel, f.cut.run, SessionId(f.cut.thread.value), "fixture", "next model",
        checkpoint, RequestedModelPolicy(ThinkingLevel.Off, RequestOutputBudget(1024)),
        ModelExecutionCapabilitiesSnapshot("fixture", ThinkingCapabilities(ThinkingControlMode.NoThinking), 1024))
}

func foregroundApprovalContinuation(f: ApprovalContinuationFixture, different: Bool): RunContinuation {
    let approval = ApprovalRequest(if (different) { f.laterOperation } else { f.operation }, f.call.callId,
        f.call.name, Capability(CapabilityKind.WorkspaceRead), preview: f.plan.canonicalArguments,
        sessionId: f.cut.thread.value, argumentHash: "original-call-and-capabilities-hash")
    RunContinuation(f.cut.run, SessionId(f.cut.thread.value), "fixture", "refresh catalog", approval,
        contextSnapshotPayload: contextSnapshotValue(InvocationContextProjection()))
}

func continuationForegroundGuardContracts(): Unit {
    // No safe cut is requested in these cases. The real public Store writer
    // must reject a lossy checkpoint even when dynamic context is unchanged.
    for (mode in ["pending", "unknown", "decision-missing", "other-debt", "corrupt-payload", "wrong-column-digest",
        "approved", "same-approval", "different-approval", "waiting-external", "same-approval-batch",
        "model-batch-cursor", "model-batch-missing", "model-batch-settled",
        "reference-attempt", "reference-semantic", "reference-decision", "reference-usage", "reference-items",
        "phase-approval", "phase-external", "phase-tool-effect", "phase-tool-settling", "phase-terminalizing"]) {
        let f = ApprovalContinuationFixture()
        try {
            if (mode == "unknown") { let _ = f.resolve("unknown") }
            if (mode == "decision-missing") {
                f.cut.database.execute("DELETE FROM approval_decisions")
                let _ = f.resolve("approved")
            }
            if (mode == "other-debt") {
                f.save(WorkDebtSnapshot(unsettledOperations: [f.operation, OperationId("other-operation")],
                    pendingApprovals: [ApprovalId("legacy-approval-" + f.operation.value)]))
                let _ = f.resolve("approved")
            }
            if (mode == "waiting-external") {
                f.save(WorkDebtSnapshot(unsettledOperations: [f.operation],
                    pendingApprovals: [ApprovalId("legacy-approval-" + f.operation.value)],
                    waitingExternal: [ExternalHandleId("unsettled-external")]))
                let _ = f.resolve("approved")
            }
            if (mode == "approved") { let _ = f.resolve("approved") }
            if (mode == "same-approval-batch") {
                f.save(f.cut.continuation().workDebt, batch: Some(ToolBatchContinuation(ToolBatchId("retained-batch"),
                    0, [f.operation, f.laterOperation])))
            }
            if (mode.startsWith("model-batch-")) {
                let _ = f.resolve("approved")
                f.save(WorkDebtSnapshot(), batch: Some(ToolBatchContinuation(ToolBatchId("guard-batch"),
                    if (mode == "model-batch-cursor") { 0 } else { 1 },
                    [if (mode == "model-batch-missing") { f.laterOperation } else { f.operation }])))
            }
            if (mode.startsWith("reference-")) { foregroundInjectModelReference(f, mode) }
            if (mode.startsWith("phase-")) { foregroundInjectPendingPhase(f, mode) }
            if (mode == "corrupt-payload") {
                f.cut.database.execute("UPDATE run_continuations SET payload='invalid-existing-checkpoint'")
            }
            if (mode == "wrong-column-digest") {
                f.cut.database.execute("UPDATE run_continuations SET digest='wrong-persisted-digest'")
            }
            let original = f.cut.database.query("SELECT payload,digest,revision FROM run_continuations")[0]
            let modelRows = f.cut.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
            let next = if (mode == "same-approval" || mode == "different-approval" || mode == "same-approval-batch" || mode.startsWith("reference-")) {
                foregroundApprovalContinuation(f, mode == "different-approval")
            } else { foregroundModelContinuation(f) }
            var rejected = false
            try { f.cut.database.transaction { tx => writeRunContinuationSnapshotProjection(tx, next, f.request) } }
            catch (_: Exception) { rejected = true }
            let allowed = ["approved", "same-approval", "same-approval-batch", "model-batch-settled"].contains(mode)
            expect(rejected != allowed, "only proved settlement or the same approval may replace its checkpoint: " + mode)
            let after = f.cut.database.query("SELECT payload,digest,revision FROM run_continuations")[0]
            if (!allowed) {
                expect(after.required(0) == original.required(0) && after.required(1) == original.required(1) &&
                    after.required(2) == original.required(2), "denied projection preserves all existing bytes and revision: " + mode)
            } else if (mode == "approved" || mode == "model-batch-settled") {
                let current = f.cut.continuation()
                expect(runExecutionPhaseName(current.phase) == "model_effect_pending" && current.pendingOperationId.isNone() &&
                    current.pendingApprovalId.isNone() && current.workDebt.unsettledOperations.isEmpty() &&
                    current.workDebt.pendingApprovals.isEmpty(), "actual canonical approval settlement permits the next model checkpoint")
            }
            if (mode == "same-approval-batch") {
                let batch = f.cut.continuation().toolBatch.getOrThrow()
                expect(batch.batchId.value == "retained-batch" && batch.nextOperationOrdinal == 0 &&
                    batch.operationIds.size == 2 && batch.operationIds[0].value == f.operation.value &&
                    batch.operationIds[1].value == f.laterOperation.value, "same-approval save preserves the exact unfinished batch")
            }
            expect(f.cut.database.scalarInt("SELECT COUNT(*) FROM model_attempts") == modelRows &&
                f.cut.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == 0,
                "checkpoint validation does not create an Attempt or depend on a context cut")
        } finally { f.close() }
    }
    println("Store continuation foreground overwrite guard passed: 24 scenarios")
}

func foregroundInjectModelReference(f: ApprovalContinuationFixture, mode: String): Unit {
    let current = f.cut.continuation()
    let next = withRunRequestSnapshotProjection(sealDurableRunContinuation(DurableRunContinuationV1(current.runId,
        current.laneId, current.turnId, current.stepOrdinal, current.phase, current.compositionSnapshotId,
        current.modelLaneSnapshotId, pendingOperationId: current.pendingOperationId, pendingApprovalId: current.pendingApprovalId,
        workDebt: current.workDebt,
        semanticRequestId: if (mode == "reference-semantic") { Some(SemanticModelRequestId("retained-semantic")) } else { None },
        attemptId: if (mode == "reference-attempt") { Some(ModelAttemptId("retained-attempt")) } else { None },
        reservedDecisionId: if (mode == "reference-decision") { Some(ModelDecisionId("retained-decision")) } else { None },
        reservedUsageId: if (mode == "reference-usage") { Some(UsageRecordId("retained-usage")) } else { None },
        reservedItemIds: if (mode == "reference-items") { [ItemId("retained-item")] } else { [] })), f.request)
    SqliteSemanticStore(f.cut.database).transact(TransactionPreconditions(f.cut.thread,
        f.cut.runtime.threadSnapshot().thread.revision, f.cut.run,
        f.cut.database.scalarInt("SELECT revision FROM run_continuations WHERE run_id='cut-run'")),
        DurableWriteSet(continuation: Some(next))).value().getOrThrow()
    f.cut.reload()
}

func foregroundInjectPendingPhase(f: ApprovalContinuationFixture, mode: String): Unit {
    let current = f.cut.continuation()
    let state = DurablePhaseState(objectValue([]))
    let phase = match (mode) {
        case "phase-approval" => RunExecutionPhase.WaitingApproval(state)
        case "phase-external" => RunExecutionPhase.WaitingExternal(state)
        case "phase-tool-effect" => RunExecutionPhase.ToolEffectPending(state)
        case "phase-tool-settling" => RunExecutionPhase.ToolSettling(state)
        case _ => RunExecutionPhase.Terminalizing(state)
    }
    // Deliberate malformed producer state: canonical codec-valid phase with
    // empty reference/debt fields must not be interpreted as a settled effect.
    let next = withRunRequestSnapshotProjection(sealDurableRunContinuation(DurableRunContinuationV1(current.runId,
        current.laneId, current.turnId, current.stepOrdinal, phase, current.compositionSnapshotId,
        current.modelLaneSnapshotId)), f.request)
    // The public semantic writer already rejects missing phase identities.
    // Inject corrupt-but-sealed stored bytes explicitly, as a recovery fault;
    // do not pretend a legal public transaction can create this state.
    f.cut.database.execute("UPDATE run_continuations SET payload=?,digest=?,phase=? WHERE run_id=?",
        [SqlParameter.Text(encodeDurableRunContinuation(next)), SqlParameter.Text(next.digest),
            SqlParameter.Text(runExecutionPhaseName(next.phase)), SqlParameter.Text(f.cut.run.value)])
}
