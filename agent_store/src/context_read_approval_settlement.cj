package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

// Called only after the actual Decision, Rejected Receipt and canonical paired
// result have been checked in the existing Thread commit transaction. This
// clears one waiting obligation; it never manufactures an approval or grant.
func contextReadApprovalRefusalKnown(transaction: SqliteTransaction, transition: ThreadTransition,
    result: ThreadItem, receipt: VNextOperationReceipt, operation: OperationId,
    plan: NormalizedOperationPlan, priorState: String): Bool {
    if (priorState != "waiting_approval" || operation.value != receipt.operationId.value ||
        receipt.outcome != OperationOutcome.Rejected || !isContextReadPlan(plan) ||
        !httpIntentExactFields(receipt.verification, ["policy_rejected"])) { return false }
    let rejected = receipt.verification.field("policy_rejected").getOrThrow()
    if (rejected.unifiedKind != ValueKind.Boolean || !rejected.asBool()) { return false }
    let run = result.provenance.runId.getOrThrow()
    let rows = transaction.query("SELECT o.tool_call_item_id,o.normalized_plan,call.payload,r.epoch " +
        "FROM operations o JOIN runs r ON r.id=o.run_id " +
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.normalized_plan=o.normalized_plan " +
        "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state " +
        "JOIN items call ON call.id=o.tool_call_item_id AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id " +
        "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id " +
        "WHERE o.id=? AND o.run_id=? AND o.state='committed' AND r.thread_id=? AND r.turn_id=? " +
        "AND r.epoch=? AND call.kind='tool_call' AND receipt.id=? AND receipt.outcome='rejected' " +
        "AND e.reserved_result_item_id=? AND NOT EXISTS(SELECT 1 FROM approvals a WHERE a.operation_id=o.id) " +
        "AND NOT EXISTS(SELECT 1 FROM audit_events h WHERE h.operation_id=o.id AND h.kind='operation_execution_handoff') " +
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions d WHERE d.operation_id=o.id)",
        [SqlParameter.Text(operation.value), SqlParameter.Text(run.value), SqlParameter.Text(result.threadId.value),
            SqlParameter.Text(result.turnId.value), SqlParameter.Int64Value(transition.before.activeEpoch),
            SqlParameter.Text(receipt.receiptId), SqlParameter.Text(result.id.value)])
    if (rows.size != 1 || rows[0].required(1) != encodeOperationPlan(plan)) { return false }
    try {
        match (decodeStoredThreadContent(rows[0].required(2))) {
            case ThreadItemContent.ToolCall(_, name, arguments) =>
                if (name != HOST_CONTEXT_READ_TOOL || canonicalAgentValue(arguments) != canonicalAgentValue(plan.canonicalArguments)) { return false }
            case _ => return false
        }
        requireContextReadOriginBinding(transaction, operation, run, ItemId(rows[0].required(0)), false)
        requireContextReadPlan(transaction, ItemId(rows[0].required(0)), plan)
        true
    } catch (_: Exception) { false }
}
