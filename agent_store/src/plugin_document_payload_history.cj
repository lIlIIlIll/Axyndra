package agent_store

import yjson.*
import yjson_support.*

import agent_domain.*
import std.convert.*

// Immutable content metadata only. It grants no read, admission, execution or
// continuation authority. A caller must retain its original operator scope and
// paid raw reader until the actual pure/admission consumer acknowledges it.
public class CompletedPluginDocumentPayloadHistory {
    public let expectedRevision: Int64
    public let revision: Int64
    public let expectedPayload: PluginDocumentPayloadReference
    public let payload: PluginDocumentPayloadReference
    init(intent: PluginDocumentIntent) {
        expectedRevision=intent.expectedRevision;revision=intent.expectedRevision+1
        expectedPayload=intent.expectedPayload.getOrThrow();payload=intent.nextPayload.getOrThrow()
    }
}

// Historical supplied-transaction validator. It deliberately does not call
// requireDocumentPayloadFact/Plan/ConsumptionFields: those enforce an active,
// unsettled parent and would reject the completed Run used by continuation.
// Preparatory GC pins are not inspected or treated as completed authority.
public func verifyCompletedPluginDocumentPayloadHistory(transaction: SqliteTransaction,
    parentOperation: OperationId, childOperation: OperationId, run: RunId, parentItem: ItemId,
    parent: NormalizedOperationPlan, child: NormalizedOperationPlan, receiptId: String,
    scope: ContinuationDocumentReadScope): Result<CompletedPluginDocumentPayloadHistory> {
    try {
        if (!pluginDocumentParentAllows(parent,child) || parent.contextReadFacts.size!=1 ||
            httpIntentText(parent.canonicalArguments.field("host_plan").getOrThrow(),"version")!=PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA) {
            return documentPayloadHistoryError() }
        let intent=parsePluginDocumentIntent(child.canonicalArguments).value().getOrThrow()
        if (!intent.referencesPayload || !intent.compareExchange) {return documentPayloadHistoryError()}
        let binding=intent.binding()
        let rows=scope.query(transaction,"SELECT r.thread_id,r.turn_id,r.epoch,i.payload,i.provenance,parent.normalized_plan,"+
            "child.normalized_plan,a.request_key,a.request_digest,ph.id,ph.payload,receipt.detail,pr.id,pe.reserved_result_item_id "+
            "FROM operations child JOIN derived_operation_admissions a ON a.operation_id=child.id "+
            "JOIN operations parent ON parent.id=a.parent_operation_id AND parent.run_id=child.run_id "+
            "AND parent.tool_call_item_id=child.tool_call_item_id JOIN runs r ON r.id=child.run_id "+
            "JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id "+
            "JOIN items i ON i.id=parent.tool_call_item_id AND i.thread_id=r.thread_id AND i.turn_id=r.turn_id "+
            "JOIN run_lane_bindings lane ON lane.run_id=r.id AND lane.thread_id=r.thread_id "+
            "JOIN item_tree_edges edge ON edge.item_id=i.id AND edge.thread_id=r.thread_id AND edge.lane_id=lane.lane_id "+
            "JOIN operation_effect_records pe ON pe.operation_id=parent.id AND pe.run_id=r.id AND pe.tool_call_item_id=i.id "+
            "AND pe.normalized_plan=parent.normalized_plan "+
            "JOIN operation_effect_records ce ON ce.operation_id=child.id AND ce.run_id=r.id AND ce.tool_call_item_id=i.id "+
            "AND ce.normalized_plan=child.normalized_plan "+
            "JOIN operation_state_registers ps ON ps.operation_id=parent.id AND ps.state=parent.state "+
            "JOIN operation_state_registers cs ON cs.operation_id=child.id AND cs.state=child.state "+
            "JOIN operation_receipts receipt ON receipt.operation_id=child.id AND receipt.id=ce.reserved_receipt_id "+
            "JOIN operation_receipts pr ON pr.operation_id=parent.id AND pr.id=pe.reserved_receipt_id AND pr.outcome='completed' "+
            "JOIN items result ON result.id=pe.reserved_result_item_id AND result.thread_id=r.thread_id "+
            "AND result.turn_id=r.turn_id AND result.kind='tool_result' "+
            "JOIN audit_events ph ON ph.operation_id=parent.id AND ph.run_id=r.id AND ph.thread_id=r.thread_id "+
            "AND ph.kind='operation_execution_handoff' "+
            "WHERE child.id=? AND parent.id=? AND r.id=? AND i.id=? AND receipt.id=? AND lane.lane_id=? "+
            "AND parent.state='committed' AND child.state='committed' AND receipt.outcome='completed' "+
            "AND r.state='completed' AND r.finished_at_millis IS NOT NULL AND t.state='completed' AND t.active_run_id IS NULL "+
            "AND i.kind='tool_call' AND pe.tool_id=? AND ce.tool_id=? "+
            "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions nested WHERE nested.operation_id=parent.id) LIMIT 2",
            [SqlParameter.Text(childOperation.value),SqlParameter.Text(parentOperation.value),SqlParameter.Text(run.value),
                SqlParameter.Text(parentItem.value),SqlParameter.Text(receiptId),SqlParameter.Text(httpIntentText(binding,"lane_id")),
                SqlParameter.Text(parent.toolName),SqlParameter.Text(HOST_PLUGIN_DOCUMENT_TOOL)],14)
        if (rows.size!=1) {return documentPayloadHistoryError()}
        let row=rows[0]
        for(index in [3,4,5,6,10,11]){scope.preflightStored(row.required(index))}
        if (row.required(5)!=encodeOperationPlan(parent) || row.required(6)!=encodeOperationPlan(child) ||
            row.required(8)!=child.bindingDigest || row.required(11)!=encodeStoredValue(intent.result()) ||
            httpIntentText(binding,"thread_id")!=row.required(0) || httpIntentText(binding,"run_id")!=run.value ||
            binding.field("epoch").getOrThrow().asNumberText()!=row.required(2)) {return documentPayloadHistoryError()}
        let callId=match(decodeStoredThreadContent(row.required(3))){
            case ThreadItemContent.ToolCall(id,name,input)=>
                if(name!=parent.toolName || id.value!=httpIntentText(binding,"parent_call_id") ||
                    canonicalAgentValue(input)!=canonicalAgentValue(contextReadBusinessInput(parent.canonicalArguments.field("input").getOrThrow()))){
                    return documentPayloadHistoryError()};id.value
            case _=>return documentPayloadHistoryError()}
        // The real parent Item and Receipt still contain the full public
        // result. Validate each under a temporary paid codec lease; never load
        // both full copies in the retained observation scope simultaneously.
        let itemDigest=scope.transientDigest(transaction,"SELECT payload FROM items WHERE id=? AND thread_id=? AND turn_id=? AND kind='tool_result'",
            [SqlParameter.Text(row.required(13)),SqlParameter.Text(row.required(0)),SqlParameter.Text(row.required(1))],{raw,check=>
                check(raw)
                match(decodeStoredThreadContent(raw)){
                    case ThreadItemContent.ToolResult(id,operation,receipt,output,isError)=>
                        if(id.value!=callId || operation.value!=parentOperation.value || receipt!=row.required(12) || isError){
                            throw IllegalStateException("historical parent result identity changed")}
                        modelPolicySha256Text(canonicalAgentValue(output))
                    case _=>throw IllegalStateException("historical parent result kind changed")}})
        let receiptDigest=scope.transientDigest(transaction,"SELECT detail FROM operation_receipts WHERE id=? AND operation_id=? AND outcome='completed'",
            [SqlParameter.Text(row.required(12)),SqlParameter.Text(parentOperation.value)],{raw,check=>
                check(raw);modelPolicySha256Text(canonicalAgentValue(decodeStoredValue(raw)))})
        if(itemDigest!=receiptDigest){return documentPayloadHistoryError()}
        if(row.required(7)!=exactServiceRequestKey(callId,child) || row.required(10)!=encodeStoredValue(objectValue([
            ValueField("document_parent_epoch",textValue(row.required(2))),
            ValueField("parent_plan_digest",textValue(modelPolicySha256Text(row.required(5))))]))){return documentPayloadHistoryError()}
        let provenance=decodeStoredProvenance(row.required(4))
        if(provenance.runId.isNone() || provenance.runId.getOrThrow().value!=run.value){return documentPayloadHistoryError()}
        let decisions=scope.query(transaction,"SELECT d.id,b.scoped_tool_call_id FROM decision_operations source "+
            "JOIN model_decisions d ON d.id=source.decision_id JOIN model_attempts attempt ON attempt.id=d.attempt_id "+
            "JOIN model_decision_blocks b ON b.decision_id=d.id AND b.scoped_tool_call_id=source.scoped_tool_call_id AND b.kind='tool_call' "+
            "JOIN canonical_decision_items c ON c.decision_id=d.id AND c.decision_block_id=b.id "+
            "WHERE source.operation_id=? AND c.item_id=? AND attempt.run_id=? AND d.validation_status='validated' "+
            "AND d.canonical_committed_at_millis IS NOT NULL",
            [SqlParameter.Text(parentOperation.value),SqlParameter.Text(parentItem.value),SqlParameter.Text(run.value)],2)
        let direct=provenance.source=="direct_tool"
        if(direct){
            if(provenance.operationId.isNone() || provenance.operationId.getOrThrow().value!=parentOperation.value ||
                !sameDirectCallOrigin(effectiveDirectCallOrigin(provenance),DirectCallOrigin.UserDirect) || !decisions.isEmpty() ||
                !scope.query(transaction,"SELECT decision_id FROM decision_operations WHERE operation_id=?",[SqlParameter.Text(parentOperation.value)],1).isEmpty() ||
                !scope.query(transaction,"SELECT decision_id FROM canonical_decision_items WHERE item_id=?",[SqlParameter.Text(parentItem.value)],1).isEmpty()){
                return documentPayloadHistoryError()}
        }else if(decisions.size!=1 || provenance.operationId.isSome()){return documentPayloadHistoryError()}
        let evidence=objectValue([
            ValueField("authorization_source",textValue("parent_intent")),ValueField("root_source",textValue(if(direct){"direct"}else{"committed"})),
            ValueField("thread_id",textValue(row.required(0))),ValueField("turn_id",textValue(row.required(1))),
            ValueField("run_id",textValue(run.value)),ValueField("epoch",textValue(row.required(2))),
            ValueField("root_item_id",textValue(parentItem.value)),ValueField("root_call_id",textValue(callId)),
            ValueField("decision_id",textValue(if(direct){""}else{decisions[0].required(0)})),
            ValueField("scoped_tool_call_id",textValue(if(direct){""}else{decisions[0].required(1)})),
            ValueField("parent_operation_id",textValue(parentOperation.value)),ValueField("parent_handoff_id",textValue(row.required(9))),
            ValueField("parent_plan_digest",textValue(parent.bindingDigest)),ValueField("child_operation_id",textValue(childOperation.value)),
            ValueField("child_plan_digest",textValue(child.bindingDigest)),ValueField("request_key",textValue(row.required(7))),
            ValueField("intent_id",textValue(intent.id)),ValueField("document_intent_digest",textValue(modelPolicySha256Text(row.required(6))))])
        match(provenance.directOrigin){case Some(value)=>evidence.put("root_origin",directCallOriginValue(value));case None=>()}
        let authorized=scope.query(transaction,"SELECT thread_id,run_id,payload FROM audit_events WHERE operation_id=? AND kind='operation_parent_intent_authorized'",
            [SqlParameter.Text(childOperation.value)],3)
        let handed=scope.query(transaction,"SELECT id FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='operation_execution_handoff'",
            [SqlParameter.Text(childOperation.value),SqlParameter.Text(run.value),SqlParameter.Text(row.required(0))],1)
        if(authorized.size!=1 || authorized[0].required(0)!=row.required(0) || authorized[0].required(1)!=run.value ||
            authorized[0].required(2)!=encodeStoredValue(evidence) || handed.size!=1){return documentPayloadHistoryError()}
        let link=parent.contextReadFacts[0]
        let factRows=scope.query(transaction,"SELECT call.payload,call.provenance,o.normalized_plan,receipt.detail,result.payload,a.payload "+
            "FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id "+
            "JOIN items call ON call.id=o.tool_call_item_id JOIN operation_receipts receipt ON receipt.operation_id=o.id "+
            "JOIN items result ON result.id=e.reserved_result_item_id JOIN audit_events a ON a.operation_id=o.id "+
            "AND a.kind='context_read_admitted' WHERE o.id=? AND o.run_id=? LIMIT 2",
            [SqlParameter.Text(link.operationId.value),SqlParameter.Text(run.value)],6)
        if(factRows.size!=1){return documentPayloadHistoryError()}
        for(index in 0..6){scope.preflightStored(factRows[0].required(index))}
        let fact=requireContextReadFact(transaction,link.operationId,run)
        let read=decodeOperationPlan(factRows[0].required(2))
        let supplied=parent.canonicalArguments.field("input").getOrThrow()
        let envelope=supplied.field(CONTEXT_READ_INPUT_FIELD).getOrThrow()
        if(link.runId.value!=run.value || fact.origin.parentCallItemId!=parentItem.value ||
            documentPayloadParentOperation(fact).value!=parentOperation.value ||
            canonicalAgentValue(link.toValue())!=canonicalAgentValue(fact.reference()) ||
            !isContextReadPlan(read) || !pluginDocumentReadAuthority(read) ||
            httpIntentText(read.canonicalArguments,"schema")!=PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA ||
            canonicalAgentValue(read.canonicalArguments.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
            !pluginDocumentReadResultValid(fact.output(),read.canonicalArguments) ||
            validateContextReadInputProjection(supplied,parent.contextReadFacts).isError() ||
            canonicalAgentValue(envelope.field("data").getOrThrow())!=canonicalAgentValue(fact.output())){return documentPayloadHistoryError()}
        let order=scope.query(transaction,"SELECT parent.ordinal,call.ordinal,result.ordinal,r.skill_snapshot FROM items parent "+
            "JOIN items call ON call.id=? AND call.thread_id=parent.thread_id AND call.turn_id=parent.turn_id "+
            "JOIN items result ON result.id=? AND result.thread_id=parent.thread_id AND result.turn_id=parent.turn_id "+
            "JOIN runs r ON r.id=? AND r.thread_id=parent.thread_id AND r.turn_id=parent.turn_id WHERE parent.id=?",
            [SqlParameter.Text(fact.sourceItemId.value),SqlParameter.Text(fact.resultItemId.value),SqlParameter.Text(run.value),
                SqlParameter.Text(parentItem.value)],4)
        if(order.size!=1 || Int64.parse(order[0].required(0))>=Int64.parse(order[0].required(1)) ||
            Int64.parse(order[0].required(1))>=Int64.parse(order[0].required(2))){return documentPayloadHistoryError()}
        scope.preflightStored(order[0].required(3))
        if(contextReadProjectionDigest(contextSnapshotFromValue(decodeStoredValue(order[0].required(3))))!=fact.origin.projectionDigest){
            return documentPayloadHistoryError()}
        var found=false
        for(item in fact.output().field("documents").getOrThrow().items where httpIntentText(item,"key")==intent.key){
            if(found || item.field("revision").getOrThrow().asNumberText()!=intent.expectedRevision.toString() ||
                canonicalAgentValue(item.field("payload").getOrThrow())!=canonicalAgentValue(intent.expectedPayload.getOrThrow().value())){
                return documentPayloadHistoryError()};found=true}
        if(!found){return documentPayloadHistoryError()}
        // The same paid scope guards and accounts each metadata read before
        // the existing bounded metadata codec is entered. No raw blob is read.
        for(reference in [intent.expectedPayload.getOrThrow(),intent.nextPayload.getOrThrow()]){
            let metadata=scope.query(transaction,"SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=?",
                [SqlParameter.Text(reference.digest)],4)
            if(metadata.size!=1){return documentPayloadHistoryError()}
            requireDocumentPayloadMetadata(transaction,reference)
        }
        Result.Ok(CompletedPluginDocumentPayloadHistory(intent))
    }catch(_:Exception){documentPayloadHistoryError()}
}

func documentPayloadHistoryError<T>(): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.document_payload_history_invalid",
        "historical document data requires the exact completed canonical parent, child and original read"))
}
