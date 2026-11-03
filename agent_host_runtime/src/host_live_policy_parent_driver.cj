package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

// This work in progress is the actual Catalog executor's driver. It contains
// no alternate operation registry or Source reconstruction from a payload.
// The complete effect/receipt replay loop is being added before sealing.
private class HostLiveParentStep263 {
    var metadata:?AgentValue=None<AgentValue>
    var closed=false
    init(){}
    func capture(value:AgentValue,parent:PreparedToolInvocation,ledger:AgentValue):Result<Unit>{
        if(closed || metadata.isSome()){
            return hostPluginResourceError("plugin.live_driver_metadata_closed","actual same-owner metadata cannot be recaptured")}
        let kind=httpIntentText(value,"kind")
        if(!httpIntentExactFields(value,if(kind=="completed"){
                ["schema","kind","output_index","prior_receipts","now_millis","is_error"]
            }else{["schema","kind","output_index","prior_receipts","now_millis","effect"]}) ||
            httpIntentText(value,"schema")!="axyndra.plugin-live-policy-host-step/v1" ||
            !["completed","effect"].contains(kind) ||
            canonicalAgentValue(value.field("prior_receipts").getOrThrow())!=canonicalAgentValue(ledger)){
            return hostPluginResourceError("plugin.live_driver_metadata_changed","actual Host step metadata changed its exact current ledger")}
        let bytes=logicalJsonWriteReservationBytes(value,16384)
        if(bytes>16384){return hostPluginResourceError("plugin.live_driver_metadata_changed","original actual captured metadata exceeded its fixed bound")}
        // The actual 264 Session metadata owner already paid and retained this
        // independent original-writer clone. No extra 16-MiB clone reservation
        // is made; this alias is dropped before that real custody's ACK.
        match(parsePluginDocumentPayloadReference(value.field("output_index").getOrThrow())){
            case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        metadata=Some(value);Result<Unit>.Ok(())
    }
    func close():Unit{if(!closed){metadata=None<AgentValue>;closed=true}}
}

func hostLivePolicyEmptyLedger(parent:OperationId):AgentValue{
    objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
        ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(0)),
        ValueField("tip",nullValue())])
}

// The final single Tool output keeps the original eight-MiB bound. Its
// payload_count==1 follows that old bound and the actual eight-MiB slot
// contract. A large proposal is handled by the separate effect path.
func hostLivePolicyFinalIndex(value:AgentValue):Result<PluginDocumentPayloadReference>{
    try{
        if(!httpIntentExactFields(value,["schema","native_manifest","payloads"]) ||
            httpIntentText(value,"schema")!="axyndra.plugin-live-policy-output-index/v1"){
            return hostPluginResourceError("plugin.live_final_index_changed","actual output index changed its exact Host shape")}
        let manifest=value.field("native_manifest").getOrThrow()
        let payloads=value.field("payloads").getOrThrow()
        if(!httpIntentExactFields(manifest,["schema","kind","total_bytes","sha256","payload_count"]) ||
            httpIntentText(manifest,"kind")!="completed" || httpIntentText(manifest,"schema")=="" ||
            payloads.unifiedKind!=ValueKind.List || payloads.items.size!=1 ||
            hostLivePolicyRPCInteger(manifest,"payload_count")!=1){
            return hostPluginResourceError("plugin.live_final_output_bound","final Tool output exceeds its original single-output codec or changed its manifest")}
        let payload=parsePluginDocumentPayloadReference(payloads.items[0]).value().getOrThrow()
        if(payload.bytes!=hostLivePolicyRPCInteger(manifest,"total_bytes") ||
            payload.digest!=httpIntentText(manifest,"sha256")){
            return hostPluginResourceError("plugin.live_final_index_changed","final index does not retain all actual whole-output bytes")}
        Result<PluginDocumentPayloadReference>.Ok(payload)
    }catch(_:Exception){hostPluginResourceError("plugin.live_final_index_changed","actual final output index is malformed")}
}

func hostLivePolicyFinalDescriptor(parent:PreparedToolInvocation,ledger:AgentValue,
    payload:PluginDocumentPayloadReference,isError:Bool):AgentValue{
    objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_TERMINAL_DATA_SCHEMA)),
        ValueField("parent_operation_id",textValue(parent.operationId.value)),
        ValueField("parent_binding_digest",textValue(parent.operationPlan.bindingDigest)),
        ValueField("prior_receipts",ledger),ValueField("result_payload",payload.value()),ValueField("is_error",boolValue(isError))])
}

// Actual FD Source/pin copy and the actual output lease are used together.
// No whole output String/DOM is constructed in this driver or used as a
// Source. The producer selects a Host descriptor before the original tool
// decoder and the generic terminal audit; the final factory is being wired
// into the Catalog's three typed methods in this same successor.
private func hostProduceLivePolicyCompleted(context:ToolInvocationContext,parent:PreparedToolInvocation,
    actual:HostDocumentDataSession,state:HostLiveParentStep263,ledger:AgentValue,
    current:()->Result<Unit>,consumeDescriptor:(AgentValue)->Unit,releaseStep:()->Result<Unit>):Result<HostServiceArtifactWriter>{
    let produce:()->Result<HostServiceArtifactWriter>={=>
    let step=match(state.metadata){case Some(value)=>value
        case None=>return hostPluginResourceError("plugin.live_final_metadata_missing","same paid step metadata is absent")}
    if(httpIntentText(step,"kind")!="completed" || step.field("is_error").getOrThrow().unifiedKind!=ValueKind.Boolean){
        return hostPluginResourceError("plugin.live_final_metadata_changed","only an actual completed Native data step can select this output")}
    let index=parsePluginDocumentPayloadReference(step.field("output_index").getOrThrow()).value().getOrThrow()
    // A completed output index has exactly one reference. Its actual compact
    // metadata is inspected in the existing sixteen-KiB private-file path.
    let indexWriter=match(actual.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(actual.copyLivePolicyStepPayload(context,parent,ledger,index,indexWriter,current)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let selected=HostLivePolicyFinalSelection263()
    match(actual.inspectLivePolicyWriterMetadata(indexWriter,current,{value=>
        selected.payload=Some(match(hostLivePolicyFinalIndex(value)){
            case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(reference)=>reference})})){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let payload=selected.payload.getOrThrow()
    let descriptor=hostLivePolicyFinalDescriptor(parent,ledger,payload,step.field("is_error").getOrThrow().asBool())
    let writer=match(actual.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    // Both pieces are actual current GC-pinned data; the second Source/FD
    // proof checks the complete output itself, not only the compact index.
    match(actual.copyLivePolicyStepPayload(context,parent,ledger,payload,writer,current)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    actual.withLivePolicyRunningMetadata(descriptor,{_,_=>consumeDescriptor(descriptor)})
    Result<HostServiceArtifactWriter>.Ok(writer)}
    let result=produce()
    // The lexical producer and its complete copied step/manifest references
    // have ended before the owner is closed and the large decoder starts.
    state.close()
    match(releaseStep()){case Result.Err(error)=>return Result<HostServiceArtifactWriter>.Err(error);case Result.Ok(_)=>()}
    result
}
private class HostLivePolicyFinalSelection263 {
    var payload:?PluginDocumentPayloadReference=None<PluginDocumentPayloadReference>
    init(){}
}

func hostExecutePluginLivePolicyParent(host:HostJavaScriptPluginHost,namespace:String,bareTool:String,
    generation:UInt64,context:ToolInvocationContext,parent:PreparedToolInvocation,
    control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
    if(!isPluginLivePolicyParentPlan(parent.operationPlan) || parent.call.name!="plugin."+namespace+"."+bareTool ||
        parent.source.runId.value!=context.runId.value || parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch){
        return hostPluginResourceError("plugin.live_owned_scope","actual original prepared Parent and published Tool are required")}
    let packageDescriptor=match(host.servicePackageData81(namespace,generation)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let configuration=match(host.livePolicyConfiguration(namespace,packageDescriptor.contentDigest,parent.call.name)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(Some(value))=>value
        case Result.Ok(None)=>return hostPluginResourceError("plugin.live_owned_disabled","operator did not select this actual owned family")}
    let binding=parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    if(httpIntentText(parent.operationPlan.canonicalArguments.field("configuration").getOrThrow(),"digest")!=configuration.digest){
        return hostPluginResourceError("plugin.live_owned_config_changed","actual prepared Parent changed its frozen live configuration")}
    let revoked=AtomicBool(false)
    let registration=match(host.observeServiceRevocation(namespace,generation,{=>revoked.store(true)})){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    try{
        let local:()->Result<Unit>={=>
            if(revoked.load() || context.cancellation.isCancelled() ||
                !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:namespace)){
                return hostPluginResourceError<Unit>("plugin.live_owned_cancelled","actual owned Parent was cancelled or revoked")}
            configuration.validateTransferWitness()}
        let full:()->Result<Unit>={=>
            match(local()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            hostLivePolicyInputCurrent(host,configuration,generation,context,parent.call,binding)}
        match(full()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let ledger=hostLivePolicyEmptyLedger(parent.operationId)
        let metadata=HostLiveParentStep263()
        let retained=HostLivePolicyActualStep265()
        try{
            let step=match(hostRunPluginLivePolicyNativeStep(host,configuration,generation,context,parent,0,ledger,
                agentUtcMillis(),bareTool,local,full,{_,_=>Result<Unit>.Ok(())})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            retained.value=Some(step)
            match(step.capturePaidMetadata({value=>metadata.capture(value,parent,ledger)})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            // Mutation proposals proceed through the actual independently
            // prepared child loop. That loop is being completed in this WIP;
            // they can never be relabeled as a completed Parent here.
            if(httpIntentText(metadata.metadata.getOrThrow(),"kind")!="completed"){
                return hostPluginResourceError("plugin.live_effect_driver_pending","actual mutation proposal has no completed effect/Receipt loop yet")}
            // Worker/FD/writer debt has physically ACKed; 264 has ACKed the
            // old decoder's result. The original Session's small metadata
            // remains paid until the final producer copies its actual bounded
            // descriptor into the new actual Session, then drops/ACKs it.
            // No large final decoder runs while this old owner is retained.
            let session=match(host.documentDataSession()){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let terminal=match(hostMaterializeSelectedLivePolicyParentOutput(session,context,parent,
                {actual,select=>hostProduceLivePolicyCompleted(context,parent,actual,metadata,ledger,local,select,{=>
                    let old=match(retained.value){case Some(value)=>value;case None=>return Result<Unit>.Ok(())}
                    match(old.close()){case Result.Err(error)=>Result<Unit>.Err(error)
                        case Result.Ok(_)=>retained.value=None<HostLivePolicySessionCustody>;Result<Unit>.Ok(())}})},local,full)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let result=control.completeParent(terminal.result,terminal.owner)
            if(result.isError()){match(terminal.result.payloadLease){case Some(lease)=>lease.close();case None=>()}}
            result
        }finally{
            // Unknown/error never has a Parent completion. The existing Host
            // collector keeps any actual failed physical close as debt.
            metadata.close()
            match(retained.value){case Some(value)=>let _=value.close();case None=>()}
        }
    }finally{registration.dispose()}
}

private class HostLivePolicyActualStep265 {
    var value:?HostLivePolicySessionCustody=None<HostLivePolicySessionCustody>
    init(){}
}

// Distinct unused migration entries. The mounted executor's old three owned
// methods remain byte exact until actual canonical carrier/oracles enable it.
// ONE private custody object persists across every claimed approval resume.
private class HostLiveParentCustody312 <: LiveToolExecutionCustody {
    let host:HostJavaScriptPluginHost
    let namespace:String
    let bareTool:String
    let generation:UInt64
    let configuration:HostPluginLivePolicyConfiguration
    let parent:PreparedToolInvocation
    let revoked:AtomicBool
    let metadata=HostLiveParentStep263()
    var step:?HostLivePolicySessionCustody=None<HostLivePolicySessionCustody>
    var ledger:?AgentValue=None<AgentValue>
    var nowMillis:Int64=0
    var waitingAliases=false
    private let lock=Mutex()
    private var disposeRegistration:?(() -> Unit)
    private var closing=false
    private var closed=false
    init(host:HostJavaScriptPluginHost,namespace:String,bareTool:String,generation:UInt64,
        configuration:HostPluginLivePolicyConfiguration,parent:PreparedToolInvocation,
        revoked:AtomicBool,disposeRegistration:()->Unit){
        this.host=host;this.namespace=namespace;this.bareTool=bareTool;this.generation=generation
        this.configuration=configuration;this.parent=parent;this.revoked=revoked
        this.disposeRegistration=Some(disposeRegistration)
    }
    func local(context:ToolInvocationContext):Result<Unit>{
        if(revoked.load() || context.cancellation.isCancelled() ||
            (context.budget.deadlineMillis>0 && agentUtcMillis()>=context.budget.deadlineMillis) ||
            !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:namespace)){
            return hostPluginResourceError("plugin.live_owned_cancelled","actual retained parent was cancelled, expired or revoked")}
        configuration.validateTransferWitness()
    }
    func full(context:ToolInvocationContext):Result<Unit>{
        match(local(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        hostLivePolicyInputCurrent(host,configuration,generation,context,parent.call,
            parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow())
    }
    func adoptFirst(value:HostLivePolicySessionCustody,initial:AgentValue):Result<Unit>{
        if(step.isSome() || ledger.isSome()){return hostPluginResourceError("plugin.live_driver_owner_changed","one original actual first step required")}
        step=Some(value);ledger=Some(initial)
        value.capturePaidMetadata({data=>
            match(metadata.capture(data,parent,initial)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            nowMillis=hostLivePolicyRPCInteger(data,"now_millis")
            if(nowMillis<1){return hostPluginResourceError("plugin.live_driver_clock_changed","actual frozen clock is missing")}
            Result<Unit>.Ok(())})
    }
    public func releaseTransient():Result<Unit>{
        match(step){case Some(value)=>value.releaseTransient()
            case None=>hostPluginResourceError("plugin.live_driver_owner_changed","same actual retained step is absent")}
    }
    // Descriptor copy first prepays the ledger in the actual final Session.
    // Only small aliases and the previous physical Session are retired here;
    // revocation remains observed until the final exact output ACK below.
    func releaseFinalStep():Result<Unit>{
        metadata.close()
        match(step){case Some(value)=>match(value.close()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>step=None<HostLivePolicySessionCustody>}
            case None=>()}
        Result.Ok(())
    }
    public func close():Result<Unit>{
        lock.lock();try{
            if(closed){return Result.Ok(())}
            if(waitingAliases){return hostPluginResourceError("plugin.live_pending_alias_ack_required",
                "same original Session still pays immutable pending Prepared aliases; typed canonical retirement is required")}
            if(closing){return hostPluginResourceError("plugin.live_driver_cleanup_pending","same actual parent cleanup is active")}
            closing=true;metadata.close();ledger=None<AgentValue>
        }finally{lock.unlock()}
        let released:Result<Unit>=try{
            match(step){case Some(value)=>value.close();case None=>Result<Unit>.Ok(())}
        }catch(_:Exception){hostPluginResourceError("plugin.live_driver_cleanup_pending","same actual parent retains physical cleanup debt")}
        lock.lock();try{
            closing=false
            match(released){case Result.Err(error)=>Result.Err(error)
                case Result.Ok(_)=>
                    step=None<HostLivePolicySessionCustody>
                    match(disposeRegistration){case Some(dispose)=>dispose();case None=>()}
                    disposeRegistration=None<(() -> Unit)>;closed=true;Result.Ok(())}
        }finally{lock.unlock()}
    }
}

// Same actual final owner and lease, plus the original observer lifetime.
// No Source/Receipt is asserted by this resource-only forwarding owner.
private class HostLiveParentFinalOwner312 <: AcknowledgedOperationTerminalDataOwner {
    private let actual:HostAcknowledgedLivePolicyTerminalDataOwner294
    private let custody:HostLiveParentCustody312
    init(actual:HostAcknowledgedLivePolicyTerminalDataOwner294,custody:HostLiveParentCustody312){
        this.actual=actual;this.custody=custody}
    public func withRetainedOutput(lease:ToolResultPayloadLease,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        actual.withRetainedOutput(lease,consume)}
    public func retainCanonicalBacking(lease:ToolResultPayloadLease):Result<LogicalJsonOwnerReservation>{
        actual.retainCanonicalBacking(lease)}
    public func closeRetainedOutput(lease:ToolResultPayloadLease):Result<Unit>{
        match(actual.closeRetainedOutput(lease)){case Result.Err(error)=>Result.Err(error)
            case Result.Ok(_)=>custody.close()}
    }
}
private class HostLiveParentFinalCapture312 {
    var output:?HostAcknowledgedLivePolicyFinalOutput294=None<HostAcknowledgedLivePolicyFinalOutput294>
    var owner:?HostLiveParentFinalOwner312=None<HostLiveParentFinalOwner312>
    var lease:?ToolResultPayloadLease=None<ToolResultPayloadLease>
    init(){}
}

private func hostFinishLiveParent312(context:ToolInvocationContext,custody:HostLiveParentCustody312,
    control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
    let frame=hostRetainLiveInvocationContext159(context)
    try{hostFinishLiveParentFrame159(hostLiveInvocationContext159(frame,context),custody,control,frame)}
    finally{hostLiveInvocationProducerReturned159(frame)}
}

private func hostFinishLiveParentFrame159(context:ToolInvocationContext,custody:HostLiveParentCustody312,
    control:OwnedToolExecutionControl,contextOwner159:?HostLiveInvocationContext159):Result<OwnedToolExecutionProgress>{
    let session=match(custody.host.documentDataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let selected=HostLiveParentFinalCapture312()
    let produce:(HostDocumentDataSession,(AgentValue)->Unit)->Result<HostServiceArtifactWriter>={actual,select=>
        let ledger=custody.ledger.getOrThrow()
        hostProduceLivePolicyCompleted(context,custody.parent,actual,custody.metadata,ledger,
            {=>custody.local(context)},select,{=>custody.releaseFinalStep()})}
    selected.output=Some(match(hostMaterializeAcknowledgedSelectedLivePolicyParentOutput294(session,context,custody.parent,
        produce,{=>custody.local(context)},{=>custody.full(context)},contextOwner159:contextOwner159)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value})
    // The final descriptor now owns this bounded ledger under the final SAME
    // Session payment; the initial/successor step aliases no longer hold it.
    custody.ledger=None<AgentValue>
    let capture:()->Result<OwnedToolExecutionProgress>={=>
        let actual=selected.output.getOrThrow()
        let owner=HostLiveParentFinalOwner312(actual.owner,custody)
        selected.owner=Some(owner);selected.lease=actual.result.payloadLease
        control.completeParent(actual.result,owner)}
    let result:Result<OwnedToolExecutionProgress>=try{capture()}
        catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("plugin.live_driver_terminal_unverified","actual canonical control rejected the final output")}
    // Drop the last local large ToolResult before checked owner cleanup. On
    // success only the real Kernel completion owns it and its marker owner.
    selected.output=None<HostAcknowledgedLivePolicyFinalOutput294>
    if(result.isError()){
        let closed=match(selected.owner){case Some(owner)=>owner.closeRetainedOutput(selected.lease.getOrThrow())
            case None=>hostPluginResourceError<Unit>("plugin.live_driver_terminal_cleanup_pending","actual final owner was not captured")}
        match(closed){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    }
    result
}

private func hostLiveParentChildCall312(custody:HostLiveParentCustody312):ToolCall{
    let step=custody.metadata.metadata.getOrThrow();let ledger=custody.ledger.getOrThrow()
    let through=hostLivePolicyRPCInteger(ledger,"through_sequence")
    if(through==Int64.Max || httpIntentText(step,"kind")!="effect"){
        throw IllegalStateException("actual finite Native step cannot select another effect")}
    let hostPlan=custody.parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
    let args=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_STREAMING_CHILD_SCHEMA)),
        ValueField("binding",hostPlan.field("binding").getOrThrow()),ValueField("sequence",integerValue(through+1)),
        ValueField("effect",step.field("effect").getOrThrow()),ValueField("proposal_payload",step.field("output_index").getOrThrow()),
        ValueField("read_facts",hostPlan.field("initial_read_facts").getOrThrow()),ValueField("prior_receipts",ledger)])
    if(!pluginLivePolicyStreamingChildValueValid(args)){throw IllegalStateException("actual Native step changed its exact ordinary child arguments")}
    ToolCall(custody.parent.call.callId+":live:"+(through+1).toString(),HOST_PLUGIN_LIVE_EFFECT_TOOL,args)
}

private func hostRunLiveParentSuccessor312(context:ToolInvocationContext,custody:HostLiveParentCustody312,
    nextLedger:AgentValue):Result<Unit>{
    let actual=custody.step.getOrThrow()
    let through=hostLivePolicyRPCInteger(nextLedger,"through_sequence")
    let run:()->Result<HostLivePolicySessionCustody>={=>
        hostRunPluginLivePolicyNativeStep312(custody.host,custody.configuration,custody.generation,context,custody.parent,
            through,nextLedger,custody.nowMillis,custody.bareTool,{=>custody.local(context)},{=>custody.full(context)},
            {_,_=>hostPluginResourceError<Unit>("plugin.live_history_owner_required","actual full known stream requires its paid running owner")},
            uploadKnownOwned:Some({session,rpc,owner,peak=>
                for(sequence in 1..(through+1)){
                    match(hostUploadLivePolicyKnownSequence290(session,rpc,context,custody.parent,sequence,through,nextLedger,
                        owner,peak,{=>custody.local(context)})){
                        case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}}
                Result<Unit>.Ok(())}),
            retirePrevious291:Some({=>
                if(custody.waitingAliases){return hostPluginResourceError<Unit>("plugin.live_pending_alias_ack_required",
                    "pending publication still holds original Prepared aliases; original Session cannot refund or compute")}
                // The new actual Session has prepaid nextLedger already.
                // Every old step DOM/ledger alias owned by this driver ends
                // before the SAME previous physical custody can be refunded.
                custody.metadata.close();custody.ledger=None<AgentValue>
                actual.retireCapturedMetadataForSuccessor291()}))}
    let next=match(run()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(actual.adoptMetadataSuccessor291(next)){
        case Result.Err(error)=>
            match(next.close()){case Result.Err(cleanup)=>return Result.Err(cleanup);case Result.Ok(_)=>()}
            return Result.Err(error)
        case Result.Ok(_)=>()}
    // Reopen only the actual small holder. SAME custody identity is unchanged;
    // the successor's own original private decoder backing is still paid.
    custody.metadata.closed=false;custody.ledger=Some(nextLedger)
    actual.capturePaidMetadata({value=>custody.metadata.capture(value,custody.parent,nextLedger)})
}

private class HostLiveNextLedger312 {var value:?AgentValue=None<AgentValue>;init(){}}
private func hostSettleLiveParentChild312(context:ToolInvocationContext,custody:HostLiveParentCustody312,
    child:PreparedToolInvocation,control:OwnedToolExecutionControl,rejected:Bool):Result<AgentValue>{
    let selected=HostLiveNextLedger312();let actual=custody.step.getOrThrow()
    let previous=custody.ledger.getOrThrow()
    let capture:(?ToolResult)->Result<Unit>={result=>actual.captureKnownChildLedger(context,custody.parent,child,previous,result,
        {=>custody.local(context)},{value=>selected.value=Some(value)})}
    let settled:Result<Unit>=if(rejected){
        // ONLY actual User-false already persisted by original Kernel. The
        // Root's distinct no-handoff proof must accept this exact old child.
        capture(None<ToolResult>)
    }else{
        let held=match(control.executeRetainedChild(context,child,custody)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        // The actual result/lease remains retained through full Root18 Unit,
        // Source/Receipt/prefix validation and bounded ledger copy.
        let proof=held.withOutput({result=>capture(Some(result))})
        // Callback's actual ToolResult alias has ended. Both success/failure
        // attempt checked physical ACK; any failure keeps Kernel's SAME debt.
        let closed=held.closeAfterConsumption()
        match(closed){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(!held.isAcknowledged()){
            return hostPluginResourceError<AgentValue>("plugin.live_child_ack_pending","actual child output physical acknowledgement is missing")}
        proof
    }
    match(settled){case Result.Err(error)=>selected.value=None<AgentValue>;return Result.Err(error);case Result.Ok(_)=>()}
    let next=match(selected.value){case Some(value)=>value;case None=>return hostPluginResourceError("plugin.live_known_child_tip_missing","full actual Root18 returned no ledger")}
    selected.value=None<AgentValue>;Result<AgentValue>.Ok(next)
}

private enum HostLiveDriverSelection312 {
    Known(AgentValue) | Waiting(OwnedToolExecutionProgress)
}
private func hostSelectLiveParentChild312(context:ToolInvocationContext,custody:HostLiveParentCustody312,
    control:OwnedToolExecutionControl):Result<HostLiveDriverSelection312>{
    // This complete lexical call/prepared/output frame ends BEFORE Native
    // successor prepays next ledger and retires the previous step metadata.
    let call=hostLiveParentChildCall312(custody)
    let sequence=hostLivePolicyRPCInteger(custody.ledger.getOrThrow(),"through_sequence")+1
    let prepared=match(control.prepareChild(context,call,"live-policy:"+custody.parent.call.callId+":"+sequence.toString())){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(prepared){
        case ToolPreparation.Ready(child)=>match(hostSettleLiveParentChild312(context,custody,child,control,false)){
            case Result.Err(error)=>Result.Err(error);case Result.Ok(value)=>Result.Ok(HostLiveDriverSelection312.Known(value))}
        case ToolPreparation.NeedsApproval(child,_)=>
            // Preserve the actual original Session charge until Core supplies
            // a typed, independently paid publication alias retirement seam.
            // No immutable pending.child alias can be cleared by this Host.
            custody.waitingAliases=true
            match(control.awaitChild(child,custody)){
                case Result.Err(error)=>Result.Err(error);case Result.Ok(value)=>Result.Ok(HostLiveDriverSelection312.Waiting(value))}
        case ToolPreparation.Denied(denial)=>Result.Err(denial.reason)
        case ToolPreparation.Completed(_)=>hostPluginResourceError("plugin.live_prepare_result_unattested",
            "ordinary completed prepare value supplies no actual independently executed known child")}
}

private func hostDriveLiveParent312(context:ToolInvocationContext,custody:HostLiveParentCustody312,
    control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
    while(true){
        match(custody.full(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(httpIntentText(custody.metadata.metadata.getOrThrow(),"kind")=="completed"){
            return hostFinishLiveParent312(context,custody,control)}
        let selected=match(hostSelectLiveParentChild312(context,custody,control)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(selected){
            case HostLiveDriverSelection312.Known(ledger)=>
                match(hostRunLiveParentSuccessor312(context,custody,ledger)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            case HostLiveDriverSelection312.Waiting(value)=>return Result.Ok(value)}
    }
    hostPluginResourceError("plugin.live_driver_closed","actual finite driver stopped")
}

private func hostInitializeLiveParent312(context:ToolInvocationContext,custody:HostLiveParentCustody312):Result<Unit>{
    let ledger=hostLivePolicyEmptyLedger(custody.parent.operationId)
    let first=match(hostRunPluginLivePolicyNativeStep312(custody.host,custody.configuration,custody.generation,context,custody.parent,0,ledger,
        agentUtcMillis(),custody.bareTool,{=>custody.local(context)},{=>custody.full(context)},{_,_=>Result<Unit>.Ok(())})){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    custody.adoptFirst(first,ledger)
}

func hostExecutePluginLivePolicyParent312(host:HostJavaScriptPluginHost,namespace:String,bareTool:String,
    generation:UInt64,context:ToolInvocationContext,parent:PreparedToolInvocation,
    control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
    if(!isPluginLivePolicyParentPlan(parent.operationPlan) || parent.call.name!="plugin."+namespace+"."+bareTool ||
        parent.source.runId.value!=context.runId.value || parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch){
        return hostPluginResourceError("plugin.live_owned_scope","actual original prepared parent and published tool are required")}
    let packageDescriptor=match(host.servicePackageData81(namespace,generation)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let configuration=match(host.livePolicyConfiguration(namespace,packageDescriptor.contentDigest,parent.call.name)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(Some(value))=>value
        case Result.Ok(None)=>return hostPluginResourceError("plugin.live_owned_disabled","actual operator did not select this owned family")}
    if(httpIntentText(parent.operationPlan.canonicalArguments.field("configuration").getOrThrow(),"digest")!=configuration.digest){
        return hostPluginResourceError("plugin.live_owned_config_changed","actual prepared parent changed its frozen live configuration")}
    let revoked=AtomicBool(false)
    let registration=match(host.observeServiceRevocation(namespace,generation,{=>revoked.store(true)})){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let custody=HostLiveParentCustody312(host,namespace,bareTool,generation,configuration,parent,revoked,{=>registration.dispose()})
    let run:()->Result<OwnedToolExecutionProgress>={=>
        match(custody.full(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(hostInitializeLiveParent312(context,custody)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        hostDriveLiveParent312(context,custody,control)}
    let result:Result<OwnedToolExecutionProgress>=try{run()}
        catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("plugin.live_driver_unverified","actual retained driver could not complete")}
    // Waiting and terminal transfer this actual custody/observer to the real
    // Kernel owner. Error clears aliases before checked physical cleanup.
    if(result.isError()){
        match(custody.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
    result
}

func hostResumePluginLivePolicyParent312(host:HostJavaScriptPluginHost,namespace:String,bareTool:String,
    generation:UInt64,context:ToolInvocationContext,pending:OwnedToolExecutionContinuation,
    decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
    pending.withClaimedCustody({retained=>
        let custody=match(retained as HostLiveParentCustody312){case Some(value)=>value
            case None=>return hostPluginResourceError("plugin.live_driver_owner_changed","actual private retained parent custody is required")}
        if(!refEq(custody.host,host) || !refEq(custody.parent,pending.parent) || custody.namespace!=namespace ||
            custody.bareTool!=bareTool || custody.generation!=generation ||
            pending.parent.source.runId.value!=context.runId.value || pending.parent.source.sessionId.value!=context.sessionId.value ||
            pending.parent.source.epoch!=context.epoch){
            return hostPluginResourceError("plugin.live_driver_owner_changed","claimed original parent/custody/current invocation changed")}
        match(custody.full(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        // Loan only bounded metadata, not SQL/prepare/worker work. All values
        // remain owned by the SAME original captured Session while waiting.
        match(custody.step.getOrThrow().withPaidMetadata({value=>
            if(canonicalAgentValue(value)!=canonicalAgentValue(custody.metadata.metadata.getOrThrow())){
                return hostPluginResourceError<Unit>("plugin.live_driver_metadata_changed","claimed paid step differs from its original owner")}
            Result<Unit>.Ok(())})){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let rejected=match(decision){case ApprovalDecision.Reject | ApprovalDecision.RejectWithReason(_)=>true
            case ApprovalDecision.Approve | ApprovalDecision.ApproveSession=>false}
        let child=if(rejected){pending.child}else{
            match(control.approvedPendingChild()){case Result.Err(error)=>return Result.Err(error)
                case Result.Ok(Some(value))=>value
                case Result.Ok(None)=>return hostPluginResourceError("plugin.live_driver_approval_missing","actual original Kernel supplied no approved child")}}
        let ledger=match(hostSettleLiveParentChild312(context,custody,child,control,rejected)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(hostRunLiveParentSuccessor312(context,custody,ledger)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        hostDriveLiveParent312(context,custody,control)})
}

// Unused adapter for the NEW segmented mutable Tools publication path only.
// The real Kernel must use this SAME wrapper object from initial execute
// through every paid resume. The original312 class/legacy Waiting driver is
// unchanged and cannot be adopted after its immutable publication escaped.
// Root's permanent Prepared/input owner is a separate required lifetime.
private class HostLivePendingPreparedCustody319 <: LiveToolExecutionCustody & OwnedPendingPreparedAliasCustody {
    private let actual:HostLiveParentCustody312
    private let lock=Mutex()
    private var pending=false
    private var closing=false
    private var closed=false
    init(actual:HostLiveParentCustody312){this.actual=actual}
    public func retainPendingPreparedAliases(parent:PreparedToolInvocation,
        child:PreparedToolInvocation):Result<LogicalJsonOwnerReservation>{
        lock.lock();try{
            // These are custody/data binding checks only. Original ordinary
            // Kernel prepare/approval/handoff and full Store Source remain
            // independent authority; no ID/plan JSON produces a grant here.
            if(closed || closing || pending || actual.waitingAliases ||
                actual.step.isNone() || actual.ledger.isNone() || actual.metadata.metadata.isNone() ||
                !refEq(parent,actual.parent) || child.source.kind!=PreparedInvocationSourceKind.Derived ||
                child.source.parentOperationId.isNone() ||
                child.source.parentOperationId.getOrThrow().value!=parent.operationId.value ||
                child.operationId.value==parent.operationId.value ||
                child.source.runId.value!=parent.source.runId.value ||
                child.source.sessionId.value!=parent.source.sessionId.value || child.source.epoch!=parent.source.epoch){
                return hostPluginResourceError("plugin.live_pending_prepared_owner_changed",
                    "new mutable publication requires the original unconsumed parent and actual prepared child custody")}
            // Original captured Session remains the physical collector on
            // failure. Tools must pay ALL actual private Prepared/source,
            // call/plan/approval/read/escaper aliases on this derived child
            // BEFORE publishing; 8192 accounts for wrapper cells only.
            pending=true;actual.waitingAliases=true
            actual.step.getOrThrow().retainPendingPreparedBacking315(8192)
        }finally{lock.unlock()}
    }
    public func pendingPreparedAliasesRetired(retirement:OwnedPendingPreparedAliasRetirement):Result<Unit>{
        lock.lock();try{
            if(closed || closing || !pending || !actual.waitingAliases){
                return hostPluginResourceError("plugin.live_pending_alias_retirement_closed",
                    "same actual new mutable pending alias lifetime is unavailable")}
            // minimum2 consumes the private token successfully once, bound
            // to THIS exact original Kernel custody object. No wire Bool,
            // old immutable Waiting or previous-cycle token can unlock it.
            if(!retirement.matches(this)){
                return hostPluginResourceError("plugin.live_pending_alias_retirement_unverified",
                    "Tools must retire all actual pending Prepared aliases before releasing this gate")}
            pending=false;actual.waitingAliases=false
            // Unlock only. Keep actual old metadata/ledger/Session charged:
            // next phase must first pay its full ledger, then original291
            // performs real alias-clear and checked physical metadata ACK.
            Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    public func releaseTransient():Result<Unit>{actual.releaseTransient()}
    public func close():Result<Unit>{
        lock.lock();try{
            if(closed){return Result<Unit>.Ok(())}
            if(closing || pending || actual.waitingAliases){
                return hostPluginResourceError("plugin.live_pending_alias_ack_required",
                    "same actual Session collector and allocation remain until typed private alias retirement")}
            closing=true
        }finally{lock.unlock()}
        let released:Result<Unit>=try{actual.close()}
            catch(_:Exception){hostPluginResourceError("plugin.live_pending_physical_cleanup_pending",
                "same original custody retains physical cleanup debt")}
        lock.lock();try{
            closing=false
            match(released){case Result.Err(error)=>Result<Unit>.Err(error)
                case Result.Ok(_)=>closed=true;Result<Unit>.Ok(())}
        }finally{lock.unlock()}
    }
}

// Concrete trusted Host phase executor, deliberately not selected by the
// current mounting factory. Its original Session is collected BEFORE Tools
// walks/retains full Prepared data and is reused for the FIRST Native run.
// No independent input pool, Source-from-ID decoder or lifetime refund.
private class HostLiveInitialPreparedCustody332 <: OwnedKernelPreparedReferenceCustody {
    let actual:HostLiveParentCustody312
    let session:HostDocumentDataSession
    let physical:HostLiveExecutionCustody
    private let lock=Mutex()
    private var firstBacking:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
    private var firstDebt:?OwnedKernelPreparedReferenceDebt=None<OwnedKernelPreparedReferenceDebt>
    private var requested:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
    private let adopted=ArrayList<OwnedKernelPreparedReferenceDebt>()
    private var started=false
    private var awaitingInput=false
    private var pendingDebt336:?OwnedKernelPreparedReferenceDebt=None<OwnedKernelPreparedReferenceDebt>
    private var inputAction336:?HostLivePreparedInputAction336=None<HostLivePreparedInputAction336>
    private let inputActions336=ArrayList<HostLivePreparedInputAction336>()
    private let dataPins336=ArrayList<HostLiveCapturedMetadataPin336>()
    private var inputActionAdmitted336=false
    private var nextLedger:?AgentValue=None<AgentValue>
    private var finalAttempted94=false
    private var finalCapture94:?HostLivePreparedFinalCapture94=None<HostLivePreparedFinalCapture94>
    init(actual:HostLiveParentCustody312,session:HostDocumentDataSession,physical:HostLiveExecutionCustody){
        this.actual=actual;this.session=session;this.physical=physical
    }
    public func retainPendingPreparedAliases(parent:PreparedToolInvocation,
        child:PreparedToolInvocation):Result<LogicalJsonOwnerReservation>{
        lock.lock();try{
            if(!refEq(parent,actual.parent) || requested.isSome()){
                return hostPluginResourceError("plugin.live_initial_prepared_owner_changed",
                    "same original parent input custody must adopt its prior actual invoice first")}
            if(!started){
                if(firstBacking.isSome() || firstDebt.isSome() || !refEq(parent,child) || actual.step.isSome()){
                    return hostPluginResourceError("plugin.live_initial_prepared_owner_changed",
                        "first input invoice requires the exact original parent before Native initialization")}
                let loan=match(session.retainLivePolicyInitialPreparedBacking332(this,physical,8192)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                firstBacking=Some(loan);requested=Some(loan);Result<LogicalJsonOwnerReservation>.Ok(loan)
            }else{
                let step=match(actual.step){case Some(value)=>value
                    case None=>return hostPluginResourceError("plugin.live_initial_prepared_owner_changed",
                        "later input retains its actual completed step metadata owner")}
                let loan=match(step.retainPendingPreparedBacking315(8192)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                requested=Some(loan);Result<LogicalJsonOwnerReservation>.Ok(loan)
            }
        }finally{lock.unlock()}
    }
    public func adoptKernelPreparedReferenceDebt(debt:OwnedKernelPreparedReferenceDebt):Result<Unit>{
        lock.lock();try{
            if(requested.isNone() || !ownedKernelPreparedReferenceDebtMatchesCustody332(this,debt)){
                return hostPluginResourceError("plugin.live_initial_prepared_debt_changed",
                    "actual full Kernel invoice must belong to this original custody")}
            // Adopt BEFORE any error escapes. Payment/callback/source fields
            // remain held on failure; no cleanup return refunds these aliases.
            adopted.add(debt)
            if(!started){
                if(firstDebt.isSome() || firstBacking.isNone()){
                    return hostPluginResourceError("plugin.live_initial_prepared_debt_changed",
                        "first original input debt cannot be adopted twice")}
                firstDebt=Some(debt)
                match(session.adoptLivePolicyInitialPreparedDebt332(this,physical,firstBacking.getOrThrow(),debt)){
                    case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            }
            requested=None<LogicalJsonOwnerReservation>;Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    private let outerFrames334=ArrayList<PluginLivePolicyOuterErrorFrame334>()
    func retainOuterErrorFrame334(parent:PreparedToolInvocation):Result<PluginLivePolicyOuterErrorFrame334>{
        lock.lock();try{
            if(!started || firstDebt.isNone() || !refEq(parent,actual.parent) || actual.step.isNone()){
                return hostPluginResourceError("plugin.live_error_frame_owner_changed","same actual initialized parent custody is required")}
            let loan=match(actual.step.getOrThrow().retainPendingPreparedBacking315(8192)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            try{
                let frame=PluginLivePolicyOuterErrorFrame334.retain(loan)
                outerFrames334.add(frame);Result.Ok(frame)
            }finally{loan.close()}
        }catch(_:Exception){hostPluginResourceError("plugin.live_error_frame_capacity","same existing metadata bank could not retain its frame")}
        finally{lock.unlock()}
    }
    func initialize(context:ToolInvocationContext):Result<Unit>{
        lock.lock()
        let debt:OwnedKernelPreparedReferenceDebt=try{
            if(started || firstDebt.isNone() || requested.isSome() || actual.step.isSome()){
                return hostPluginResourceError<Unit>("plugin.live_initial_prepared_debt_required",
                    "first actual Native initialization requires completed original Kernel prepayment")}
            started=true;firstDebt.getOrThrow()
        }finally{lock.unlock()}
        let ledger=hostLivePolicyEmptyLedger(actual.parent.operationId)
        let first=match(hostRunPluginLivePolicyNativeInitialStep332(session,physical,this,debt,
            actual.host,actual.configuration,actual.generation,context,actual.parent,0,ledger,
            agentUtcMillis(),actual.bareTool,{=>actual.local(context)},{=>actual.full(context)},
            {_,_=>Result<Unit>.Ok(())})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        actual.adoptFirst(first,ledger)
    }
    func markWaiting():Result<Unit>{
        lock.lock();try{
            if(!started || awaitingInput || nextLedger.isSome()){
                return hostPluginResourceError("plugin.live_prepared_input_phase_changed",
                    "one actual pending input phase is required")}
            awaitingInput=true;actual.waitingAliases=true;Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    func retainSettledInput(ledger:AgentValue):Result<Unit>{
        lock.lock();try{
            if(!awaitingInput || !actual.waitingAliases || nextLedger.isSome()){
                return hostPluginResourceError("plugin.live_prepared_input_phase_changed",
                    "actual settled ledger remains in its original pending metadata owner")}
            // Root18 capture prepaid this exact ledger in actual.step. No
            // AgentValue copy/new parser occurs when retaining the reference.
            nextLedger=Some(ledger);Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    func markWaiting336():Result<Unit>{
        lock.lock();try{
            if(adopted.isEmpty() || pendingDebt336.isSome() || inputAction336.isSome()){
                return hostPluginResourceError("plugin.live_waiting_scope_changed","actual original executing Kernel debt is required")}
            pendingDebt336=Some(adopted[adopted.size-1]);inputActionAdmitted336=false
        }finally{lock.unlock()}
        markWaiting()
    }
    func settlePreparedInput336(context:ToolInvocationContext,child:PreparedToolInvocation,
        decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<Unit>{
        lock.lock();try{
            if(!awaitingInput || !actual.waitingAliases || pendingDebt336.isNone() || inputAction336.isSome() || inputActionAdmitted336){
                return hostPluginResourceError("plugin.live_input_action_changed","same original pending action must settle at most once")}
            inputActionAdmitted336=true
        }finally{lock.unlock()}
        let loan=match(actual.step.getOrThrow().retainPendingPreparedBacking315(8192)){
            case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
        let data=match(retainOwnedHostPreparedActionData336(loan,child,decision)){
            case Result.Err(error)=>loan.close();return Result<Unit>.Err(error);case Result.Ok(value)=>value}
        let action=HostLivePreparedInputAction336(data)
        lock.lock();try{inputActions336.add(action);inputAction336=Some(action)}finally{lock.unlock()}
        // Real child/decision/approval references now belong to action, not
        // another persistent parallel holder. Failure retains all of them.
        match(action.execute(context,this,control)){
            case Result.Err(error)=>Result<Unit>.Err(error);case Result.Ok(_)=>action.transfer(context,this)}
    }
    func advanceReadyLedger336(context:ToolInvocationContext,ledger:AgentValue):Result<Unit>{
        let pin=match(actual.step.getOrThrow().retainCapturedSuccessorPin336(actual.ledger.getOrThrow(),ledger)){
            case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
        lock.lock();try{dataPins336.add(pin)}finally{lock.unlock()}
        hostRunLiveParentPaidSuccessor336(context,actual,ledger,pin)
    }
    func continueSettledInput336(context:ToolInvocationContext,witness:OwnedPreparedWaitingFieldsWitness,
        control:OwnedToolExecutionControl):Result<OwnedPreparedPhaseProgress>{
        lock.lock()
        let debt:OwnedKernelPreparedReferenceDebt=try{
            if(!awaitingInput || !actual.waitingAliases || nextLedger.isNone() || pendingDebt336.isNone() ||
                inputAction336.isNone()){
                return hostPluginResourceError<OwnedPreparedPhaseProgress>("plugin.live_input_fields_live","actual Host and Kernel input frames must end before successor")}
            pendingDebt336.getOrThrow()
        }finally{lock.unlock()}
        if(!inputAction336.getOrThrow().fieldsCleared336()){
            return hostPluginResourceError("plugin.live_input_fields_live","actual Host input helper frames remain live")}
        match(actual.full(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(!witness.matchesHostWaitingScope336(this,debt)){
            return hostPluginResourceError("plugin.live_waiting_scope_changed","foreign or replayed Kernel phase cannot change actual paid successor state")}
        let ledger=nextLedger.getOrThrow()
        let pin=match(actual.step.getOrThrow().retainCapturedSuccessorPin336(actual.ledger.getOrThrow(),ledger)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        lock.lock();try{dataPins336.add(pin)}finally{lock.unlock()}
        // The original private phase shares this claim across NEW witnesses.
        // Foreign custody/debt or replay cannot authorize another computation.
        if(!witness.claimHostWaitingScope336(this,debt)){
            return hostPluginResourceError("plugin.live_waiting_scope_changed","same actual consumed Kernel phase and adopted original debt are required")}
        match(hostRunLiveParentPaidSuccessor336(context,actual,ledger,pin)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock();try{
            nextLedger=None<AgentValue>;pendingDebt336=None<OwnedKernelPreparedReferenceDebt>
            inputAction336=None<HostLivePreparedInputAction336>;awaitingInput=false
            // Original GLOBAL waitingAliases stays true. Adopted full input
            // Source, context/caller and each old metadata pin remain paid.
        }finally{lock.unlock()}
        hostDriveLivePreparedParent336(context,this,control)
    }
    // Completion transfers the actual final result to the existing Kernel
    // verifier. Permanent input/Source debt and every old data pin stay paid.
    // The final owner acknowledges only its own physical output, never this
    // custody's independent caller, configuration or Prepared aliases.
    func completePaidParent94(context:ToolInvocationContext,
        control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        let frame=hostRetainLiveInvocationContext159(context)
        try{completePaidParentFrame159(hostLiveInvocationContext159(frame,context),control,frame)}
        finally{hostLiveInvocationProducerReturned159(frame)}
    }

    private func completePaidParentFrame159(context:ToolInvocationContext,
        control:OwnedToolExecutionControl,contextOwner159:?HostLiveInvocationContext159):Result<OwnedToolExecutionProgress>{
        match(actual.full(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock()
        let step:HostLivePolicySessionCustody=try{
            if(!started || finalAttempted94 || awaitingInput || nextLedger.isSome() ||
                pendingDebt336.isSome() || inputAction336.isSome() || actual.step.isNone() || actual.ledger.isNone()){
                return hostPluginResourceError<OwnedToolExecutionProgress>("plugin.live_final_phase_changed",
                    "one actual completed initialized parent with no active input action is required")}
            finalAttempted94=true;actual.step.getOrThrow()
        }finally{lock.unlock()}
        let ledger=actual.ledger.getOrThrow()
        // Both ledger occurrences and the complete actual old metadata are
        // prepaid in a child of the original Session allocation. The pin stays
        // owned here even when a later constructor or output transfer fails.
        let pin=match(step.retainCapturedSuccessorPin336(ledger,ledger)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        lock.lock();try{dataPins336.add(pin)}finally{lock.unlock()}
        // This actual successor Session is registered by the original
        // collector before any writer, FD copy or large result decoder runs.
        let finalSession=match(step.createPaidDataSuccessorSession336(pin)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let selected=HostLivePreparedFinalCapture94()
        lock.lock();try{finalCapture94=Some(selected)}finally{lock.unlock()}
        let produce:(HostDocumentDataSession,(AgentValue)->Unit)->Result<HostServiceArtifactWriter>={session,select=>
            hostProduceLivePolicyCompleted(context,actual.parent,session,actual.metadata,ledger,
                {=>actual.local(context)},select,{=>
                    // The original producer has returned and cleared its real
                    // private step holder. The full ledger/metadata data is
                    // still funded by pin; this ACK clears physical fields.
                    actual.ledger=None<AgentValue>
                    step.retireCapturedPhysicalForPaidSuccessor336(pin)})}
        selected.output=Some(match(hostMaterializeAcknowledgedSelectedLivePolicyParentOutput294(
            finalSession,context,actual.parent,produce,{=>actual.local(context)},{=>actual.full(context)},contextOwner159:contextOwner159)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value})
        let capture:()->Result<OwnedToolExecutionProgress>={=>
            let output=selected.output.getOrThrow()
            // The original typed 294 owner preserves actual result backing
            // through canonical persistence, then checks the same lease ACK.
            // No 312 whole-parent close or global input retirement is claimed.
            control.completeParent(output.result,output.owner)}
        let result:Result<OwnedToolExecutionProgress>=try{capture()}
            catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
            catch(_:Exception){hostPluginResourceError("plugin.live_driver_terminal_unverified",
                "actual canonical control rejected the final output")}
        // capture's raw ToolResult frame has ended. A successful actual Kernel
        // completion now owns it; on failure this same custody keeps the real
        // output/owner/lease and its Session's outputPending payment debt.
        if(!result.isError()){selected.output=None<HostAcknowledgedLivePolicyFinalOutput294>}
        result
    }
    public func pendingPreparedAliasesRetired(retirement:OwnedPendingPreparedAliasRetirement):Result<Unit>{
        let _=retirement
        hostPluginResourceError("plugin.live_initial_prepared_aliases_pending",
            "Kernel field witness cannot retire independent Host and permanent parent Source aliases")
    }
    public func releaseTransient():Result<Unit>{
        match(actual.step){case Some(value)=>value.releaseTransient()
            case None=>physical.releaseTransient()}
    }
    public func close():Result<Unit>{
        // The original collector retains the real physical resources and
        // adopted loans. No explicit caller, Host configuration, permanent
        // Root/Source or output-error alias retirement is installed here.
        hostPluginResourceError("plugin.live_initial_prepared_aliases_pending",
            "same original full Prepared funding remains paid until independent aliases retire")
    }
}

func hostRetainOuterErrorFrame334(parent:PreparedToolInvocation,
    custody:LiveToolExecutionCustody):Result<PluginLivePolicyOuterErrorFrame334>{
    match(custody as HostLiveInitialPreparedCustody332){
        case Some(actual)=>actual.retainOuterErrorFrame334(parent)
        case None=>hostPluginResourceError("plugin.live_error_frame_owner_required","actual initial paid custody is required")}
}

private func hostCreateInitialPreparedCustody332(host:HostJavaScriptPluginHost,namespace:String,bareTool:String,
    generation:UInt64,context:ToolInvocationContext,parent:PreparedToolInvocation,
    input:HostLivePreparationData340):Result<HostLiveInitialPreparedCustody332>{
    if(!isPluginLivePolicyParentPlan(parent.operationPlan) || parent.call.name!="plugin."+namespace+"."+bareTool ||
        parent.source.runId.value!=context.runId.value || parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch){
        return hostPluginResourceError("plugin.live_owned_scope","actual original prepared parent and published tool are required")}
    let descriptor=match(host.servicePackageData81(namespace,generation)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let configuration=match(host.livePolicyConfiguration(namespace,descriptor.contentDigest,parent.call.name)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(Some(value))=>value
        case Result.Ok(None)=>return hostPluginResourceError("plugin.live_owned_disabled","actual operator did not select this owned family")}
    if(httpIntentText(parent.operationPlan.canonicalArguments.field("configuration").getOrThrow(),"digest")!=configuration.digest){
        return hostPluginResourceError("plugin.live_owned_config_changed","actual prepared parent changed its frozen live configuration")}
    // Actual published ContextRead data factory inserts this SAME inert
    // Session into retainedDataSessions before obtaining any physical loan.
    if(!input.matches(context,parent.source.operationRoot,parent.call)){
        return hostPluginResourceError("plugin.live_preparation_owner_changed","actual prepaid input must remain bound to this original parent")}
    let session=input.session;let physical=input.physical
    let revoked=AtomicBool(false)
    let registration=match(host.observeServiceRevocation(namespace,generation,{=>revoked.store(true)})){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let driver=HostLiveParentCustody312(host,namespace,bareTool,generation,configuration,parent,revoked,{=>registration.dispose()})
    Result.Ok(HostLiveInitialPreparedCustody332(driver,session,physical))
}

private func hostSettleLiveParentChild332(context:ToolInvocationContext,custody:HostLiveInitialPreparedCustody332,
    child:PreparedToolInvocation,control:OwnedToolExecutionControl,rejected:Bool):Result<AgentValue>{
    let selected=HostLiveNextLedger312();let actual=custody.actual.step.getOrThrow()
    let previous=custody.actual.ledger.getOrThrow()
    let capture:(?ToolResult)->Result<Unit>={result=>actual.captureKnownChildLedger(context,custody.actual.parent,child,previous,result,
        {=>custody.actual.local(context)},{value=>selected.value=Some(value)})}
    let settled:Result<Unit>=if(rejected){capture(None<ToolResult>)}else{
        let held=match(control.executeRetainedChild(context,child,custody)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let proof=held.withOutput({result=>capture(Some(result))})
        let closed=held.closeAfterConsumption()
        match(closed){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(!held.isAcknowledged()){
            return hostPluginResourceError<AgentValue>("plugin.live_child_ack_pending","actual child output physical acknowledgement is missing")}
        proof
    }
    match(settled){case Result.Err(error)=>selected.value=None<AgentValue>;return Result.Err(error);case Result.Ok(_)=>()}
    let next=match(selected.value){case Some(value)=>value
        case None=>return hostPluginResourceError("plugin.live_known_child_tip_missing","full actual Root18 returned no ledger")}
    selected.value=None<AgentValue>;Result<AgentValue>.Ok(next)
}

private enum HostLivePreparedSelection332 { Known(AgentValue) | Waiting(OwnedPreparedWaitingPhase) }
private func hostSelectLivePreparedChild332(context:ToolInvocationContext,custody:HostLiveInitialPreparedCustody332,
    control:OwnedToolExecutionControl):Result<HostLivePreparedSelection332>{
    let actual=custody.actual;let call=hostLiveParentChildCall312(actual)
    let sequence=hostLivePolicyRPCInteger(actual.ledger.getOrThrow(),"through_sequence")+1
    let prepared=match(control.prepareChild(context,call,"live-policy:"+actual.parent.call.callId+":"+sequence.toString())){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(prepared){
        case ToolPreparation.Ready(child)=>match(hostSettleLiveParentChild332(context,custody,child,control,false)){
            case Result.Err(error)=>Result.Err(error);case Result.Ok(value)=>Result.Ok(HostLivePreparedSelection332.Known(value))}
        case ToolPreparation.NeedsApproval(child,_)=>
            match(custody.markWaiting()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(control.awaitPreparedPhase(child,custody)){
                case Result.Err(error)=>Result.Err(error);case Result.Ok(value)=>Result.Ok(HostLivePreparedSelection332.Waiting(value))}
        case ToolPreparation.Denied(denial)=>Result.Err(denial.reason)
        case ToolPreparation.Completed(_)=>hostPluginResourceError("plugin.live_prepare_result_unattested",
            "ordinary completed prepare value supplies no actual independently executed known child")}
}
private func hostDriveLivePreparedParent332(context:ToolInvocationContext,custody:HostLiveInitialPreparedCustody332,
    control:OwnedToolExecutionControl):Result<OwnedPreparedPhaseProgress>{
    while(true){
        let actual=custody.actual
        match(actual.full(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(httpIntentText(actual.metadata.metadata.getOrThrow(),"kind")=="completed"){
            match(hostFinishLiveParent312(context,actual,control)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>return Result.Ok(OwnedPreparedPhaseProgress.Legacy(value))}}
        let selected=match(hostSelectLivePreparedChild332(context,custody,control)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(selected){
            case HostLivePreparedSelection332.Known(ledger)=>
                match(hostRunLiveParentSuccessor312(context,actual,ledger)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            case HostLivePreparedSelection332.Waiting(value)=>return Result.Ok(OwnedPreparedPhaseProgress.Waiting(value))}
    }
    hostPluginResourceError("plugin.live_driver_closed","actual finite driver stopped")
}

// The common mounting factory selects this actual Catalog executor for the
// operator-selected live parent, using the same Host/generation. Ordinary
// behavior still delegates to the original executor; actual Root validation is required.
class HostLivePreparedPhaseExecutor332 <: ToolExecutor & OwnedPreparedPhaseExecutor & OwnedPersistedToolResultObserver & OwnedPreparationInputExecutor340 {
    private let legacy:HostJavaScriptPluginToolExecutor
    private let host:HostJavaScriptPluginHost
    private let namespace:String
    private let bareTool:String
    private let generation:UInt64
    private let lock=Mutex()
    private let custodies=ArrayList<HostLiveInitialPreparedCustody332>()
    private var preparations340:?HostLivePreparationData340=None<HostLivePreparationData340>
    init(legacy:HostJavaScriptPluginToolExecutor,host:HostJavaScriptPluginHost,namespace:String,bareTool:String,generation:UInt64){
        this.legacy=legacy;this.host=host;this.namespace=namespace;this.bareTool=bareTool;this.generation=generation
    }
    public func retainPreparationInput340(context:ToolInvocationContext,root:?OperationRootSource,
        call:ToolCall,facts:Array<ContextReadFactLink>):Result<Unit>{
        if(context.trustedControl || call.name!="plugin."+namespace+"."+bareTool){
            return hostPluginResourceError("plugin.live_preparation_scope","actual published input and ordinary context are required")}
        lock.lock();try{
            var cursor=preparations340
            while(cursor.isSome()){
                let value=cursor.getOrThrow()
                if(value.matches(context,root,call)){return value.pay(context,root,call,facts)}
                cursor=value.previous
            }
            // Original factory/collector adopts this inert Session BEFORE
            // any input traversal, retained graph, Native init/spawn or IO.
            let session=match(host.documentDataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let physical=match(session.retainExecutionCustody()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let loan=match(session.retainLivePolicyPreparationBacking340(physical)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            match(ownedPreparationInputInvoice340(loan,context,root,call,facts)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            preparations340=Some(HostLivePreparationData340(session,physical,root,context,call,preparations340))
            Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    public func preparedReferenceCustody(context:ToolInvocationContext,
        parent:PreparedToolInvocation):Result<OwnedKernelPreparedReferenceCustody>{
        lock.lock();try{
            // Reference identity is data routing only; actual original Kernel
            // Source/current/admission proof already ran and runs again later.
            for(value in custodies){if(refEq(value.actual.parent,parent)){
                match(value.actual.full(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                return Result<OwnedKernelPreparedReferenceCustody>.Ok(value)}}
            var cursor=preparations340
            var input:?HostLivePreparationData340=None<HostLivePreparationData340>
            while(cursor.isSome()){
                let value=cursor.getOrThrow()
                if(value.matches(context,parent.source.operationRoot,parent.call)){input=Some(value);break}
                cursor=value.previous
            }
            if(input.isNone()){
                return hostPluginResourceError("plugin.live_preparation_unpaid","installed prepared parent requires its actual earlier same-Session input loan")}
            let value=match(hostCreateInitialPreparedCustody332(host,namespace,bareTool,generation,context,parent,input.getOrThrow())){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
            // No ownership is forgotten on later invoice/adoption errors.
            // The actual physical Session already lives in Host collector.
            custodies.add(value);Result<OwnedKernelPreparedReferenceCustody>.Ok(value)
        }finally{lock.unlock()}
    }
    private func actualCustody(context:ToolInvocationContext,parent:PreparedToolInvocation):Result<HostLiveInitialPreparedCustody332>{
        let value=match(preparedReferenceCustody(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
        match(value as HostLiveInitialPreparedCustody332){case Some(actual)=>Result.Ok(actual)
            case None=>hostPluginResourceError("plugin.live_initial_prepared_owner_changed","actual private initial Host input custody required")}
    }
    public func executePreparedPhase(context:ToolInvocationContext,parent:PreparedToolInvocation,
        control:OwnedToolExecutionControl):Result<OwnedPreparedPhaseProgress>{
        let custody=match(actualCustody(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(custody.actual.full(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(custody.initialize(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        hostDriveLivePreparedParent336(context,custody,control)
    }
    public func rejectPreparedPhase(context:ToolInvocationContext,parent:PreparedToolInvocation,
        decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<OwnedPreparedPhaseProgress>{
        // Original parent rejection path: no Native init/effect replay. The
        // already adopted full Prepared debt remains conservatively pinned.
        match(hostRejectPluginLivePolicyParent(host,namespace,bareTool,generation,context,parent,decision,control)){
            case Result.Err(error)=>Result.Err(error);case Result.Ok(value)=>Result.Ok(OwnedPreparedPhaseProgress.Legacy(value))}
    }
    public func resumePreparedInput(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,decision:ApprovalDecision,control:OwnedToolExecutionControl,
        custody:OwnedKernelPreparedReferenceCustody):Result<Unit>{
        let actual=match(custody as HostLiveInitialPreparedCustody332){case Some(value)=>value
            case None=>return hostPluginResourceError("plugin.live_initial_prepared_owner_changed","actual same original input custody required")}
        if(!refEq(actual.actual.parent,parent) || !refEq(actual.actual.host,host) ||
            actual.actual.namespace!=namespace || actual.actual.bareTool!=bareTool || actual.actual.generation!=generation){
            return hostPluginResourceError("plugin.live_initial_prepared_owner_changed","actual installed Host and retained parent input changed")}
        match(actual.actual.full(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        actual.settlePreparedInput336(context,child,decision,control)
    }
    public func continuePreparedInput(context:ToolInvocationContext,parent:PreparedToolInvocation,
        witness:OwnedPreparedWaitingFieldsWitness,control:OwnedToolExecutionControl,
        custody:OwnedKernelPreparedReferenceCustody):Result<OwnedPreparedPhaseProgress>{
        let actual=match(custody as HostLiveInitialPreparedCustody332){case Some(value)=>value
            case None=>return hostPluginResourceError("plugin.live_initial_prepared_owner_changed","same actual original Host input custody is required")}
        if(!refEq(actual.actual.parent,parent) || !refEq(actual.actual.host,host) ||
            actual.actual.namespace!=namespace || actual.actual.bareTool!=bareTool || actual.actual.generation!=generation){
            return hostPluginResourceError("plugin.live_initial_prepared_owner_changed","actual installed Host and retained parent input changed")}
        actual.continueSettledInput336(context,witness,control)
    }
    public func acquireHandoffLease(context:ToolInvocationContext,prepared:PreparedToolInvocation):Result<ToolExecutionHandoffLease>{
        legacy.acquireHandoffLease(context,prepared)}
    public func execute(context:ToolInvocationContext,prepared:PreparedToolInvocation):Result<ToolResult>{legacy.execute(context,prepared)}
    public func executeObserved(context:ToolInvocationContext,prepared:PreparedToolInvocation):ToolExecutionOutcome{legacy.executeObserved(context,prepared)}
    public func cancel(runId:RunId):Result<Unit>{legacy.cancel(runId)}
    public func afterResultPersisted(context:ToolInvocationContext,result:ToolResult):Result<Unit>{legacy.afterResultPersisted(context,result)}
    public func afterOwnedResultPersisted(context:ToolInvocationContext,held:OwnedCanonicalThreadItemAliasCustody):Result<Unit>{
        legacy.afterOwnedResultPersisted(context,held)}
    public func executeOwned(context:ToolInvocationContext,parent:PreparedToolInvocation,
        control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        let _=context;let _=parent;let _=control
        hostPluginResourceError("plugin.live_prepared_phase_required","this trusted executor requires the original typed Kernel phase path")}
    public func rejectOwned(context:ToolInvocationContext,parent:PreparedToolInvocation,
        decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        let _=context;let _=parent;let _=decision;let _=control
        hostPluginResourceError("plugin.live_prepared_phase_required","this trusted executor requires the original typed Kernel phase path")}
    public func resumeOwned(context:ToolInvocationContext,pending:OwnedToolExecutionContinuation,
        decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        let _=context;let _=pending;let _=decision;let _=control
        hostPluginResourceError("plugin.live_prepared_phase_required","old immutable pending Source cannot enter this paid mutable phase")}
}

// Exact old data remains here under an independent child of its actual
// original metadata reservation. Clearing physical fields is NOT retirement
// of this copied/borrowed data or any external Prepared/Source/caller alias.
class HostLiveCapturedMetadataPin336 {
    private let source:HostDocumentDataSession
    private let backing:LogicalJsonOwnerReservation
    private let metadata:AgentValue
    private let previous:AgentValue
    private let next:AgentValue
    private let paidPeak:Int64
    private let lock=Mutex()
    private var successorBacking:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
    private var successor:?HostDocumentDataSession=None<HostDocumentDataSession>
    init(source:HostDocumentDataSession,backing:LogicalJsonOwnerReservation,
        metadata:AgentValue,previous:AgentValue,next:AgentValue,paidPeak:Int64){
        this.source=source;this.backing=backing;this.metadata=metadata;this.previous=previous;this.next=next
        this.paidPeak=paidPeak
    }
    func matches(source:HostDocumentDataSession):Bool{refEq(this.source,source)}
    func prepaySuccessor336():Result<LogicalJsonOwnerReservation>{
        lock.lock();try{
            if(successorBacking.isSome() || successor.isSome()){
                return hostPluginResourceError("plugin.live_successor_already_constructed","actual old allocation may construct one physical successor")}
            let loan=backing.deriveRetainedLease()
            // Publish the loan before a later payment/constructor/callback can
            // fail. It is data debt, never a fallback independent acquisition.
            successorBacking=Some(loan)
            match(ownedHostJsonOccurrenceInvoice336(loan,metadata,previous,next)){
                case Result.Err(error)=>return Result<LogicalJsonOwnerReservation>.Err(error);case Result.Ok(_)=>()}
            loan.ensureRetainedPeak(2097152)
            Result<LogicalJsonOwnerReservation>.Ok(loan)
        }catch(_:Exception){hostPluginResourceError("plugin.live_successor_unpaid","same old bank retains its actual successor construction debt")}
        finally{lock.unlock()}
    }
    func adoptSuccessor336(value:HostDocumentDataSession):Result<Unit>{
        lock.lock();try{
            if(successorBacking.isNone() || successor.isSome()){
                return hostPluginResourceError("plugin.live_successor_owner_changed","one real prepaid successor must be retained before collector callback")}
            successor=Some(value);Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    func retainsCompleteData336():Bool{
        try{backing.ensureRetainedPeak(paidPeak);true}catch(_:Exception){false}}
    func closeData336():Result<Unit>{hostPluginResourceError("plugin.live_successor_external_data_pending",
        "full old metadata, both ledgers and all escaped data remain permanently paid")}
}

// The real resume callback uses this holder instead of retaining a second
// private immutable child/decision/approval object. Allocation and complete
// typed data walking occurred before this constructor was called.
private class HostLivePreparedInputAction336 {
    private let data:OwnedHostPreparedActionData336
    private let lock=Mutex()
    private var ledger:?AgentValue=None<AgentValue>
    private var settled=false
    private var transferred=false
    init(data:OwnedHostPreparedActionData336){this.data=data}
    func execute(context:ToolInvocationContext,custody:HostLiveInitialPreparedCustody332,
        control:OwnedToolExecutionControl):Result<Unit>{
        data.consumeInput336({child,decision,_=>
            let rejected=match(decision){case ApprovalDecision.Reject | ApprovalDecision.RejectWithReason(_)=>true
                case ApprovalDecision.Approve | ApprovalDecision.ApproveSession=>false}
            // Exact original Root18 includes full actual Source/current/User
            // receipt validation. True children keep their actual retained
            // output through Root18 and checked physical ACK, unchanged.
            let next=match(hostSettleLiveParentChild332(context,custody,child,control,rejected)){
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
            // The original Root18 already funded constructing this ledger.
            // Prepay this additional Host field occurrence through the SAME
            // complete typed strings/nodes/slots walk before publishing it.
            match(data.retainLedgerOccurrence336(next)){
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            lock.lock();try{ledger=Some(next);settled=true;Result<Unit>.Ok(())}finally{lock.unlock()}
        })
    }
    func transfer(context:ToolInvocationContext,custody:HostLiveInitialPreparedCustody332):Result<Unit>{
        lock.lock();try{
            if(!settled || transferred || !data.inputFieldsCleared336() || ledger.isNone()){
                return hostPluginResourceError("plugin.live_input_fields_live","actual child/approval callback frame must end before private ledger transfer")}
            match(custody.retainSettledInput(ledger.getOrThrow())){
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            ledger=None<AgentValue>;transferred=true;Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    func fieldsCleared336():Bool{lock.lock();try{
        settled && transferred && ledger.isNone() && data.inputFieldsCleared336()
    }finally{lock.unlock()}}
}

// Real new one-shot Session is already prepaid on the actual old bank and
// adopted by the original ContextRead collector before this function runs.
// Its IO body remains the original312 algorithm, full Source and fixed FD
// history, all eight error fields, original Known-child and original Receipt.
private func hostRunLiveParentPaidSuccessor336(context:ToolInvocationContext,
    custody:HostLiveParentCustody312,nextLedger:AgentValue,pin:HostLiveCapturedMetadataPin336):Result<Unit>{
    let actual=custody.step.getOrThrow()
    let through=hostLivePolicyRPCInteger(nextLedger,"through_sequence")
    let session=match(actual.createPaidDataSuccessorSession336(pin)){
        case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
    let run:()->Result<HostLivePolicySessionCustody>={=>
        hostRunPluginLivePolicyNativeSuccessorStep336(session,custody.host,custody.configuration,custody.generation,
            context,custody.parent,through,nextLedger,custody.nowMillis,custody.bareTool,
            {=>custody.local(context)},{=>custody.full(context)},
            {_,_=>hostPluginResourceError<Unit>("plugin.live_history_owner_required","actual full known stream requires its paid running owner")},
            uploadKnownOwned:Some({newSession,rpc,owner,peak=>
                for(sequence in 1..(through+1)){
                    match(hostUploadLivePolicyKnownSequence290(newSession,rpc,context,custody.parent,sequence,through,nextLedger,
                        owner,peak,{=>custody.local(context)})){
                        case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}}
                Result<Unit>.Ok(())}),
            retirePrevious291:Some({=>
                // The global waitingAliases gate stays TRUE. This distinct
                // route does not call old291/final release and does not assert
                // that external Prepared, Host or caller data retired.
                if(!pin.retainsCompleteData336()){
                    return hostPluginResourceError<Unit>("plugin.live_successor_data_unpaid","complete old data pin is required")}
                custody.metadata.close();custody.ledger=None<AgentValue>
                actual.retireCapturedPhysicalForPaidSuccessor336(pin)}))}
    let next=match(run()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
    match(actual.adoptMetadataSuccessor291(next)){
        case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
    custody.metadata.closed=false;custody.ledger=Some(nextLedger)
    actual.capturePaidMetadata({value=>custody.metadata.capture(value,custody.parent,nextLedger)})
}

private func hostSelectLivePreparedChild336(context:ToolInvocationContext,custody:HostLiveInitialPreparedCustody332,
    control:OwnedToolExecutionControl):Result<HostLivePreparedSelection332>{
    let actual=custody.actual;let call=hostLiveParentChildCall312(actual)
    let sequence=hostLivePolicyRPCInteger(actual.ledger.getOrThrow(),"through_sequence")+1
    let prepared=match(control.prepareChild(context,call,"live-policy:"+actual.parent.call.callId+":"+sequence.toString())){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(prepared){
        case ToolPreparation.Ready(child)=>match(hostSettleLiveParentChild332(context,custody,child,control,false)){
            case Result.Err(error)=>Result.Err(error);case Result.Ok(value)=>Result.Ok(HostLivePreparedSelection332.Known(value))}
        case ToolPreparation.NeedsApproval(child,_)=>
            match(custody.markWaiting336()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(control.awaitPreparedPhase(child,custody)){
                case Result.Err(error)=>Result.Err(error);case Result.Ok(value)=>Result.Ok(HostLivePreparedSelection332.Waiting(value))}
        case ToolPreparation.Denied(denial)=>Result.Err(denial.reason)
        case ToolPreparation.Completed(_)=>hostPluginResourceError("plugin.live_prepare_result_unattested",
            "ordinary completed prepare value supplies no real independently executed Known child")}
}
// Kept in the actual registered parent custody. Failed control capture never
// closes an output that is still referenced by this private paid holder.
private class HostLivePreparedFinalCapture94 {
    var output:?HostAcknowledgedLivePolicyFinalOutput294=None<HostAcknowledgedLivePolicyFinalOutput294>
    init(){}
}
private func hostDriveLivePreparedParent336(context:ToolInvocationContext,custody:HostLiveInitialPreparedCustody332,
    control:OwnedToolExecutionControl):Result<OwnedPreparedPhaseProgress>{
    while(true){
        let actual=custody.actual
        match(actual.full(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(httpIntentText(actual.metadata.metadata.getOrThrow(),"kind")=="completed"){
            return match(custody.completePaidParent94(context,control)){
                case Result.Err(error)=>Result<OwnedPreparedPhaseProgress>.Err(error)
                case Result.Ok(value)=>Result.Ok(OwnedPreparedPhaseProgress.Legacy(value))}}
        let selected=match(hostSelectLivePreparedChild336(context,custody,control)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(selected){
            case HostLivePreparedSelection332.Known(ledger)=>
                match(custody.advanceReadyLedger336(context,ledger)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            case HostLivePreparedSelection332.Waiting(value)=>return Result.Ok(OwnedPreparedPhaseProgress.Waiting(value))}
    }
    hostPluginResourceError("plugin.live_driver_closed","actual finite driver stopped")
}
