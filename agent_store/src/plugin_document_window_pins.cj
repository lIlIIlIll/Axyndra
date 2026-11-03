package agent_store

import agent_domain.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

func windowFactDataList(tx:SqliteTransaction,links:Array<ContextReadFactLink>):AgentValue{
    listValue(links.map{link=>requireContextReadFact(tx,link.operationId,link.runId).output()})}
// Package-private lifetime holder; it grants no Source or consumption.
class OpaqueRowJournalWindowObservation{
    let value:AgentValue
    private let owner:LogicalJsonOwnerReservation
    init(value:AgentValue,owner:LogicalJsonOwnerReservation){this.value=value;this.owner=owner}
    func close():Unit{owner.close()}
}
func requireWindowObservation(tx:SqliteTransaction,link:ContextReadFactLink,read:NormalizedOperationPlan):OpaqueRowJournalWindowObservation{
    let metadata=tx.query("SELECT id,length(CAST(payload AS BLOB)) FROM audit_events WHERE operation_id=? AND run_id=? AND kind='plugin_document_window_observed' LIMIT 2",
        [SqlParameter.Text(link.operationId.value),SqlParameter.Text(link.runId.value)])
    if(metadata.size!=1){throw IllegalStateException("window lacks one actual payload observation")}
    let bytes=journalStreamInteger(metadata[0].required(1));let request=read.canonicalArguments
    let selected=tx.documentStorageBackend(httpIntentText(request.field("binding").getOrThrow(),"namespace"),httpIntentText(request,"key"))
    let backend=match(selected){case Some(value)=>match(latestJournalOriginalWindowBackend(value)){case Some(value)=>value;
        case None=>throw IllegalStateException("window observation backend changed")};case None=>throw IllegalStateException("window observation backend absent")}
    let owner=backend.observationOwner(read,bytes)
    try{
    let rows=tx.query("SELECT payload FROM audit_events WHERE id=? AND operation_id=? AND run_id=? AND kind='plugin_document_window_observed' AND length(CAST(payload AS BLOB))=?",
        [SqlParameter.Text(metadata[0].required(0)),SqlParameter.Text(link.operationId.value),SqlParameter.Text(link.runId.value),SqlParameter.Int64Value(bytes)])
    if(rows.size!=1){throw IllegalStateException("window actual payload observation changed during capture")}
    let value=decodeStoredValue(rows[0].required(0));let fact=requireContextReadFact(tx,link.operationId,link.runId)
    if(!httpIntentExactFields(value,["schema","thread_id","lane_id","run_id","read_operation_id","read_item_id","plan_sha256","binding","key","revision","window","manifest_sha256","state","visible_rows","payload"]) ||
        httpIntentText(value,"schema")!="axyndra.document-window-observation/v1" || httpIntentText(value,"run_id")!=link.runId.value ||
        httpIntentText(value,"read_operation_id")!=link.operationId.value || httpIntentText(value,"read_item_id")!=fact.sourceItemId.value ||
        httpIntentText(value,"plan_sha256")!=modelPolicySha256Text(encodeOperationPlan(read)) ||
        canonicalAgentValue(value.field("binding").getOrThrow())!=canonicalAgentValue(read.canonicalArguments.field("binding").getOrThrow()) ||
        canonicalAgentValue(value.field("window").getOrThrow())!=canonicalAgentValue(read.canonicalArguments.field("window").getOrThrow()) ||
        httpIntentText(value,"key")!=httpIntentText(read.canonicalArguments,"key")){
        throw IllegalStateException("window observation differs from its actual source and complete original plan")}
    let result=fact.output().field("documents").getOrThrow().items[0]
    if(canonicalAgentValue(result.field("payload").getOrThrow())!=canonicalAgentValue(value.field("payload").getOrThrow()) ||
        canonicalAgentValue(result.field("revision").getOrThrow())!=canonicalAgentValue(value.field("revision").getOrThrow())){
        throw IllegalStateException("window observation is not its immutable complete output")}
    requireDocumentPayloadMetadata(tx,parsePluginDocumentPayloadReference(value.field("payload").getOrThrow()).value().getOrThrow())
    backend.check(read)
    OpaqueRowJournalWindowObservation(value,owner)
    }catch(error:Exception){owner.close();throw error}
}

// Shared data integrity for already committed actual read facts. It creates
// no read Source or grant. Callers separately prove their Tool12/Context9
// current source, canonical parent/provider, lane, epoch and configuration.
func requirePluginDocumentWindowFacts(tx:SqliteTransaction,links:Array<ContextReadFactLink>,binding:AgentValue,
    dataList:AgentValue,complete:Bool):OpaqueRowJournalWindowObservation{
    if(links.isEmpty() || links.size>8 || dataList.unifiedKind!=ValueKind.List || dataList.items.size!=links.size){
        throw IllegalStateException("window input needs its entire ordered original fact prefix")}
    var manifest:?OpaqueRowJournalWindowObservation=None;var transferred=false
    var offset:Int64=0;var firstRead:?NormalizedOperationPlan=None
    try{
    let seen=HashSet<String>()
    for(index in 0..links.size){let link=links[index]
        if(seen.contains(link.operationId.value)){throw IllegalStateException("window input repeats an actual fact")};seen.add(link.operationId.value)
        let fact=requireContextReadFact(tx,link.operationId,link.runId);let read=journalWindowFactPlan(tx,link)
        if(!isContextReadPlan(read) || link.runId.value!=httpIntentText(binding,"run_id") ||
            canonicalAgentValue(dataList.items[index])!=canonicalAgentValue(fact.output()) ||
            canonicalAgentValue(read.canonicalArguments.field("binding").getOrThrow())!=canonicalAgentValue(binding)){
            throw IllegalStateException("window bytes cannot be transferred to another frozen scope")}
        if(index==0){firstRead=Some(read)}else if(httpIntentText(read.canonicalArguments,"schema")!=httpIntentText(firstRead.getOrThrow().canonicalArguments,"schema") ||
            httpIntentText(read.canonicalArguments,"projection_digest")!=httpIntentText(firstRead.getOrThrow().canonicalArguments,"projection_digest") ||
            httpIntentText(read.canonicalArguments,"key")!=httpIntentText(firstRead.getOrThrow().canonicalArguments,"key")){
            throw IllegalStateException("window facts belong to different current projections or fixed mappings")}
        let prior=contextReadFactLinksFromValue(read.canonicalArguments.field("prior_facts").getOrThrow())
        if(prior.size!=index){throw IllegalStateException("window fact omits an earlier completed read")}
        for(position in 0..index){if(canonicalAgentValue(prior[position].toValue())!=canonicalAgentValue(links[position].toValue())){
            throw IllegalStateException("window fact substitutes an earlier actual original link")}}
        let observed=requireWindowObservation(tx,link,read);var retained=false
        try{let observation=observed.value;let window=read.canonicalArguments.field("window").getOrThrow()
        if(index==0){
            if(httpIntentText(window,"kind")!="manifest" ||
                httpIntentText(observation,"manifest_sha256")!=httpIntentText(observation.field("payload").getOrThrow(),"sha256")){
                throw IllegalStateException("window chain has no actual original manifest")};manifest=Some(observed);retained=true
        }else{
            if(httpIntentText(window,"kind")!="rows" || journalWindowInteger(window.field("manifest_fact").getOrThrow())!=0 ||
                journalWindowInteger(window.field("offset").getOrThrow())!=offset ||
                httpIntentText(observation,"manifest_sha256")!=httpIntentText(manifest.getOrThrow().value,"manifest_sha256") ||
                canonicalAgentValue(observation.field("state").getOrThrow())!=canonicalAgentValue(manifest.getOrThrow().value.field("state").getOrThrow()) ||
                canonicalAgentValue(observation.field("revision").getOrThrow())!=canonicalAgentValue(manifest.getOrThrow().value.field("revision").getOrThrow()) ||
                canonicalAgentValue(observation.field("visible_rows").getOrThrow())!=canonicalAgentValue(manifest.getOrThrow().value.field("visible_rows").getOrThrow())){
                throw IllegalStateException("window body skips, overlaps or changed the full original journal fence")}
            offset=journalStreamAdd(offset,journalWindowInteger(window.field("count").getOrThrow()))
        }
        }finally{if(!retained){observed.close()}}
    }
    let original=manifest.getOrThrow().value;let visible=journalWindowInteger(original.field("visible_rows").getOrThrow())
    if(offset>visible || (complete && offset!=visible)){throw IllegalStateException("window input is not the complete current corpus")}
    let selected=tx.documentStorageBackend(httpIntentText(binding,"namespace"),httpIntentText(original,"key"))
    let backend=match(selected){case Some(value)=>match(latestJournalOriginalWindowBackend(value)){case Some(value)=>value;
        case None=>throw IllegalStateException("window backend not explicitly bound")};case None=>throw IllegalStateException("window backend absent")}
    let actual=backend.full(tx,firstRead.getOrThrow(),{=>Result<Unit>.Ok(())});let state=original.field("state").getOrThrow()
    if(actual.digest!=httpIntentText(state,"sha256") || actual.chain!=httpIntentText(state,"chain_sha256") ||
        actual.nextEvent!=journalWindowInteger(state.field("next_event_id").getOrThrow()) ||
        actual.rows!=journalWindowInteger(state.field("rows").getOrThrow()) || actual.events!=journalWindowInteger(state.field("events").getOrThrow()) ||
        backend.revision(tx)!=journalWindowInteger(original.field("revision").getOrThrow())){
        throw IllegalStateException("actual full state or revision changed since the original window read")}
    transferred=true;manifest.getOrThrow()
    }finally{if(!transferred){match(manifest){case Some(value)=>value.close();case None=>()}}}
}
func requireToolWindowInput(tx:SqliteTransaction,links:Array<ContextReadFactLink>,binding:AgentValue,dataList:AgentValue):OpaqueRowJournalWindowObservation{
    if(validatePluginDocumentBinding(binding).isError() || links.isEmpty()){throw IllegalStateException("Tool window input requires its strict twelve-field binding")}
    let first=requireContextReadFact(tx,links[0].operationId,links[0].runId)
    requireContextReadFactConsumptionFields(tx,documentPayloadParentOperation(first),links[0].runId,ItemId(first.origin.parentCallItemId),
        httpIntentText(binding,"contribution"),links)
    for(link in links){let read=journalWindowFactPlan(tx,link)
        if(!pluginDocumentRowJournalReadAuthority(read) || !pluginDocumentRowJournalReadResultValid(requireContextReadFact(tx,link.operationId,link.runId).output(),read.canonicalArguments)){
            throw IllegalStateException("Tool window input is not an actual strict Tool12 read")}}
    requirePluginDocumentWindowFacts(tx,links,binding,dataList,true)
}
// A separate paid-upload predicate for an observed manifest/body prefix.
// Every Tool12 canonical Source/parent/run/lane/epoch and full current state
// proof is identical to final preparation; only complete coverage waits for
// the final verifier. This cannot authorize mutation or a prepared result.
func requireToolWindowPrefix(tx:SqliteTransaction,links:Array<ContextReadFactLink>,binding:AgentValue,dataList:AgentValue):OpaqueRowJournalWindowObservation{
    if(validatePluginDocumentBinding(binding).isError() || links.isEmpty()){throw IllegalStateException("Tool window input requires its strict twelve-field binding")}
    let first=requireContextReadFact(tx,links[0].operationId,links[0].runId)
    requireContextReadFactConsumptionFields(tx,documentPayloadParentOperation(first),links[0].runId,ItemId(first.origin.parentCallItemId),
        httpIntentText(binding,"contribution"),links)
    for(link in links){let read=journalWindowFactPlan(tx,link)
        if(!pluginDocumentRowJournalReadAuthority(read) || !pluginDocumentRowJournalReadResultValid(requireContextReadFact(tx,link.operationId,link.runId).output(),read.canonicalArguments)){
            throw IllegalStateException("Tool window input is not an actual strict Tool12 read")}}
    requirePluginDocumentWindowFacts(tx,links,binding,dataList,false)
}
public func verifyObservedPluginDocumentWindowPrefix(tx:SqliteTransaction,links:Array<ContextReadFactLink>,binding:AgentValue,dataList:AgentValue):Result<Unit>{
    // Parentless Context9 has its own strict actual source predicate.
    if(binding.field("provider").isSome()){return verifyObservedPluginDocumentContextWindowPrefix(tx,links,binding,dataList)}
    try{let observed=requireToolWindowPrefix(tx,links,binding,dataList);observed.close();Result.Ok(())}
    catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}catch(_:Exception){documentPayloadError("plugin.document_window_prefix_stale")}
}
public func verifyPreparedPluginDocumentWindowInput(tx:SqliteTransaction,links:Array<ContextReadFactLink>,binding:AgentValue,dataList:AgentValue):Result<Unit>{
    // A separately implemented strict Context9 actual-parentless predicate.
    // The Tool predicate and the old v1 single-fact body are never widened.
    if(binding.field("provider").isSome()){return verifyPreparedPluginDocumentContextWindowInput(tx,links,binding,dataList)}
    try{let observed=requireToolWindowInput(tx,links,binding,dataList);observed.close();Result.Ok(())}
    catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}catch(_:Exception){documentPayloadError("plugin.document_window_input_stale")}
}
func windowPinEvidence(links:Array<ContextReadFactLink>,value:AgentValue,result:Bool):AgentValue{
    objectValue([ValueField("schema",textValue(if(result){"axyndra.document-window-result-prepared/v1"}else{"axyndra.document-window-payload-prepared/v1"})),
        ValueField("facts",listValue(links.map{link=>link.toValue()})),ValueField("value_sha256",textValue(modelPolicySha256Text(canonicalAgentValue(value)))),ValueField("value",value)])}
func retainWindowPin(tx:SqliteTransaction,links:Array<ContextReadFactLink>,value:AgentValue,result:Bool,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:()->Result<Unit>):Unit{
    if(links.isEmpty()){throw IllegalStateException("window pin has no actual facts")}
    let first=requireContextReadFact(tx,links[0].operationId,links[0].runId);let parent=documentPayloadParentOperation(first)
    if(!tx.query("SELECT id FROM operations WHERE tool_call_item_id=?",[SqlParameter.Text(first.origin.parentCallItemId)]).isEmpty()){
        throw IllegalStateException("window pin cannot be staged after parent preparation")}
    let binding=if(result){value.field("host_plan").getOrThrow().field("binding").getOrThrow()}else{
        parsePluginDocumentRowJournalIntent(value).value().getOrThrow().binding()}
    let observed=requireToolWindowInput(tx,links,binding,windowFactDataList(tx,links))
    try{let observation=observed.value
    if(result){
        let host=value.field("host_plan").getOrThrow()
        if(!pluginDocumentRowJournalFrozenResultValid(host) || validateContextReadInputProjection(value.field("input").getOrThrow(),links).isError()){
            throw IllegalStateException("window final parent differs from its full original input")}
        requireDocumentPayloadMetadata(tx,parsePluginDocumentPayloadReference(host.field("result_payload").getOrThrow()).value().getOrThrow())
        for(raw in host.field("intents").getOrThrow().items){
            let child=pluginDocumentRowJournalChildArguments(value,httpIntentText(raw,"id")).value().getOrThrow()
            let intent=parsePluginDocumentRowJournalIntent(child).value().getOrThrow()
            if(intent.expectedRevision!=journalWindowInteger(observation.field("revision").getOrThrow()) ||
                canonicalAgentValue(intent.manifestPayload.value())!=canonicalAgentValue(observation.field("payload").getOrThrow())){
                throw IllegalStateException("window parent does not freeze the actual original manifest")}}
    }else{
        let intent=parsePluginDocumentRowJournalIntent(value).value().getOrThrow()
        if(intent.expectedRevision!=journalWindowInteger(observation.field("revision").getOrThrow()) ||
            canonicalAgentValue(intent.manifestPayload.value())!=canonicalAgentValue(observation.field("payload").getOrThrow())){
            throw IllegalStateException("window intent does not freeze its actual original manifest")}
        requireDocumentPayloadMetadata(tx,intent.manifestPayload)
        match(intent.nextPayload){case Some(next)=>requireDocumentPayloadMetadata(tx,next);case None=>()}
    }
    journalStreamCheck(verifyContent)
    // Current scope, facts, metadata and entire fence are checked again
    // after the actual immutable writer/file-content check.
    let rechecked=requireToolWindowInput(tx,links,binding,windowFactDataList(tx,links));rechecked.close()
    let kind=if(result){"plugin_document_window_result_prepared"}else{"plugin_document_window_payload_prepared"}
    let evidence=encodeStoredValue(windowPinEvidence(links,value,result))
    if(evidence.size>65536){throw IllegalStateException("window pin exceeds its original compact witness bound")}
    let lease=allocate(max(1,evidence.size))
    try{
        let existing=tx.query("SELECT id,length(CAST(payload AS BLOB)) FROM audit_events WHERE operation_id=? AND run_id=? AND kind=? LIMIT 9",
            [SqlParameter.Text(parent.value),SqlParameter.Text(links[0].runId.value),SqlParameter.Text(kind)])
        if(existing.size>8){throw IllegalStateException("window pin history is ambiguous")}
        var same=false
        for(row in existing){
            let bytes=journalStreamInteger(row.required(1))
            if(bytes<1 || bytes>65536){throw IllegalStateException("window prior pin exceeds its compact durable codec")}
            let priorOwner=allocate(bytes)
            try{
                priorOwner.ensureDecoded(bytes,bytes)
                let stored=tx.query("SELECT payload FROM audit_events WHERE id=? AND operation_id=? AND run_id=? AND kind=? AND length(CAST(payload AS BLOB))=?",
                    [SqlParameter.Text(row.required(0)),SqlParameter.Text(parent.value),SqlParameter.Text(links[0].runId.value),SqlParameter.Text(kind),SqlParameter.Int64Value(bytes)])
                if(stored.size!=1){throw IllegalStateException("window prior pin changed during paid capture")}
                if(stored[0].required(0)==evidence){same=true}
            }finally{priorOwner.close()}}
        if(!same){
            if(result && !existing.isEmpty()){throw IllegalStateException("window final result was frozen differently")}
            if(!result && existing.size>=8){throw IllegalStateException("window intent pin count exceeded")}
            tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES(?,?,?,?,?,?)",
                [SqlParameter.Text(httpIntentText(binding,"thread_id")),SqlParameter.Text(links[0].runId.value),SqlParameter.Text(parent.value),
                    SqlParameter.Text(kind),SqlParameter.Text(evidence),SqlParameter.Int64Value(agentUtcMillis())])}
    }finally{lease.close()}
    }finally{observed.close()}
}
public func retainPreparedPluginDocumentWindowPayload(tx:SqliteTransaction,links:Array<ContextReadFactLink>,value:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:()->Result<Unit>):Result<Unit>{
    try{retainWindowPin(tx,links,value,false,allocate,verifyContent);Result.Ok(())}
    catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}catch(_:Exception){documentPayloadError("plugin.document_window_payload_pin_stale")}
}
public func retainPreparedPluginDocumentWindowResult(tx:SqliteTransaction,links:Array<ContextReadFactLink>,parent:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:()->Result<Unit>):Result<Unit>{
    try{retainWindowPin(tx,links,parent,true,allocate,verifyContent);Result.Ok(())}
    catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}catch(_:Exception){documentPayloadError("plugin.document_window_result_pin_stale")}
}
func requireWindowPin(tx:SqliteTransaction,parent:OperationId,run:RunId,links:Array<ContextReadFactLink>,value:AgentValue,result:Bool,
    allocate:(Int64)->LogicalJsonOwnerReservation):Unit{
    let evidence=encodeStoredValue(windowPinEvidence(links,value,result));let kind=if(result){"plugin_document_window_result_prepared"}else{"plugin_document_window_payload_prepared"}
    let lease=allocate(max(1,evidence.size))
    try{let rows=tx.query("SELECT id FROM audit_events WHERE operation_id=? AND run_id=? AND kind=? AND payload=? LIMIT 2",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(kind),SqlParameter.Text(evidence)])
        if(rows.size!=1){throw IllegalStateException("window parent lacks its exact Host data preparation pin")}}
    finally{lease.close()}
}
func requireDocumentWindowPayloadPlan(tx:SqliteTransaction,run:RunId,item:ItemId,plan:NormalizedOperationPlan,
    allocate:?(Int64)->LogicalJsonOwnerReservation,checkCurrent:Bool):Unit{
    let parent=plan.canonicalArguments;let host=parent.field("host_plan").getOrThrow()
    if(allocate.isNone() || !pluginDocumentRowJournalFrozenResultValid(host) || plan.contextReadFacts.isEmpty() ||
        validateContextReadInputProjection(parent.field("input").getOrThrow(),plan.contextReadFacts).isError()){
        throw IllegalStateException("window parent needs full actual fact provenance and its original paid owner")}
    let first=requireContextReadFact(tx,plan.contextReadFacts[0].operationId,run);let operation=documentPayloadParentOperation(first)
    if(first.origin.parentCallItemId!=item.value){throw IllegalStateException("window input belongs to another parent")}
    if(checkCurrent){let observed=requireToolWindowInput(tx,plan.contextReadFacts,host.field("binding").getOrThrow(),windowFactDataList(tx,plan.contextReadFacts));observed.close()}
    else{for(link in plan.contextReadFacts){let _=requireContextReadFact(tx,link.operationId,link.runId)}}
    requireWindowPin(tx,operation,run,plan.contextReadFacts,parent,true,allocate.getOrThrow())
    for(raw in host.field("intents").getOrThrow().items){let child=pluginDocumentRowJournalChildArguments(parent,httpIntentText(raw,"id")).value().getOrThrow()
        let intent=parsePluginDocumentRowJournalIntent(child).value().getOrThrow()
        // The exact final whole-parent pin above freezes every read intent,
        // original manifest and full fact prefix. Only an append owns a new
        // immutable proposal payload and therefore requires its separate pin.
        if(intent.append){requireWindowPin(tx,operation,run,plan.contextReadFacts,child,false,allocate.getOrThrow())}}
    requireDocumentPayloadMetadata(tx,parsePluginDocumentPayloadReference(host.field("result_payload").getOrThrow()).value().getOrThrow())
}
