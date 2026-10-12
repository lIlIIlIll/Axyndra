package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

func journalCopyPath(value:AgentValue):Array<String>{
    if(value.unifiedKind!=ValueKind.List || value.items.isEmpty() || value.items.size>16){throw IllegalStateException("opaque copy path is not bounded")}
    let path=ArrayList<String>()
    for(node in value.items){
        if(node.unifiedKind!=ValueKind.Text || node.text=="" || node.text.size>64 || node.text.contains("\u{0000}")){
            throw IllegalStateException("opaque copy segment is invalid")}
        path.add(node.text)
    };path.toArray()
}
// A private invocation-local cell lets the trusted synchronous callback
// publish its observed metadata without capturing mutable scalar locals.
class OpaqueRowJournalEncodedEventMetadata {
    var size:Int64=0
    var digest=""
    var kind=""
}
func journalCopyField(value:AgentValue,path:Array<String>,offset:Int64):AgentValue{
    if(offset==path.size){return value}
    if(value.unifiedKind!=ValueKind.Object){throw IllegalStateException("opaque copy source path is not an object")}
    journalCopyField(value.field(path[offset]).getOrThrow(),path,offset+1)
}
func journalReplaceNull(value:AgentValue,path:Array<String>,offset:Int64,replacement:AgentValue):AgentValue{
    if(offset==path.size){if(value.unifiedKind!=ValueKind.Null || replacement.unifiedKind!=ValueKind.Text){
        throw IllegalStateException("opaque copy only fills an exact null text field")};return replacement}
    if(value.unifiedKind!=ValueKind.Object || value.field(path[offset]).isNone()){throw IllegalStateException("opaque copy target path is not exact")}
    objectValue(value.fields.toArray().map{field=>if(field.name==path[offset]){
        ValueField(field.name,journalReplaceNull(field.value,path,offset+1,replacement))}else{field}})
}

// Its one-shot transaction lifetime and constructor are Store-private. The
// Host's actual artifact lock is held before entering settlement. It passes
// only immutable reference-content readers; Native never supplies this proof,
// Source, path, owner, SQL, tenant or a reusable file reader.
public class SqlitePluginRowJournalCommitProof <: PluginDocumentPayloadCommitProof{
    private let tx:SqliteTransaction
    private let run:RunId
    private let parent:OperationId
    private let operation:OperationId
    private let plan:NormalizedOperationPlan
    private let intent:PluginDocumentRowJournalIntent
    private let links:Array<ContextReadFactLink>
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let guard:()->Result<Unit>
    private let lock=Mutex()
    private var active=true
    private var applied=false
    public prop runId:RunId{get(){run}}
    public prop parentOperationId:OperationId{get(){parent}}
    public prop operationId:OperationId{get(){operation}}
    public func payload():AgentValue{intent.nextPayload.getOrThrow().value()}
    init(tx:SqliteTransaction,run:RunId,parent:OperationId,operation:OperationId,plan:NormalizedOperationPlan,
        intent:PluginDocumentRowJournalIntent,links:Array<ContextReadFactLink>,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>){
        this.tx=tx;this.run=run;this.parent=parent;this.operation=operation;this.plan=plan;this.intent=intent;this.links=links;this.allocate=allocate;this.guard=guard}
    private func current():Unit{
        journalStreamCheck(guard)
        let initial=journalWindowFactPlan(tx,links[0])
        let selected=tx.documentStorageBackend(httpIntentText(intent.binding(),"namespace"),intent.key)
        match(selected){case Some(value)=>match(latestJournalOriginalWindowBackend(value)){case Some(value)=>value.check(initial);
            case None=>throw IllegalStateException("actual window backend changed")};case None=>throw IllegalStateException("actual window backend disappeared")}
    }
    private func content(reference:PluginDocumentPayloadReference,read:(PluginDocumentPayloadReference)->Result<String>):String{
        current();requireDocumentPayloadMetadata(tx,reference)
        let raw=match(read(reference)){case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(raw)=>raw}
        if(raw.size!=reference.bytes || modelPolicySha256Text(raw)!=reference.digest){throw IllegalStateException("opaque copy bytes differ from their actual immutable fact")}
        current();requireDocumentPayloadMetadata(tx,reference);raw
    }
    private func withEvent(entry:AgentValue,read:(PluginDocumentPayloadReference)->Result<String>,consume:(String)->Unit):Unit{
        current()
        if(!httpIntentExactFields(entry,["id","key","revision","operation","created_at_millis","event","copies"]) ||
            entry.field("copies").getOrThrow().unifiedKind!=ValueKind.List){throw IllegalStateException("opaque append event descriptor is not exact")}
        let owner=allocate(65536)
        try{
            var event=entry.field("event").getOrThrow();var retained=logicalJsonWriteReservationBytes(event,8388608)
            owner.ensureRetainedPeak(retained*4+logicalJsonValueNodeCount(event)*512+1048576)
            let paths=ArrayList<Array<String>>()
            for(copy in entry.field("copies").getOrThrow().items){current()
                if(!httpIntentExactFields(copy,["path","from"])){throw IllegalStateException("opaque copy descriptor is not exact")}
                let path=journalCopyPath(copy.field("path").getOrThrow())
                for(previous in paths){var equal:Int64=0
                    while(equal<min(path.size,previous.size) && path[equal]==previous[equal]){equal++}
                    if(equal==min(path.size,previous.size)){throw IllegalStateException("opaque copy paths overlap or repeat")}}
                paths.add(path);let from=copy.field("from").getOrThrow()
                if(!httpIntentExactFields(from,["fact","row","path"])){throw IllegalStateException("opaque copy source is not exact")}
                let factIndex=journalWindowInteger(from.field("fact").getOrThrow());let rowIndex=journalWindowInteger(from.field("row").getOrThrow())
                if(factIndex<1 || factIndex>=links.size || rowIndex<0){throw IllegalStateException("opaque copy source is not an observed body window")}
                let link=links[factIndex];let sourcePlan=journalWindowFactPlan(tx,link)
                if(httpIntentText(sourcePlan.canonicalArguments.field("window").getOrThrow(),"kind")!="rows" ||
                    rowIndex>=journalWindowInteger(sourcePlan.canonicalArguments.field("window").getOrThrow().field("count").getOrThrow())){
                    throw IllegalStateException("opaque copy selects an unobserved source row")}
                let reference=parsePluginDocumentPayloadReference(requireContextReadFact(tx,link.operationId,link.runId).output().field("documents").getOrThrow().items[0].field("payload").getOrThrow()).value().getOrThrow()
                owner.ensureRetainedPeak(retained*4+reference.bytes*4+1048576)
                let raw=content(reference,read);let nodes=logicalJsonNodeCount(raw)
                owner.ensureRetainedPeak(retained*4+reference.bytes*4+nodes*512+1048576)
                let body=decodeAgentValue(raw,maxBytes:8388608).value().getOrThrow()
                let original=body.field("rows").getOrThrow().items[rowIndex].field("payload").getOrThrow().text
                let sourceNodes=logicalJsonNodeCount(original)
                owner.ensureRetainedPeak(retained*4+reference.bytes*4+original.size*2+(nodes+sourceNodes)*512+1048576)
                let payload=decodeAgentValue(original,maxBytes:67108864).value().getOrThrow()
                let replacement=journalCopyField(payload,journalCopyPath(from.field("path").getOrThrow()),0)
                if(replacement.unifiedKind!=ValueKind.Text){throw IllegalStateException("opaque copy source must be an observed text field")}
                retained=journalStreamAdd(retained,stringifyUnifiedJson(replacement).size)
                owner.ensureRetainedPeak(retained*4+reference.bytes*4+original.size*2+(nodes+sourceNodes)*512+1048576)
                event=journalReplaceNull(event,path,0,replacement)
            }
            let bytes=logicalJsonWriteReservationBytes(event,67108864)
            owner.ensureRetainedPeak(bytes*4+logicalJsonValueNodeCount(event)*512+1048576)
            let raw=encodeAgentValue(event);let record=event.field("record").getOrThrow()
            if(event.field("version").getOrThrow().asNumberText()!="3" ||
                httpIntentText(record,"id")!=httpIntentText(entry,"key") ||
                journalWindowInteger(record.field("revision").getOrThrow())!=journalWindowInteger(entry.field("revision").getOrThrow()) ||
                httpIntentText(event,"operation")!=httpIntentText(entry,"operation")){
                throw IllegalStateException("opaque appended payload differs from its frozen event/index metadata")}
            let scope=httpIntentText(record,"scopeKind");let value=httpIntentText(record,"scopeKey")
            let observation=requireWindowObservation(tx,links[0],journalWindowFactPlan(tx,links[0]));observation.close()
            if(!["global","user","workspace","session"].contains(scope) || (scope=="global" && value!="") || (scope=="user" && value=="") ||
                (scope=="session" && value!=httpIntentText(intent.binding(),"thread_id"))){throw IllegalStateException("opaque append access label differs from its actual namespace/thread")}
            // Workspace equality is proved by the trusted fixed data dialect
            // callback, never by a path or identity supplied by Native.
            requireRowJournalAppendAccess(tx,intent.binding(),intent.key,record)
            current();consume(raw);current()
        }finally{owner.close()}
    }
    public func materialize(read:(PluginDocumentPayloadReference)->Result<String>):Result<Unit>{
        lock.lock();var manifestOwner:?OpaqueRowJournalWindowObservation=None
        try{
            if(!active){return documentPayloadError("plugin.row_journal_commit_closed")};active=false
            current();manifestOwner=Some(requireToolWindowInput(tx,links,intent.binding(),windowFactDataList(tx,links)))
            let manifest=manifestOwner.getOrThrow().value
            let next=intent.nextPayload.getOrThrow();let owner=allocate(max(1,next.bytes))
            try{
                let raw=content(next,read);owner.ensureDecoded(raw.size,logicalJsonNodeCount(raw))
                let proposal=decodeAgentValue(raw,maxBytes:8388608).value().getOrThrow()
                if(!httpIntentExactFields(proposal,["schema","manifest_sha256","entries"]) ||
                    httpIntentText(proposal,"schema")!="axyndra.opaque-row-journal-append/v1" ||
                    httpIntentText(proposal,"manifest_sha256")!=intent.manifestPayload.digest ||
                    proposal.field("entries").getOrThrow().unifiedKind!=ValueKind.List || proposal.field("entries").getOrThrow().items.isEmpty()){
                    throw IllegalStateException("opaque append proposal is not the complete frozen original batch")}
                let selected=tx.documentStorageBackend(httpIntentText(intent.binding(),"namespace"),intent.key)
                let backend=match(selected){case Some(value)=>match(latestJournalOriginalWindowBackend(value)){case Some(value)=>value;
                    case None=>throw IllegalStateException("fixed actual append backend missing")};case None=>throw IllegalStateException("fixed actual append backend missing")}
                if(backend.revision(tx)!=intent.expectedRevision){throw IllegalStateException("opaque journal logical revision changed")}
                let before=backend.full(tx,journalWindowFactPlan(tx,links[0]),{=>current();Result<Unit>.Ok(())})
                let entries=ArrayList<OpaqueRowJournalPreparedAppend>()
                for(entry in proposal.field("entries").getOrThrow().items){
                    let observed=OpaqueRowJournalEncodedEventMetadata()
                    withEvent(entry,read,{encoded=>observed.size=encoded.size;observed.digest=modelPolicySha256Text(encoded)
                        observed.kind=httpIntentText(decodeAgentValue(encoded,maxBytes:67108864).value().getOrThrow().field("record").getOrThrow(),"kind")})
                    let captured=entry
                    entries.add(OpaqueRowJournalPreparedAppend(journalWindowInteger(entry.field("id").getOrThrow()),httpIntentText(entry,"key"),
                        journalWindowInteger(entry.field("revision").getOrThrow()),observed.kind,httpIntentText(entry,"operation"),
                        journalWindowInteger(entry.field("created_at_millis").getOrThrow()),observed.size,observed.digest,{consume=>
                            withEvent(captured,read,{encoded=>let bytes=encoded.toArray();var offset:Int64=0
                                while(offset<bytes.size){current();let end=min(bytes.size,offset+65536);consume(bytes[offset..end]);offset=end}})}))}
                // Predict every original row/event/absence and full future
                // chain before the first SQL mutation, never from a trigger's
                // already modified post-write state.
                let future=predictOpaqueRowJournalAppendFence(tx,before,entries.toArray(),allocate,{=>current();Result<Unit>.Ok(())})
                for(index in 0..entries.size){let descriptor=entries[index];let entry=proposal.field("entries").getOrThrow().items[index]
                    withEvent(entry,read,{encoded=>
                        if(encoded.size!=descriptor.payloadBytes || modelPolicySha256Text(encoded)!=descriptor.payloadDigest){throw IllegalStateException("opaque append bytes changed after prediction")}
                        tx.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(?,?,?,?,?,?)",
                            [SqlParameter.Int64Value(descriptor.eventId),SqlParameter.Text(descriptor.key),SqlParameter.Int64Value(descriptor.revision),
                                SqlParameter.Text(descriptor.operation),SqlParameter.Text(encoded),SqlParameter.Int64Value(descriptor.createdAtMillis)])
                        tx.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES(?,NULL,?,?,?) ON CONFLICT(id) DO UPDATE SET thread_id=NULL,kind=excluded.kind,payload=excluded.payload,revision=excluded.revision",
                            [SqlParameter.Text(descriptor.key),SqlParameter.Text(descriptor.kind),SqlParameter.Text(encoded),SqlParameter.Int64Value(descriptor.revision)])})}
                updateRowJournalWindowRevision(tx,intent,future,operation,run,plan,manifest)
                let check={=>current();let after=backend.full(tx,journalWindowFactPlan(tx,links[0]),{=>current();Result<Unit>.Ok(())})
                    if(after.digest!=future.digest || after.chain!=future.chain || after.nextEvent!=future.nextEvent ||
                        backend.revision(tx)!=intent.expectedRevision+1){throw IllegalStateException("opaque append or Receipt changed the predicted complete future state")}}
                check();tx.retainBackendPostCheck(check);applied=true;Result.Ok(())
            }finally{owner.close()}
        }catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(_:Exception){documentPayloadError("plugin.row_journal_append_unverified")}
        finally{match(manifestOwner){case Some(value)=>value.close();case None=>()};lock.unlock()}
    }
    func didApply():Bool{lock.lock();try{applied}finally{lock.unlock()}}
    func close():Unit{lock.lock();try{active=false}finally{lock.unlock()}}
}
func updateRowJournalWindowRevision(tx:SqliteTransaction,intent:PluginDocumentRowJournalIntent,future:OpaqueRowJournalStreamFence,
    operation:OperationId,run:RunId,plan:NormalizedOperationPlan,manifest:AgentValue):Unit{
    let namespace=httpIntentText(intent.binding(),"namespace")
    if(intent.expectedRevision==1){tx.execute("INSERT INTO plugin_documents(thread_id,lane_id,namespace,document_key,revision,payload) VALUES('$row-journal','canonical',?,?,2,'opaque-fact-events-v3')",
        [SqlParameter.Text(namespace),SqlParameter.Text(intent.key)])}
    else{tx.execute("UPDATE plugin_documents SET revision=? WHERE thread_id='$row-journal' AND lane_id='canonical' AND namespace=? AND document_key=? AND revision=? AND payload='opaque-fact-events-v3'",
        [SqlParameter.Int64Value(intent.expectedRevision+1),SqlParameter.Text(namespace),SqlParameter.Text(intent.key),SqlParameter.Int64Value(intent.expectedRevision)])
        requireStoreChanged(tx,"opaque journal logical CAS changed")}
    let state=objectValue([ValueField("sha256",textValue(future.digest)),ValueField("chain_sha256",textValue(future.chain)),
        ValueField("next_event_id",integerValue(future.nextEvent)),ValueField("rows",integerValue(future.rows)),ValueField("events",integerValue(future.events))])
    let evidence=objectValue([ValueField("schema",textValue("axyndra.row-journal-commit-observation/v1")),ValueField("plan_sha256",textValue(modelPolicySha256Text(encodeOperationPlan(plan)))),
        ValueField("binding",intent.binding()),ValueField("manifest_payload",intent.manifestPayload.value()),ValueField("before_state",manifest.field("state").getOrThrow()),
        ValueField("after_state",state),ValueField("revision",integerValue(intent.expectedRevision+1))])
    if(!tx.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='row_journal_commit_observed'",[SqlParameter.Text(operation.value)]).isEmpty()){
        throw IllegalStateException("opaque journal actual child already has a commit observation")}
    tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES(?,?,?,'row_journal_commit_observed',?,?)",
        [SqlParameter.Text(httpIntentText(intent.binding(),"thread_id")),SqlParameter.Text(run.value),SqlParameter.Text(operation.value),SqlParameter.Text(encodeStoredValue(evidence)),SqlParameter.Int64Value(agentUtcMillis())])
}

func requireRowJournalAppendAccess(tx:SqliteTransaction,binding:AgentValue,key:String,record:AgentValue):Unit{
    let selected=tx.documentStorageBackend(httpIntentText(binding,"namespace"),key)
    match(selected){case Some(value)=>match(latestJournalOriginalWindowBackend(value)){case Some(value)=>
        if(value.permitsAppendRecord(binding,record)){return};case None=>()};case None=>()}
    throw IllegalStateException("opaque append access label is not allowed by its already proved actual fixed mapping")
}
