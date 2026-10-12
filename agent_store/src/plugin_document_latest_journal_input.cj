package agent_store

import agent_domain.*
import std.sync.*
import yjson.*
import yjson_support.*

func latestJournalInputRequireFact(tx:SqliteTransaction,link:ContextReadFactLink,binding:AgentValue,
    data:AgentValue,payment:ContextReadCompletedMetadataPayment):NormalizedOperationPlan{
    let fact=payment.fact()
    if(canonicalAgentValue(fact.reference())!=canonicalAgentValue(link.toValue()) ||
        canonicalAgentValue(fact.output())!=canonicalAgentValue(data)){
        throw IllegalStateException("journal input descriptor differs from its actual complete fact")}
    let read=payment.plan();let request=read.canonicalArguments
    let contextRead=pluginDocumentContextLatestJournalStreamReadAuthority(read)
    if(!contextRead && !pluginDocumentLatestJournalStreamReadAuthority(read)){
        throw IllegalStateException("journal input is not the new exact read-only dialect")}
    if(canonicalAgentValue(request.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
        link.runId.value!=httpIntentText(binding,"run_id") ||
        !(if(contextRead){pluginDocumentContextLatestJournalStreamReadResultValid(data,request)}
          else{pluginDocumentLatestJournalStreamReadResultValid(data,request)})){
        throw IllegalStateException("journal input is not its original frozen request and output")}
    let origin=fact.origin
    if(origin.ownerNamespace!=httpIntentText(binding,"namespace") || origin.packageDigest!=httpIntentText(binding,"package_digest") ||
        origin.configurationDigest!=httpIntentText(binding,"configuration_digest") ||
        origin.projectionDigest!=httpIntentText(request,"projection_digest")){
        throw IllegalStateException("journal input changed its actual original owner or projection")}
    payment.origin(fact.sourceItemId)
    let epoch=journalStreamInteger(binding.field("epoch").getOrThrow().asNumberText())
    if(requirePluginDocumentLane(tx,ThreadId(httpIntentText(binding,"thread_id")),link.runId,epoch).value!=httpIntentText(binding,"lane_id")){
        throw IllegalStateException("journal input lost its actual current Run lane and epoch")}
    if(contextRead){
        if(!pluginDocumentContextBindingValid(binding) || origin.parentCallItemId!="" || origin.parentKind!="" ||
            origin.parentOperationId!="" || origin.parentDecisionId!="" || origin.parentScopedCallId!=""){
            throw IllegalStateException("parentless journal input changed an original parent field")}
    }else{
        if(!validatePluginDocumentBinding(binding).isOk() || origin.parentCallItemId==""){
            throw IllegalStateException("Tool journal input lost its exact actual parent")}
        requireContextReadFactConsumptionFieldsPaid(tx,documentPayloadParentOperation(fact),link.runId,ItemId(origin.parentCallItemId),
            httpIntentText(binding,"contribution"),[link],payment)
    }
    read
}

func latestJournalInputRequireObservation(tx:SqliteTransaction,link:ContextReadFactLink,
    plan:NormalizedOperationPlan,data:AgentValue,backend:SqliteOpaqueRowJournalLatestStreamBackend,
    guard:()->Result<Unit>):PluginDocumentLatestJournalStreamReference{
    let request=plan.canonicalArguments;let binding=request.field("binding").getOrThrow()
    let rows=tx.query("SELECT thread_id,payload FROM audit_events WHERE operation_id=? AND run_id=? "+
        "AND kind='plugin_document_latest_journal_observed' LIMIT 2",[SqlParameter.Text(link.operationId.value),SqlParameter.Text(link.runId.value)])
    if(rows.size!=1 || rows[0].required(0)!=httpIntentText(binding,"thread_id")){
        throw IllegalStateException("journal input lost its sole actual observed stream")}
    let value=decodeStoredValue(rows[0].required(1));let document=data.field("documents").getOrThrow().items[0]
    if(!httpIntentExactFields(value,["schema","thread_id","lane_id","run_id","read_operation_id","read_item_id","plan_sha256",
        "binding","projection_digest","access_policy_digest","view_policy_digest","key","revision","epoch","private_event_fence","stream"]) ||
        httpIntentText(value,"schema")!="axyndra.journal-stream-observation/v3" ||
        httpIntentText(value,"thread_id")!=httpIntentText(binding,"thread_id") || httpIntentText(value,"lane_id")!=httpIntentText(binding,"lane_id") ||
        httpIntentText(value,"run_id")!=link.runId.value || httpIntentText(value,"read_operation_id")!=link.operationId.value ||
        httpIntentText(value,"read_item_id")!=link.sourceItemId.value ||
        httpIntentText(value,"plan_sha256")!=modelPolicySha256Text(encodeOperationPlan(plan)) ||
        canonicalAgentValue(value.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
        httpIntentText(value,"projection_digest")!=httpIntentText(request,"projection_digest") ||
        httpIntentText(value,"access_policy_digest")!=httpIntentText(request,"access_policy_digest") ||
        httpIntentText(value,"view_policy_digest")!=httpIntentText(request,"view_policy_digest") ||
        httpIntentText(value,"key")!=httpIntentText(request,"key") ||
        value.field("epoch").getOrThrow().asNumberText()!=binding.field("epoch").getOrThrow().asNumberText() ||
        value.field("revision").getOrThrow().asNumberText()!=document.field("revision").getOrThrow().asNumberText() ||
        canonicalAgentValue(value.field("stream").getOrThrow())!=canonicalAgentValue(document.field("stream").getOrThrow())){
        throw IllegalStateException("journal observation no longer matches all original canonical fields")}
    let reference=parsePluginDocumentLatestJournalStreamReference(document.field("stream").getOrThrow()).value().getOrThrow()
    let metadata=tx.query("SELECT length(CAST(metadata AS BLOB)),length(CAST(mime AS BLOB)),length(CAST(relative_path AS BLOB)) FROM artifacts WHERE hash=? LIMIT 2",
        [SqlParameter.Text(reference.digest)])
    if(metadata.size!=1 || journalStreamInteger(metadata[0].required(0))<1 || journalStreamInteger(metadata[0].required(0))>4096 ||
        journalStreamInteger(metadata[0].required(1))>128 || journalStreamInteger(metadata[0].required(2))>256){
        throw IllegalStateException("journal input artifact metadata changed its fixed original extent")}
    requireLatestJournalStreamArtifactMetadata(tx,reference);journalStreamCheck(guard)
    let actual=backend.full(tx,guard)
    // The ignored SQL-cell fingerprint never leaves this private proof.
    if(!httpIntentDigest(httpIntentText(value,"private_event_fence")) || actual.digest!=httpIntentText(value,"private_event_fence") ||
        journalStreamAdd(actual.events,1)!=journalStreamInteger(document.field("revision").getOrThrow().asNumberText())){
        throw IllegalStateException("journal input full private event fence changed")}
    reference
}

// Construction is package-private and occurs only after reloading the sole
// committed actual fact, Source enclosure, current scope and private fence.
// Native DTOs cannot construct this object, a path, SQL or a read permission.
public class SqlitePluginDocumentLatestJournalInputProof {
    private let tx:SqliteTransaction
    private let link:ContextReadFactLink
    private let binding:AgentValue
    private let data:AgentValue
    private let backend:SqliteOpaqueRowJournalLatestStreamBackend
    private let guard:()->Result<Unit>
    private let configurationCurrent:()->Result<Unit>
    private let charge:ContextReadCompletedMetadataPayment
    private let lock=Mutex()
    private let inMaterialize=AtomicBool(false)
    private var active=true
    private var verified=false
    init(tx:SqliteTransaction,link:ContextReadFactLink,binding:AgentValue,data:AgentValue,
        backend:SqliteOpaqueRowJournalLatestStreamBackend,guard:()->Result<Unit>){
        this.tx=tx;this.link=link;this.binding=binding;this.data=data;this.backend=backend;this.guard=guard
        let owner=ContextReadCompletedMetadataPayment(tx,link,{bytes=>backend.owner(bytes)},guard)
        try{
            journalStreamCheck(guard)
            let read=latestJournalInputRequireFact(tx,link,binding,data,owner)
            this.configurationCurrent=backend.capture(read)
            journalStreamCheck(configurationCurrent)
            let _=owner.withObservation({=>latestJournalInputRequireObservation(tx,link,read,data,backend,guard)})
            this.charge=owner
        }catch(error:Exception){owner.close();throw error}
    }
    private func current():Result<Unit>{
        if(!inMaterialize.load()){return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,
            "plugin.document_latest_input_closed","private input cursor has left its materialization scope"))}
        journalStreamCheck(guard);journalStreamCheck(configurationCurrent)
        charge.current(binding)
    }
    // The actual Host file owner reports its independently counted complete
    // EOF/hash only after FD close and the captured native parser's final ACK.
    // Replays remain inside this same proof/TX and cannot adopt new metadata.
    public func materialize(consume:(PluginDocumentLatestJournalStreamReference,()->Result<Unit>)->Result<(Int64,String)>):Result<Unit>{
        lock.lock()
        try{
            if(!active){return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,
                "plugin.document_latest_input_closed","actual completed input is one-shot"))}
            active=false;inMaterialize.store(true)
            let read=latestJournalInputRequireFact(tx,link,binding,data,charge)
            let reference=charge.withObservation({=>latestJournalInputRequireObservation(tx,link,read,data,backend,{=>current()})})
            let copied=match(consume(reference,{=>current()})){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
            if(copied[0]!=reference.bytes || copied[1]!=reference.digest){
                return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.document_latest_input_content_changed",
                    "actual EOF and hash differ from the original paid read artifact"))}
            journalStreamCheck({=>current()})
            let after=latestJournalInputRequireFact(tx,link,binding,data,charge)
            let actual=charge.withObservation({=>latestJournalInputRequireObservation(tx,link,after,data,backend,{=>current()})})
            if(actual.bytes!=reference.bytes || actual.digest!=reference.digest){throw IllegalStateException("journal EOF changed its actual original artifact")}
            verified=true;Result<Unit>.Ok(())
        }catch(error:PluginDocumentGuardFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.document_latest_input_stale",
            "actual completed read or private EOF fence changed"))}
        finally{inMaterialize.store(false);lock.unlock()}
    }
    func verifiedResult():Bool{lock.lock();try{verified}finally{lock.unlock()}}
    func close():Unit{inMaterialize.store(false);lock.lock();try{active=false;charge.close()}finally{lock.unlock()}}
}

// This is a real bounded input materialization, never an authorize-only grant
// that could be returned and used to open a file in another transaction.
public func consumePreparedPluginDocumentLatestJournalInput(tx:SqliteTransaction,link:ContextReadFactLink,
    binding:AgentValue,data:AgentValue,guard:()->Result<Unit>,
    materialize:(SqlitePluginDocumentLatestJournalInputProof)->Result<Unit>):Result<Unit>{
    try{
        if((!pluginDocumentContextBindingValid(binding) && !validatePluginDocumentBinding(binding).isOk()) ||
            !pluginDocumentLatestJournalStreamResultDataValid(data,httpIntentText(data,"request_digest"),
                httpIntentText(data.field("documents").getOrThrow().items[0],"key"))){
            throw IllegalStateException("actual completed input requires its strict original result and binding")}
        let key=httpIntentText(data.field("documents").getOrThrow().items[0],"key")
        let backend=match(tx.documentStorageBackend(httpIntentText(binding,"namespace"),key)){
            case Some(value)=>match(value as SqliteOpaqueRowJournalLatestStreamBackend){case Some(actual)=>actual
                case None=>throw IllegalStateException("actual latest input backend was not explicitly assembled")}
            case None=>throw IllegalStateException("actual latest input backend disappeared")}
        let proof=SqlitePluginDocumentLatestJournalInputProof(tx,link,binding,data,backend,guard)
        try{
            let result=materialize(proof)
            if(result.isOk() && !proof.verifiedResult()){
                throw IllegalStateException("actual input owner did not consume its one-shot proof through EOF ACK")}
            result
        }finally{proof.close()}
    }catch(error:PluginDocumentGuardFailure){Result<Unit>.Err(error.failure)}
    catch(_:Exception){Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.document_latest_input_stale",
        "completed input cannot consume another Source, current scope, configuration or artifact"))}
}
