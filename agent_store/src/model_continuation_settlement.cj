package agent_store

import agent_domain.*
import std.convert.*
import yjson.*
import yjson_support.*

// Compatibility clear consumes only a proved, canonically committed model
// effect. It cannot remove the Run's lane, context identity, or unrelated work.
// Keeping the current checkpoint makes the next safe cut an actual CAS.
public func settleModelExecutionContinuation(
    transaction: SqliteTransaction, run: RunId, attempt: ModelAttemptId
): Unit {
    let proof = transaction.query("SELECT d.id,a.completed_at_millis FROM model_attempts a " +
        "JOIN model_decisions d ON d.attempt_id=a.id WHERE a.id=? AND a.run_id=? " +
        "AND a.lifecycle='completed' AND a.completed_at_millis IS NOT NULL " +
        "AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NOT NULL",
        [SqlParameter.Text(attempt.value), SqlParameter.Text(run.value)])
    if (proof.size != 1) {
        throw IllegalStateException("model continuation clear requires its actually committed canonical Decision")
    }
    let auditPayload = encodeStoredValue(objectValue([
        ValueField("attempt_id", textValue(attempt.value)), ValueField("decision_id", textValue(proof[0].required(0)))]))
    let alreadySettled = !transaction.query("SELECT id FROM audit_events WHERE run_id=? " +
        "AND kind='model_continuation_settled' AND payload=?",
        [SqlParameter.Text(run.value), SqlParameter.Text(auditPayload)]).isEmpty()
    let rows = transaction.query("SELECT r.thread_id,c.revision,c.payload,c.digest,c.active_attempt_id FROM runs r " +
        "LEFT JOIN run_continuations c ON c.run_id=r.id WHERE r.id=?", [SqlParameter.Text(run.value)])
    if (rows.size != 1) { throw IllegalStateException("model continuation Run is missing") }
    if (rows[0][2].isNone()) {
        // A historical pre-upgrade clear may already have removed the row.
        // Do not reconstruct a new lane or request from current configuration.
        return
    }
    let current = decodeDurableRunContinuation(rows[0].required(2))
    if (current.runId.value != run.value || current.digest != rows[0].required(3)) {
        throw IllegalStateException("model continuation is inconsistent")
    }
    // A late clear cannot touch a later Attempt, lane, approval or context.
    // Its exact prior settled audit plus canonical Decision is the only no-op proof.
    if (alreadySettled) { return }
    if (current.attemptId.isNone() || current.attemptId.getOrThrow().value != attempt.value ||
        (rows[0][4].isSome() && rows[0].required(4) != attempt.value)) {
        throw IllegalStateException("model continuation Attempt identity changed")
    }
    match (current.phase) {
        case RunExecutionPhase.ModelEffectPending(_) | RunExecutionPhase.ModelSettling(_) |
            RunExecutionPhase.DecisionReady(_) => ()
        case _ => throw IllegalStateException("model continuation no longer owns that effect phase")
    }
    for (value in current.workDebt.activeAttempts where value.value != attempt.value) {
        throw IllegalStateException("model continuation owns another active Attempt")
    }
    for (value in current.workDebt.uncommittedDecisions where value.value != proof[0].required(0)) {
        throw IllegalStateException("model continuation owns another uncommitted Decision")
    }
    let debt = current.workDebt
    let next = sealDurableRunContinuation(DurableRunContinuationV1(run, current.laneId, current.turnId,
        current.stepOrdinal, RunExecutionPhase.Checkpoint(DurablePhaseState(objectValue([
            ValueField("settled_model_attempt_id", textValue(attempt.value)),
            ValueField("committed_decision_id", textValue(proof[0].required(0)))]))),
        current.compositionSnapshotId, current.modelLaneSnapshotId,
        contextManifestId: current.contextManifestId,
        toolBatch: current.toolBatch, pendingOperationId: current.pendingOperationId,
        pendingApprovalId: current.pendingApprovalId, waitingExternal: current.waitingExternal,
        workDebt: WorkDebtSnapshot(unclaimedInputs: debt.unclaimedInputs,
            unsettledOperations: debt.unsettledOperations, pendingApprovals: debt.pendingApprovals,
            waitingExternal: debt.waitingExternal, activeChildRuns: debt.activeChildRuns,
            ownedTasks: debt.ownedTasks, deferredContexts: debt.deferredContexts),
        recoveryPolicyVersion: current.recoveryPolicyVersion))
    let thread = ThreadId(rows[0].required(0))
    let observed = Int64.parse(proof[0].required(1))
    putClaimContinuation(transaction, thread, next, Int64.parse(rows[0].required(1)), observed)
    transaction.execute("UPDATE run_continuations SET active_attempt_id=NULL WHERE run_id=?",
        [SqlParameter.Text(run.value)])
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) " +
        "VALUES (?,?,NULL,'model_continuation_settled',?,?,?)",
        [SqlParameter.Text(thread.value), SqlParameter.Text(run.value), SqlParameter.Text(auditPayload),
            SqlParameter.Int64Value(observed), SqlParameter.Int64Value(Int64.parse(transaction.query(
                "SELECT last_sequence FROM thread_commit_heads WHERE thread_id=?", [SqlParameter.Text(thread.value)])[0].required(0)))])
}
