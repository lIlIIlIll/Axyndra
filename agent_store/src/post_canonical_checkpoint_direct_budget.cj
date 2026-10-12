package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Accounting is restrictive data only. The actual Direct Source, full
// canonical call/plan/result/reserved Receipt and current Thread remain
// independently checked by the original complete readback in the SAME TX.
func requirePostCanonicalCheckpointDirectBudget(tx: SqliteTransaction, thread: ThreadRecord,
    run: RunId, epoch: Int64, boundary: DirectPostCanonicalProjectionBoundary,
    owner: LogicalJsonOwnerReservation, retained: Int64,
    allocate: (Int64) -> LogicalJsonOwnerReservation, guard: () -> Result<Unit>): Unit {
    let source = boundary.source; let budget = boundary.budget; let usage = budget.snapshot()
    if (source.threadId.value != thread.id.value || source.runId.value != run.value || source.epoch != epoch ||
        source.turnId.value != thread.activeTurnId.getOrThrow().value || usage.activeTools != 0 ||
        usage.turns != 0 || usage.modelRequests != 0 || usage.drainModelRequests != 0 ||
        usage.inputTokens != 0 || usage.outputTokens != 0 || usage.costMicros != 0 || usage.toolCalls < 1) {
        throw IllegalStateException("checkpoint Direct accounting does not match its actual Run") }
    match (source.origin) { case DirectCallOrigin.UserDirect => ()
        case _ => throw IllegalStateException("checkpoint Direct accounting origin changed") }
    let args = [SqlParameter.Text(run.value), SqlParameter.Text(thread.id.value), SqlParameter.Int64Value(epoch)]
    withLivePolicyStoredValueOwned(tx, "budget", " FROM runs WHERE id=? AND thread_id=? AND epoch=? AND state='running'",
        args, allocate, guard, owner, retained, { raw: String =>
            let actual = decodeStoredValue(raw)
            if (!httpIntentExactFields(actual, ["run_kind", "read_only", "max_tool_calls", "max_concurrent_tools", "deadline_millis"]) ||
                postCanonicalCheckpointDirectText(actual, "run_kind") != "direct_tool" ||
                actual.field("read_only").getOrThrow().unifiedKind != ValueKind.Boolean || actual.field("read_only").getOrThrow().asBool() ||
                postCanonicalCheckpointDirectInteger(actual, "max_tool_calls") != budget.maxToolCalls ||
                postCanonicalCheckpointDirectInteger(actual, "max_concurrent_tools") != budget.maxConcurrentTools ||
                postCanonicalCheckpointDirectInteger(actual, "deadline_millis") != budget.deadlineMillis ||
                usage.toolCalls > budget.maxToolCalls) {
                throw IllegalStateException("checkpoint actual durable Direct limits changed") }
        })
    let ops = tx.query("SELECT COUNT(*) FROM operations WHERE run_id=?", [SqlParameter.Text(run.value)])
    if (ops.size != 1 || journalStreamInteger(ops[0].required(0)) != usage.toolCalls ||
        !tx.query("SELECT 1 FROM operations o LEFT JOIN operation_receipts receipt ON receipt.operation_id=o.id " +
            "LEFT JOIN operation_effect_records e ON e.operation_id=o.id WHERE o.run_id=? AND " +
            "(o.state!='committed' OR receipt.id IS NULL OR receipt.outcome!='completed' OR receipt.id!=e.reserved_receipt_id " +
            "OR e.operation_id IS NULL OR NOT EXISTS(SELECT 1 FROM items i WHERE i.id=e.reserved_result_item_id " +
            "AND i.kind='tool_result'))", [SqlParameter.Text(run.value)]).isEmpty() ||
        !tx.query("SELECT 1 FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id WHERE o.run_id=?",
            [SqlParameter.Text(run.value)]).isEmpty() ||
        !tx.query("SELECT 1 FROM model_attempts WHERE run_id=?", [SqlParameter.Text(run.value)]).isEmpty() ||
        !tx.query("SELECT 1 FROM run_model_usage WHERE run_id=?", [SqlParameter.Text(run.value)]).isEmpty()) {
        throw IllegalStateException("checkpoint Direct accounting has unknown or unretired canonical work") }
    journalStreamCheck(guard)
}
private func postCanonicalCheckpointDirectText(value: AgentValue, name: String): String {
    let field = value.field(name).getOrThrow()
    if (field.unifiedKind != ValueKind.Text) { throw IllegalStateException("Direct budget text kind changed") }
    field.text
}
private func postCanonicalCheckpointDirectInteger(value: AgentValue, name: String): Int64 {
    let field = value.field(name).getOrThrow()
    if (field.unifiedKind != ValueKind.Number) { throw IllegalStateException("Direct budget integer kind changed") }
    let raw = field.asNumberText(); let result = journalStreamInteger(raw)
    if (result.toString() != raw || result < 0) { throw IllegalStateException("Direct budget integer spelling changed") }
    result
}
