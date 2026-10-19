package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

// Read-only reconstruction of an existing canonical execution. Neither this
// query nor an old startup Receipt reserves a new operation or grants I/O.
func requireChannelInvocationRoot(
    transaction: SqliteTransaction, operationId: OperationId, runId: RunId,
    threadId: ThreadId, epoch: Int64, source: OperationRootSource,
    plan: NormalizedOperationPlan, binding: AgentValue, startupReads!: ?ChannelStartupReadMemo = None,
    frozenDirectArguments!: ?AgentValue = None
): Unit {
    if (frozenDirectArguments.isSome()) {
        match (source) { case OperationRootSource.Direct(value) =>
            match (value.origin) { case DirectCallOrigin.UserDirect => (); case _ => channelStoreRequire(false) }
            case _ => channelStoreRequire(false) }
    }
    channelStoreRequire(epoch > 0 && isFrozenChannelParentPlan(plan) &&
        httpIntentText(binding, "target_thread_id") == managedJobServiceThread(transaction,
            source.itemId(), threadId.value, runId, binding) &&
        canonicalAgentValue(plan.canonicalArguments.field("host_plan").getOrThrow()
            .field("binding").getOrThrow()) == canonicalAgentValue(binding))
    let rows = transaction.query(
        "SELECT r.turn_id,item.payload,item.provenance,handoff.payload FROM operations o " +
        "JOIN runs r ON r.id=o.run_id JOIN threads thread ON thread.id=r.thread_id " +
        "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id " +
        "JOIN items item ON item.id=o.tool_call_item_id AND item.thread_id=r.thread_id AND item.turn_id=r.turn_id " +
        "JOIN operation_effect_records effect ON effect.operation_id=o.id AND effect.run_id=o.run_id " +
        "AND effect.tool_call_item_id=o.tool_call_item_id AND effect.normalized_plan=o.normalized_plan " +
        "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state " +
        "JOIN audit_events handoff ON handoff.operation_id=o.id AND handoff.run_id=r.id AND handoff.thread_id=r.thread_id " +
        "AND handoff.kind='operation_execution_handoff' " +
        "WHERE o.id=? AND o.run_id=? AND o.normalized_plan=? AND o.state='executing' " +
        "AND item.id=? AND item.kind='tool_call' AND r.thread_id=? AND r.epoch=? AND r.state='running' " +
        "AND thread.active_turn_id=r.turn_id AND turn.active_run_id=r.id " +
        "AND NOT EXISTS (SELECT 1 FROM derived_operation_admissions nested WHERE nested.operation_id=o.id)",
        [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value), SqlParameter.Text(encodeOperationPlan(plan)),
        SqlParameter.Text(source.itemId().value), SqlParameter.Text(threadId.value), SqlParameter.Int64Value(epoch)])
    channelStoreRequire(rows.size == 1)
    let row = rows[0]
    channelStoreRequire(row.required(3) == encodeStoredValue(objectValue([
        ValueField("channel_parent_epoch", textValue(epoch.toString())),
        ValueField("parent_plan_digest", textValue(plan.bindingDigest))])))
    let provenance = decodeStoredProvenance(row.required(2))
    channelStoreRequire(provenance.runId.isSome() && provenance.runId.getOrThrow().value == runId.value)
    match (decodeStoredThreadContent(row.required(1))) {
        case ThreadItemContent.ToolCall(id, name, arguments) =>
            channelStoreRequire(id.value == source.callId() && name == source.toolName() && name == plan.toolName)
            match (source) {
                case OperationRootSource.Direct(value) =>
                    channelStoreRequire(value.operationId.value == operationId.value && value.runId.value == runId.value &&
                        value.threadId.value == threadId.value && value.epoch == epoch && value.turnId.value == row.required(0) &&
                        canonicalAgentValue(frozenDirectArguments ?? value.call.arguments) == canonicalAgentValue(arguments))
                case OperationRootSource.Committed(value) =>
                    channelStoreRequire(value.block.callId == id.value && value.block.name == name)
            }
        case _ => throw IllegalStateException("channel root has no canonical ToolCall")
    }
    match (source) {
        case OperationRootSource.Direct(value) =>
            channelStoreRequire(provenance.source == "direct_tool" && provenance.operationId.isSome() &&
                provenance.operationId.getOrThrow().value == operationId.value &&
                transaction.query("SELECT operation_id FROM decision_operations WHERE operation_id=?",
                    [SqlParameter.Text(operationId.value)]).isEmpty() &&
                transaction.query("SELECT item_id FROM canonical_decision_items WHERE item_id=?",
                    [SqlParameter.Text(source.itemId().value)]).isEmpty())
            requireHostServiceOriginBinding(transaction, operationId, runId, source.itemId(), expectedOrigin: Some(value.origin))
        case OperationRootSource.Committed(value) =>
            channelStoreRequire(provenance.source != "direct_tool" && provenance.operationId.isNone())
            let decisions = transaction.query(
                "SELECT d.id FROM decision_operations source JOIN model_decisions d ON d.id=source.decision_id " +
                "JOIN model_decision_blocks block ON block.decision_id=d.id AND block.scoped_tool_call_id=source.scoped_tool_call_id " +
                "JOIN canonical_decision_items item ON item.decision_id=d.id AND item.decision_block_id=block.id " +
                "JOIN model_attempts attempt ON attempt.id=d.attempt_id " +
                "WHERE source.operation_id=? AND source.decision_id=? AND source.scoped_tool_call_id=? " +
                "AND item.item_id=? AND attempt.run_id=? AND d.validation_status='validated' " +
                "AND d.canonical_committed_at_millis IS NOT NULL",
                [SqlParameter.Text(operationId.value), SqlParameter.Text(value.decisionId.value),
                SqlParameter.Text(value.scopedToolCallId.value), SqlParameter.Text(source.itemId().value), SqlParameter.Text(runId.value)])
            channelStoreRequire(decisions.size == 1)
            requireHostServiceOriginBinding(transaction, operationId, runId, source.itemId())
    }
    requireServicePayloadPlan(transaction, runId, source.itemId(), plan)
    requireManagedJobPlan(transaction, source.itemId(), plan)
    match (startupReads) {
        case Some(value) => value.validate(transaction, binding, plan)
        case None => requireChannelStartupReceipt(transaction, binding, plan)
    }
}
