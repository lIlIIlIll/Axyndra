package agent_store
import agent_domain.*
import std.convert.*
import yjson.*
import yjson_support.*

// Called from the same original requireExactParentIntent flow on actual
// child admission, executing, handoff and settlement. This only proves
// fixed-row data access; it cannot manufacture Source or authorization.
func requirePluginRowJournalScope(tx:SqliteTransaction,parent:OperationId,run:RunId,thread:String,epoch:String,item:String,
    child:NormalizedOperationPlan,settlementOnly:Bool,allocate:?(Int64)->LogicalJsonOwnerReservation):Unit{
    if(!isPluginDocumentRowJournalChildPlan(child)){throw IllegalStateException("invalid strict journal child plan")}
    let intent=parsePluginDocumentRowJournalIntent(child.canonicalArguments).value().getOrThrow();let binding=intent.binding()
    if(httpIntentText(binding,"thread_id")!=thread || httpIntentText(binding,"run_id")!=run.value ||
        binding.field("epoch").getOrThrow().asNumberText()!=epoch){throw IllegalStateException("journal child differs from its canonical parent scope")}
    let calls=tx.query("SELECT payload FROM items WHERE id=? AND thread_id=?",[SqlParameter.Text(item),SqlParameter.Text(thread)])
    if(calls.size!=1){throw IllegalStateException("journal child has no exact canonical parent call")}
    match(decodeStoredThreadContent(calls[0].required(0))){case ThreadItemContent.ToolCall(id,_,_)=>
        if(id.value!=httpIntentText(binding,"parent_call_id")){throw IllegalStateException("journal child belongs to another canonical call")}
        case _=>throw IllegalStateException("journal child parent is not a ToolCall")}
    let lanes=tx.query("SELECT binding.lane_id FROM run_lane_bindings binding JOIN runs actual ON actual.id=binding.run_id AND actual.thread_id=binding.thread_id JOIN turns active ON active.id=actual.turn_id AND active.thread_id=actual.thread_id AND active.active_run_id=actual.id AND active.state='active' JOIN item_tree_edges edge ON edge.thread_id=binding.thread_id AND edge.lane_id=binding.lane_id JOIN lanes lane ON lane.thread_id=binding.thread_id AND lane.lane_id=binding.lane_id WHERE binding.run_id=? AND binding.thread_id=? AND edge.item_id=? AND lane.status='open'",
        [SqlParameter.Text(run.value),SqlParameter.Text(thread),SqlParameter.Text(item)])
    if(lanes.size!=1 || lanes[0].required(0)!=httpIntentText(binding,"lane_id")){throw IllegalStateException("journal child lane changed")}
    let parents=tx.query("SELECT normalized_plan,tool_call_item_id FROM operations WHERE id=? AND run_id=?",[SqlParameter.Text(parent.value),SqlParameter.Text(run.value)])
    if(parents.size!=1 || parents[0].required(1)!=item){throw IllegalStateException("journal child lost its actual canonical parent")}
    let plan=decodeOperationPlan(parents[0].required(0))
    if(!isFrozenPluginDocumentRowJournalParentPlan(plan) ||
        canonicalAgentValue(pluginDocumentRowJournalChildArguments(plan.canonicalArguments,intent.id).value().getOrThrow())!=canonicalAgentValue(child.canonicalArguments)){
        throw IllegalStateException("journal child differs from its full original frozen intent")}
    requireDocumentWindowPayloadPlan(tx,run,ItemId(item),plan,allocate,!settlementOnly)
}
