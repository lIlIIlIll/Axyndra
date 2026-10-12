package agent_store

import agent_domain.*
import agent_runtime.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// These readers are trusted fixed-FD Artifact assembly. Native code never
// receives the SQL transaction, Source, reservation or current-check closure.
public type LivePolicyHistoricalRawReader = (PluginDocumentPayloadReference,()->Result<Unit>,
    (Int64,Array<Byte>)->Result<Unit>)->Result<(Int64,String)>
public type LivePolicyHistoricalIndexReader = (PluginDocumentPayloadReference,()->Result<Unit>,
    (AgentValue)->Unit)->Result<(Int64,String)>
public type LivePolicyHistoricalSlotSender = (PluginDocumentPayloadReference,
    LivePolicyHistoricalRawReader)->Result<Unit>

private class LivePolicyHistoricalPayloadState {
    var prior:?AgentValue=None<AgentValue>
    var indexCalls:Int64=0
    var active:Bool=true
    init(){}
}

// One ordered pass retains two incremental SHA states and counters, never
// the proposal's bytes. Each slot is bounded by the original 8MiB reference;
// the complete group has no artificial aggregate/count ceiling.
class LivePolicyHistoricalPayloadPass {
    let groupHash=SHA256()
    var slotHash=SHA256()
    var ordinal:Int64=0
    var total:Int64=0
    var offset:Int64=0
    var active:Bool=false
    var failed:Bool=false
    init(){}
    func begin():Unit{
        if(active || failed){throw IllegalStateException("historical slot pass has an unfinished or failed member")}
        slotHash=SHA256();offset=0;active=true
    }
    func observe(at:Int64,raw:Array<Byte>,expected:PluginDocumentPayloadReference,
        guard:()->Result<Unit>):Result<Unit>{
        try{
            journalStreamCheck(guard)
            if(!active || failed || at!=offset || raw.isEmpty() || raw.size>65536 ||
                raw.size>expected.bytes-offset){
                failed=true;throw IllegalStateException("historical slot changed complete ordered bounded bytes")}
            slotHash.write(raw);groupHash.write(raw)
            offset=journalStreamAdd(offset,raw.size);total=journalStreamAdd(total,raw.size)
            journalStreamCheck(guard);Result<Unit>.Ok(())
        }catch(error:PluginDocumentGuardFailure){failed=true;Result<Unit>.Err(error.failure)}
        catch(_:Exception){failed=true;historicalPayloadError("plugin.live_history_bytes_changed")}
    }
    func end(expected:PluginDocumentPayloadReference,copied:(Int64,String)):Unit{
        if(!active || failed || offset!=expected.bytes || copied[0]!=expected.bytes ||
            copied[1]!=expected.digest || journalStreamHex(slotHash.finish())!=expected.digest){
            failed=true;throw IllegalStateException("historical slot did not finish full fixed-FD EOF/hash/ACK")}
        active=false;ordinal=journalStreamAdd(ordinal,1)
    }
    func finish(manifest:AgentValue):Unit{
        if(active || failed || ordinal!=historicalPayloadInteger(manifest,"payload_count") ||
            total!=historicalPayloadInteger(manifest,"total_bytes") ||
            journalStreamHex(groupHash.finish())!=httpIntentText(manifest,"sha256")){
            failed=true;throw IllegalStateException("historical proposal did not finish its actual complete group SHA")}
    }
}

private func historicalPayloadInteger(value:AgentValue,name:String):Int64{
    let field=value.field(name).getOrThrow()
    if(field.unifiedKind!=ValueKind.Number){throw IllegalStateException("historical payload integer required")}
    journalStreamInteger(field.asNumberText())
}
private func historicalPayloadError(code:String):Result<Unit>{
    Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,code,
        "historical actual proposal, immutable member, complete bytes or current Source changed"))
}

// The index itself is data, not a read grant. Exact original six-field
// references determine ordered membership; full group bytes are checked
// separately before the caller may transmit any member to Native.
func livePolicyHistoricalIndexManifest(index:AgentValue):AgentValue{
    if(!httpIntentExactFields(index,["schema","native_manifest","payloads"]) ||
        httpIntentText(index,"schema")!="axyndra.plugin-live-policy-output-index/v1"){
        throw IllegalStateException("historical proposal requires the original complete output index")}
    let manifest=index.field("native_manifest").getOrThrow()
    if(!httpIntentExactFields(manifest,["schema","kind","total_bytes","sha256","payload_count","proposal_digest"]) ||
        httpIntentText(manifest,"schema")=="" || httpIntentText(manifest,"schema").size>512 ||
        httpIntentText(manifest,"kind")!="effect" || !httpIntentDigest(httpIntentText(manifest,"sha256")) ||
        !httpIntentDigest(httpIntentText(manifest,"proposal_digest"))){
        throw IllegalStateException("historical proposal requires its original complete effect manifest")}
    let members=index.field("payloads").getOrThrow()
    if(members.unifiedKind!=ValueKind.List || members.items.isEmpty() ||
        historicalPayloadInteger(manifest,"payload_count")!=members.items.size){
        throw IllegalStateException("historical index changed its complete ordinal member count")}
    var bytes:Int64=0
    for(row in members.items){
        let payload=parsePluginDocumentPayloadReference(row).value().getOrThrow()
        if(payload.bytes<1){throw IllegalStateException("historical proposal contains an empty member")}
        bytes=journalStreamAdd(bytes,payload.bytes)
    }
    if(bytes!=historicalPayloadInteger(manifest,"total_bytes")){
        throw IllegalStateException("historical index changed its complete aggregate byte count")}
    manifest
}

// The caller lends its actual retained Session owner; no second floor,
// slot or pool is created, and this method never closes that owner. The
// parent Source and historical production pin remain independent proof.
private func withLivePolicyHistoricalMember(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,through:Int64,currentLedger:AgentValue,
    produced:AgentValue,payload:PluginDocumentPayloadReference,allocate:(Int64)->LogicalJsonOwnerReservation,
    verifyContent:(PluginDocumentPayloadReference)->Result<Unit>,guard:()->Result<Unit>,
    metadataOwner:LogicalJsonOwnerReservation,metadataPeak:Int64,consume:()->Unit):Unit{
    journalStreamCheck(guard)
    let priorExtent=livePolicyStoredExtent(produced)
    // Complete descriptor DOM and stored encoding plus fixed wrapper/SHA
    // bookkeeping coexist with the original Session retained peak.
    let extra=journalStreamAdd(contextReadMetadataPeak(priorExtent.bytes,priorExtent.nodes),65536)
    metadataOwner.ensureRetainedPeak(journalStreamAdd(metadataPeak,extra))
    let descriptor=objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-step-data/v1")),
        ValueField("parent_operation_id",textValue(parent.value)),ValueField("parent_binding_digest",textValue(plan.bindingDigest)),
        ValueField("prior_receipts",produced),ValueField("payloads",listValue([payload.value()]))])
    let extent=livePolicyStoredExtent(descriptor)
    metadataOwner.ensureRetainedPeak(journalStreamAdd(metadataPeak,
        journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),65536)))
    let encoded=encodeStoredValue(descriptor)
    if(encoded.size!=extent.bytes){throw IllegalStateException("historical member changed its original paid pin encoding")}
    let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    let current:()->Unit={=>
        requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,plan,allocate,guard,
            phase:LivePolicyParentPhase.Executing,progress:Some(LivePolicyReadProgress(through,currentLedger,None)))
        requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
        livePolicyRequireOne(tx,"SELECT 1 WHERE (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND run_id=? "+
            "AND thread_id=? AND kind='plugin_live_policy_step_data_v1' AND payload=?)=1",
            [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Text(encoded)],
            "historical member lost its sole original same-parent production data pin")
        withPluginLivePolicyReceiptPrefixOwned(tx,parent,run,root.callId(),binding,through,currentLedger,allocate,guard,{actualOwner,retained=>
            requireLivePolicyParentTerminalBlobOwned(tx,payload,actualOwner,retained,{=>verifyContent(payload)},guard)})}
    current();journalStreamCheck(guard);consume();journalStreamCheck(guard);current()
}

// Read one actual known child. Unknown/recovery-only children have no path
// here. The original sequence reader verifies the immutable full child plan,
// reviewed approval, decision/handoff or User rejection, reserved Receipt,
// complete error data and current Source before and after this Unit callback.
public func withPluginLivePolicyKnownProposalSequencePayloads(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,
    sequence:Int64,currentThrough:Int64,currentLedger:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:(PluginDocumentPayloadReference)->Result<Unit>,
    guard:()->Result<Unit>,readIndex:LivePolicyHistoricalIndexReader,readPayload:LivePolicyHistoricalRawReader,
    consume:(AgentValue,PluginDocumentPayloadReference,AgentValue,AgentValue,LivePolicyHistoricalSlotSender)->Unit,
    metadataOwner:LogicalJsonOwnerReservation,metadataPeak:Int64):Unit{
    if(metadataPeak<1){throw IllegalStateException("historical data requires the actual retained Session invoice")}
    withPluginLivePolicyKnownProposalSequence(tx,root,parent,run,thread,epoch,parentPlan,
        sequence,currentThrough,currentLedger,allocate,verifyContent,guard,{tip,indexRef,errorData=>
            let state=LivePolicyHistoricalPayloadState()
            try{
                withLivePolicyStoredValue(tx,"e.normalized_plan",
                    " FROM operation_effect_records e WHERE e.operation_id=? AND e.run_id=? AND e.tool_call_item_id=?",
                    [SqlParameter.Text(httpIntentText(tip,"operation_id")),SqlParameter.Text(run.value),SqlParameter.Text(root.itemId().value)],
                    allocate,guard,{encoded=>
                        let plan=decodeOperationPlan(encoded)
                        if(modelPolicySha256Text(encoded)!=httpIntentText(tip,"plan_sha256") ||
                            !pluginLivePolicyStreamingChildWithinCeiling(parentPlan,plan) ||
                            journalStreamInteger(plan.canonicalArguments.field("sequence").getOrThrow().asNumberText())!=sequence){
                            throw IllegalStateException("historical payload changed its actual immutable child plan")}
                        let prior=plan.canonicalArguments.field("prior_receipts").getOrThrow()
                        if(!pluginLivePolicyLedgerReferenceValid(prior,parent.value,sequence-1)){
                            throw IllegalStateException("historical payload changed its original production prefix")}
                        let extent=livePolicyStoredExtent(prior)
                        // The old plan reader remains paid during this
                        // copy. Prepay detached nodes and both complete
                        // stored encodings before copying the small prefix,
                        // so retaining it cannot retain the entire old plan
                        // or its original raw String backing after close.
                        let rawCopies=journalStreamAdd(extent.bytes,journalStreamAdd(extent.bytes,extent.bytes))
                        let nodeCopies=journalStreamAdd(extent.nodes,extent.nodes)
                        metadataOwner.ensureRetainedPeak(journalStreamAdd(metadataPeak,
                            journalStreamAdd(contextReadMetadataPeak(rawCopies,nodeCopies),65536)))
                        let detachedRaw=encodeStoredValue(prior)
                        if(detachedRaw.size!=extent.bytes){throw IllegalStateException("historical prefix changed its paid complete encoding")}
                        let detached=decodeStoredValue(detachedRaw)
                        if(!pluginLivePolicyLedgerReferenceValid(detached,parent.value,sequence-1) ||
                            encodeStoredValue(detached)!=detachedRaw){
                            throw IllegalStateException("historical prefix changed while detaching its complete original data")}
                        state.prior=Some(detached)
                    })
                let produced=state.prior.getOrThrow()
                let priorExtent=livePolicyStoredExtent(produced)
                let priorPeak=journalStreamAdd(metadataPeak,
                    journalStreamAdd(contextReadMetadataPeak(priorExtent.bytes,priorExtent.nodes),65536))
                metadataOwner.ensureRetainedPeak(priorPeak)
                withLivePolicyHistoricalMember(tx,root,parent,run,thread,epoch,parentPlan,currentThrough,currentLedger,
                    produced,indexRef,allocate,verifyContent,guard,metadataOwner,priorPeak,{=>
                        let copied=match(readIndex(indexRef,guard,{index=>
                            if(!state.active || state.indexCalls!=0){throw IllegalStateException("historical index callback replayed")}
                            state.indexCalls=1
                            // The actual fixed-FD reader pays the original
                            // JSON DOM. This borrowed Session owner prepays
                            // all additional index views, wrapper arrays,
                            // prior prefix and both pass states together.
                            let indexExtent=livePolicyStoredExtent(index)
                            let indexPeak=journalStreamAdd(priorPeak,
                                journalStreamAdd(contextReadMetadataPeak(indexExtent.bytes,indexExtent.nodes),65536))
                            metadataOwner.ensureRetainedPeak(indexPeak)
                            let manifest=livePolicyHistoricalIndexManifest(index)
                            let members=index.field("payloads").getOrThrow().items
                            let preflight=LivePolicyHistoricalPayloadPass()
                            for(row in members){
                                let payload=parsePluginDocumentPayloadReference(row).value().getOrThrow()
                                withLivePolicyHistoricalMember(tx,root,parent,run,thread,epoch,parentPlan,currentThrough,currentLedger,
                                    produced,payload,allocate,verifyContent,guard,metadataOwner,indexPeak,{=>
                                        preflight.begin()
                                        let result=match(readPayload(payload,guard,{at,raw=>preflight.observe(at,raw,payload,guard)})){
                                            case Result.Err(error)=>throw PluginDocumentGuardFailure(error)
                                            case Result.Ok(value)=>value}
                                        preflight.end(payload,result)})
                            }
                            preflight.finish(manifest)
                            let sent=LivePolicyHistoricalPayloadPass()
                            let send:LivePolicyHistoricalSlotSender={requested,materialize=>
                                try{
                                    journalStreamCheck(guard)
                                    if(!state.active || sent.active || sent.failed || sent.ordinal>=members.size){
                                        throw IllegalStateException("historical slot callback escaped its actual Unit lifetime")}
                                    let expected=parsePluginDocumentPayloadReference(members[sent.ordinal]).value().getOrThrow()
                                    if(requested.bytes!=expected.bytes || requested.digest!=expected.digest){
                                        throw IllegalStateException("historical slot is not the next immutable index member")}
                                    withLivePolicyHistoricalMember(tx,root,parent,run,thread,epoch,parentPlan,currentThrough,currentLedger,
                                        produced,expected,allocate,verifyContent,guard,metadataOwner,indexPeak,{=>
                                            sent.begin()
                                            let result=match(materialize(expected,guard,{at,raw=>sent.observe(at,raw,expected,guard)})){
                                                case Result.Err(error)=>throw PluginDocumentGuardFailure(error)
                                                case Result.Ok(value)=>value}
                                            sent.end(expected,result)})
                                    Result<Unit>.Ok(())
                                }catch(error:PluginDocumentGuardFailure){sent.failed=true;Result<Unit>.Err(error.failure)}
                                catch(_:Exception){sent.failed=true;historicalPayloadError("plugin.live_history_member_stale")}}
                            consume(tip,indexRef,errorData,index,send)
                            sent.finish(manifest);journalStreamCheck(guard)
                        })){
                            case Result.Err(error)=>throw PluginDocumentGuardFailure(error)
                            case Result.Ok(value)=>value}
                        if(state.indexCalls!=1 || copied[0]!=indexRef.bytes || copied[1]!=indexRef.digest){
                            throw IllegalStateException("historical output index failed full fixed-FD EOF/hash/ACK")}
                    })
            }finally{state.active=false;state.prior=None<AgentValue>}
        })
    journalStreamCheck(guard)
}
