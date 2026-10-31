package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

func hubProcessRootTicketValue180(value: HubProcessRootHandoff180): AgentValue {
    objectValue([
        ValueField("nonce", textValue(value.nonce)),
        ValueField("parent", textValue(value.parent.value)),
        ValueField("child", textValue(value.child.value)),
        ValueField("run", textValue(value.run.value)),
        ValueField("thread", textValue(value.thread.value)),
        ValueField("epoch", integerValue(value.epoch)),
        ValueField("source_item", textValue(value.sourceItem.value)),
        ValueField("source_call", textValue(value.sourceCall)),
        ValueField("source_tool", textValue(value.sourceTool)),
        ValueField("broker_pid", integerValue(value.brokerPid)),
        ValueField("broker_start", textValue(value.brokerStartIdentity)),
        ValueField("plan", storedOperationPlanValue(value.plan)),
        ValueField("configuration", value.configuration),ValueField("current_endpoint",textValue(value.currentEndpoint))
    ])
}

// The caller has already paid the complete expected codec before constructing
// this String. Actual parent/item payloads NEVER cross the SQL boundary here:
// compare their complete bytes with the original reservation proofs in SQL.
func requireHubProcessRootTicketInTransaction180(transaction: SqliteTransaction,
    value: HubProcessRootHandoff180, encodedPlan: String): Unit {
    let rows = transaction.query(
        "SELECT COUNT(*) FROM operations child " +
        "JOIN runs actual ON actual.id=child.run_id " +
        "JOIN operation_state_registers state ON state.operation_id=child.id AND state.state=child.state " +
        "JOIN derived_operation_admissions derived ON derived.operation_id=child.id " +
        "JOIN operations parent ON parent.id=derived.parent_operation_id AND parent.run_id=child.run_id " +
        "AND parent.tool_call_item_id=child.tool_call_item_id " +
        "JOIN operation_state_registers parentstate ON parentstate.operation_id=parent.id AND parentstate.state=parent.state " +
        "JOIN operation_effect_records effect ON effect.operation_id=child.id AND effect.run_id=child.run_id " +
        "AND effect.tool_call_item_id=child.tool_call_item_id AND effect.normalized_plan=child.normalized_plan " +
        "JOIN audit_events lease ON lease.operation_id=child.id AND lease.run_id=child.run_id " +
        "AND lease.thread_id=actual.thread_id AND lease.kind='hub_process_service_reserved' " +
        "AND lease.payload=child.normalized_plan " +
        "JOIN audit_events parentproof ON parentproof.operation_id=child.id AND parentproof.run_id=child.run_id " +
        "AND parentproof.kind='hub_process_parent_plan' AND parentproof.payload=parent.normalized_plan " +
        "JOIN items original ON original.id=child.tool_call_item_id AND original.thread_id=actual.thread_id AND original.kind='tool_call' " +
        "JOIN audit_events sourceproof ON sourceproof.operation_id=child.id AND sourceproof.run_id=child.run_id " +
        "AND sourceproof.kind='hub_process_source_payload' AND sourceproof.payload=original.payload " +
        "JOIN audit_events handoff ON handoff.operation_id=child.id AND handoff.run_id=child.run_id " +
        "AND handoff.thread_id=actual.thread_id AND handoff.kind='operation_execution_handoff' " +
        "LEFT JOIN operation_receipts receipt ON receipt.operation_id=child.id AND receipt.id=effect.reserved_receipt_id " +
        "WHERE child.id=? AND parent.id=? AND child.run_id=? AND actual.thread_id=? AND actual.epoch=? " +
        "AND original.id=? AND child.normalized_plan=? AND derived.request_key=? AND derived.request_digest=? " +
        "AND actual.state NOT IN ('cancelled','failed','recovery_required') " +
        "AND parent.state IN ('executing','committed') " +
        "AND ((child.state='executing' AND receipt.id IS NULL) OR (child.state='committed' AND receipt.outcome='completed')) " +
        "AND NOT EXISTS(SELECT 1 FROM audit_events revoked WHERE revoked.operation_id=child.id " +
        "AND revoked.kind='hub_process_service_revoked')", [
            SqlParameter.Text(value.child.value), SqlParameter.Text(value.parent.value),
            SqlParameter.Text(value.run.value), SqlParameter.Text(value.thread.value),
            SqlParameter.Int64Value(value.epoch), SqlParameter.Text(value.sourceItem.value),
            SqlParameter.Text(encodedPlan),
            SqlParameter.Text(exactServiceRequestKey(value.sourceCall, value.plan)),
            SqlParameter.Text(value.plan.bindingDigest)])
    channelStoreRequire(rows.size == 1 && rows[0].required(0) == "1")
}

func issueHubProcessRootTicketInTransaction180(transaction: SqliteTransaction,
    source: OperationRootSource, value: HubProcessRootHandoff180,
    encodedPlan: String, encodedTicket: String): Unit {
    channelStoreRequire(source.itemId().value == value.sourceItem.value &&
        source.callId() == value.sourceCall && source.toolName() == value.sourceTool)
    requireHubProcessRootTicketInTransaction180(transaction, value, encodedPlan)
    channelStoreRequire(transaction.query("SELECT COUNT(*) FROM audit_events WHERE " +
        "kind='hub_process_root_issued' AND payload=?", [SqlParameter.Text(encodedTicket)])[0].required(0) == "0")
    // At most one authenticated physical Root may receive this original child.
    channelStoreRequire(transaction.query("SELECT COUNT(*) FROM audit_events WHERE operation_id=? " +
        "AND kind='hub_process_root_issued'", [SqlParameter.Text(value.child.value)])[0].required(0) == "0")
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
        "VALUES(?,?,?,'hub_process_root_issued',?,?)", [SqlParameter.Text(value.thread.value),
        SqlParameter.Text(value.run.value), SqlParameter.Text(value.child.value),
        SqlParameter.Text(encodedTicket), SqlParameter.Int64Value(agentUtcMillis())])
}

func claimHubProcessRootTicketInTransaction180(transaction: SqliteTransaction,
    value: HubProcessRootHandoff180, encodedPlan: String, encodedTicket: String): Unit {
    requireHubProcessRootTicketInTransaction180(transaction, value, encodedPlan)
    channelStoreRequire(transaction.query("SELECT COUNT(*) FROM audit_events WHERE operation_id=? " +
        "AND run_id=? AND thread_id=? AND kind='hub_process_root_issued' AND payload=?", [
        SqlParameter.Text(value.child.value), SqlParameter.Text(value.run.value),
        SqlParameter.Text(value.thread.value), SqlParameter.Text(encodedTicket)])[0].required(0) == "1")
    channelStoreRequire(transaction.query("SELECT COUNT(*) FROM audit_events WHERE operation_id=? " +
        "AND kind='hub_process_root_claimed'", [SqlParameter.Text(value.child.value)])[0].required(0) == "0")
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
        "VALUES(?,?,?,'hub_process_root_claimed',?,?)", [SqlParameter.Text(value.thread.value),
        SqlParameter.Text(value.run.value), SqlParameter.Text(value.child.value),
        SqlParameter.Text(encodedTicket), SqlParameter.Int64Value(agentUtcMillis())])
}

// A denial does not require the Run still to be active. Match the actual
// complete issued/claimed ticket before idempotent revocation, preserving its
// exact nonce/epoch/Source/plan bytes even after another cancellation wins.
func requireActualRootRestrictionTicket180(transaction:SqliteTransaction,
    value:HubProcessRootHandoff180,encodedTicket:String):Unit{
    channelStoreRequire(transaction.query("SELECT COUNT(*) FROM audit_events issued " +
        "JOIN audit_events claimed ON claimed.operation_id=issued.operation_id AND claimed.run_id=issued.run_id " +
        "AND claimed.thread_id=issued.thread_id AND claimed.payload=issued.payload AND claimed.kind='hub_process_root_claimed' " +
        "WHERE issued.operation_id=? AND issued.run_id=? AND issued.thread_id=? " +
        "AND issued.kind='hub_process_root_issued' AND issued.payload=?",[
            SqlParameter.Text(value.child.value),SqlParameter.Text(value.run.value),
            SqlParameter.Text(value.thread.value),SqlParameter.Text(encodedTicket)])[0].required(0)=="1")
}
func verifyHubProcessRootTicketInTransaction180(transaction: SqliteTransaction,
    value: HubProcessRootHandoff180, encodedPlan: String, encodedTicket: String): Unit {
    requireHubProcessRootTicketInTransaction180(transaction, value, encodedPlan)
    channelStoreRequire(transaction.query("SELECT COUNT(*) FROM audit_events issued " +
        "JOIN audit_events claimed ON claimed.operation_id=issued.operation_id " +
        "AND claimed.run_id=issued.run_id AND claimed.thread_id=issued.thread_id " +
        "AND claimed.payload=issued.payload AND claimed.kind='hub_process_root_claimed' " +
        "WHERE issued.operation_id=? AND issued.kind='hub_process_root_issued' AND issued.payload=?", [
        SqlParameter.Text(value.child.value), SqlParameter.Text(encodedTicket)])[0].required(0) == "1")
}


// Public DATA codec only. Its caller pays all original codec representations
// before entry. Decoding cannot issue/claim a Source, nonce or execution lease.
public func hubProcessRootWireValue180(value:HubProcessRootHandoff180):AgentValue{
    objectValue([
        ValueField("nonce",textValue(value.nonce)),ValueField("parent",textValue(value.parent.value)),
        ValueField("child",textValue(value.child.value)),ValueField("run",textValue(value.run.value)),
        ValueField("thread",textValue(value.thread.value)),ValueField("epoch",integerValue(value.epoch)),
        ValueField("source_item",textValue(value.sourceItem.value)),ValueField("source_call",textValue(value.sourceCall)),
        ValueField("source_tool",textValue(value.sourceTool)),ValueField("broker_pid",integerValue(value.brokerPid)),
        ValueField("broker_start",textValue(value.brokerStartIdentity)),
        ValueField("plan",textValue(encodeOperationPlan(value.plan))),ValueField("configuration",value.configuration),
        ValueField("current_endpoint",textValue(value.currentEndpoint))])
}
public func decodeHubProcessRootWireData180(value:AgentValue):HubProcessRootHandoff180{
    channelStoreRequire(value.unifiedKind==ValueKind.Object && value.asObject().size()==14)
    let names=["nonce","parent","child","run","thread","epoch","source_item","source_call", "source_tool",
        "broker_pid","broker_start","plan","configuration","current_endpoint"]
    let object=value.asObject()
    for(index in 0..object.size()){
        let name=object.nameAt(index);var matches:Int64=0
        for(expected in names where expected==name){matches+=1}
        channelStoreRequire(matches==1)
        for(prior in 0..index){channelStoreRequire(object.nameAt(prior)!=name)}}
    func text(name:String):String{
        let item=value.field(name).getOrThrow();channelStoreRequire(item.unifiedKind==ValueKind.Text);item.text}
    func integer(name:String):Int64{
        let item=value.field(name).getOrThrow();channelStoreRequire(item.unifiedKind==ValueKind.Number)
        let encoded=item.asNumberText();let result=Int64.parse(encoded)
        channelStoreRequire(result.toString()==encoded);result}
    HubProcessRootHandoff180(text("nonce"),OperationId(text("parent")),OperationId(text("child")),
        RunId(text("run")),ThreadId(text("thread")),integer("epoch"),ItemId(text("source_item")),
        text("source_call"),text("source_tool"),integer("broker_pid"),text("broker_start"),
        decodeOperationPlan(text("plan")),value.field("configuration").getOrThrow(),text("current_endpoint"))
}
