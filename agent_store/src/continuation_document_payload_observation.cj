package agent_store

import agent_domain.*
import std.collection.*
import std.convert.*

// Exact content identity only. The constructor and public getters confer no
// file read, document permission, live owner or continuation admission.
public class ContinuationDocumentVersion {
    public let threadId: ThreadId
    public let laneId: LaneId
    public let namespace: String
    public let key: String
    public let revision: Int64
    public let payload: PluginDocumentPayloadReference
    public init(thread: ThreadId, lane: LaneId, namespace: String, key: String,
        revision: Int64, payload: PluginDocumentPayloadReference) {
        this.threadId=thread;this.laneId=lane;this.namespace=namespace;this.key=key
        this.revision=revision;this.payload=payload
    }
}

// Hash the current row transiently before any historical typed result is
// decoded. No current raw string or DOM survives this method. All subsequent
// historical proofs use the same transaction and original paid/current scope.
public func readContinuationDocumentVersion(transaction: SqliteTransaction,
    thread: ThreadId,lane: LaneId,namespace: String,key: String,
    scope: ContinuationDocumentReadScope): Result<ContinuationDocumentVersion> {
    try {
        let parameters=[SqlParameter.Text(thread.value),SqlParameter.Text(lane.value),
            SqlParameter.Text(namespace),SqlParameter.Text(key)]
        let rows=scope.query(transaction,"SELECT revision,length(CAST(payload AS BLOB)) FROM plugin_documents "+
            "WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",parameters,2)
        if(rows.size!=1){return continuationDocumentObservationError()}
        let revision=Int64.parse(rows[0].required(0));let bytes=Int64.parse(rows[0].required(1))
        if(revision<1 || bytes<1 || bytes>PLUGIN_DOCUMENT_MAX_BYTES){return continuationDocumentObservationError()}
        let digest=scope.transientDigest(transaction,"SELECT payload FROM plugin_documents "+
            "WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",parameters,
            {raw,_=>modelPolicySha256Text(raw)})
        Result.Ok(ContinuationDocumentVersion(thread,lane,namespace,key,revision,
            continuationDocumentPayloadReference(digest,bytes)))
    }catch(_:Exception){continuationDocumentObservationError()}
}

func continuationDocumentPayloadReference(digest:String,bytes:Int64):PluginDocumentPayloadReference {
    parsePluginDocumentPayloadReference(objectValue([
        ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
        ValueField("artifact_ref",textValue("blob:sha256:"+digest)),ValueField("encoding",textValue("utf8")),
        ValueField("bytes",integerValue(bytes)),ValueField("sha256",textValue(digest)),
        ValueField("content_type",textValue("text/plain; charset=utf-8"))])).value().getOrThrow()
}

// The result lookup only narrows candidate rows. The supplied-Tx historical
// validator still proves the actual root/child plans, canonical Item and
// reserved Receipts, handoffs, ParentIntent and original completed read. A
// matching artifact or preparatory GC pin is never sufficient.
public func observeCompletedPluginDocumentPayload(transaction: SqliteTransaction,
    version: ContinuationDocumentVersion,parentTool:String,packageDigest:String,generation:String,
    configurationDigest:String,scope:ContinuationDocumentReadScope,operationId!:?String=None
):Result<CompletedPluginDocumentObservation> {
    try {
        if(version.revision<1){return continuationDocumentObservationError()}
        let result=encodeStoredValue(objectValue([
            ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_RESULT_SCHEMA)),ValueField("key",textValue(version.key)),
            ValueField("revision",integerValue(version.revision)),ValueField("payload",version.payload.value())]))
        let rows=scope.query(transaction,"SELECT child.id,receipt.id,r.id,r.epoch,parent.id,parent.normalized_plan,"+
            "child.normalized_plan,parent.tool_call_item_id FROM operation_receipts receipt "+
            "JOIN operations child ON child.id=receipt.operation_id "+
            "JOIN derived_operation_admissions a ON a.operation_id=child.id "+
            "JOIN operations parent ON parent.id=a.parent_operation_id AND parent.run_id=child.run_id "+
            "AND parent.tool_call_item_id=child.tool_call_item_id JOIN runs r ON r.id=child.run_id "+
            "JOIN run_lane_bindings lane ON lane.run_id=r.id AND lane.thread_id=r.thread_id "+
            "JOIN operation_effect_records pe ON pe.operation_id=parent.id "+
            "WHERE r.thread_id=? AND lane.lane_id=? AND pe.tool_id=? AND receipt.detail=? "+
            "AND receipt.outcome='completed' AND child.state='committed' AND parent.state='committed' "+
            "AND (?='' OR child.id=?) LIMIT 2",[
                SqlParameter.Text(version.threadId.value),SqlParameter.Text(version.laneId.value),SqlParameter.Text(parentTool),
                SqlParameter.Text(result),SqlParameter.Text(operationId??""),SqlParameter.Text(operationId??"")],8)
        if(rows.size!=1){return continuationDocumentObservationError()}
        let row=rows[0];scope.preflightStored(row.required(5));scope.preflightStored(row.required(6))
        let parent=decodeOperationPlan(row.required(5));let child=decodeOperationPlan(row.required(6))
        let intent=parsePluginDocumentIntent(child.canonicalArguments).value().getOrThrow();let binding=intent.binding()
        if(parent.toolName!=parentTool || !intent.referencesPayload || !intent.compareExchange ||
            intent.expectedRevision!=version.revision-1 || intent.key!=version.key ||
            canonicalAgentValue(intent.nextPayload.getOrThrow().value())!=canonicalAgentValue(version.payload.value()) ||
            httpIntentText(binding,"thread_id")!=version.threadId.value || httpIntentText(binding,"lane_id")!=version.laneId.value ||
            httpIntentText(binding,"namespace")!=version.namespace || httpIntentText(binding,"package_digest")!=packageDigest ||
            httpIntentText(binding,"generation")!=generation || httpIntentText(binding,"configuration_digest")!=configurationDigest ||
            httpIntentText(binding,"contribution")!=parentTool){return continuationDocumentObservationError()}
        let proof=match(verifyCompletedPluginDocumentPayloadHistory(transaction,OperationId(row.required(4)),
            OperationId(row.required(0)),RunId(row.required(2)),ItemId(row.required(7)),parent,child,row.required(1),scope)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(proof.revision!=version.revision || canonicalAgentValue(proof.payload.value())!=canonicalAgentValue(version.payload.value())){
            return continuationDocumentObservationError()}
        Result.Ok(CompletedPluginDocumentObservation(row.required(0),row.required(1),row.required(2),
            Int64.parse(row.required(3)),proof.revision,proof.payload,binding,proof.expectedPayload,
            modelPolicySha256Text(row.required(6)),modelPolicySha256Text(result)))
    }catch(_:Exception){continuationDocumentObservationError()}
}

// Only the bounded suffix after the last consumed, completed claim is walked.
// Raw bodies are not retained during this proof pass; every predecessor is an
// exact CAS expected reference, including a pause later followed by resume.
public func observeContinuationDocumentPayloadChain(transaction:SqliteTransaction,version:ContinuationDocumentVersion,
    anchorOperation:String,anchorRevision:Int64,anchorDigest:String,parentTool:String,packageDigest:String,
    generation:String,configurationDigest:String,scope:ContinuationDocumentReadScope
):Result<Array<CompletedPluginDocumentObservation>> {
    try {
        if(anchorRevision<1 || version.revision<anchorRevision || version.revision-anchorRevision>=256){
            return continuationDocumentObservationError()}
        let reverse=ArrayList<CompletedPluginDocumentObservation>();var current=version
        var declaredBytes:Int64=0
        while(true){
            // Preserve the previous aggregate semantic boundary. Metadata
            // transport does not silently expand the supported chain size.
            if(current.payload.bytes>8388608-declaredBytes){return continuationDocumentObservationError()}
            declaredBytes+=current.payload.bytes
            let value=match(observeCompletedPluginDocumentPayload(transaction,current,parentTool,packageDigest,
                generation,configurationDigest,scope)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(item)=>item}
            reverse.add(value)
            if(value.revision==anchorRevision){
                if(value.operationId!=anchorOperation || value.digest!=anchorDigest){return continuationDocumentObservationError()}
                break
            }
            current=ContinuationDocumentVersion(version.threadId,version.laneId,version.namespace,version.key,
                value.revision-1,value.expectedPayload.getOrThrow())
        }
        Result.Ok(Array<CompletedPluginDocumentObservation>(reverse.size,{index=>reverse[reverse.size-1-index]}))
    }catch(_:Exception){continuationDocumentObservationError()}
}
