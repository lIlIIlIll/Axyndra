package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Use the existing canonical audit ledger, not a parallel authority database.
// Reservation and replay exclusion are in the SAME existing SQLite transaction
// as the original Source/ParentIntent/execution verification. An ID or a JSON
// description alone never passes this verifier.
func reserveHubProcessServiceInTransaction180(transaction: SqliteTransaction,
    source: OperationRootSource, parent: OperationId, child: OperationId, run: RunId,
    thread: ThreadId, epoch: Int64, plan: NormalizedOperationPlan,
    requireParentIntent: () -> Unit): Unit {
    channelStoreRequire(pluginPrimitivePlanService111(plan)=="process.service")
    requirePluginChildExecution111(transaction,source,parent,child,run,thread,epoch,plan)
    requireParentIntent()
    channelStoreRequire(transaction.query("SELECT id FROM audit_events WHERE operation_id=? " +
        "AND kind='hub_process_service_reserved' LIMIT 2",[SqlParameter.Text(child.value)]).isEmpty())
    // Binding is the exact canonical normalized plan, including the actual
    // namespace/current generation, request and operator-selected capabilities.
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
        "VALUES(?,?,?,'hub_process_service_reserved',?,?)",[SqlParameter.Text(thread.value),
        SqlParameter.Text(run.value),SqlParameter.Text(child.value),SqlParameter.Text(encodeOperationPlan(plan)),
        SqlParameter.Int64Value(agentUtcMillis())])
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
        "SELECT ?,?,?,'hub_process_parent_plan',normalized_plan,? FROM operations WHERE id=? AND run_id=?", [
        SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),
        SqlParameter.Int64Value(agentUtcMillis()),SqlParameter.Text(parent.value),SqlParameter.Text(run.value)])
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
        "SELECT ?,?,?,'hub_process_source_payload',payload,? FROM items WHERE id=? AND thread_id=? AND kind='tool_call'", [
        SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),
        SqlParameter.Int64Value(agentUtcMillis()),SqlParameter.Text(source.itemId().value),SqlParameter.Text(thread.value)])
}

// A resource remains dependent on its actual start. Unknown/rejected/changed
// canonical outcomes revoke it; only an exact executing handoff or the actual
// Store-Committed Completed receipt permits continued physical ownership.
// Completed is not inferred from a callback, PID, cancellation or status flag.
func requireHubProcessServiceInTransaction180(transaction: SqliteTransaction,
    source: OperationRootSource,parent: OperationId,child: OperationId,run: RunId,
    thread: ThreadId,epoch: Int64,plan: NormalizedOperationPlan): Unit {
    channelStoreRequire(epoch>0 && pluginPrimitivePlanService111(plan)=="process.service" &&
        isPluginChildStartPlan111(plan))
    // This is descriptive DATA only; its nonce is not used or issued here.
    // The exact Store reservation remains mandatory in the common scalar verifier.
    let value=HubProcessRootHandoff180("0000000000000000000000000000000000000000000000000000000000000000",
        parent,child,run,thread,epoch,source.itemId(),source.callId(),source.toolName(),1,"unclaimed",
        plan,nullValue(),"unclaimed")
    requireHubProcessRootTicketInTransaction180(transaction,value,encodeOperationPlan(plan))
}

func revokeHubProcessServiceInTransaction180(transaction: SqliteTransaction,
    source: OperationRootSource,parent: OperationId,child: OperationId,run: RunId,
    thread: ThreadId,epoch: Int64,plan: NormalizedOperationPlan): Unit {
    // Revoke remains legal after loss of authority and is idempotent, but
    // cannot alter another incarnation's original reservation or payload.
    let original=transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND run_id=? " +
        "AND thread_id=? AND kind='hub_process_service_reserved' AND payload=? LIMIT 2",[
        SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value),
        SqlParameter.Text(encodeOperationPlan(plan))])
    channelStoreRequire(original.size==1 && source.itemId().value!="" && epoch>0)
    if(transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='hub_process_service_revoked' LIMIT 1",
        [SqlParameter.Text(child.value)]).isEmpty()){
        transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
            "VALUES(?,?,?,'hub_process_service_revoked',?,?)",[SqlParameter.Text(thread.value),
            SqlParameter.Text(run.value),SqlParameter.Text(child.value),SqlParameter.Text(encodeOperationPlan(plan)),
            SqlParameter.Int64Value(agentUtcMillis())])}
}

// Read-only service uses the ORIGINAL actual Source/ParentIntent/SQL ledger.
func reserveHubProcessObservationInTransaction197(transaction: SqliteTransaction,
    source: OperationRootSource, parent: OperationId, child: OperationId, run: RunId,
    thread: ThreadId, epoch: Int64, plan: NormalizedOperationPlan,
    requireParentIntent: () -> Unit): Unit {
    channelStoreRequire(isPluginHubProcessObservationPlan197(plan))
    requirePluginChildExecution111(transaction,source,parent,child,run,thread,epoch,plan)
    requireParentIntent()
    channelStoreRequire(transaction.query("SELECT id FROM audit_events WHERE operation_id=? " +
        "AND kind='hub_process_service_reserved' LIMIT 2",[SqlParameter.Text(child.value)]).isEmpty())
    // Binding is the exact canonical normalized plan, including the actual
    // namespace/current generation, request and operator-selected capabilities.
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
        "VALUES(?,?,?,'hub_process_service_reserved',?,?)",[SqlParameter.Text(thread.value),
        SqlParameter.Text(run.value),SqlParameter.Text(child.value),SqlParameter.Text(encodeOperationPlan(plan)),
        SqlParameter.Int64Value(agentUtcMillis())])
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
        "SELECT ?,?,?,'hub_process_parent_plan',normalized_plan,? FROM operations WHERE id=? AND run_id=?", [
        SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),
        SqlParameter.Int64Value(agentUtcMillis()),SqlParameter.Text(parent.value),SqlParameter.Text(run.value)])
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
        "SELECT ?,?,?,'hub_process_source_payload',payload,? FROM items WHERE id=? AND thread_id=? AND kind='tool_call'", [
        SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),
        SqlParameter.Int64Value(agentUtcMillis()),SqlParameter.Text(source.itemId().value),SqlParameter.Text(thread.value)])
}

func requireHubProcessObservationInTransaction197(transaction: SqliteTransaction,
    source: OperationRootSource,parent: OperationId,child: OperationId,run: RunId,
    thread: ThreadId,epoch: Int64,plan: NormalizedOperationPlan): Unit {
    channelStoreRequire(epoch>0 && isPluginHubProcessObservationPlan197(plan) &&
        isPluginChildStartPlan111(plan))
    // This is descriptive DATA only; its nonce is not used or issued here.
    // The exact Store reservation remains mandatory in the common scalar verifier.
    let value=HubProcessRootHandoff180("0000000000000000000000000000000000000000000000000000000000000000",
        parent,child,run,thread,epoch,source.itemId(),source.callId(),source.toolName(),1,"unclaimed",
        plan,nullValue(),"unclaimed")
    requireHubProcessRootTicketInTransaction180(transaction,value,encodeOperationPlan(plan))
}
