package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.io.*
import std.sync.*
import stdx.crypto.digest.*
import yjson.*
import yjson_support.*

// This is the original generic User approval error, not a Memory result or
// Native completion. Actual rejected Parent Source is independently checked
// by Root's dedicated no-handoff retain/verify helpers and the typed Pipeline.
func hostLivePolicyParentUserRejection(call:ToolCall,decision:ApprovalDecision):AgentError{
    let reason=match(decision){case ApprovalDecision.Reject=>"";case ApprovalDecision.RejectWithReason(value)=>value
        case _=>throw IllegalArgumentException("only an actual rejected User decision can produce a rejected Parent error")}
    let fields:Array<ErrorField>=if(reason.trimAscii()==""){[ErrorField("tool",call.name)]}
        else{[ErrorField("tool",call.name),ErrorField("reason",reason)]}
    AgentError(AgentErrorKind.PermissionDenied,"tool.approval_rejected",
        if(reason.trimAscii()==""){"user rejected the pending tool operation"}
        else{"user rejected the pending tool operation: "+reason},fields:fields)
}

private class HostLivePolicyOriginalOutputWriter263 <: OutputStream{
    private let writer:HostServiceArtifactWriter
    private let guard:()->Result<Unit>
    private let hash=SHA256()
    private var bytes:Int64=0
    private var finished=false
    init(writer:HostServiceArtifactWriter,guard:()->Result<Unit>){this.writer=writer;this.guard=guard}
    public func write(raw:Array<Byte>):Unit{
        if(finished || raw.size>8388608-bytes){throw IllegalStateException("original complete Tool JSON exceeded its eight-MiB bound")}
        var offset:Int64=0
        while(offset<raw.size){
            match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
            let end=min(raw.size,offset+16384);let part=raw[offset..end]
            match(writer.appendBytes(bytes,part,8388608)){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
            hash.write(part);bytes+=part.size;offset=end
        }
    }
    public func flush():Unit{match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}}
    func finish():Unit{
        if(finished){throw IllegalStateException("same original output writer cannot finish twice")}
        flush();finished=true
        match(writer.finish(bytes,hostArtifactHex(hash.finish()))){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
    }
}

// The phase ends, including its complete original error/output DOM references,
// before the real single-use output decoder allocates its final reservation.
// No whole JSON String is made: this is the original pinned writeJson codec.
func hostWriteLivePolicyRejectedParent(actual:HostDocumentDataSession,parent:PreparedToolInvocation,
    decision:ApprovalDecision,ledger:AgentValue,guard:()->Result<Unit>,select:(AgentValue)->Unit):Result<HostServiceArtifactWriter>{
    let reason=match(decision){case ApprovalDecision.Reject=>"";case ApprovalDecision.RejectWithReason(value)=>value
        case _=>return hostPluginResourceError("plugin.live_parent_rejection_changed","only the actual rejected decision can enter the no-handoff output writer")}
    let phase=reserveNativeRowJournalPayload(65536)
    try{
        // Account the actual message concatenation, original five-field
        // recoverable output/field cells, and original escaped writer buffers
        // BEFORE constructing those copies. This retains the original pool.
        if(reason.size>(Int64.Max-1048576-parent.call.name.size*4)/4){throw IllegalStateException("actual rejection extent overflow")}
        let initial=1048576+reason.size*4+parent.call.name.size*4+65536
        phase.ensureRetainedPeak(initial)
        let produce:()->Result<HostServiceArtifactWriter>={=>
            let error=hostLivePolicyParentUserRejection(parent.call,decision)
            let value=recoverableToolResult(parent.call,error,receiptId:parent.operationId.value).output
            let bytes=logicalJsonWriteReservationBytes(value,Int64.Max)
            if(bytes<1 || bytes>(Int64.Max-initial)/2){
                return hostPluginResourceError("plugin.live_parent_rejection_bound","original complete rejection JSON exceeds its original Tool codec")}
            phase.ensureRetainedPeak(initial+bytes*2+logicalJsonValueNodeCount(value)*512)
            let writer=match(actual.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let sink=HostLivePolicyOriginalOutputWriter263(writer,guard)
            value.writeJson(sink,options:JsonWriteOptions.defaults);sink.finish()
            let payload=parsePluginDocumentPayloadReference(hostLivePolicyActualPayload(writer.completedArtifact())).value().getOrThrow()
            let descriptor=hostLivePolicyFinalDescriptor(parent,ledger,payload,true)
            actual.withLivePolicyRunningMetadata(descriptor,{_,_=>select(descriptor)})
            Result<HostServiceArtifactWriter>.Ok(writer)}
        produce()
    }catch(error:HostArtifactOperationFailure){Result<HostServiceArtifactWriter>.Err(error.failure)}
    catch(_:LogicalJsonPayloadError){hostPluginResourceError("plugin.live_parent_rejection_capacity","actual original rejection exhausted the original shared pool")}
    catch(_:Exception){hostPluginResourceError("plugin.live_parent_rejection_codec","actual rejected output did not complete the original full JSON writer")}
    finally{phase.close()}
}

func hostRejectPluginLivePolicyParent(host:HostJavaScriptPluginHost,namespace:String,bareTool:String,
    generation:UInt64,context:ToolInvocationContext,parent:PreparedToolInvocation,decision:ApprovalDecision,
    control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
    if(!isPluginLivePolicyParentPlan(parent.operationPlan) || parent.approval.isNone() ||
        parent.call.name!="plugin."+namespace+"."+bareTool || parent.source.runId.value!=context.runId.value ||
        parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch){
        return hostPluginResourceError("plugin.live_rejected_parent_scope","actual same prepared Parent/approval and published Tool are required")}
    match(decision){case ApprovalDecision.Reject | ApprovalDecision.RejectWithReason(_)=>()
        case _=>return hostPluginResourceError("plugin.live_rejected_parent_decision","approved decisions cannot use the actual User no-handoff output")}
    let packageDescriptor=match(host.servicePackageData81(namespace,generation)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let configuration=match(host.livePolicyConfiguration(namespace,packageDescriptor.contentDigest,parent.call.name)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(Some(value))=>value
        case Result.Ok(None)=>return hostPluginResourceError("plugin.live_owned_disabled","operator did not select the actual owned family")}
    let binding=parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    if(httpIntentText(parent.operationPlan.canonicalArguments.field("configuration").getOrThrow(),"digest")!=configuration.digest){
        return hostPluginResourceError("plugin.live_owned_config_changed","actual rejected Parent changed its original frozen operator configuration")}
    let revoked=AtomicBool(false)
    let registration=match(host.observeServiceRevocation(namespace,generation,{=>revoked.store(true)})){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    try{
        let local:()->Result<Unit>={=>
            if(revoked.load() || context.cancellation.isCancelled() || !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:namespace)){
                return hostPluginResourceError("plugin.live_owned_cancelled","actual rejected Parent output was cancelled or revoked")}
            configuration.validateTransferWitness()}
        let full:()->Result<Unit>={=>
            match(local()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            hostLivePolicyInputCurrent(host,configuration,generation,context,parent.call,binding)}
        match(full()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let ledger=hostLivePolicyEmptyLedger(parent.operationId)
        let session=match(host.documentDataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let terminal=match(hostMaterializeSelectedLivePolicyParentOutput(session,context,parent,
            {actual,select=>hostWriteLivePolicyRejectedParent(actual,parent,decision,ledger,local,select)},local,full)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let accepted=control.completeParent(terminal.result,terminal.owner)
        if(accepted.isError()){match(terminal.result.payloadLease){case Some(lease)=>lease.close();case None=>()}}
        accepted
    }finally{registration.dispose()}
}
