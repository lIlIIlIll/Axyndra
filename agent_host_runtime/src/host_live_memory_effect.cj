package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

private class HostLiveMemoryEffectDataOwner308 <: AcknowledgedOperationTerminalDataOwner {
    private let lock=Mutex()
    private var session:?HostDocumentDataSession=None<HostDocumentDataSession>
    private var actual:?HostAcknowledgedLivePolicyTerminalDataOwner294=None<HostAcknowledgedLivePolicyTerminalDataOwner294>
    private var lease:?ToolResultPayloadLease=None<ToolResultPayloadLease>
    private var closed=false
    init(){}
    func adopt(value:HostDocumentDataSession):Unit{
        lock.lock();try{if(closed || session.isSome()){throw IllegalStateException("actual effect Session cannot be adopted twice")};session=Some(value)}finally{lock.unlock()}}
    func publish(value:HostAcknowledgedLivePolicyTerminalDataOwner294,lease:ToolResultPayloadLease):Unit{
        lock.lock();try{if(closed || session.isNone() || actual.isSome()){throw IllegalStateException("actual effect data owner cannot publish twice")}
            actual=Some(value);this.lease=Some(lease)}finally{lock.unlock()}}
    func actualLease():?ToolResultPayloadLease{lock.lock();try{lease}finally{lock.unlock()}}
    public func withRetainedOutput(lease:ToolResultPayloadLease,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        lock.lock();let selected=try{actual}finally{lock.unlock()}
        match(selected){case Some(value)=>value.withRetainedOutput(lease,consume)
            case None=>hostPluginResourceError("plugin.live_effect_output_unpublished","actual effect has no published output")}
    }
    public func retainCanonicalBacking(lease:ToolResultPayloadLease):Result<LogicalJsonOwnerReservation>{
        lock.lock();let selected=try{actual}finally{lock.unlock()}
        match(selected){case Some(value)=>value.retainCanonicalBacking(lease)
            case None=>hostPluginResourceError("plugin.live_effect_output_unpublished","actual effect has no paid output backing")}
    }
    public func closeRetainedOutput(lease:ToolResultPayloadLease):Result<Unit>{
        lock.lock();let selected=try{actual}finally{lock.unlock()}
        match(selected){case Some(value)=>value.closeRetainedOutput(lease)
            case None=>hostPluginResourceError("plugin.live_effect_output_unpublished","actual effect never captured this output lease")}
    }
    public func closeUnpublishedOutput():Result<Unit>{
        lock.lock()
        let selected=try{
            if(closed){return Result<Unit>.Ok(())}
            if(actual.isSome() || lease.isSome()){
                return hostPluginResourceError<Unit>("plugin.live_effect_output_ack_required","published effect output needs its exact actual lease acknowledgement")}
            session
        }finally{lock.unlock()}
        // All factory result/metadata handles have ended before this Kernel
        // cleanup-only call. A failed close preserves SAME Session and debt.
        match(selected){case Some(value)=>
            value.acknowledgeOutput()
            match(value.closeExecutionDataOwner()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            case None=>()}
        lock.lock();try{session=None<HostDocumentDataSession>;closed=true;Result.Ok(())}finally{lock.unlock()}
    }
}
private class HostLiveMemoryEffectDecoded308 {
    var value:Result<AgentValue>=hostPluginResourceError("plugin.live_effect_output_unpublished","actual effect output is not published")
    var tip:?AgentValue=None<AgentValue>
    init(){}
}

// Real typed executor: the Kernel gives the actual independently prepared,
// approved and handed-off parent/child/custody. Native emits only proposal
// data. Original retrieval, proposal and reducer algorithms remain Native.
public class HostLiveMemoryJournalEffectExecutor308 <: ToolExecutor & OwnedToolEffectExecutor & RetainedOwnedToolEffectExecutor {
    private let host:HostJavaScriptPluginHost
    private let operations:OperationRuntimePort
    public init(host:HostJavaScriptPluginHost,operations:OperationRuntimePort){this.host=host;this.operations=operations}
    public func execute(context:ToolInvocationContext,child:PreparedToolInvocation):Result<ToolResult>{
        hostPluginResourceError("plugin.live_effect_owned_entry_required","actual live effect requires its retained Kernel parent and custody")}
    public func executeLiveEffect(context:ToolInvocationContext,child:PreparedToolInvocation):ToolExecutionOutcome{
        ToolExecutionOutcome(hostPluginResourceError("plugin.live_effect_retained_entry_required","actual live effect requires the typed resource owner return"))}
    public func executeRetainedEffect(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,custody:LiveToolExecutionCustody):OwnedRetainedToolEffectOutcome{
        let frame=hostRetainLiveInvocationContext159(context)
        try{executeRetainedEffectFrame159(hostLiveInvocationContext159(frame,context),parent,child,custody,frame)}
        finally{hostLiveInvocationProducerReturned159(frame)}
    }

    private func executeRetainedEffectFrame159(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,custody:LiveToolExecutionCustody,contextOwner159:?HostLiveInvocationContext159):OwnedRetainedToolEffectOutcome{
        let owner=HostLiveMemoryEffectDataOwner308();let selected=HostLiveMemoryEffectDecoded308()
        let execute:()->Result<ToolResult>={=>
            if(context.trustedControl || parent.source.operationRoot.isNone() ||
                child.source.kind!=PreparedInvocationSourceKind.Derived || child.source.parentOperationId.isNone() ||
                child.source.parentOperationId.getOrThrow().value!=parent.operationId.value ||
                parent.source.runId.value!=context.runId.value || child.source.runId.value!=context.runId.value ||
                parent.source.sessionId.value!=context.sessionId.value || child.source.sessionId.value!=context.sessionId.value ||
                parent.source.epoch!=context.epoch || child.source.epoch!=context.epoch ||
                !pluginLivePolicyStreamingChildWithinCeiling(parent.operationPlan,child.operationPlan) ||
                httpIntentText(child.operationPlan.canonicalArguments.field("effect").getOrThrow(),"kind")!="row_journal.append"){
                return hostPluginResourceError<ToolResult>("plugin.live_effect_actual_scope_changed","actual live journal parent/child scope is required")}
            // Existing custody must finish the real preceding worker/FD/writer
            // handoff. A DTO or isError value cannot replace this exact object.
            match(custody.releaseTransient()){case Result.Err(error)=>return Result<ToolResult>.Err(error);case Result.Ok(_)=>()}
            let binding=child.operationPlan.canonicalArguments.field("binding").getOrThrow()
            let namespace=httpIntentText(binding,"namespace");let digest=httpIntentText(binding,"package_digest")
            let generation=UInt64.parse(httpIntentText(binding,"generation"))
            let configuration=match(host.livePolicyConfiguration(namespace,digest,httpIntentText(binding,"contribution"))){
                case Result.Err(error)=>return Result<ToolResult>.Err(error);case Result.Ok(Some(value))=>value
                case Result.Ok(None)=>return hostPluginResourceError<ToolResult>("plugin.live_effect_disabled","actual operator did not select this live effect family")}
            if(configuration.read.digest!=httpIntentText(binding,"configuration_digest")){
                return hostPluginResourceError<ToolResult>("plugin.live_effect_config_changed","actual child changed its frozen operator read configuration")}
            match(configuration.validateCurrent()){case Result.Err(error)=>return Result<ToolResult>.Err(error);case Result.Ok(_)=>()}
            let revoked=AtomicBool(false)
            let registration=match(host.observeServiceRevocation(namespace,generation,{=>revoked.store(true)})){
                case Result.Err(error)=>return Result<ToolResult>.Err(error);case Result.Ok(value)=>value}
            try{
                let current:()->Result<Unit>={=>
                    if(revoked.load() || context.cancellation.isCancelled() ||
                        (context.budget.deadlineMillis>0 && agentUtcMillis()>=context.budget.deadlineMillis) ||
                        !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:namespace)){
                        return hostPluginResourceError<Unit>("plugin.live_effect_cancelled","actual effect was cancelled, expired or revoked")}
                    configuration.validateTransferWitness()}
                match(current()){case Result.Err(error)=>return Result<ToolResult>.Err(error);case Result.Ok(_)=>()}
                let session=match(host.documentDataSession()){
                    case Result.Err(error)=>return Result<ToolResult>.Err(error);case Result.Ok(value)=>value}
                owner.adopt(session)
                match(session.retainExecutionCustody()){case Result.Err(error)=>return Result<ToolResult>.Err(error);case Result.Ok(_)=>()}
                selected.value=session.run({actual=>
                    match(actual.executeLivePolicyJournalEffect307(context,parent,child,operations,current,{tip=>
                        actual.withLivePolicyRunningMetadata(tip,{_,_=>
                            selected.tip=Some(parseUnifiedJson(encodeAgentValue(tip),maxBytes:16384,maxDepth:32))})
                    })){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
                    let tip=match(selected.tip){case Some(value)=>value
                        case None=>return hostPluginResourceError<AgentValue>("plugin.live_effect_tip_missing","actual committed Store tip is absent")}
                    let output=objectValue([ValueField("schema",textValue("axyndra.plugin-live-effect-result/v1")),ValueField("receipt",tip)])
                    let writer=match(actual.newWriter()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
                    let encoded=encodeAgentValue(output);let raw=encoded.toArray()
                    if(raw.size>16384){return hostPluginResourceError<AgentValue>("plugin.live_effect_tip_changed","actual data-only child tip exceeds its original bound")}
                    match(writer.appendBytes(0,raw,16384)){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
                    match(writer.finish(raw.size,modelPolicySha256(raw))){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
                    actual.readPrivateLiveToolValue(writer,current)
                })
                selected.tip=None<AgentValue>
                let value=match(selected.value){case Result.Err(error)=>return Result<ToolResult>.Err(error);case Result.Ok(value)=>value}
                match(session.releaseLivePolicyOutputTransient292()){case Result.Err(error)=>return Result<ToolResult>.Err(error);case Result.Ok(_)=>()}
                match(current()){case Result.Err(error)=>return Result<ToolResult>.Err(error);case Result.Ok(_)=>()}
                let lease=match(session.captureAcknowledgedLivePolicyOutputLease292()){
                    case Result.Err(error)=>return Result<ToolResult>.Err(error);case Result.Ok(value)=>value}
                let actual=HostAcknowledgedLivePolicyTerminalDataOwner294(session,lease,value,current,current,contextOwner159:contextOwner159)
                owner.publish(actual,lease)
                Result<ToolResult>.Ok(ToolResult(child.call.callId,value,isError:false,receiptId:child.operationId.value,payloadLease:Some(lease)))
            }finally{registration.dispose()}
        }
        let result:Result<ToolResult>=try{execute()}
            catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
            catch(_:Exception){hostPluginResourceError("plugin.live_effect_execution_closed","actual live journal effect could not complete its checked return")}
        // No big decoder or metadata alias remains in the factory before its
        // cleanup-only owner is returned to the original Kernel debt route.
        selected.value=hostPluginResourceError("plugin.live_effect_output_transferred","local actual output was transferred or discarded")
        selected.tip=None<AgentValue>
        OwnedRetainedToolEffectOutcome(ToolExecutionOutcome(result),owner,cleanupLease:owner.actualLease())
    }
}
