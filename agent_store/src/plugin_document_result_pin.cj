package agent_store

import yjson.*
import yjson_support.*

import agent_domain.*
import std.convert.*

func documentResultPreparationEvidence(parent: AgentValue, fact: ContextReadFact): AgentValue {
    objectValue([ValueField("schema",textValue("axyndra.document-result-prepared/v1")),
        ValueField("parent_item_id",textValue(fact.origin.parentCallItemId)),
        ValueField("parent_operation_id",textValue(documentPayloadParentOperation(fact).value)),
        ValueField("arguments_sha256",textValue(modelPolicySha256Text(canonicalAgentValue(parent)))),
        ValueField("fact",fact.reference()),ValueField("result_payload",parent.field("host_plan").getOrThrow().field("result_payload").getOrThrow())])
}

func requireDocumentResultFact(transaction: SqliteTransaction, run: RunId, parentItem: ItemId,
    parent: AgentValue, link: ContextReadFactLink): ContextReadFact {
    let host=parent.field("host_plan").getOrThrow()
    if(!pluginDocumentFrozenResultValid(host) || !httpIntentExactFields(parent,["input","configuration","host_plan"]) ||
        validateContextReadInputProjection(parent.field("input").getOrThrow(),[link]).isError()){
        throw IllegalStateException("document result requires the exact compact final parent")}
    let fact=requireContextReadFact(transaction,link.operationId,run)
    let binding=host.field("binding").getOrThrow()
    requireContextReadFactConsumptionFields(transaction,documentPayloadParentOperation(fact),run,parentItem,httpIntentText(binding,"contribution"),[link])
    let plans=transaction.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?",
        [SqlParameter.Text(link.operationId.value),SqlParameter.Text(run.value)])
    if(plans.size!=1){throw IllegalStateException("document result has no original read plan")}
    let read=decodeOperationPlan(plans[0].required(0))
    let data=parent.field("input").getOrThrow().field(CONTEXT_READ_INPUT_FIELD).getOrThrow().field("data").getOrThrow()
    if(!isContextReadPlan(read) || !pluginDocumentReadAuthority(read) ||
        httpIntentText(read.canonicalArguments,"schema")!=PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA ||
        canonicalAgentValue(read.canonicalArguments.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
        !pluginDocumentReadResultValid(fact.output(),read.canonicalArguments) ||
        canonicalAgentValue(data)!=canonicalAgentValue(fact.output()) || fact.origin.parentCallItemId!=parentItem.value ||
        canonicalAgentValue(link.toValue())!=canonicalAgentValue(fact.reference())){
        throw IllegalStateException("document result differs from its exact canonical fact")}
    for(raw in host.field("intents").getOrThrow().items){
        let child=pluginDocumentChildArguments(parent,httpIntentText(raw,"id")).value().getOrThrow()
        let intent=parsePluginDocumentIntent(child).value().getOrThrow()
        let _=requireDocumentPayloadFact(transaction,run,parentItem,link,intent)
    }
    fact
}

func documentResultPreparationMatch(transaction: SqliteTransaction, run: RunId, parent: OperationId,
    thread: String, evidence: String, allocate: (Int64)->LogicalJsonOwnerReservation): (Bool,Bool) {
    let rows=transaction.query("SELECT id,length(CAST(payload AS BLOB)) FROM audit_events WHERE thread_id=? AND run_id=? "+
        "AND operation_id=? AND kind='plugin_document_result_prepared' LIMIT 2",
        [SqlParameter.Text(thread),SqlParameter.Text(run.value),SqlParameter.Text(parent.value)])
    if(rows.size>1){throw IllegalStateException("document result preparation is ambiguous")}
    if(rows.isEmpty()){return (false,false)}
    let bytes=Int64.parse(rows[0].required(1))
    if(bytes<1 || bytes>65536){throw IllegalStateException("document result preparation exceeded its compact codec")}
    let lease=allocate(bytes)
    try {
        lease.ensureDecoded(bytes,bytes)
        let selected=transaction.query("SELECT payload FROM audit_events WHERE id=? AND operation_id=? AND kind='plugin_document_result_prepared' "+
            "AND length(CAST(payload AS BLOB))=?",
            [SqlParameter.Text(rows[0].required(0)),SqlParameter.Text(parent.value),SqlParameter.Int64Value(bytes)])
        if(selected.size!=1){throw IllegalStateException("document result preparation changed")}
        // This exact encoded comparison requires no decoding/allocation of an
        // attacker-controlled audit tree. The lease covers the raw string.
        (true,selected[0].required(0)==evidence)
    }finally{lease.close()}
}

// Called only by trusted Product under artifact lock and the original pending
// source. It creates one data/GC pin, no Operation, grant, approval or handoff.
public func retainPreparedPluginDocumentResult(transaction: SqliteTransaction, link: ContextReadFactLink,
    parent: AgentValue, allocate: (Int64)->LogicalJsonOwnerReservation, verifyContent: ()->Result<Unit>): Result<Unit> {
    try {
        let initial=requireContextReadFact(transaction,link.operationId,link.runId)
        let item=ItemId(initial.origin.parentCallItemId)
        let fact=requireDocumentResultFact(transaction,link.runId,item,parent,link)
        if(!transaction.query("SELECT id FROM operations WHERE tool_call_item_id=?",[SqlParameter.Text(item.value)]).isEmpty()){
            throw IllegalStateException("document result cannot be staged after actual parent preparation")}
        let host=parent.field("host_plan").getOrThrow();let binding=host.field("binding").getOrThrow()
        let reference=parsePluginDocumentPayloadReference(host.field("result_payload").getOrThrow()).value().getOrThrow()
        requireDocumentPayloadMetadata(transaction,reference)
        match(verifyContent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let evidence=encodeStoredValue(documentResultPreparationEvidence(parent,fact))
        if(evidence.size>65536){throw IllegalStateException("document result witness exceeds its compact codec")}
        let operation=documentPayloadParentOperation(fact)
        let prior=documentResultPreparationMatch(transaction,link.runId,operation,httpIntentText(binding,"thread_id"),evidence,allocate)
        if(prior[0] && !prior[1]){throw IllegalStateException("document final result was already frozen differently")}
        if(!prior[0]){
            transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                "VALUES(?,?,?,'plugin_document_result_prepared',?,?)",
                [SqlParameter.Text(httpIntentText(binding,"thread_id")),SqlParameter.Text(link.runId.value),SqlParameter.Text(operation.value),
                    SqlParameter.Text(evidence),SqlParameter.Int64Value(agentUtcMillis())])}
        Result.Ok(())
    }catch(_:Exception){documentPayloadError("plugin.document_result_preparation_stale")}
}

func requirePreparedPluginDocumentResult(transaction: SqliteTransaction, run: RunId, parentItem: ItemId,
    parent: AgentValue, link: ContextReadFactLink, allocate: (Int64)->LogicalJsonOwnerReservation): Unit {
    let fact=requireDocumentResultFact(transaction,run,parentItem,parent,link)
    let binding=parent.field("host_plan").getOrThrow().field("binding").getOrThrow()
    let rows=documentResultPreparationMatch(transaction,run,documentPayloadParentOperation(fact),httpIntentText(binding,"thread_id"),
        encodeStoredValue(documentResultPreparationEvidence(parent,fact)),allocate)
    if(!rows[0] || !rows[1]){
        throw IllegalStateException("document parent has no exact Host-frozen full result")}
    requireDocumentPayloadMetadata(transaction,parsePluginDocumentPayloadReference(parent.field("host_plan").getOrThrow().field("result_payload").getOrThrow()).value().getOrThrow())
}
