package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.sync.*
import std.time.*
import stdx.crypto.digest.*
import yjson.*
import yjson_support.*

// This is an actual same-Session producer, not a provider result adapter.
// All input/base bytes originate in the fixed Store/Artifact proofs. Only
// untrusted compact policy data is copied out of a paid native reply.
private class HostLiveStepState248 {
    var request:?AgentValue=None<AgentValue>
    var base:?PluginDocumentLatestJournalStreamReference=None<PluginDocumentLatestJournalStreamReference>
    var computed:?AgentValue=None<AgentValue>
    var manifest:?AgentValue=None<AgentValue>
    var page:?AgentValue=None<AgentValue>
    var result:?HostServiceArtifactWriter=None<HostServiceArtifactWriter>
    var offset:Int64=0
    var total:Int64=0
    var copied:Int64=0
    let references=ArrayList<AgentValue>()
    let hash=SHA256()
    init(){}
    func retained():AgentValue{
        objectValue([ValueField("request",request??nullValue()),ValueField("computed",computed??nullValue()),
            ValueField("manifest",manifest??nullValue()),ValueField("page",page??nullValue()),
            ValueField("payloads",listValue(references.toArray()))])
    }
}

func hostLivePolicyActualPayload(artifact:HostArtifact):AgentValue{
    objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
        ValueField("artifact_ref",textValue(HOST_ARTIFACT_PREFIX+artifact.sha256)),ValueField("encoding",textValue("utf8")),
        ValueField("bytes",integerValue(artifact.bytes)),ValueField("sha256",textValue(artifact.sha256)),
        ValueField("content_type",textValue(HOST_ARTIFACT_CONTENT_TYPE))])
}
private func hostLiveStepCopy248(value:AgentValue,maximum:Int64):AgentValue{
    let raw=encodeAgentValue(value)
    if(raw.size>maximum){throw IllegalStateException("bounded live policy metadata exceeded its transport shape")}
    parseUnifiedJson(raw,maxBytes:maximum,maxDepth:32)
}
func hostLiveStepComputeValid248(value:AgentValue):Bool{
    try{
        let kind=httpIntentText(value,"kind")
        if(kind=="effect"){
            if(!httpIntentExactFields(value,["kind","manifest","payload_count","effect"]) ||
                !hostLiveStepEffectValid248(value.field("effect").getOrThrow())){return false}
        }else if(kind=="completed"){
            if(!httpIntentExactFields(value,["kind","manifest","payload_count","is_error"]) ||
                value.field("is_error").getOrThrow().unifiedKind!=ValueKind.Boolean){return false}
        }else{return false}
        let count=hostLivePolicyRPCInteger(value,"payload_count")
        let manifest=value.field("manifest").getOrThrow()
        httpIntentExactFields(manifest,["slot","bytes","sha256"]) && httpIntentText(manifest,"slot")=="manifest" &&
            hostLivePolicyRPCInteger(manifest,"bytes")>0 && hostLivePolicyRPCInteger(manifest,"bytes")<=16384 &&
            httpIntentDigest(httpIntentText(manifest,"sha256")) && count>0
    }catch(_:Exception){false}
}
private func hostLiveStepEffectValid248(effect:AgentValue):Bool{
    let kind=httpIntentText(effect,"kind")
    if(kind=="row_journal.append"){
        return httpIntentExactFields(effect,["kind","key"]) && httpIntentText(effect,"key")!=""}
    ["directory.create","file.atomic_write","directory.delete_tree"].contains(kind) &&
        httpIntentExactFields(effect,["kind","root","relative_path","canonical_path"]) &&
        httpIntentText(effect,"root")!="" && httpIntentText(effect,"relative_path")!="" && httpIntentText(effect,"canonical_path")!=""
}
private func hostLiveStepManifestValid248(value:AgentValue,computed:AgentValue):Bool{
    try{
        let kind=httpIntentText(computed,"kind")
        if(!httpIntentExactFields(value,if(kind=="effect"){
            ["schema","kind","total_bytes","sha256","payload_count","proposal_digest"]
        }else{["schema","kind","total_bytes","sha256","payload_count"]}) ||
            httpIntentText(value,"schema")=="" || httpIntentText(value,"schema").size>512 ||
            httpIntentText(value,"kind")!=kind || !httpIntentDigest(httpIntentText(value,"sha256")) ||
            hostLivePolicyRPCInteger(value,"payload_count")!=hostLivePolicyRPCInteger(computed,"payload_count") ||
            hostLivePolicyRPCInteger(value,"total_bytes")<1){return false}
        if(kind=="effect" && !httpIntentDigest(httpIntentText(value,"proposal_digest"))){return false}
        true
    }catch(_:Exception){false}
}
private func hostLiveStepDataDescriptor248(parent:PreparedToolInvocation,ledger:AgentValue,payloads:Array<AgentValue>):AgentValue{
    objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-step-data/v1")),
        ValueField("parent_operation_id",textValue(parent.operationId.value)),
        ValueField("parent_binding_digest",textValue(parent.operationPlan.bindingDigest)),
        ValueField("prior_receipts",ledger),ValueField("payloads",listValue(payloads))])
}
private func hostLiveStepWrite248(session:HostDocumentDataSession,value:AgentValue,
    guard:()->Result<Unit>):Result<HostServiceArtifactWriter>{
    let writer=match(session.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
    try{
        // The caller's real metadata reservation pays the value and its
        // original compact encoding before this synchronous String/copy.
        let encoded=encodeAgentValue(value)
        if(encoded.size<1 || encoded.size>8388608){return hostPluginResourceError("plugin.live_index_bound","actual index exceeded its original single-Blob bound")}
        let bytes=encoded.toArray();var at:Int64=0
        while(at<bytes.size){
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let end=min(bytes.size,at+16384)
            match(writer.appendBytes(at,bytes[at..end],8388608)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()};at=end}
        match(writer.finish(bytes.size,modelPolicySha256(bytes))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(writer)
    }catch(_:Exception){hostPluginResourceError("plugin.live_index_encoding","paid original index JSON could not be written")}
}

// The trusted uploadKnown assembly must traverse actual own child admission,
// immutable proposal/data pin, full known Receipt and complete causal prefix.
// It cannot use Native success/is_error as a receipt. For through=0 it is an
// empty original prefix; through>0 the caller supplies the real Store reader.
func hostRunPluginLivePolicyNativeStep(host:HostJavaScriptPluginHost,configuration:HostPluginLivePolicyConfiguration,
    generation:UInt64,context:ToolInvocationContext,parent:PreparedToolInvocation,through:Int64,ledger:AgentValue,
    nowMillis:Int64,bareTool:String,localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>,
    uploadKnown:(HostDocumentDataSession,HostLivePolicyDataRPC)->Result<Unit>):Result<HostLivePolicySessionCustody>{
    if(through<0 || through==Int64.Max || nowMillis<1 || bareTool=="" || !isPluginLivePolicyParentPlan(parent.operationPlan) ||
        !pluginLivePolicyLedgerReferenceValid(ledger,parent.operationId.value,through)){
        return hostPluginResourceError("plugin.live_step_scope","actual live parent and exact original prefix required")}
    match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let session=match(host.documentDataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
    return hostRunLivePolicyPaidSession(session,{actual=>
        let state=HostLiveStepState248()
        let hostPlan=parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
        let input=parsePluginDocumentPayloadReference(hostPlan.field("input_payload").getOrThrow()).value().getOrThrow()
        match(actual.describeLivePolicyBaseJournal(context,parent,through,ledger,localCurrent,{request,reference=>
            state.request=Some(request);state.base=Some(reference)})){
            case Result.Err(error)=>return Result<HostServiceArtifactWriter>.Err(error);case Result.Ok(_)=>()}
        if(state.request.isNone() || state.base.isNone()){
            return hostPluginResourceError("plugin.live_step_read_missing","actual Store descriptor was not consumed")}
        let request=state.request.getOrThrow();let base=state.base.getOrThrow()
        if(!pluginDocumentLatestJournalStreamReadRequestValid(request) || httpIntentText(request,"key")!=configuration.key ||
            httpIntentText(request,"projection_digest")!=contextReadProjectionDigest(context.contextProjection)){
            return hostPluginResourceError("plugin.live_step_read_changed","actual complete read descriptor changed its frozen projection")}
        let access=match(configuration.read.access(configuration.key)){case Some(value)=>value
            case None=>return hostPluginResourceError<HostServiceArtifactWriter>("plugin.live_step_profile_missing","actual selected access projection is absent")}
        let view=match(configuration.read.view(configuration.key)){case Some(value)=>value
            case None=>return hostPluginResourceError<HostServiceArtifactWriter>("plugin.live_step_profile_missing","actual selected view projection is absent")}
        let stream=objectValue([ValueField("reference",base.toValue()),ValueField("request_digest",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),
            ValueField("access_policy_digest",textValue(access.digest)),ValueField("view_policy_digest",textValue(view.digest))])
        let retained=objectValue([ValueField("input",hostPlan.field("input_payload").getOrThrow()),ValueField("stream",stream),
            ValueField("ledger",ledger),ValueField("request",request)])
        let phase=HostLivePolicyTerminalUnit250()
        actual.withLivePolicyRunningMetadata(retained,{metadata,retainedPeak=>
            let unbounded=context.cancellation.deadlineMillis==0 && context.budget.deadlineMillis==0
            let deadline=MonoTime.now()+Duration.second*5
            phase.value=host.withPureLivePolicyDataLoan(configuration,generation,context,parent.call.callId+":live-data:"+(through+1).toString(),
                deadline,actual,localCurrent,fullCurrent,{loan=>
                    let rpc=HostLivePolicyDataRPC(loan,configuration.dataSchema,through+1,metadata,retainedPeak,localCurrent)
                    var release:Result<Unit>=Result<Unit>.Ok(())
                    let run:()->Result<Unit>={=>
                        match(rpc.begin(bareTool,parent.call.callId,nowMillis,input,stream,ledger)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(actual.uploadLivePolicyPinnedInput(context,parent,through,ledger,localCurrent,
                            {offset,raw=>rpc.appendParameters(offset,raw)},{reference=>rpc.endParameters(reference)})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(actual.readLivePolicyBaseJournal(context,parent,through,ledger,localCurrent,
                            {offset,raw=>rpc.appendBase(offset,raw)},{_=>rpc.endBase(base)},retainedMetadataPeak:retainedPeak+8388608)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(uploadKnown(actual,rpc)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(rpc.compute({value=>
                            if(!hostLiveStepComputeValid248(value)){return hostPluginResourceError<Unit>("plugin.live_step_compute_shape","native policy changed its exact metadata shape")}
                            metadata.ensureRetainedPeak(retainedPeak+8388608)
                            state.computed=Some(hostLiveStepCopy248(value,16384));Result<Unit>.Ok(())})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let computed=state.computed.getOrThrow();state.total=hostLivePolicyRPCInteger(computed,"payload_count")
                        let manifest=computed.field("manifest").getOrThrow()
                        let manifestWriter=match(actual.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                        match(rpc.download("manifest",hostLivePolicyRPCInteger(manifest,"bytes"),httpIntentText(manifest,"sha256"),manifestWriter)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(actual.inspectLivePolicyWriterMetadata(manifestWriter,localCurrent,{value=>
                            if(!hostLiveStepManifestValid248(value,computed)){throw IllegalStateException("native compact manifest changed exact metadata")}
                            state.manifest=Some(hostLiveStepCopy248(value,16384))})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let manifestPayload=hostLivePolicyActualPayload(manifestWriter.completedArtifact())
                        match(actual.retainLivePolicyStep(context,parent,hostLiveStepDataDescriptor248(parent,ledger,[manifestPayload]),
                            [manifestWriter],localCurrent,streamedSource:true)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        while(state.offset<state.total){
                            // Four actual slots fit the original nine simultaneous
                            // writer bound; each slot is published/ACKed immediately.
                            match(rpc.describe(state.offset,min(4,state.total-state.offset),{value=>
                                metadata.ensureRetainedPeak(retainedPeak+8388608)
                                state.page=Some(hostLiveStepCopy248(value,16384));Result<Unit>.Ok(())})){
                                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                            let page=state.page.getOrThrow();let rows=page.field("payloads").getOrThrow()
                            let next=hostLivePolicyRPCInteger(page,"next_offset")
                            if(rows.unifiedKind!=ValueKind.List || rows.items.isEmpty() || rows.items.size>4 ||
                                next!=state.offset+rows.items.size || hostLivePolicyRPCInteger(page,"total")!=state.total){
                                return hostPluginResourceError<Unit>("plugin.live_step_page_changed","actual slot page changed its continuous order")}
                            for(row in rows.items){
                                if(!httpIntentExactFields(row,["slot","bytes","sha256"]) || httpIntentText(row,"slot")!="payload-"+state.offset.toString()){
                                    return hostPluginResourceError<Unit>("plugin.live_step_slot_order","slot changed its exact ordinal")}
                                let writer=match(actual.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                                match(rpc.download(httpIntentText(row,"slot"),hostLivePolicyRPCInteger(row,"bytes"),httpIntentText(row,"sha256"),writer,
                                    observed:Some({raw=>state.hash.write(raw);state.copied=hostLiveStepAdd248(state.copied,raw.size)}))){
                                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                                let payload=hostLivePolicyActualPayload(writer.completedArtifact())
                                // Pay the full simultaneously retained index and
                                // its original JSON before growing the array.
                                let pending=objectValue([ValueField("retained",state.retained()),ValueField("next",payload)])
                                let size=logicalJsonWriteReservationBytes(pending,8388608)
                                metadata.ensureRetainedPeak(retainedPeak+1048576+size*8+logicalJsonValueNodeCount(pending)*512)
                                state.references.add(payload)
                                match(actual.retainLivePolicyStep(context,parent,hostLiveStepDataDescriptor248(parent,ledger,[payload]),
                                    [writer],localCurrent,streamedSource:true)){
                                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                                state.offset+=1
                            }
                            state.page=None<AgentValue>
                        }
                        let nativeManifest=state.manifest.getOrThrow()
                        if(state.copied!=hostLivePolicyRPCInteger(nativeManifest,"total_bytes") ||
                            hostArtifactHex(state.hash.finish())!=httpIntentText(nativeManifest,"sha256")){
                            return hostPluginResourceError<Unit>("plugin.live_step_whole_hash","all actual slots changed their complete original JSON EOF/hash")}
                        let index=objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-output-index/v1")),
                            ValueField("native_manifest",nativeManifest),ValueField("payloads",listValue(state.references.toArray()))])
                        let indexBytes=logicalJsonWriteReservationBytes(index,8388608)
                        metadata.ensureRetainedPeak(retainedPeak+1048576+indexBytes*8+logicalJsonValueNodeCount(index)*512)
                        let indexWriter=match(hostLiveStepWrite248(actual,index,localCurrent)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                        let indexPayload=hostLivePolicyActualPayload(indexWriter.completedArtifact())
                        match(actual.retainLivePolicyStep(context,parent,hostLiveStepDataDescriptor248(parent,ledger,[indexPayload]),
                            [indexWriter],localCurrent,streamedSource:true)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let fields=ArrayList<ValueField>([ValueField("schema",textValue("axyndra.plugin-live-policy-host-step/v1")),
                            ValueField("kind",computed.field("kind").getOrThrow()),ValueField("output_index",indexPayload),
                            ValueField("prior_receipts",ledger),ValueField("now_millis",integerValue(nowMillis))])
                        if(httpIntentText(computed,"kind")=="effect"){fields.add(ValueField("effect",computed.field("effect").getOrThrow()))}
                        else{fields.add(ValueField("is_error",computed.field("is_error").getOrThrow()))}
                        let hostMetadata=objectValue(fields.toArray())
                        metadata.ensureRetainedPeak(retainedPeak+1048576+16384*8+logicalJsonValueNodeCount(hostMetadata)*512)
                        state.result=Some(match(hostLiveStepWrite248(actual,hostMetadata,localCurrent)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value})
                        localCurrent()}
                    let outcome=try{run()}finally{release=rpc.release()}
                    // A cache release is checked before the enclosing actual
                    // worker collection. Neither acknowledgement is a Receipt.
                    match(outcome){case Result.Err(error)=>Result<Unit>.Err(error);case Result.Ok(_)=>release}
                },callerUnbounded:unbounded)
        })
        match(phase.value){case Result.Err(error)=>return Result<HostServiceArtifactWriter>.Err(error);case Result.Ok(_)=>()}
        match(state.result){case Some(writer)=>Result<HostServiceArtifactWriter>.Ok(writer)
            case None=>hostPluginResourceError<HostServiceArtifactWriter>("plugin.live_step_output_missing","actual native step did not finish its same-owner metadata writer")}
    },16384,localCurrent)
}
func hostLiveStepAdd248(left:Int64,right:Int64):Int64{
    if(left<0 || right<0 || right>Int64.Max-left){throw IllegalStateException("complete live output byte count overflow")};left+right
}

// Unused checked migration transport; original entry above stays exact.
func hostRunPluginLivePolicyNativeStep312(host:HostJavaScriptPluginHost,configuration:HostPluginLivePolicyConfiguration,
    generation:UInt64,context:ToolInvocationContext,parent:PreparedToolInvocation,through:Int64,ledger:AgentValue,
    nowMillis:Int64,bareTool:String,localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>,
    uploadKnown:(HostDocumentDataSession,HostLivePolicyDataRPC)->Result<Unit>,
    uploadKnownOwned!:?((HostDocumentDataSession,HostLivePolicyDataRPC,LogicalJsonOwnerReservation,Int64)->Result<Unit>)=None<((HostDocumentDataSession,HostLivePolicyDataRPC,LogicalJsonOwnerReservation,Int64)->Result<Unit>)>,
    retirePrevious291!:?(() -> Result<Unit>)=None<(() -> Result<Unit>)>):Result<HostLivePolicySessionCustody>{
    if(through<0 || through==Int64.Max || nowMillis<1 || bareTool=="" || !isPluginLivePolicyParentPlan(parent.operationPlan) ||
        !pluginLivePolicyLedgerReferenceValid(ledger,parent.operationId.value,through)){
        return hostPluginResourceError("plugin.live_step_scope","actual live parent and exact original prefix required")}
    match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let session=match(host.documentDataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
    return hostRunLivePolicyPaidSession312(session,{actual=>
        let state=HostLiveStepState248()
        let hostPlan=parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
        let input=parsePluginDocumentPayloadReference(hostPlan.field("input_payload").getOrThrow()).value().getOrThrow()
        match(actual.describeLivePolicyBaseJournal(context,parent,through,ledger,localCurrent,{request,reference=>
            state.request=Some(request);state.base=Some(reference)})){
            case Result.Err(error)=>return Result<HostServiceArtifactWriter>.Err(error);case Result.Ok(_)=>()}
        if(state.request.isNone() || state.base.isNone()){
            return hostPluginResourceError("plugin.live_step_read_missing","actual Store descriptor was not consumed")}
        let request=state.request.getOrThrow();let base=state.base.getOrThrow()
        if(!pluginDocumentLatestJournalStreamReadRequestValid(request) || httpIntentText(request,"key")!=configuration.key ||
            httpIntentText(request,"projection_digest")!=contextReadProjectionDigest(context.contextProjection)){
            return hostPluginResourceError("plugin.live_step_read_changed","actual complete read descriptor changed its frozen projection")}
        let access=match(configuration.read.access(configuration.key)){case Some(value)=>value
            case None=>return hostPluginResourceError<HostServiceArtifactWriter>("plugin.live_step_profile_missing","actual selected access projection is absent")}
        let view=match(configuration.read.view(configuration.key)){case Some(value)=>value
            case None=>return hostPluginResourceError<HostServiceArtifactWriter>("plugin.live_step_profile_missing","actual selected view projection is absent")}
        let stream=objectValue([ValueField("reference",base.toValue()),ValueField("request_digest",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),
            ValueField("access_policy_digest",textValue(access.digest)),ValueField("view_policy_digest",textValue(view.digest))])
        let retained=objectValue([ValueField("input",hostPlan.field("input_payload").getOrThrow()),ValueField("stream",stream),
            ValueField("ledger",ledger),ValueField("request",request)])
        let phase=HostLivePolicyTerminalUnit250()
        actual.withLivePolicyRunningMetadata(retained,{metadata,retainedPeak=>
            // Actual new Session has paid the complete original ledger graph
            // before any previous owner closes. A failed same-owner physical
            // close returns its real debt; no Native loan/compute can start.
            let retired:Result<Unit>=match(retirePrevious291){case Some(retire)=>retire();case None=>Result<Unit>.Ok(())}
            if(retired.isError()){phase.value=retired}else{
            let unbounded=context.cancellation.deadlineMillis==0 && context.budget.deadlineMillis==0
            let deadline=MonoTime.now()+Duration.second*5
            phase.value=host.withPureLivePolicyDataLoan(configuration,generation,context,parent.call.callId+":live-data:"+(through+1).toString(),
                deadline,actual,localCurrent,fullCurrent,{loan=>
                    let rpc=HostLivePolicyDataRPC(loan,configuration.dataSchema,through+1,metadata,retainedPeak,localCurrent)
                    var release:Result<Unit>=Result<Unit>.Ok(())
                    let run:()->Result<Unit>={=>
                        match(rpc.begin(bareTool,parent.call.callId,nowMillis,input,stream,ledger)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(actual.uploadLivePolicyPinnedInput(context,parent,through,ledger,localCurrent,
                            {offset,raw=>rpc.appendParameters(offset,raw)},{reference=>rpc.endParameters(reference)})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(actual.readLivePolicyBaseJournal(context,parent,through,ledger,localCurrent,
                            {offset,raw=>rpc.appendBase(offset,raw)},{_=>rpc.endBase(base)},retainedMetadataPeak:retainedPeak+8388608)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let known:Result<Unit>=match(uploadKnownOwned){
                            case Some(send)=>send(actual,rpc,metadata,retainedPeak+8388608)
                            case None=>uploadKnown(actual,rpc)}
                        match(known){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                        match(rpc.compute({value=>
                            if(!hostLiveStepComputeValid248(value)){return hostPluginResourceError<Unit>("plugin.live_step_compute_shape","native policy changed its exact metadata shape")}
                            metadata.ensureRetainedPeak(retainedPeak+8388608)
                            state.computed=Some(hostLiveStepCopy248(value,16384));Result<Unit>.Ok(())})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let computed=state.computed.getOrThrow();state.total=hostLivePolicyRPCInteger(computed,"payload_count")
                        let manifest=computed.field("manifest").getOrThrow()
                        let manifestWriter=match(actual.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                        match(rpc.download("manifest",hostLivePolicyRPCInteger(manifest,"bytes"),httpIntentText(manifest,"sha256"),manifestWriter)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(actual.inspectLivePolicyWriterMetadata(manifestWriter,localCurrent,{value=>
                            if(!hostLiveStepManifestValid248(value,computed)){throw IllegalStateException("native compact manifest changed exact metadata")}
                            state.manifest=Some(hostLiveStepCopy248(value,16384))})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let manifestPayload=hostLivePolicyActualPayload(manifestWriter.completedArtifact())
                        match(actual.retainLivePolicyStep(context,parent,hostLiveStepDataDescriptor248(parent,ledger,[manifestPayload]),
                            [manifestWriter],localCurrent,streamedSource:true)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        while(state.offset<state.total){
                            // Four actual slots fit the original nine simultaneous
                            // writer bound; each slot is published/ACKed immediately.
                            match(rpc.describe(state.offset,min(4,state.total-state.offset),{value=>
                                metadata.ensureRetainedPeak(retainedPeak+8388608)
                                state.page=Some(hostLiveStepCopy248(value,16384));Result<Unit>.Ok(())})){
                                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                            let page=state.page.getOrThrow();let rows=page.field("payloads").getOrThrow()
                            let next=hostLivePolicyRPCInteger(page,"next_offset")
                            if(rows.unifiedKind!=ValueKind.List || rows.items.isEmpty() || rows.items.size>4 ||
                                next!=state.offset+rows.items.size || hostLivePolicyRPCInteger(page,"total")!=state.total){
                                return hostPluginResourceError<Unit>("plugin.live_step_page_changed","actual slot page changed its continuous order")}
                            for(row in rows.items){
                                if(!httpIntentExactFields(row,["slot","bytes","sha256"]) || httpIntentText(row,"slot")!="payload-"+state.offset.toString()){
                                    return hostPluginResourceError<Unit>("plugin.live_step_slot_order","slot changed its exact ordinal")}
                                let writer=match(actual.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                                match(rpc.download(httpIntentText(row,"slot"),hostLivePolicyRPCInteger(row,"bytes"),httpIntentText(row,"sha256"),writer,
                                    observed:Some({raw=>state.hash.write(raw);state.copied=hostLiveStepAdd248(state.copied,raw.size)}))){
                                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                                let payload=hostLivePolicyActualPayload(writer.completedArtifact())
                                // Pay the full simultaneously retained index and
                                // its original JSON before growing the array.
                                let pending=objectValue([ValueField("retained",state.retained()),ValueField("next",payload)])
                                let size=logicalJsonWriteReservationBytes(pending,8388608)
                                metadata.ensureRetainedPeak(retainedPeak+1048576+size*8+logicalJsonValueNodeCount(pending)*512)
                                state.references.add(payload)
                                match(actual.retainLivePolicyStep(context,parent,hostLiveStepDataDescriptor248(parent,ledger,[payload]),
                                    [writer],localCurrent,streamedSource:true)){
                                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                                state.offset+=1
                            }
                            state.page=None<AgentValue>
                        }
                        let nativeManifest=state.manifest.getOrThrow()
                        if(state.copied!=hostLivePolicyRPCInteger(nativeManifest,"total_bytes") ||
                            hostArtifactHex(state.hash.finish())!=httpIntentText(nativeManifest,"sha256")){
                            return hostPluginResourceError<Unit>("plugin.live_step_whole_hash","all actual slots changed their complete original JSON EOF/hash")}
                        let index=objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-output-index/v1")),
                            ValueField("native_manifest",nativeManifest),ValueField("payloads",listValue(state.references.toArray()))])
                        let indexBytes=logicalJsonWriteReservationBytes(index,8388608)
                        metadata.ensureRetainedPeak(retainedPeak+1048576+indexBytes*8+logicalJsonValueNodeCount(index)*512)
                        let indexWriter=match(hostLiveStepWrite248(actual,index,localCurrent)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                        let indexPayload=hostLivePolicyActualPayload(indexWriter.completedArtifact())
                        match(actual.retainLivePolicyStep(context,parent,hostLiveStepDataDescriptor248(parent,ledger,[indexPayload]),
                            [indexWriter],localCurrent,streamedSource:true)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let fields=ArrayList<ValueField>([ValueField("schema",textValue("axyndra.plugin-live-policy-host-step/v1")),
                            ValueField("kind",computed.field("kind").getOrThrow()),ValueField("output_index",indexPayload),
                            ValueField("prior_receipts",ledger),ValueField("now_millis",integerValue(nowMillis))])
                        if(httpIntentText(computed,"kind")=="effect"){fields.add(ValueField("effect",computed.field("effect").getOrThrow()))}
                        else{fields.add(ValueField("is_error",computed.field("is_error").getOrThrow()))}
                        let hostMetadata=objectValue(fields.toArray())
                        metadata.ensureRetainedPeak(retainedPeak+1048576+16384*8+logicalJsonValueNodeCount(hostMetadata)*512)
                        state.result=Some(match(hostLiveStepWrite248(actual,hostMetadata,localCurrent)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value})
                        localCurrent()}
                    let outcome=try{run()}finally{release=rpc.release()}
                    // A cache release is checked before the enclosing actual
                    // worker collection. Neither acknowledgement is a Receipt.
                    match(outcome){case Result.Err(error)=>Result<Unit>.Err(error);case Result.Ok(_)=>release}
                },callerUnbounded:unbounded)
            }
        })
        match(phase.value){case Result.Err(error)=>return Result<HostServiceArtifactWriter>.Err(error);case Result.Ok(_)=>()}
        match(state.result){case Some(writer)=>Result<HostServiceArtifactWriter>.Ok(writer)
            case None=>hostPluginResourceError<HostServiceArtifactWriter>("plugin.live_step_output_missing","actual native step did not finish its same-owner metadata writer")}
    },16384,localCurrent)
}

// Same original full IO/current/EOF/hash/Native algorithm, FIRST actual paid Session.
func hostRunPluginLivePolicyNativeInitialStep332(session:HostDocumentDataSession,physical:HostLiveExecutionCustody,
    actualCustody:OwnedKernelPreparedReferenceCustody,debt:OwnedKernelPreparedReferenceDebt,host:HostJavaScriptPluginHost,configuration:HostPluginLivePolicyConfiguration,
    generation:UInt64,context:ToolInvocationContext,parent:PreparedToolInvocation,through:Int64,ledger:AgentValue,
    nowMillis:Int64,bareTool:String,localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>,
    uploadKnown:(HostDocumentDataSession,HostLivePolicyDataRPC)->Result<Unit>,
    uploadKnownOwned!:?((HostDocumentDataSession,HostLivePolicyDataRPC,LogicalJsonOwnerReservation,Int64)->Result<Unit>)=None<((HostDocumentDataSession,HostLivePolicyDataRPC,LogicalJsonOwnerReservation,Int64)->Result<Unit>)>,
    retirePrevious291!:?(() -> Result<Unit>)=None<(() -> Result<Unit>)>):Result<HostLivePolicySessionCustody>{
    if(through<0 || through==Int64.Max || nowMillis<1 || bareTool=="" || !isPluginLivePolicyParentPlan(parent.operationPlan) ||
        !pluginLivePolicyLedgerReferenceValid(ledger,parent.operationId.value,through)){
        return hostPluginResourceError("plugin.live_step_scope","actual live parent and exact original prefix required")}
    match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    return hostRunLivePolicyPaidInitialSession332(session,physical,actualCustody,debt,{actual=>
        let state=HostLiveStepState248()
        let hostPlan=parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
        let input=parsePluginDocumentPayloadReference(hostPlan.field("input_payload").getOrThrow()).value().getOrThrow()
        match(actual.describeLivePolicyBaseJournal(context,parent,through,ledger,localCurrent,{request,reference=>
            state.request=Some(request);state.base=Some(reference)})){
            case Result.Err(error)=>return Result<HostServiceArtifactWriter>.Err(error);case Result.Ok(_)=>()}
        if(state.request.isNone() || state.base.isNone()){
            return hostPluginResourceError("plugin.live_step_read_missing","actual Store descriptor was not consumed")}
        let request=state.request.getOrThrow();let base=state.base.getOrThrow()
        if(!pluginDocumentLatestJournalStreamReadRequestValid(request) || httpIntentText(request,"key")!=configuration.key ||
            httpIntentText(request,"projection_digest")!=contextReadProjectionDigest(context.contextProjection)){
            return hostPluginResourceError("plugin.live_step_read_changed","actual complete read descriptor changed its frozen projection")}
        let access=match(configuration.read.access(configuration.key)){case Some(value)=>value
            case None=>return hostPluginResourceError<HostServiceArtifactWriter>("plugin.live_step_profile_missing","actual selected access projection is absent")}
        let view=match(configuration.read.view(configuration.key)){case Some(value)=>value
            case None=>return hostPluginResourceError<HostServiceArtifactWriter>("plugin.live_step_profile_missing","actual selected view projection is absent")}
        let stream=objectValue([ValueField("reference",base.toValue()),ValueField("request_digest",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),
            ValueField("access_policy_digest",textValue(access.digest)),ValueField("view_policy_digest",textValue(view.digest))])
        let retained=objectValue([ValueField("input",hostPlan.field("input_payload").getOrThrow()),ValueField("stream",stream),
            ValueField("ledger",ledger),ValueField("request",request)])
        let phase=HostLivePolicyTerminalUnit250()
        actual.withLivePolicyRunningMetadata(retained,{metadata,retainedPeak=>
            // Actual new Session has paid the complete original ledger graph
            // before any previous owner closes. A failed same-owner physical
            // close returns its real debt; no Native loan/compute can start.
            let retired:Result<Unit>=match(retirePrevious291){case Some(retire)=>retire();case None=>Result<Unit>.Ok(())}
            if(retired.isError()){phase.value=retired}else{
            let unbounded=context.cancellation.deadlineMillis==0 && context.budget.deadlineMillis==0
            let deadline=MonoTime.now()+Duration.second*5
            phase.value=host.withPureLivePolicyDataLoan(configuration,generation,context,parent.call.callId+":live-data:"+(through+1).toString(),
                deadline,actual,localCurrent,fullCurrent,{loan=>
                    let rpc=HostLivePolicyDataRPC(loan,configuration.dataSchema,through+1,metadata,retainedPeak,localCurrent)
                    var release:Result<Unit>=Result<Unit>.Ok(())
                    let run:()->Result<Unit>={=>
                        match(rpc.begin(bareTool,parent.call.callId,nowMillis,input,stream,ledger)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(actual.uploadLivePolicyPinnedInput(context,parent,through,ledger,localCurrent,
                            {offset,raw=>rpc.appendParameters(offset,raw)},{reference=>rpc.endParameters(reference)})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(actual.readLivePolicyBaseJournal(context,parent,through,ledger,localCurrent,
                            {offset,raw=>rpc.appendBase(offset,raw)},{_=>rpc.endBase(base)},retainedMetadataPeak:retainedPeak+8388608)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let known:Result<Unit>=match(uploadKnownOwned){
                            case Some(send)=>send(actual,rpc,metadata,retainedPeak+8388608)
                            case None=>uploadKnown(actual,rpc)}
                        match(known){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                        match(rpc.compute({value=>
                            if(!hostLiveStepComputeValid248(value)){return hostPluginResourceError<Unit>("plugin.live_step_compute_shape","native policy changed its exact metadata shape")}
                            metadata.ensureRetainedPeak(retainedPeak+8388608)
                            state.computed=Some(hostLiveStepCopy248(value,16384));Result<Unit>.Ok(())})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let computed=state.computed.getOrThrow();state.total=hostLivePolicyRPCInteger(computed,"payload_count")
                        let manifest=computed.field("manifest").getOrThrow()
                        let manifestWriter=match(actual.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                        match(rpc.download("manifest",hostLivePolicyRPCInteger(manifest,"bytes"),httpIntentText(manifest,"sha256"),manifestWriter)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(actual.inspectLivePolicyWriterMetadata(manifestWriter,localCurrent,{value=>
                            if(!hostLiveStepManifestValid248(value,computed)){throw IllegalStateException("native compact manifest changed exact metadata")}
                            state.manifest=Some(hostLiveStepCopy248(value,16384))})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let manifestPayload=hostLivePolicyActualPayload(manifestWriter.completedArtifact())
                        match(actual.retainLivePolicyStep(context,parent,hostLiveStepDataDescriptor248(parent,ledger,[manifestPayload]),
                            [manifestWriter],localCurrent,streamedSource:true)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        while(state.offset<state.total){
                            // Four actual slots fit the original nine simultaneous
                            // writer bound; each slot is published/ACKed immediately.
                            match(rpc.describe(state.offset,min(4,state.total-state.offset),{value=>
                                metadata.ensureRetainedPeak(retainedPeak+8388608)
                                state.page=Some(hostLiveStepCopy248(value,16384));Result<Unit>.Ok(())})){
                                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                            let page=state.page.getOrThrow();let rows=page.field("payloads").getOrThrow()
                            let next=hostLivePolicyRPCInteger(page,"next_offset")
                            if(rows.unifiedKind!=ValueKind.List || rows.items.isEmpty() || rows.items.size>4 ||
                                next!=state.offset+rows.items.size || hostLivePolicyRPCInteger(page,"total")!=state.total){
                                return hostPluginResourceError<Unit>("plugin.live_step_page_changed","actual slot page changed its continuous order")}
                            for(row in rows.items){
                                if(!httpIntentExactFields(row,["slot","bytes","sha256"]) || httpIntentText(row,"slot")!="payload-"+state.offset.toString()){
                                    return hostPluginResourceError<Unit>("plugin.live_step_slot_order","slot changed its exact ordinal")}
                                let writer=match(actual.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                                match(rpc.download(httpIntentText(row,"slot"),hostLivePolicyRPCInteger(row,"bytes"),httpIntentText(row,"sha256"),writer,
                                    observed:Some({raw=>state.hash.write(raw);state.copied=hostLiveStepAdd248(state.copied,raw.size)}))){
                                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                                let payload=hostLivePolicyActualPayload(writer.completedArtifact())
                                // Pay the full simultaneously retained index and
                                // its original JSON before growing the array.
                                let pending=objectValue([ValueField("retained",state.retained()),ValueField("next",payload)])
                                let size=logicalJsonWriteReservationBytes(pending,8388608)
                                metadata.ensureRetainedPeak(retainedPeak+1048576+size*8+logicalJsonValueNodeCount(pending)*512)
                                state.references.add(payload)
                                match(actual.retainLivePolicyStep(context,parent,hostLiveStepDataDescriptor248(parent,ledger,[payload]),
                                    [writer],localCurrent,streamedSource:true)){
                                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                                state.offset+=1
                            }
                            state.page=None<AgentValue>
                        }
                        let nativeManifest=state.manifest.getOrThrow()
                        if(state.copied!=hostLivePolicyRPCInteger(nativeManifest,"total_bytes") ||
                            hostArtifactHex(state.hash.finish())!=httpIntentText(nativeManifest,"sha256")){
                            return hostPluginResourceError<Unit>("plugin.live_step_whole_hash","all actual slots changed their complete original JSON EOF/hash")}
                        let index=objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-output-index/v1")),
                            ValueField("native_manifest",nativeManifest),ValueField("payloads",listValue(state.references.toArray()))])
                        let indexBytes=logicalJsonWriteReservationBytes(index,8388608)
                        metadata.ensureRetainedPeak(retainedPeak+1048576+indexBytes*8+logicalJsonValueNodeCount(index)*512)
                        let indexWriter=match(hostLiveStepWrite248(actual,index,localCurrent)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                        let indexPayload=hostLivePolicyActualPayload(indexWriter.completedArtifact())
                        match(actual.retainLivePolicyStep(context,parent,hostLiveStepDataDescriptor248(parent,ledger,[indexPayload]),
                            [indexWriter],localCurrent,streamedSource:true)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let fields=ArrayList<ValueField>([ValueField("schema",textValue("axyndra.plugin-live-policy-host-step/v1")),
                            ValueField("kind",computed.field("kind").getOrThrow()),ValueField("output_index",indexPayload),
                            ValueField("prior_receipts",ledger),ValueField("now_millis",integerValue(nowMillis))])
                        if(httpIntentText(computed,"kind")=="effect"){fields.add(ValueField("effect",computed.field("effect").getOrThrow()))}
                        else{fields.add(ValueField("is_error",computed.field("is_error").getOrThrow()))}
                        let hostMetadata=objectValue(fields.toArray())
                        metadata.ensureRetainedPeak(retainedPeak+1048576+16384*8+logicalJsonValueNodeCount(hostMetadata)*512)
                        state.result=Some(match(hostLiveStepWrite248(actual,hostMetadata,localCurrent)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value})
                        localCurrent()}
                    let outcome=try{run()}finally{release=rpc.release()}
                    // A cache release is checked before the enclosing actual
                    // worker collection. Neither acknowledgement is a Receipt.
                    match(outcome){case Result.Err(error)=>Result<Unit>.Err(error);case Result.Ok(_)=>release}
                },callerUnbounded:unbounded)
            }
        })
        match(phase.value){case Result.Err(error)=>return Result<HostServiceArtifactWriter>.Err(error);case Result.Ok(_)=>()}
        match(state.result){case Some(writer)=>Result<HostServiceArtifactWriter>.Ok(writer)
            case None=>hostPluginResourceError<HostServiceArtifactWriter>("plugin.live_step_output_missing","actual native step did not finish its same-owner metadata writer")}
    },16384,localCurrent)
}

// Same original312 algorithm and all complete Source/current/history/receipt guards.
func hostRunPluginLivePolicyNativeSuccessorStep336(session:HostDocumentDataSession,host:HostJavaScriptPluginHost,configuration:HostPluginLivePolicyConfiguration,
    generation:UInt64,context:ToolInvocationContext,parent:PreparedToolInvocation,through:Int64,ledger:AgentValue,
    nowMillis:Int64,bareTool:String,localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>,
    uploadKnown:(HostDocumentDataSession,HostLivePolicyDataRPC)->Result<Unit>,
    uploadKnownOwned!:?((HostDocumentDataSession,HostLivePolicyDataRPC,LogicalJsonOwnerReservation,Int64)->Result<Unit>)=None<((HostDocumentDataSession,HostLivePolicyDataRPC,LogicalJsonOwnerReservation,Int64)->Result<Unit>)>,
    retirePrevious291!:?(() -> Result<Unit>)=None<(() -> Result<Unit>)>):Result<HostLivePolicySessionCustody>{
    if(through<0 || through==Int64.Max || nowMillis<1 || bareTool=="" || !isPluginLivePolicyParentPlan(parent.operationPlan) ||
        !pluginLivePolicyLedgerReferenceValid(ledger,parent.operationId.value,through)){
        return hostPluginResourceError("plugin.live_step_scope","actual live parent and exact original prefix required")}
    match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    return hostRunLivePolicyPaidSession312(session,{actual=>
        let state=HostLiveStepState248()
        let hostPlan=parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
        let input=parsePluginDocumentPayloadReference(hostPlan.field("input_payload").getOrThrow()).value().getOrThrow()
        match(actual.describeLivePolicyBaseJournal(context,parent,through,ledger,localCurrent,{request,reference=>
            state.request=Some(request);state.base=Some(reference)})){
            case Result.Err(error)=>return Result<HostServiceArtifactWriter>.Err(error);case Result.Ok(_)=>()}
        if(state.request.isNone() || state.base.isNone()){
            return hostPluginResourceError("plugin.live_step_read_missing","actual Store descriptor was not consumed")}
        let request=state.request.getOrThrow();let base=state.base.getOrThrow()
        if(!pluginDocumentLatestJournalStreamReadRequestValid(request) || httpIntentText(request,"key")!=configuration.key ||
            httpIntentText(request,"projection_digest")!=contextReadProjectionDigest(context.contextProjection)){
            return hostPluginResourceError("plugin.live_step_read_changed","actual complete read descriptor changed its frozen projection")}
        let access=match(configuration.read.access(configuration.key)){case Some(value)=>value
            case None=>return hostPluginResourceError<HostServiceArtifactWriter>("plugin.live_step_profile_missing","actual selected access projection is absent")}
        let view=match(configuration.read.view(configuration.key)){case Some(value)=>value
            case None=>return hostPluginResourceError<HostServiceArtifactWriter>("plugin.live_step_profile_missing","actual selected view projection is absent")}
        let stream=objectValue([ValueField("reference",base.toValue()),ValueField("request_digest",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),
            ValueField("access_policy_digest",textValue(access.digest)),ValueField("view_policy_digest",textValue(view.digest))])
        let retained=objectValue([ValueField("input",hostPlan.field("input_payload").getOrThrow()),ValueField("stream",stream),
            ValueField("ledger",ledger),ValueField("request",request)])
        let phase=HostLivePolicyTerminalUnit250()
        actual.withLivePolicyRunningMetadata(retained,{metadata,retainedPeak=>
            // Actual new Session has paid the complete original ledger graph
            // before any previous owner closes. A failed same-owner physical
            // close returns its real debt; no Native loan/compute can start.
            let retired:Result<Unit>=match(retirePrevious291){case Some(retire)=>retire();case None=>Result<Unit>.Ok(())}
            if(retired.isError()){phase.value=retired}else{
            let unbounded=context.cancellation.deadlineMillis==0 && context.budget.deadlineMillis==0
            let deadline=MonoTime.now()+Duration.second*5
            phase.value=host.withPureLivePolicyDataLoan(configuration,generation,context,parent.call.callId+":live-data:"+(through+1).toString(),
                deadline,actual,localCurrent,fullCurrent,{loan=>
                    let rpc=HostLivePolicyDataRPC(loan,configuration.dataSchema,through+1,metadata,retainedPeak,localCurrent)
                    var release:Result<Unit>=Result<Unit>.Ok(())
                    let run:()->Result<Unit>={=>
                        match(rpc.begin(bareTool,parent.call.callId,nowMillis,input,stream,ledger)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(actual.uploadLivePolicyPinnedInput(context,parent,through,ledger,localCurrent,
                            {offset,raw=>rpc.appendParameters(offset,raw)},{reference=>rpc.endParameters(reference)})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(actual.readLivePolicyBaseJournal(context,parent,through,ledger,localCurrent,
                            {offset,raw=>rpc.appendBase(offset,raw)},{_=>rpc.endBase(base)},retainedMetadataPeak:retainedPeak+8388608)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let known:Result<Unit>=match(uploadKnownOwned){
                            case Some(send)=>send(actual,rpc,metadata,retainedPeak+8388608)
                            case None=>uploadKnown(actual,rpc)}
                        match(known){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                        match(rpc.compute({value=>
                            if(!hostLiveStepComputeValid248(value)){return hostPluginResourceError<Unit>("plugin.live_step_compute_shape","native policy changed its exact metadata shape")}
                            metadata.ensureRetainedPeak(retainedPeak+8388608)
                            state.computed=Some(hostLiveStepCopy248(value,16384));Result<Unit>.Ok(())})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let computed=state.computed.getOrThrow();state.total=hostLivePolicyRPCInteger(computed,"payload_count")
                        let manifest=computed.field("manifest").getOrThrow()
                        let manifestWriter=match(actual.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                        match(rpc.download("manifest",hostLivePolicyRPCInteger(manifest,"bytes"),httpIntentText(manifest,"sha256"),manifestWriter)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(actual.inspectLivePolicyWriterMetadata(manifestWriter,localCurrent,{value=>
                            if(!hostLiveStepManifestValid248(value,computed)){throw IllegalStateException("native compact manifest changed exact metadata")}
                            state.manifest=Some(hostLiveStepCopy248(value,16384))})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let manifestPayload=hostLivePolicyActualPayload(manifestWriter.completedArtifact())
                        match(actual.retainLivePolicyStep(context,parent,hostLiveStepDataDescriptor248(parent,ledger,[manifestPayload]),
                            [manifestWriter],localCurrent,streamedSource:true)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        while(state.offset<state.total){
                            // Four actual slots fit the original nine simultaneous
                            // writer bound; each slot is published/ACKed immediately.
                            match(rpc.describe(state.offset,min(4,state.total-state.offset),{value=>
                                metadata.ensureRetainedPeak(retainedPeak+8388608)
                                state.page=Some(hostLiveStepCopy248(value,16384));Result<Unit>.Ok(())})){
                                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                            let page=state.page.getOrThrow();let rows=page.field("payloads").getOrThrow()
                            let next=hostLivePolicyRPCInteger(page,"next_offset")
                            if(rows.unifiedKind!=ValueKind.List || rows.items.isEmpty() || rows.items.size>4 ||
                                next!=state.offset+rows.items.size || hostLivePolicyRPCInteger(page,"total")!=state.total){
                                return hostPluginResourceError<Unit>("plugin.live_step_page_changed","actual slot page changed its continuous order")}
                            for(row in rows.items){
                                if(!httpIntentExactFields(row,["slot","bytes","sha256"]) || httpIntentText(row,"slot")!="payload-"+state.offset.toString()){
                                    return hostPluginResourceError<Unit>("plugin.live_step_slot_order","slot changed its exact ordinal")}
                                let writer=match(actual.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                                match(rpc.download(httpIntentText(row,"slot"),hostLivePolicyRPCInteger(row,"bytes"),httpIntentText(row,"sha256"),writer,
                                    observed:Some({raw=>state.hash.write(raw);state.copied=hostLiveStepAdd248(state.copied,raw.size)}))){
                                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                                let payload=hostLivePolicyActualPayload(writer.completedArtifact())
                                // Pay the full simultaneously retained index and
                                // its original JSON before growing the array.
                                let pending=objectValue([ValueField("retained",state.retained()),ValueField("next",payload)])
                                let size=logicalJsonWriteReservationBytes(pending,8388608)
                                metadata.ensureRetainedPeak(retainedPeak+1048576+size*8+logicalJsonValueNodeCount(pending)*512)
                                state.references.add(payload)
                                match(actual.retainLivePolicyStep(context,parent,hostLiveStepDataDescriptor248(parent,ledger,[payload]),
                                    [writer],localCurrent,streamedSource:true)){
                                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                                state.offset+=1
                            }
                            state.page=None<AgentValue>
                        }
                        let nativeManifest=state.manifest.getOrThrow()
                        if(state.copied!=hostLivePolicyRPCInteger(nativeManifest,"total_bytes") ||
                            hostArtifactHex(state.hash.finish())!=httpIntentText(nativeManifest,"sha256")){
                            return hostPluginResourceError<Unit>("plugin.live_step_whole_hash","all actual slots changed their complete original JSON EOF/hash")}
                        let index=objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-output-index/v1")),
                            ValueField("native_manifest",nativeManifest),ValueField("payloads",listValue(state.references.toArray()))])
                        let indexBytes=logicalJsonWriteReservationBytes(index,8388608)
                        metadata.ensureRetainedPeak(retainedPeak+1048576+indexBytes*8+logicalJsonValueNodeCount(index)*512)
                        let indexWriter=match(hostLiveStepWrite248(actual,index,localCurrent)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                        let indexPayload=hostLivePolicyActualPayload(indexWriter.completedArtifact())
                        match(actual.retainLivePolicyStep(context,parent,hostLiveStepDataDescriptor248(parent,ledger,[indexPayload]),
                            [indexWriter],localCurrent,streamedSource:true)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        let fields=ArrayList<ValueField>([ValueField("schema",textValue("axyndra.plugin-live-policy-host-step/v1")),
                            ValueField("kind",computed.field("kind").getOrThrow()),ValueField("output_index",indexPayload),
                            ValueField("prior_receipts",ledger),ValueField("now_millis",integerValue(nowMillis))])
                        if(httpIntentText(computed,"kind")=="effect"){fields.add(ValueField("effect",computed.field("effect").getOrThrow()))}
                        else{fields.add(ValueField("is_error",computed.field("is_error").getOrThrow()))}
                        let hostMetadata=objectValue(fields.toArray())
                        metadata.ensureRetainedPeak(retainedPeak+1048576+16384*8+logicalJsonValueNodeCount(hostMetadata)*512)
                        state.result=Some(match(hostLiveStepWrite248(actual,hostMetadata,localCurrent)){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value})
                        localCurrent()}
                    let outcome=try{run()}finally{release=rpc.release()}
                    // A cache release is checked before the enclosing actual
                    // worker collection. Neither acknowledgement is a Receipt.
                    match(outcome){case Result.Err(error)=>Result<Unit>.Err(error);case Result.Ok(_)=>release}
                },callerUnbounded:unbounded)
            }
        })
        match(phase.value){case Result.Err(error)=>return Result<HostServiceArtifactWriter>.Err(error);case Result.Ok(_)=>()}
        match(state.result){case Some(writer)=>Result<HostServiceArtifactWriter>.Ok(writer)
            case None=>hostPluginResourceError<HostServiceArtifactWriter>("plugin.live_step_output_missing","actual native step did not finish its same-owner metadata writer")}
    },16384,localCurrent)
}
