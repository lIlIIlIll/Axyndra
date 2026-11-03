package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Runs only after the real Receipt and canonical ToolResult have been inserted
// in the same Thread transaction. This does not grant execution or relax a cut.
// Incomplete, unknown or mismatched evidence retains the old approval debt.
func settleCanonicalApprovalContinuation(transaction: SqliteTransaction,
    transition: ThreadTransition, item: ThreadItem, receipt: VNextOperationReceipt, priorOperationState: String): Unit {
    if (receipt.outcome == OperationOutcome.Unknown) { return }
    let run = item.provenance.runId.getOrThrow()
    let rows = transaction.query("SELECT c.revision,c.payload,c.digest,r.thread_id,r.turn_id,r.epoch " +
        "FROM run_continuations c JOIN runs r ON r.id=c.run_id WHERE c.run_id=?",
        [SqlParameter.Text(run.value)])
    if (rows.size != 1 || rows[0].required(3) != item.threadId.value || rows[0].required(4) != item.turnId.value ||
        rows[0].required(5) != transition.before.activeEpoch.toString()) { return }
    let current = try { decodeDurableRunContinuation(rows[0].required(1)) } catch (_: Exception) { return }
    if (current.digest != rows[0].required(2) || current.runId.value != run.value || current.turnId.value != item.turnId.value ||
        current.pendingOperationId.isNone() || current.pendingApprovalId.isNone()) { return }
    match (current.phase) { case RunExecutionPhase.WaitingApproval(_) => (); case _ => return }
    let operation = current.pendingOperationId.getOrThrow()
    let approval = current.pendingApprovalId.getOrThrow()
    if (approval.value != "legacy-approval-" + operation.value) { return }
    let frozen = match (optionalRunRequestSnapshotFromDurableContinuation(current)) {
        case Some(value) => value; case None => return }
    // Decode only data that can be bounded/validated without a new authority.
    let requestApproval = match (frozen.field("approval")) { case Some(value) => value; case None => return }
    if (requestApproval.unifiedKind != ValueKind.Object || httpIntentText(frozen, "kind") != "waiting_approval" ||
        httpIntentText(frozen, "run_id") != run.value || httpIntentText(frozen, "session_id") != item.threadId.value ||
        httpIntentText(requestApproval, "operation_id") != operation.value ||
        httpIntentText(requestApproval, "session_id") != item.threadId.value) { return }
    let proof = transaction.query("SELECT o.normalized_plan,call.payload,COALESCE(a.id,''),COALESCE(a.operation_digest,''),COALESCE(a.decision,'')," +
        "d.payload,receipt.id,receipt.outcome,receipt.detail,receipt.verification " +
        "FROM operations o JOIN items call ON call.id=o.tool_call_item_id " +
        "LEFT JOIN approvals a ON a.operation_id=o.id JOIN approval_decisions d ON d.operation_id=o.id AND d.run_id=o.run_id " +
        "JOIN operation_receipts receipt ON receipt.operation_id=o.id " +
        "WHERE o.id=? AND o.run_id=? AND o.state='committed' AND call.kind='tool_call' " +
        "AND call.thread_id=? AND call.turn_id=?",
        [SqlParameter.Text(operation.value), SqlParameter.Text(run.value), SqlParameter.Text(item.threadId.value),
            SqlParameter.Text(item.turnId.value)])
    if (proof.size != 1) { return }
    let row = proof[0]
    let plan = try { decodeOperationPlan(row.required(0)) } catch (_: Exception) { return }
    let call = try { decodeStoredThreadContent(row.required(1)) } catch (_: Exception) { return }
    let callId = match (call) { case ThreadItemContent.ToolCall(id, name, _) =>
        if (name != plan.toolName || name != httpIntentText(requestApproval, "tool_name")) { return }; id.value
        case _ => return }
    let decision = try { parseUnifiedJson(row.required(5), maxBytes: 67108864) } catch (_: Exception) { return }
    if (!httpIntentExactFields(decision, ["version", "operation_id", "run_id", "session_id", "call_id", "argument_hash", "decision"]) ||
        decision.field("version").getOrThrow().unifiedKind != ValueKind.Number ||
        decision.field("version").getOrThrow().asNumberText() != "1" ||
        httpIntentText(decision, "operation_id") != operation.value || httpIntentText(decision, "run_id") != run.value ||
        httpIntentText(decision, "session_id") != item.threadId.value || httpIntentText(decision, "call_id") != callId ||
        httpIntentText(requestApproval, "call_id") != callId || httpIntentText(requestApproval, "argument_hash") == "" ||
        httpIntentText(decision, "argument_hash") != httpIntentText(requestApproval, "argument_hash")) { return }
    let preview = requestApproval.field("preview")
    if (preview.isNone() || canonicalAgentValue(preview.getOrThrow()) != canonicalAgentValue(plan.canonicalArguments)) { return }
    let choice = decision.field("decision").getOrThrow()
    if (choice.unifiedKind != ValueKind.Object) { return }
    let kind = httpIntentText(choice, "kind")
    let approved = kind == "approve" || kind == "approve_session"
    if (approved || kind == "reject") {
        if (!httpIntentExactFields(choice, ["kind"])) { return }
    } else if (kind == "reject_with_reason") {
        if (!httpIntentExactFields(choice, ["kind", "reason"]) || httpIntentText(choice, "reason") == "") { return }
    } else { return }
    if (row.required(2) == "") {
        // No capability approval was created: a formerly valid preparation
        // became stale after the actual user decision. Prove the original
        // waiting read and its zero-handoff Rejected result in this same TX.
        if ((kind == "approve_session" && (!plan.approvalMetadata.sessionApprovalAllowed ||
            !networkPolicyModeIsDenied(plan.networkPolicy.mode))) || !contextReadApprovalRefusalKnown(transaction, transition,
            item, receipt, operation, plan, priorOperationState)) { return }
    } else if (row.required(2) != "approval-" + operation.value || row.required(3) != plan.bindingDigest ||
        row.required(4) != (if (approved) { "approved" } else { "rejected" }) ||
        (!approved && row.required(7) != "rejected") ||
        !["completed", "failed", "rejected", "cancelled", "timed_out"].contains(row.required(7))) { return }
    if (!approvalHasCanonicalResult(transaction, run, item.threadId, item.turnId, operation, callId,
        row.required(6), row.required(7), row.required(8))) { return }
    // A later result can finish a batch, but cannot infer/advance its cursor.
    // Until the actual cursor and every listed result are terminal, keep debt.
    match (current.toolBatch) {
        case Some(batch) =>
            if (batch.nextOperationOrdinal != batch.operationIds.size) { return }
            for (op in batch.operationIds) {
                if (!approvalBatchOperationKnown(transaction, run, item.threadId, item.turnId, op)) { return }
            }
        case None => ()
    }
    let debt = current.workDebt
    let operations = ArrayList<OperationId>(); let approvals = ArrayList<ApprovalId>()
    for (op in debt.unsettledOperations where op.value != operation.value) { operations.add(op) }
    for (entry in debt.pendingApprovals where entry.value != approval.value) { approvals.add(entry) }
    let next = withRunRequestSnapshotProjection(sealDurableRunContinuation(DurableRunContinuationV1(
        current.runId, current.laneId, current.turnId, current.stepOrdinal,
        RunExecutionPhase.Checkpoint(DurablePhaseState(objectValue([
            ValueField("settled_approval_id", textValue(approval.value)),
            ValueField("settled_operation_id", textValue(operation.value)),
            ValueField("settled_receipt_id", textValue(row.required(6)))]))),
        current.compositionSnapshotId, current.modelLaneSnapshotId,
        contextManifestId: current.contextManifestId, semanticRequestId: current.semanticRequestId,
        attemptId: current.attemptId, reservedDecisionId: current.reservedDecisionId,
        reservedUsageId: current.reservedUsageId, reservedItemIds: current.reservedItemIds,
        toolBatch: current.toolBatch, waitingExternal: current.waitingExternal,
        workDebt: WorkDebtSnapshot(unclaimedInputs: debt.unclaimedInputs, activeAttempts: debt.activeAttempts,
            uncommittedDecisions: debt.uncommittedDecisions, unsettledOperations: operations.toArray(),
            pendingApprovals: approvals.toArray(), waitingExternal: debt.waitingExternal,
            activeChildRuns: debt.activeChildRuns, ownedTasks: debt.ownedTasks, deferredContexts: debt.deferredContexts),
        recoveryPolicyVersion: current.recoveryPolicyVersion)), frozen)
    putClaimContinuation(transaction, item.threadId, next, Int64.parse(rows[0].required(0)), receipt.observedAtMillis)
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) " +
        "VALUES (?,?,?,'approval_continuation_settled',?,?,?)",
        [SqlParameter.Text(item.threadId.value), SqlParameter.Text(run.value), SqlParameter.Text(operation.value),
            SqlParameter.Text(encodeStoredValue(objectValue([
                ValueField("approval_id", textValue(approval.value)), ValueField("receipt_id", textValue(row.required(6))),
                ValueField("previous_continuation_digest", textValue(current.digest))]))),
            SqlParameter.Int64Value(receipt.observedAtMillis), SqlParameter.Int64Value(Int64.parse(transaction.query(
                "SELECT last_sequence FROM thread_commit_heads WHERE thread_id=" + sqliteText(item.threadId.value))[0].required(0)))])
}

func approvalHasCanonicalResult(transaction: SqliteTransaction, run: RunId, thread: ThreadId, turn: SemanticTurnId,
    operation: OperationId, callId: String, receiptId: String, outcome: String, encodedDetail: String): Bool {
    var found = false
    let detail = try { decodeStoredValue(encodedDetail) } catch (_: Exception) { return false }
    for (row in transaction.query("SELECT payload,provenance FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result'",
        [SqlParameter.Text(thread.value), SqlParameter.Text(turn.value)])) {
        let value = try { decodeStoredThreadContent(row.required(0)) } catch (_: Exception) { return false }
        match (value) {
            case ThreadItemContent.ToolResult(id, op, receipt, output, isError) =>
                if (op.value != operation.value) { continue }
                let provenance = try { decodeStoredProvenance(row.required(1)) } catch (_: Exception) { return false }
                if (found || id.value != callId || receipt != receiptId || provenance.runId.isNone() ||
                    provenance.runId.getOrThrow().value != run.value || provenance.source != "operation" ||
                    provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != operation.value ||
                    isError != (outcome != "completed")) { return false }
                if (canonicalAgentValue(output) != canonicalAgentValue(detail)) {
                    if (output.unifiedKind != ValueKind.Object) { return false }
                    let error = output.field("error")
                    let reconciliation = output.field("reconciliation_required")
                    if (httpIntentText(output, "outcome") != outcome || error.isNone() || reconciliation.isNone() ||
                        reconciliation.getOrThrow().unifiedKind != ValueKind.Boolean || reconciliation.getOrThrow().asBool() ||
                        canonicalAgentValue(error.getOrThrow()) != canonicalAgentValue(detail)) { return false }
                }
                found = true
            case _ => return false
        }
    }
    found
}

func approvalBatchOperationKnown(transaction: SqliteTransaction, run: RunId, thread: ThreadId,
    turn: SemanticTurnId, operation: OperationId): Bool {
    let rows = transaction.query("SELECT call.payload,receipt.id,receipt.outcome,receipt.detail FROM operations o " +
        "JOIN items call ON call.id=o.tool_call_item_id JOIN operation_receipts receipt ON receipt.operation_id=o.id " +
        "WHERE o.id=? AND o.run_id=? AND o.state='committed' AND call.thread_id=? AND call.turn_id=? AND call.kind='tool_call'",
        [SqlParameter.Text(operation.value), SqlParameter.Text(run.value), SqlParameter.Text(thread.value), SqlParameter.Text(turn.value)])
    if (rows.size != 1 || !["completed", "failed", "rejected", "cancelled", "timed_out"].contains(rows[0].required(2))) { return false }
    let call = try { decodeStoredThreadContent(rows[0].required(0)) } catch (_: Exception) { return false }
    let id = match (call) { case ThreadItemContent.ToolCall(value, _, _) => value.value; case _ => return false }
    approvalHasCanonicalResult(transaction, run, thread, turn, operation, id, rows[0].required(1), rows[0].required(2), rows[0].required(3))
}
