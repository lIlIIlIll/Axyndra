package agent_store

import yjson.*
import yjson_support.*

import agent_domain.*

// Metadata validity only. Matching content metadata is never read authority.
public func verifyPluginDocumentPayloadMetadata(transaction:SqliteTransaction,reference:PluginDocumentPayloadReference):Result<Unit>{
    try{requireDocumentPayloadMetadata(transaction,reference);Result.Ok(())}
    catch(_:Exception){documentPayloadError("plugin.document_payload_metadata_changed")}
}

// Exact canonical input metadata only, inspected in the existing supplied
// transaction. The original completed read already retained these immutable
// blobs; no new read fact, artifact authority, approval or worker grant exists.
public func verifyPreparedPluginDocumentPayloadInput(transaction: SqliteTransaction, link: ContextReadFactLink,
    binding: AgentValue, data: AgentValue): Result<Unit> {
    try {
        let fact=requireContextReadFact(transaction,link.operationId,link.runId)
        requireContextReadFactConsumptionFields(transaction,documentPayloadParentOperation(fact),link.runId,
            ItemId(fact.origin.parentCallItemId),httpIntentText(binding,"contribution"),[link])
        let rows=transaction.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?",
            [SqlParameter.Text(link.operationId.value),SqlParameter.Text(link.runId.value)])
        if(rows.size!=1){throw IllegalStateException("document query has no original read")}
        let read=decodeOperationPlan(rows[0].required(0))
        if(!isContextReadPlan(read) || !pluginDocumentReadAuthority(read) ||
            httpIntentText(read.canonicalArguments,"schema")!=PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA ||
            canonicalAgentValue(read.canonicalArguments.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
            canonicalAgentValue(fact.reference())!=canonicalAgentValue(link.toValue()) ||
            canonicalAgentValue(data)!=canonicalAgentValue(fact.output()) ||
            !pluginDocumentReadResultValid(data,read.canonicalArguments)){
            throw IllegalStateException("document query differs from its original completed read")}
        for(item in data.field("documents").getOrThrow().items){
            requireDocumentPayloadMetadata(transaction,parsePluginDocumentPayloadReference(item.field("payload").getOrThrow()).value().getOrThrow())}
        Result.Ok(())
    }catch(_:Exception){documentPayloadError("plugin.document_query_input_stale")}
}
