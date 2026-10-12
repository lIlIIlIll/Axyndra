package agent_store
import agent_domain.*
import agent_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// This private finite proof is created only after actual source, complete
// normalized plan, handoff and exact Tool12/Context9 scope checks. The Host
// reserves proof.bytes before invoking its one-shot selected body copy.
public class SqlitePluginDocumentWindowReadProof <: PluginDocumentPayloadReadProof{
    private let transaction:SqliteTransaction
    private let source:DirectToolCallRef
    private let encodedPlan:String
    private let actualLane:LaneId
    private let backend:SqliteOpaqueRowJournalWindowBackend
    private let catalog:OpaqueRowJournalWindowCatalog
    private let current:()->Result<Unit>
    private let lock=Mutex()
    private var active=true
    private var verified:?String=None
    private let count:Int64
    public prop threadId:ThreadId{get(){source.threadId}}
    public prop runId:RunId{get(){source.runId}}
    public prop operationId:OperationId{get(){source.operationId}}
    public prop laneId:LaneId{get(){actualLane}}
    public prop key:String{get(){httpIntentText(decodeOperationPlan(encodedPlan).canonicalArguments,"key")}}
    public prop revision:Int64{get(){catalog.revision}}
    public prop bytes:Int64{get(){count}}
    init(tx:SqliteTransaction,source:DirectToolCallRef,plan:NormalizedOperationPlan,lane:LaneId,
        backend:SqliteOpaqueRowJournalWindowBackend,catalog:OpaqueRowJournalWindowCatalog,current:()->Result<Unit>){
        this.transaction=tx;this.source=source;this.encodedPlan=encodeOperationPlan(plan);this.actualLane=lane
        this.backend=backend;this.catalog=catalog;this.current=current;this.count=rowJournalWindowRawBytes(catalog,plan.canonicalArguments.field("window").getOrThrow())}
    public func plan():NormalizedOperationPlan{decodeOperationPlan(encodedPlan)}
    public func materialize(action:(SqliteTransaction,PluginDocumentSnapshot,String)->Result<AgentValue>):Result<AgentValue>{
        lock.lock()
        try{
            if(!active){return documentPayloadError("plugin.document_window_closed")};active=false
            let actual=plan();requireContextReadExecutingInTransaction(transaction,source,actual)
            journalStreamCheck(current);backend.check(actual);requireRowJournalWindowPrefix(transaction,source,actual,catalog)
            let before=backend.full(transaction,actual,current)
            if(before.digest!=catalog.fence.digest || before.chain!=catalog.fence.chain || before.nextEvent!=catalog.fence.nextEvent ||
                backend.revision(transaction)!=catalog.revision){return documentPayloadError("plugin.document_window_fence_changed")}
            let raw=rowJournalWindowRaw(transaction,catalog,actual.canonicalArguments.field("window").getOrThrow(),current)
            if(raw.size!=count){return documentPayloadError("plugin.document_window_bytes_changed")}
            let digest=modelPolicySha256Text(raw)
            let snapshot=PluginDocumentSnapshot(source.threadId,actualLane,httpIntentText(actual.canonicalArguments.field("binding").getOrThrow(),"namespace"),key,revision,raw)
            let value=match(action(transaction,snapshot,digest)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let reference=parsePluginDocumentPayloadReference(value).value().getOrThrow()
            if(reference.bytes!=count || reference.digest!=digest){return documentPayloadError("plugin.document_window_content_changed")}
            requireDocumentPayloadMetadata(transaction,reference);journalStreamCheck(current);backend.check(actual)
            let after=backend.full(transaction,actual,current)
            if(after.digest!=catalog.fence.digest || after.chain!=catalog.fence.chain || backend.revision(transaction)!=catalog.revision){
                return documentPayloadError("plugin.document_window_fence_changed")}
            let observationOwner=backend.observationWriteOwner(actual)
            try{
            let evidence=objectValue([ValueField("schema",textValue("axyndra.document-window-observation/v1")),
                ValueField("thread_id",textValue(source.threadId.value)),ValueField("lane_id",textValue(actualLane.value)),ValueField("run_id",textValue(source.runId.value)),
                ValueField("read_operation_id",textValue(source.operationId.value)),ValueField("read_item_id",textValue(source.canonicalItemId.value)),
                ValueField("plan_sha256",textValue(modelPolicySha256Text(encodedPlan))),ValueField("binding",actual.canonicalArguments.field("binding").getOrThrow()),
                ValueField("key",textValue(key)),ValueField("revision",integerValue(revision)),ValueField("window",actual.canonicalArguments.field("window").getOrThrow()),
                ValueField("manifest_sha256",textValue(modelPolicySha256Text(catalog.raw))),ValueField("state",catalog.manifest.field("state").getOrThrow()),ValueField("visible_rows",integerValue(catalog.manifest.field("rows").getOrThrow().items.size)),ValueField("payload",value)])
            let old=transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='plugin_document_window_observed' LIMIT 2",[SqlParameter.Text(source.operationId.value)])
            let encoded=encodeStoredValue(evidence)
            if(encoded.size>65536){return documentPayloadError("plugin.document_window_observation_bound")}
            if(!old.isEmpty()){return documentPayloadError("plugin.document_window_observation_ambiguous")}
            transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES(?,?,?,'plugin_document_window_observed',?,?)",
                [SqlParameter.Text(source.threadId.value),SqlParameter.Text(source.runId.value),SqlParameter.Text(source.operationId.value),SqlParameter.Text(encoded),SqlParameter.Int64Value(agentUtcMillis())])
            verified=Some(stringifyUnifiedJson(value));Result.Ok(value)
            }finally{observationOwner.close()}
        }catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(_:Exception){documentPayloadError("plugin.document_window_unverified")}
        finally{lock.unlock()}
    }
    func verifiedResult(value:AgentValue):Bool{lock.lock();try{match(verified){case Some(v)=>v==stringifyUnifiedJson(value);case None=>false}}finally{lock.unlock()}}
    func close():Unit{lock.lock();try{active=false;catalog.close()}finally{lock.unlock()}}
}

func requirePluginDocumentWindowReadScope(tx:SqliteTransaction,source:DirectToolCallRef,plan:NormalizedOperationPlan):LaneId{
    if(httpIntentText(plan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_ROW_JOURNAL_READ_SCHEMA){
        return requirePluginDocumentRowJournalReadScope(tx,source,plan)}
    requirePluginDocumentContextWindowReadScope(tx,source,plan)
}
func readPluginDocumentWindowsInTransaction(tx:SqliteTransaction,source:DirectToolCallRef,plan:NormalizedOperationPlan,
    materializer:PluginDocumentPayloadMaterializer,guard:()->Result<Unit>):AgentValue{
    let lane=requirePluginDocumentWindowReadScope(tx,source,plan);let request=plan.canonicalArguments
    let namespace=httpIntentText(request.field("binding").getOrThrow(),"namespace");let key=httpIntentText(request,"key")
    let selected=tx.documentStorageBackend(namespace,key)
    let backend=match(selected){case Some(value)=>match(latestJournalOriginalWindowBackend(value)){
        case Some(value)=>value;case None=>throw IllegalStateException("window backend not explicitly bound")};case None=>throw IllegalStateException("window backend missing")}
    let scope={=>journalStreamCheck(guard);requireContextReadExecutingInTransaction(tx,source,plan)
        if(requirePluginDocumentWindowReadScope(tx,source,plan).value!=lane.value){return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.document_window_scope_changed","window actual scope changed"))}
        backend.check(plan);Result<Unit>.Ok(())}
    let catalog=backend.catalog(tx,source,plan,lane,scope)
    let proof=SqlitePluginDocumentWindowReadProof(tx,source,plan,lane,backend,catalog,scope)
    let value=try{requireRowJournalWindowPrefix(tx,source,plan,catalog)
        match(materializer.materialize(proof)){case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(value)=>value}}
        finally{proof.close()}
    if(!proof.verifiedResult(value)){throw IllegalStateException("window materializer did not consume its actual proof")}
    objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_ROW_JOURNAL_READ_RESULT_SCHEMA)),
        ValueField("request_digest",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),ValueField("documents",listValue([
            objectValue([ValueField("key",textValue(key)),ValueField("revision",integerValue(proof.revision)),ValueField("payload",value)])]))])
}

// The original Tool source predicate is retained under a new strict dialect.
func requirePluginDocumentRowJournalReadScope(transaction: SqliteTransaction, source: DirectToolCallRef,
    plan: NormalizedOperationPlan): LaneId {
    let request = plan.canonicalArguments
    if (!pluginDocumentRowJournalReadAuthority(plan)) { throw IllegalStateException("invalid document read authority") }
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

