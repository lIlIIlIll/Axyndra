package agent_store

import agent_domain.*
import agent_runtime.*

// This is a same-transaction completion check over canonical facts. It neither
// reconstructs a live Source nor changes any Operation, Receipt, or permission.
func requireCompletedDerivedSettlement240(tx: SqliteTransaction, rowid: Int64, run: RunId,
    allocate: ?(Int64)->LogicalJsonOwnerReservation): Unit {
    let bound = tx.query("SELECT COUNT(*) FROM operations o " +
        "JOIN runs r ON r.id=o.run_id " +
        "JOIN items call ON call.id=o.tool_call_item_id AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id " +
        "JOIN derived_operation_admissions a ON a.operation_id=o.id " +
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id " +
        "AND e.tool_call_item_id=o.tool_call_item_id AND CAST(e.normalized_plan AS BLOB)=CAST(o.normalized_plan AS BLOB) " +
        "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id " +
        "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state " +
        "WHERE o.rowid=? AND o.run_id=? AND call.kind='tool_call' AND " +
        "((o.state='rejected' AND receipt.outcome='rejected') OR (o.state='cancelled' AND receipt.outcome='cancelled') OR " +
        "(o.state='timed_out' AND receipt.outcome='timed_out') OR (o.state='failed' AND receipt.outcome='failed')) " +
        "AND (SELECT COUNT(*) FROM operation_receipts other WHERE other.operation_id=o.id)=1",
        [SqlParameter.Int64Value(rowid), SqlParameter.Text(run.value)])
    if (bound.size != 1 || parseStoreInt(bound[0].required(0), "settled derived count") != 1) {
        throw IllegalStateException("completed Run still owns an unsettled or unbound derived Operation")
    }
    // Reuse the original bounded same-Run/call/root/depth proof, including
    // legacy one-edge identities and the ban on a derived Thread ToolResult.
    completedInitiatorDerivedAncestry173f(tx, rowid, run.value)
    match (allocate) {
        case Some(original) =>
            let payment = original(65536)
            let owner = PlanExecutionReadOwner204(payment)
            try {
                let scope = CompletedInitiatorPayment173e(payment, 65536, { => Result<Unit>.Ok(()) })
                requireCompletedDerivedDigestFrame240(tx, rowid, run, Some(scope))
            } catch (error: Exception) {
                owner.holdUnknownConsumer204(); throw error
            } finally { owner.closeAfterCaller204() }
        // The existing standalone Store API has no Registry allocator. It
        // keeps its synchronous codec path, without inventing another bank.
        case None => requireCompletedDerivedDigestFrame240(tx, rowid, run, None<CompletedInitiatorPayment173e>)
    }
}

private func requireCompletedDerivedDigestFrame240(tx: SqliteTransaction, rowid: Int64, run: RunId,
    payment: ?CompletedInitiatorPayment173e): Unit {
    let suffix = " FROM operations o JOIN derived_operation_admissions a ON a.operation_id=o.id WHERE o.rowid=? AND o.run_id=?"
    let args = [SqlParameter.Int64Value(rowid), SqlParameter.Text(run.value)]
    match (payment) {
        case Some(scope) => scope.raw173e(tx, "o.normalized_plan", suffix, args, { _, raw =>
            scope.withDecoded173e(raw, { =>
                let plan = decodeOperationPlan(raw)
                scope.raw173e(tx, "a.request_digest", suffix, args, { _, expected =>
                    if (plan.bindingDigest != expected) {
                        throw IllegalStateException("completed derived Operation changed its original plan binding") }
                })
            })
        })
        case None =>
            let rows = tx.query("SELECT o.normalized_plan,a.request_digest" + suffix, args)
            if (rows.size != 1 || decodeOperationPlan(rows[0].required(0)).bindingDigest != rows[0].required(1)) {
                throw IllegalStateException("completed derived Operation changed its original plan binding") }
    }
}
