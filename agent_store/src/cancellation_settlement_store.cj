package agent_store

import agent_domain.*
import agent_runtime.*
import std.time.*

let CANCELLATION_SETTLEMENT_AUDIT = "operation_cancellation_settlement_only"

func cancellationSettlementEvidence(runId: RunId, itemId: ItemId, plan: NormalizedOperationPlan,
    epoch: Int64, decisionId: String, scopedCallId: String, callId: String): AgentValue {
    objectValue([
        ValueField("run_id", textValue(runId.value)), ValueField("item_id", textValue(itemId.value)),
        ValueField("epoch", textValue(epoch.toString())), ValueField("plan_digest", textValue(plan.bindingDigest)),
        ValueField("decision_id", textValue(decisionId)), ValueField("scoped_call_id", textValue(scopedCallId)),
        ValueField("call_id", textValue(callId)),
        ValueField("output", cancelledUnpreparedToolOutput())
    ])
}

func requireCancellationCall(transaction: SqliteTransaction, operationId: OperationId,
    runId: RunId, source: CommittedToolCallRef, plan: NormalizedOperationPlan, epoch: Int64): Unit {
    let rows = transaction.query("SELECT item.payload,item.provenance,r.thread_id,r.turn_id FROM items item " +
        "JOIN runs r ON r.id=? AND item.thread_id=r.thread_id AND item.turn_id=r.turn_id " +
        "JOIN threads thread ON thread.id=r.thread_id AND thread.active_turn_id=r.turn_id " +
        "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id AND turn.active_run_id=r.id AND turn.state='active' " +
        "JOIN canonical_decision_items c ON c.item_id=item.id " +
        "JOIN model_decisions d ON d.id=c.decision_id " +
        "JOIN model_decision_blocks b ON b.id=c.decision_block_id AND b.decision_id=d.id " +
        "JOIN model_attempts attempt ON attempt.id=d.attempt_id AND attempt.run_id=r.id " +
        "WHERE item.id=? AND item.kind='tool_call' AND r.state='cancelling' AND r.epoch=? AND r.finished_at_millis IS NULL " +
        "AND d.id=? AND b.scoped_tool_call_id=? AND d.validation_status='validated' " +
        "AND d.canonical_committed_at_millis IS NOT NULL",
        [SqlParameter.Text(runId.value), SqlParameter.Text(source.canonicalItemId.value), SqlParameter.Int64Value(epoch),
            SqlParameter.Text(source.decisionId.value), SqlParameter.Text(source.scopedToolCallId.value)])
    if (rows.size != 1) { throw IllegalStateException("cancellation settlement lost the current Run/epoch") }
    let provenance = decodeStoredProvenance(rows[0].required(1))
    if (provenance.runId.isNone() || provenance.runId.getOrThrow().value != runId.value || provenance.operationId.isSome()) {
        throw IllegalStateException("cancellation call belongs to another canonical Run")
    }
    match (decodeStoredThreadContent(rows[0].required(0))) {
        case ThreadItemContent.ToolCall(callId, name, arguments) =>
            if (callId.value != source.block.callId || name != source.block.name ||
                canonicalAgentValue(arguments) != canonicalAgentValue(source.block.arguments) ||
                encodeOperationPlan(plan) != encodeOperationPlan(cancelledUnpreparedOperationPlan(runId,
                    source.canonicalItemId, ToolCall(callId.value, name, arguments)))) {
                throw IllegalStateException("cancellation settlement changed the original canonical ToolCall")
            }
        case _ => throw IllegalStateException("cancellation source is not a ToolCall")
    }
    // No executor/approval/child obligation may be overwritten by this path.
    let previous = transaction.query("SELECT id,state FROM operations WHERE tool_call_item_id=?",
        [SqlParameter.Text(source.canonicalItemId.value)])
    if (!previous.isEmpty()) {
        if (previous.size != 1 || previous[0].required(0) != operationId.value || previous[0].required(1) != "prepared" ||
            transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND kind=?",
                [SqlParameter.Text(operationId.value), SqlParameter.Text(CANCELLATION_SETTLEMENT_AUDIT)]).size != 1) {
            throw IllegalStateException("cancellation settlement cannot replace a prepared or executed operation")
        }
    }
    if (!transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'",
            [SqlParameter.Text(operationId.value)]).isEmpty() ||
        !transaction.query("SELECT id FROM approvals WHERE operation_id=?", [SqlParameter.Text(operationId.value)]).isEmpty() ||
        !transaction.query("SELECT id FROM operation_receipts WHERE operation_id=?", [SqlParameter.Text(operationId.value)]).isEmpty() ||
        !transaction.query("SELECT operation_id FROM derived_operation_admissions WHERE operation_id=? OR parent_operation_id=?",
            [SqlParameter.Text(operationId.value), SqlParameter.Text(operationId.value)]).isEmpty()) {
        throw IllegalStateException("cancellation settlement is restricted to an unexecuted unapproved call")
    }
    let results = transaction.query("SELECT payload FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result'",
        [SqlParameter.Text(rows[0].required(2)), SqlParameter.Text(rows[0].required(3))])
    for (row in results) {
        match (decodeStoredThreadContent(row.required(0))) {
            case ThreadItemContent.ToolResult(callId, _, _, _, _) => if (callId.value == source.block.callId) {
                throw IllegalStateException("canonical call already has a terminal result")
            }
            case _ => throw IllegalStateException("invalid canonical ToolResult")
        }
    }
}

func recordCancellationSettlement(transaction: SqliteTransaction, operationId: OperationId, runId: RunId,
    source: CommittedToolCallRef, plan: NormalizedOperationPlan, epoch: Int64): Unit {
    let expected = encodeStoredValue(cancellationSettlementEvidence(runId, source.canonicalItemId, plan, epoch,
        source.decisionId.value, source.scopedToolCallId.value, source.block.callId))
    let rows = transaction.query("SELECT thread_id FROM runs WHERE id=?", [SqlParameter.Text(runId.value)])
    if (rows.size != 1) { throw IllegalStateException("cancellation Run disappeared") }
    let existing = transaction.query("SELECT thread_id,run_id,payload FROM audit_events WHERE operation_id=? AND kind=?",
        [SqlParameter.Text(operationId.value), SqlParameter.Text(CANCELLATION_SETTLEMENT_AUDIT)])
    if (existing.isEmpty()) {
        transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES (?,?,?,?,?,?)",
            [SqlParameter.Text(rows[0].required(0)), SqlParameter.Text(runId.value), SqlParameter.Text(operationId.value),
                SqlParameter.Text(CANCELLATION_SETTLEMENT_AUDIT), SqlParameter.Text(expected),
                SqlParameter.Int64Value(DateTime.nowUTC().toUnixTimeStamp().toMilliseconds())])
    } else if (existing.size != 1 || existing[0].required(0) != rows[0].required(0) ||
        existing[0].required(1) != runId.value || existing[0].required(2) != expected) {
        throw IllegalStateException("cancellation settlement evidence changed")
    }
}

// Used by ordinary prepare, wait/transition, execution and handoff. The plan
// tag only narrows access; absence or tampering of the audit cannot reopen I/O.
func requireExecutableOperation(transaction: SqliteTransaction, operationId: OperationId): Unit {
    requireNotDirectPreparationRejection(transaction, operationId)
    if (!transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND kind=?",
        [SqlParameter.Text(operationId.value), SqlParameter.Text(CANCELLATION_SETTLEMENT_AUDIT)]).isEmpty()) {
        throw IllegalStateException("cancellation-only operation cannot enter execution or approval")
    }
    let rows = transaction.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(operationId.value)])
    if (rows.size == 1 && decodeOperationPlan(rows[0].required(0)).implementation.implementationFingerprint == CANCELLATION_SETTLEMENT_IMPLEMENTATION) {
        throw IllegalStateException("cancellation-only plan cannot enter execution or approval")
    }
}

func requireCancellationSettlementOutcome(transaction: SqliteTransaction, transition: ThreadTransition,
    item: ThreadItem, receipt: VNextOperationReceipt): Unit {
    let run = item.provenance.runId.getOrThrow()
    let rows = transaction.query("SELECT o.normalized_plan,o.tool_call_item_id,r.epoch,r.state,call.payload " +
        "FROM operations o JOIN runs r ON r.id=o.run_id JOIN items call ON call.id=o.tool_call_item_id " +
        "WHERE o.id=? AND o.run_id=?", [SqlParameter.Text(receipt.operationId.value), SqlParameter.Text(run.value)])
    if (rows.size != 1) { throw IllegalStateException("settling Operation disappeared") }
    let plan = decodeOperationPlan(rows[0].required(0))
    let evidence = transaction.query("SELECT thread_id,run_id,payload FROM audit_events WHERE operation_id=? AND kind=?",
        [SqlParameter.Text(receipt.operationId.value), SqlParameter.Text(CANCELLATION_SETTLEMENT_AUDIT)])
    if (evidence.isEmpty() && plan.implementation.implementationFingerprint != CANCELLATION_SETTLEMENT_IMPLEMENTATION) { return }
    // Re-read the actual canonical source, not just the audit's descriptive IDs.
    // This branch never applies to ordinary Direct or prepared operations.
    let sources = transaction.query("SELECT d.id,b.scoped_tool_call_id,call.provenance FROM operations o " +
        "JOIN runs r ON r.id=o.run_id JOIN threads thread ON thread.id=r.thread_id AND thread.active_turn_id=r.turn_id " +
        "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id AND turn.active_run_id=r.id AND turn.state='active' " +
        "JOIN items call ON call.id=o.tool_call_item_id AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id " +
        "JOIN decision_operations source ON source.operation_id=o.id " +
        "JOIN model_decisions d ON d.id=source.decision_id " +
        "JOIN model_attempts attempt ON attempt.id=d.attempt_id AND attempt.run_id=r.id " +
        "JOIN model_decision_blocks b ON b.decision_id=d.id AND b.scoped_tool_call_id=source.scoped_tool_call_id " +
        "JOIN canonical_decision_items c ON c.decision_id=d.id AND c.decision_block_id=b.id AND c.item_id=call.id " +
        "JOIN operation_effect_records effect ON effect.operation_id=o.id AND effect.run_id=o.run_id " +
        "AND effect.tool_call_item_id=o.tool_call_item_id AND effect.normalized_plan=o.normalized_plan " +
        "JOIN operation_state_registers register ON register.operation_id=o.id AND register.state='prepared' " +
        "WHERE o.id=? AND r.id=? AND r.thread_id=? AND r.turn_id=? AND r.epoch=? " +
        "AND r.state='cancelling' AND r.finished_at_millis IS NULL AND o.state='prepared' AND call.kind='tool_call' " +
        "AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NOT NULL",
        [SqlParameter.Text(receipt.operationId.value), SqlParameter.Text(run.value),
            SqlParameter.Text(item.threadId.value), SqlParameter.Text(item.turnId.value),
            SqlParameter.Int64Value(transition.before.activeEpoch)])
    if (sources.size != 1) { throw IllegalStateException("cancellation settlement lost its exact canonical Decision source") }
    let provenance = decodeStoredProvenance(sources[0].required(2))
    if (provenance.runId.isNone() || provenance.runId.getOrThrow().value != run.value || provenance.operationId.isSome()) {
        throw IllegalStateException("cancellation settlement changed canonical call provenance")
    }
    let call = match (decodeStoredThreadContent(rows[0].required(4))) {
        case ThreadItemContent.ToolCall(id, name, arguments) => ToolCall(id.value, name, arguments)
        case _ => throw IllegalStateException("cancellation-only source is not a ToolCall")
    }
    let expected = encodeStoredValue(cancellationSettlementEvidence(run, ItemId(rows[0].required(1)), plan,
        transition.before.activeEpoch, sources[0].required(0), sources[0].required(1), call.callId))
    if (evidence.size != 1 || evidence[0].required(0) != item.threadId.value || evidence[0].required(1) != run.value ||
        evidence[0].required(2) != expected || rows[0].required(2) != transition.before.activeEpoch.toString() ||
        rows[0].required(3) != "cancelling" || transition.nextRunState != "cancelling" || receipt.outcome != OperationOutcome.Rejected ||
        canonicalAgentValue(receipt.detail) != canonicalAgentValue(cancelledUnpreparedToolOutput()) ||
        canonicalAgentValue(receipt.verification) != canonicalAgentValue(objectValue([
            ValueField("known_completion", boolValue(true)), ValueField("stage", textValue("prepared"))])) ||
        !transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'",
            [SqlParameter.Text(receipt.operationId.value)]).isEmpty()) {
        throw IllegalStateException("cancellation-only outcome is not the exact unexecuted rejection")
    }
    if (encodeOperationPlan(plan) != encodeOperationPlan(cancelledUnpreparedOperationPlan(run, ItemId(rows[0].required(1)), call))) {
        throw IllegalStateException("cancellation-only plan changed before settlement")
    }
    match (item.content) {
        case ThreadItemContent.ToolResult(id, operationId, receiptId, output, isError) =>
            if (id.value != call.callId || operationId.value != receipt.operationId.value || receiptId != receipt.receiptId ||
                !isError || canonicalAgentValue(output) != canonicalAgentValue(cancelledUnpreparedToolOutput())) {
                throw IllegalStateException("cancellation-only ToolResult changed call, error, or receipt")
            }
        case _ => throw IllegalStateException("cancellation-only settlement requires its canonical ToolResult")
    }
}
