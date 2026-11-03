package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*

let DIRECT_PREPARATION_REJECTION_AUDIT = "operation_direct_preparation_rejection_only"
func directPreparationEvidence(source: DirectToolCallRef, plan: NormalizedOperationPlan): AgentValue {
    objectValue([ValueField("item_id", textValue(source.canonicalItemId.value)),
        ValueField("run_id", textValue(source.runId.value)), ValueField("epoch", integerValue(source.epoch)),
        ValueField("call_id", textValue(source.call.callId)), ValueField("plan", textValue(encodeOperationPlan(plan)))])
}
func requireDirectPreparationRejection(transaction: SqliteTransaction, source: DirectToolCallRef,
    plan: NormalizedOperationPlan): Unit {
    let rows = transaction.query("SELECT call.payload,call.provenance FROM items call JOIN runs r ON r.id=? " +
        "AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id JOIN threads t ON t.id=r.thread_id AND t.active_turn_id=r.turn_id " +
        "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id AND turn.active_run_id=r.id AND turn.state='active' " +
        "WHERE call.id=? AND call.kind='tool_call' AND r.thread_id=? AND r.turn_id=? AND r.epoch=? " +
        "AND r.state='running' AND r.finished_at_millis IS NULL",
        [SqlParameter.Text(source.runId.value), SqlParameter.Text(source.canonicalItemId.value),
            SqlParameter.Text(source.threadId.value), SqlParameter.Text(source.turnId.value), SqlParameter.Int64Value(source.epoch)])
    if (rows.size != 1 || encodeOperationPlan(plan) != encodeOperationPlan(rejectedDirectPreparationPlan(source))) {
        throw IllegalStateException("Direct rejection no longer owns its current canonical call") }
    let provenance = decodeStoredProvenance(rows[0].required(1))
    if (provenance.source != "direct_tool" || provenance.runId.isNone() || provenance.runId.getOrThrow().value != source.runId.value ||
        provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != source.operationId.value ||
        !sameDirectCallOrigin(effectiveDirectCallOrigin(provenance), DirectCallOrigin.UserDirect)) {
        throw IllegalStateException("Direct rejection source is not the original UserDirect Item") }
    match (decodeStoredThreadContent(rows[0].required(0))) {
        case ThreadItemContent.ToolCall(id, name, arguments) =>
            if (id.value != source.call.callId || name != source.call.name ||
                canonicalAgentValue(arguments) != canonicalAgentValue(source.call.arguments)) {
                throw IllegalStateException("Direct rejection changed its original call") }
        case _ => throw IllegalStateException("Direct rejection is not a ToolCall") }
    if (!transaction.query("SELECT id FROM operations WHERE id=? OR tool_call_item_id=?",
            [SqlParameter.Text(source.operationId.value), SqlParameter.Text(source.canonicalItemId.value)]).isEmpty() ||
        !transaction.query("SELECT item_id FROM canonical_decision_items WHERE item_id=?",
            [SqlParameter.Text(source.canonicalItemId.value)]).isEmpty() ||
        !transaction.query("SELECT id FROM approvals WHERE operation_id=?", [SqlParameter.Text(source.operationId.value)]).isEmpty() ||
        !transaction.query("SELECT id FROM operation_receipts WHERE operation_id=?", [SqlParameter.Text(source.operationId.value)]).isEmpty() ||
        !transaction.query("SELECT id FROM audit_events WHERE operation_id=?", [SqlParameter.Text(source.operationId.value)]).isEmpty() ||
        !transaction.query("SELECT operation_id FROM derived_operation_admissions WHERE operation_id=? OR parent_operation_id=?",
            [SqlParameter.Text(source.operationId.value), SqlParameter.Text(source.operationId.value)]).isEmpty()) {
        throw IllegalStateException("Direct rejection cannot overwrite an admitted effect or approval") }
    for (row in transaction.query("SELECT payload FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result'",
        [SqlParameter.Text(source.threadId.value), SqlParameter.Text(source.turnId.value)])) {
        match (decodeStoredThreadContent(row.required(0))) {
            case ThreadItemContent.ToolResult(id, _, _, _, _) => if (id.value == source.call.callId) {
                throw IllegalStateException("Direct preparation already has a result") }
            case _ => throw IllegalStateException("canonical ToolResult is malformed") }
    }
}
func recordDirectPreparationRejection(transaction: SqliteTransaction, source: DirectToolCallRef,
    plan: NormalizedOperationPlan): Unit {
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES (?,?,?,?,?,0)",
        [SqlParameter.Text(source.threadId.value), SqlParameter.Text(source.runId.value), SqlParameter.Text(source.operationId.value),
            SqlParameter.Text(DIRECT_PREPARATION_REJECTION_AUDIT), SqlParameter.Text(encodeStoredValue(directPreparationEvidence(source, plan)))])
}
func requireNotDirectPreparationRejection(transaction: SqliteTransaction, operationId: OperationId): Unit {
    if (!transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND kind=?",
        [SqlParameter.Text(operationId.value), SqlParameter.Text(DIRECT_PREPARATION_REJECTION_AUDIT)]).isEmpty()) {
        throw IllegalStateException("unprepared Direct rejection cannot acquire execution or approval") }
    let rows = transaction.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(operationId.value)])
    if (rows.size == 1 && decodeOperationPlan(rows[0].required(0)).implementation.implementationFingerprint == DIRECT_PREPARATION_REJECTION) {
        throw IllegalStateException("Direct rejection plan cannot acquire execution or approval") }
}
func requireDirectPreparationRejectionOutcome(transaction: SqliteTransaction, transition: ThreadTransition,
    item: ThreadItem, receipt: VNextOperationReceipt): Unit {
    let rows = transaction.query("SELECT o.normalized_plan,o.tool_call_item_id,o.state,call.payload,call.provenance,r.epoch,r.state " +
        "FROM operations o JOIN runs r ON r.id=o.run_id JOIN items call ON call.id=o.tool_call_item_id " +
        "AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id WHERE o.id=? AND o.run_id=?",
        [SqlParameter.Text(receipt.operationId.value), SqlParameter.Text(item.provenance.runId.getOrThrow().value)])
    if (rows.size != 1) { throw IllegalStateException("settling Direct operation is missing") }
    let row = rows[0]; let plan = decodeOperationPlan(row.required(0))
    let evidence = transaction.query("SELECT thread_id,run_id,payload FROM audit_events WHERE operation_id=? AND kind=?",
        [SqlParameter.Text(receipt.operationId.value), SqlParameter.Text(DIRECT_PREPARATION_REJECTION_AUDIT)])
    if (evidence.isEmpty() && plan.implementation.implementationFingerprint != DIRECT_PREPARATION_REJECTION) { return }
    let provenance = decodeStoredProvenance(row.required(4))
    let call = match (decodeStoredThreadContent(row.required(3))) {
        case ThreadItemContent.ToolCall(id, name, args) => ToolCall(id.value, name, args)
        case _ => throw IllegalStateException("Direct rejection source kind changed") }
    let expected = objectValue([ValueField("item_id", textValue(row.required(1))),
        ValueField("run_id", textValue(item.provenance.runId.getOrThrow().value)),
        ValueField("epoch", integerValue(transition.before.activeEpoch)), ValueField("call_id", textValue(call.callId)),
        ValueField("plan", textValue(encodeOperationPlan(plan)))])
    if (evidence.size != 1 || evidence[0].required(0) != item.threadId.value ||
        evidence[0].required(1) != item.provenance.runId.getOrThrow().value || evidence[0].required(2) != encodeStoredValue(expected) ||
        plan.implementation.implementationFingerprint != DIRECT_PREPARATION_REJECTION || row.required(2) != "prepared" ||
        row.required(5) != transition.before.activeEpoch.toString() || row.required(6) != "running" || transition.nextRunState != "running" ||
        encodeOperationPlan(plan) != encodeOperationPlan(rejectedDirectPreparationPlan(item.provenance.runId.getOrThrow(), ItemId(row.required(1)), call)) ||
        provenance.runId.isNone() || provenance.runId.getOrThrow().value != item.provenance.runId.getOrThrow().value ||
        provenance.source != "direct_tool" || provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != receipt.operationId.value ||
        !sameDirectCallOrigin(effectiveDirectCallOrigin(provenance), DirectCallOrigin.UserDirect) ||
        !transaction.query("SELECT id FROM approvals WHERE operation_id=?", [SqlParameter.Text(receipt.operationId.value)]).isEmpty() ||
        !transaction.query("SELECT operation_id FROM derived_operation_admissions WHERE operation_id=? OR parent_operation_id=?",
            [SqlParameter.Text(receipt.operationId.value), SqlParameter.Text(receipt.operationId.value)]).isEmpty() ||
        receipt.outcome != OperationOutcome.Rejected || canonicalAgentValue(receipt.detail) != canonicalAgentValue(rejectedDirectPreparationOutput()) ||
        canonicalAgentValue(receipt.verification) != canonicalAgentValue(objectValue([
            ValueField("known_completion", boolValue(true)), ValueField("stage", textValue("prepared"))])) ||
        !transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'",
            [SqlParameter.Text(receipt.operationId.value)]).isEmpty()) {
        throw IllegalStateException("Direct rejection is not an exact known unexecuted terminal") }
    match (item.content) { case ThreadItemContent.ToolResult(id, op, receiptId, output, isError) =>
        if (id.value != call.callId || op.value != receipt.operationId.value || receiptId != receipt.receiptId || !isError ||
            canonicalAgentValue(output) != canonicalAgentValue(rejectedDirectPreparationOutput())) {
            throw IllegalStateException("Direct rejection result changed") }
        case _ => throw IllegalStateException("Direct rejection did not produce its actual result") }
}
