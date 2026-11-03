package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

// This is an additional proof inside the existing derived-operation transaction.
// It neither starts a child nor treats a worker's intent ID as a capability.
func requirePluginChildScope111(transaction: SqliteTransaction, run: RunId,
    thread: String, epoch: String, item: String, plan: NormalizedOperationPlan): Unit {
    let intent = parsePluginChildStartIntent111(plan.canonicalArguments).value().getOrThrow()
    let binding = intent.binding()
    channelStoreRequire(httpIntentText(binding, "thread_id") == thread &&
        httpIntentText(binding, "run_id") == run.value &&
        binding.field("epoch").getOrThrow().asNumberText() == epoch)
    let calls = transaction.query("SELECT payload FROM items WHERE id=? AND thread_id=? AND kind='tool_call' LIMIT 2",
        [SqlParameter.Text(item), SqlParameter.Text(thread)])
    channelStoreRequire(calls.size == 1)
    match (decodeStoredThreadContent(calls[0].required(0))) {
        case ThreadItemContent.ToolCall(id, name, _) =>
            channelStoreRequire(id.value == httpIntentText(binding, "parent_call_id") &&
                name == httpIntentText(binding, "contribution"))
        case _ => throw IllegalStateException("child parent is not a canonical ToolCall")
    }
    let lanes = transaction.query("SELECT binding.lane_id FROM run_lane_bindings binding " +
        "JOIN runs actual ON actual.id=binding.run_id AND actual.thread_id=binding.thread_id " +
        "JOIN threads thread ON thread.id=actual.thread_id AND thread.active_turn_id=actual.turn_id " +
        "JOIN turns active ON active.id=actual.turn_id AND active.thread_id=actual.thread_id " +
        "AND active.active_run_id=actual.id AND active.state='active' " +
        "JOIN item_tree_edges edge ON edge.thread_id=binding.thread_id AND edge.lane_id=binding.lane_id " +
        "JOIN lanes lane ON lane.thread_id=binding.thread_id AND lane.lane_id=binding.lane_id " +
        "WHERE binding.run_id=? AND binding.thread_id=? AND edge.item_id=? AND lane.status='open' LIMIT 2",
        [SqlParameter.Text(run.value), SqlParameter.Text(thread), SqlParameter.Text(item)])
    channelStoreRequire(lanes.size == 1 && lanes[0].required(0) == httpIntentText(binding, "lane_id"))
}

// Called only after the common Store verifier has checked the supplied actual
// Direct/Committed source with isActiveDerivedRoot. Require the hidden child's
// own executing state and physical handoff; a prepared plan cannot launch a Run.
func requirePluginChildExecution111(transaction: SqliteTransaction, source: OperationRootSource,
    parent: OperationId, child: OperationId, run: RunId, thread: ThreadId, epoch: Int64,
    plan: NormalizedOperationPlan): Unit {
    channelStoreRequire(epoch > 0 && isPluginChildStartPlan111(plan))
    let rows = transaction.query("SELECT child.tool_call_item_id,parent.normalized_plan FROM operations child " +
        "JOIN operation_state_registers state ON state.operation_id=child.id AND state.state=child.state " +
        "JOIN operation_effect_records effect ON effect.operation_id=child.id AND effect.run_id=child.run_id " +
        "AND effect.tool_call_item_id=child.tool_call_item_id AND effect.normalized_plan=child.normalized_plan " +
        "JOIN derived_operation_admissions derived ON derived.operation_id=child.id " +
        "JOIN operations parent ON parent.id=derived.parent_operation_id AND parent.run_id=child.run_id " +
        "AND parent.tool_call_item_id=child.tool_call_item_id " +
        "JOIN runs actual ON actual.id=child.run_id " +
        "JOIN audit_events handoff ON handoff.operation_id=child.id AND handoff.run_id=child.run_id " +
        "AND handoff.thread_id=actual.thread_id AND handoff.kind='operation_execution_handoff' " +
        "WHERE child.id=? AND parent.id=? AND child.run_id=? AND child.state='executing' " +
        "AND child.normalized_plan=? AND actual.thread_id=? AND actual.epoch=? AND actual.state='running' " +
        "AND derived.request_key=? AND derived.request_digest=? " +
        "AND NOT EXISTS(SELECT 1 FROM operation_receipts receipt WHERE receipt.operation_id=child.id) LIMIT 2",
        [SqlParameter.Text(child.value), SqlParameter.Text(parent.value), SqlParameter.Text(run.value),
            SqlParameter.Text(encodeOperationPlan(plan)), SqlParameter.Text(thread.value), SqlParameter.Int64Value(epoch),
            SqlParameter.Text(exactServiceRequestKey(source.callId(), plan)), SqlParameter.Text(plan.bindingDigest)])
    channelStoreRequire(rows.size == 1 && rows[0].required(0) == source.itemId().value &&
        pluginChildParentAllows111(decodeOperationPlan(rows[0].required(1)), plan))
    requirePluginChildScope111(transaction, run, thread.value, epoch.toString(), rows[0].required(0), plan)
    let input=plan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow()
    if(input.field("resume").isSome()) {
        let actualParent=decodeOperationPlan(rows[0].required(1))
        channelStoreRequire(actualParent.contextReadFacts.size==1 && pluginPeerResumeParentMatches111(actualParent.canonicalArguments,input))
        requireContextReadFactConsumption(transaction,parent,run,source.itemId(),actualParent)
        let link=actualParent.contextReadFacts[0]
        let fact=requireContextReadFact(transaction,link.operationId,run)
        let read=transaction.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=? LIMIT 2",
            [SqlParameter.Text(link.operationId.value),SqlParameter.Text(run.value)])
        channelStoreRequire(read.size==1)
        let readPlan=decodeOperationPlan(read[0].required(0));let resume=input.field("resume").getOrThrow()
        channelStoreRequire(isContextReadPlan(readPlan) && pluginPeerReadAuthority111(readPlan) &&
            canonicalAgentValue(readPlan.canonicalArguments)==canonicalAgentValue(resume.field("read_request").getOrThrow()) &&
            canonicalAgentValue(fact.output())==canonicalAgentValue(resume.field("read_fact").getOrThrow()))
    }
}

func requirePluginChildStartReceipt111(transaction: SqliteTransaction, source: OperationRootSource,
    parent: OperationId, wait: OperationId, run: RunId, thread: ThreadId, epoch: Int64,
    plan: NormalizedOperationPlan, verifyStart: (OperationId, NormalizedOperationPlan) -> Unit): VNextOperationReceipt {
    requirePluginChildExecution111(transaction, source, parent, wait, run, thread, epoch, plan)
    let intent = plan.canonicalArguments.field("intent").getOrThrow()
    channelStoreRequire(httpIntentText(intent, "service") == "child.wait")
    let id = httpIntentText(intent.field("input").getOrThrow(), "start_intent_id")
    let rows = transaction.query("SELECT child.id,child.normalized_plan,parent.normalized_plan," +
        "receipt.id,receipt.detail,receipt.verification,receipt.created_at_millis,derived.request_digest " +
        "FROM derived_operation_admissions derived JOIN operations child ON child.id=derived.operation_id " +
        "JOIN operations parent ON parent.id=derived.parent_operation_id AND parent.run_id=child.run_id " +
        "AND parent.tool_call_item_id=child.tool_call_item_id " +
        "JOIN operation_state_registers state ON state.operation_id=child.id AND state.state=child.state " +
        "JOIN operation_effect_records effect ON effect.operation_id=child.id AND effect.run_id=child.run_id " +
        "AND effect.tool_call_item_id=child.tool_call_item_id AND effect.normalized_plan=child.normalized_plan " +
        "JOIN operation_receipts receipt ON receipt.operation_id=child.id AND receipt.outcome='completed' " +
        "AND receipt.id=effect.reserved_receipt_id " +
        "JOIN audit_events handoff ON handoff.operation_id=child.id AND handoff.run_id=child.run_id " +
        "AND handoff.thread_id=? AND handoff.kind='operation_execution_handoff' " +
        "WHERE parent.id=? AND child.run_id=? AND child.tool_call_item_id=? AND child.state='committed' " +
        "AND derived.request_key=? LIMIT 2",
        [SqlParameter.Text(thread.value),SqlParameter.Text(parent.value),SqlParameter.Text(run.value),
            SqlParameter.Text(source.itemId().value),SqlParameter.Text("child-service:"+source.callId()+":"+id)])
    channelStoreRequire(rows.size == 1)
    let row=rows[0];let childPlan=decodeOperationPlan(row.required(1));let parentPlan=decodeOperationPlan(row.required(2))
    channelStoreRequire(isPluginChildStartPlan111(childPlan) && pluginChildParentAllows111(parentPlan,childPlan) &&
        httpIntentText(childPlan.canonicalArguments.field("intent").getOrThrow(),"id")==id &&
        httpIntentText(childPlan.canonicalArguments.field("intent").getOrThrow(),"service")=="child.start" &&
        canonicalAgentValue(childPlan.canonicalArguments.field("binding").getOrThrow())==
            canonicalAgentValue(plan.canonicalArguments.field("binding").getOrThrow()) &&
        row.required(3)=="receipt-"+row.required(0) && row.required(7)==childPlan.bindingDigest)
    verifyStart(OperationId(row.required(0)),childPlan)
    requirePluginChildScope111(transaction,run,thread.value,epoch.toString(),source.itemId().value,childPlan)
    let detail=decodeStoredValue(row.required(4));let verification=decodeStoredValue(row.required(5))
    channelStoreRequire(httpIntentText(detail,"schema")=="axyndra.child-launch-result/v1" &&
        httpIntentText(detail,"run_id")!="" && httpIntentText(detail,"thread_id")!="" && httpIntentText(detail,"child_id")!="" &&
        httpIntentText(verification,"parent_operation_id")==parent.value &&
        httpIntentText(verification,"request_key")=="child-service:"+source.callId()+":"+id &&
        httpIntentText(verification,"request_id")==id && httpIntentText(verification,"service")=="child.start")
    VNextOperationReceipt(row.required(3),OperationId(row.required(0)),OperationOutcome.Completed,
        detail,verification,parseStoreInt(row.required(6),"child launch Receipt timestamp"))
}
