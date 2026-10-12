package agent_store

import agent_domain.*
import agent_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// Private construction occurs only inside the already executing canonical
// ContextRead transaction. The descriptive interface cannot be decoded from
// a worker DTO; this one-shot implementation has no public constructor/path.
public class SqlitePluginDocumentJournalStreamReadProof <: PluginDocumentPayloadReadProof {
    private let tx:SqliteTransaction
    private let source:DirectToolCallRef
    private let actualLane:LaneId
    private let encodedPlan:String
    private let backend:SqliteOpaqueRowJournalStreamBackend
    private let state:JournalStreamV2Fence
    private let observed:FixedJournalCellObservation
    private let actualRevision:Int64
    private let guard:()->Result<Unit>
    private let lock=Mutex()
    private var active=true
    private var verified:?String=None
    public prop threadId:ThreadId{get(){source.threadId}}
    public prop runId:RunId{get(){source.runId}}
    public prop operationId:OperationId{get(){source.operationId}}
    public prop laneId:LaneId{get(){actualLane}}
    public prop key:String{get(){httpIntentText(plan().canonicalArguments,"key")}}
    public prop revision:Int64{get(){actualRevision}}
    public prop bytes:Int64{get(){observed.bytes}}
    init(tx:SqliteTransaction,source:DirectToolCallRef,plan:NormalizedOperationPlan,lane:LaneId,
        backend:SqliteOpaqueRowJournalStreamBackend,guard:()->Result<Unit>){
        this.tx=tx;this.source=source;this.actualLane=lane;this.encodedPlan=encodeOperationPlan(plan)
        this.backend=backend;this.guard=guard;this.actualRevision=backend.revision(tx)
        this.state=backend.full(tx,guard)
        this.observed=backend.emit(tx,source,plan,lane,state,actualRevision,guard,None)
        if(backend.full(tx,guard).digest!=state.digest || backend.revision(tx)!=actualRevision){
            throw IllegalStateException("stream preparation changed before its actual proof")}}
    public func plan():NormalizedOperationPlan{decodeOperationPlan(encodedPlan)}
    // consume and finish are supplied by the actual Host artifact owner. They
    // may not retain raw columns or turn the Source into a native permission.
    // A successful return needs native cursor/writer/file ACK and registered
    // exact metadata before the one Root can complete its Receipt.
    public func materialize(consume:(Int64,Array<Byte>)->Result<Unit>,
        finish:(SqliteTransaction,String,Int64)->Result<AgentValue>):Result<AgentValue>{
        lock.lock()
        try{
            if(!active){return documentPayloadError("plugin.document_journal_stream_closed")};active=false
            journalStreamCheck(guard);let actual=plan();backend.check(actual)
            requireContextReadExecutingInTransaction(tx,source,actual)
            if(backend.full(tx,guard).digest!=state.digest || backend.revision(tx)!=revision){
                return documentPayloadError("plugin.document_journal_stream_fence_changed")}
            let copied=backend.emit(tx,source,actual,actualLane,state,revision,guard,Some({offset,bytes=>
                match(consume(offset,bytes)){case Result.Ok(_)=>();case Result.Err(error)=>throw PluginDocumentGuardFailure(error)}}))
            if(copied.bytes!=observed.bytes || copied.digest!=observed.digest){
                return documentPayloadError("plugin.document_journal_stream_content_changed")}
            journalStreamCheck(guard)
            if(backend.full(tx,guard).digest!=state.digest || backend.revision(tx)!=revision){
                return documentPayloadError("plugin.document_journal_stream_fence_changed")}
            let value=match(finish(tx,copied.digest,copied.bytes)){case Result.Ok(value)=>value;case Result.Err(error)=>return Result.Err(error)}
            let reference=parsePluginDocumentJournalStreamReference(value).value().getOrThrow()
            if(reference.digest!=copied.digest || reference.bytes!=copied.bytes){
                return documentPayloadError("plugin.document_journal_stream_reference_changed")}
            let owner=backend.owner(65536)
            try{
                owner.ensureRetainedPeak(1048576+65536*8)
                requireJournalStreamArtifactMetadata(tx,reference);journalStreamCheck(guard);backend.check(actual)
                if(backend.full(tx,guard).digest!=state.digest || backend.revision(tx)!=revision){
                    return documentPayloadError("plugin.document_journal_stream_fence_changed")}
                let evidence=objectValue([ValueField("schema",textValue("axyndra.journal-stream-observation/v2")),
                    ValueField("thread_id",textValue(source.threadId.value)),ValueField("lane_id",textValue(actualLane.value)),ValueField("run_id",textValue(source.runId.value)),
                    ValueField("read_operation_id",textValue(source.operationId.value)),ValueField("read_item_id",textValue(source.canonicalItemId.value)),
                    ValueField("plan_sha256",textValue(modelPolicySha256Text(encodedPlan))),ValueField("binding",actual.canonicalArguments.field("binding").getOrThrow()),
                    ValueField("projection_digest",actual.canonicalArguments.field("projection_digest").getOrThrow()),
                    ValueField("access_policy_digest",actual.canonicalArguments.field("access_policy_digest").getOrThrow()),
                    ValueField("key",textValue(key)),ValueField("revision",integerValue(revision)),ValueField("epoch",integerValue(source.epoch)),
                    ValueField("state",state.value()),ValueField("stream",value)])
                let old=tx.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='plugin_document_journal_stream_observed' LIMIT 2",[SqlParameter.Text(source.operationId.value)])
                let encoded=encodeStoredValue(evidence)
                if(!old.isEmpty() || encoded.size>65536){return documentPayloadError("plugin.document_journal_stream_observation_ambiguous")}
                journalStreamCheck(guard)
                tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES(?,?,?,'plugin_document_journal_stream_observed',?,?)",
                    [SqlParameter.Text(source.threadId.value),SqlParameter.Text(source.runId.value),SqlParameter.Text(source.operationId.value),SqlParameter.Text(encoded),SqlParameter.Int64Value(agentUtcMillis())])
                verified=Some(stringifyUnifiedJson(value));Result.Ok(value)
            }finally{owner.close()}
        }catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(_:Exception){documentPayloadError("plugin.document_journal_stream_unverified")}
        finally{lock.unlock()}}
    func verifiedResult(value:AgentValue):Bool{lock.lock();try{match(verified){case Some(valueText)=>valueText==stringifyUnifiedJson(value);case None=>false}}finally{lock.unlock()}}
    func close():Unit{lock.lock();try{active=false}finally{lock.unlock()}}
}
func requireJournalStreamArtifactMetadata(tx:SqliteTransaction,reference:PluginDocumentJournalStreamReference):Unit{
    let rows=tx.query("SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=?",[SqlParameter.Text(reference.digest)])
    if(rows.size!=1 || rows[0].required(0)!=PLUGIN_DOCUMENT_JOURNAL_STREAM_CONTENT_TYPE ||
        rows[0].required(1)!=reference.bytes.toString() || rows[0].required(3)!="blobs/"+reference.digest+".txt"){
        throw IllegalStateException("actual journal stream artifact metadata changed")}
    let metadata=parseUnifiedJson(rows[0].required(2),maxBytes:4096,maxDepth:4)
    if(!httpIntentExactFields(metadata,["version","ref","sha256","bytes","content_type"]) ||
        metadata.field("version").getOrThrow().asNumberText()!="1" ||
        httpIntentText(metadata,"ref")!=reference.artifactRef || httpIntentText(metadata,"sha256")!=reference.digest ||
        metadata.field("bytes").getOrThrow().asNumberText()!=reference.bytes.toString() ||
        httpIntentText(metadata,"content_type")!=PLUGIN_DOCUMENT_JOURNAL_STREAM_CONTENT_TYPE){
        throw IllegalStateException("actual journal stream artifact identity changed")}}

func readPluginDocumentJournalStreamInTransaction(tx:SqliteTransaction,source:DirectToolCallRef,
    plan:NormalizedOperationPlan,materializer:PluginDocumentPayloadMaterializer,guard:()->Result<Unit>):AgentValue{
    requireContextReadExecutingInTransaction(tx,source,plan)
    let lane=requirePluginDocumentJournalStreamReadScope(tx,source,plan);let request=plan.canonicalArguments
    let namespace=httpIntentText(request.field("binding").getOrThrow(),"namespace");let key=httpIntentText(request,"key")
    let backend=match(tx.documentStorageBackend(namespace,key)){case Some(value)=>match(value as SqliteOpaqueRowJournalStreamBackend){
        case Some(actual)=>actual;case None=>throw IllegalStateException("new stream backend was not explicitly assembled")}
        case None=>throw IllegalStateException("new stream data access backend missing")}
    let current={=>journalStreamCheck(guard);backend.check(plan);requireContextReadExecutingInTransaction(tx,source,plan)
        if(requirePluginDocumentJournalStreamReadScope(tx,source,plan).value!=lane.value){
            return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.document_journal_stream_scope_changed","actual stream scope changed"))}
        Result<Unit>.Ok(())}
    let proof=SqlitePluginDocumentJournalStreamReadProof(tx,source,plan,lane,backend,current)
    let value=try{match(materializer.materialize(proof)){case Result.Ok(value)=>value;case Result.Err(error)=>throw PluginDocumentGuardFailure(error)}}
        finally{proof.close()}
    if(!proof.verifiedResult(value)){throw IllegalStateException("actual stream materializer did not consume its one-shot proof")}
    objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_READ_RESULT_SCHEMA)),
        ValueField("request_digest",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),ValueField("documents",listValue([
            objectValue([ValueField("key",textValue(key)),ValueField("revision",integerValue(proof.revision)),ValueField("stream",value)])]))])
}

// The original Tool source predicate is retained under a new strict dialect.
func requirePluginDocumentJournalStreamToolReadScope(transaction: SqliteTransaction, source: DirectToolCallRef,
    plan: NormalizedOperationPlan): LaneId {
    let request = plan.canonicalArguments
    if (!pluginDocumentJournalStreamReadAuthority(plan)) { throw IllegalStateException("invalid document read authority") }
    let binding = request.field("binding").getOrThrow()
    let origin = match (source.origin) { case DirectCallOrigin.ContextRead(value) => value
        case _ => throw IllegalStateException("document read is not a ContextRead") }
    let lane = requirePluginDocumentLane(transaction, source.threadId, source.runId, source.epoch)
    if (httpIntentText(binding, "thread_id") != source.threadId.value || httpIntentText(binding, "run_id") != source.runId.value ||
        binding.field("epoch").getOrThrow().asNumberText() != source.epoch.toString() ||
        httpIntentText(binding, "lane_id") != lane.value || origin.parentCallItemId == "" ||
        origin.ownerNamespace != httpIntentText(binding, "namespace") || origin.packageDigest != httpIntentText(binding, "package_digest") ||
        origin.configurationDigest != httpIntentText(binding, "configuration_digest") ||
        origin.projectionDigest != httpIntentText(request, "projection_digest")) {
        throw IllegalStateException("document read has another canonical scope") }
    let parents = transaction.query("SELECT item.payload FROM items item JOIN item_tree_edges edge ON edge.item_id=item.id " +
        "AND edge.thread_id=item.thread_id WHERE item.id=? AND item.thread_id=? AND item.turn_id=? AND edge.lane_id=? " +
        "AND item.kind='tool_call' AND NOT EXISTS(SELECT 1 FROM operations o WHERE o.tool_call_item_id=item.id)",
        [SqlParameter.Text(origin.parentCallItemId), SqlParameter.Text(source.threadId.value),
            SqlParameter.Text(source.turnId.value), SqlParameter.Text(lane.value)])
    if (parents.size != 1) { throw IllegalStateException("document read lost its unprepared canonical parent") }
    match (decodeStoredThreadContent(parents[0].required(0))) {
        case ThreadItemContent.ToolCall(id, name, _) => if (id.value != httpIntentText(binding, "parent_call_id") ||
            name != httpIntentText(binding, "contribution")) { throw IllegalStateException("document read parent differs from its frozen binding") }
        case _ => throw IllegalStateException("document parent is not a ToolCall") }
    lane
}


// Called inside the existing executing ContextRead transaction, after the
// complete Source, normalized plan, state register and handoff validation.
// The Tool12 predicate is separate and is never accepted by this function.
func requirePluginDocumentJournalStreamContextReadScope(transaction:SqliteTransaction,source:DirectToolCallRef,
    plan:NormalizedOperationPlan):LaneId{
    if(!isContextReadPlan(plan) || !pluginDocumentContextJournalStreamReadAuthority(plan)){
        throw IllegalStateException("invalid parentless document window authority")}
    let binding=plan.canonicalArguments.field("binding").getOrThrow()
    let origin=match(source.origin){case DirectCallOrigin.ContextRead(value)=>value
        case _=>throw IllegalStateException("document window has another Source kind")}
    let lane=requirePluginDocumentLane(transaction,source.threadId,source.runId,source.epoch)
    if(origin.parentCallItemId!="" || origin.parentKind!="" || origin.parentOperationId!="" ||
        origin.parentDecisionId!="" || origin.parentScopedCallId!="" ||
        httpIntentText(binding,"thread_id")!=source.threadId.value || httpIntentText(binding,"run_id")!=source.runId.value ||
        binding.field("epoch").getOrThrow().asNumberText()!=source.epoch.toString() ||
        httpIntentText(binding,"lane_id")!=lane.value ||
        origin.ownerNamespace!=httpIntentText(binding,"namespace") || origin.packageDigest!=httpIntentText(binding,"package_digest") ||
        origin.configurationDigest!=httpIntentText(binding,"configuration_digest") ||
        origin.projectionDigest!=httpIntentText(plan.canonicalArguments,"projection_digest")){
        throw IllegalStateException("document window lost its exact parentless Run and lane")}
    lane
}

func requirePluginDocumentJournalStreamReadScope(tx:SqliteTransaction,source:DirectToolCallRef,plan:NormalizedOperationPlan):LaneId{
    if(httpIntentText(plan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_JOURNAL_STREAM_READ_SCHEMA){
        return requirePluginDocumentJournalStreamToolReadScope(tx,source,plan)}
    requirePluginDocumentJournalStreamContextReadScope(tx,source,plan)
}
