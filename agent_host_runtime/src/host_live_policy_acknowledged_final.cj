package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// Separate opt-in marker. The old Host owner and both old factories retain
// their exact route. Only a real same-Session factory constructs this owner;
// no Native reply, equal descriptor or operation-ID lookup creates it.
class HostAcknowledgedLivePolicyTerminalDataOwner294 <: AcknowledgedOperationTerminalDataOwner {
    private let actual:HostLivePolicyTerminalDataOwner
    private let session:HostDocumentDataSession
    private var contextOwner159:?HostLiveInvocationContext159=None<HostLiveInvocationContext159>
    private let contextLock159=Mutex()
    init(session:HostDocumentDataSession,lease:ToolResultPayloadLease,descriptor:AgentValue,
        localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>,
        contextOwner159!:?HostLiveInvocationContext159=None<HostLiveInvocationContext159>){
        this.session=session
        actual=HostLivePolicyTerminalDataOwner(session,lease,descriptor,localCurrent,fullCurrent)
        this.contextOwner159=contextOwner159
        match(contextOwner159){case Some(value)=>value.transfer159();case None=>()}
    }
    public func withRetainedOutput(lease:ToolResultPayloadLease,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        actual.withRetainedOutput(lease,consume)
    }
    public func closeRetainedOutput(lease:ToolResultPayloadLease):Result<Unit>{
        let result=actual.closeRetainedOutput(lease)
        match(result){case Result.Err(_)=>return result;case Result.Ok(_)=>()}
        // Full original helper has returned: its borrow is zero, both guard
        // closures are None and actual Session cleanup succeeded.
        let returned=clearContextOwner159()
        match(returned){case Some(value)=>value.consumerReturned159();case None=>()}
        result
    }
    private func clearContextOwner159():?HostLiveInvocationContext159{
        contextLock159.lock();try{
            let returned=contextOwner159;contextOwner159=None<HostLiveInvocationContext159>;returned
        }finally{contextLock159.unlock()}
    }
    public func retainCanonicalBacking(lease:ToolResultPayloadLease):Result<LogicalJsonOwnerReservation>{
        session.retainLivePolicyCanonicalBacking301(lease)
    }
}

class HostAcknowledgedLivePolicyFinalOutput294 {
    let result:ToolResult
    let owner:HostAcknowledgedLivePolicyTerminalDataOwner294
    init(result:ToolResult,owner:HostAcknowledgedLivePolicyTerminalDataOwner294){this.result=result;this.owner=owner}
}
private class HostAcknowledgedLivePolicyDecoded36 {
    var value:Result<AgentValue>
    init(value:Result<AgentValue>){this.value=value}
}

private class HostAcknowledgedLivePolicySelected294 {
    var descriptor:?AgentValue=None<AgentValue>
    init(){}
}

// Complete final data uses original private StoredValue decoder and Root pin.
// Its actual typed owner travels with the terminal to the canonical consumer.
// This function neither creates a Parent Receipt nor treats lease.close as ACK.
func hostMaterializeAcknowledgedSelectedLivePolicyParentOutput294(session:HostDocumentDataSession,context:ToolInvocationContext,
    parent:PreparedToolInvocation,produce:(HostDocumentDataSession,(AgentValue)->Unit)->Result<HostServiceArtifactWriter>,
    localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>,
    contextOwner159!:?HostLiveInvocationContext159=None<HostLiveInvocationContext159>):Result<HostAcknowledgedLivePolicyFinalOutput294>{
    match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let physical=match(session.retainExecutionCustody()){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
    let selected=HostAcknowledgedLivePolicySelected294()
    let decoded=HostAcknowledgedLivePolicyDecoded36(session.run({actual=>
        match(localCurrent()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        let writer=match(produce(actual,{descriptor=>
            if(selected.descriptor.isSome() ||
                !pluginLivePolicyTerminalDataValid(descriptor,parent.operationId.value,parent.operationPlan.bindingDigest)){
                throw IllegalStateException("same actual final producer selected another or repeated descriptor")}
            selected.descriptor=Some(descriptor)})){
            case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
        let descriptor=match(selected.descriptor){case Some(value)=>value
            case None=>return hostPluginResourceError<AgentValue>("plugin.live_terminal_descriptor_missing","same final producer supplied no bounded descriptor")}
        let value=match(actual.readPrivateLiveToolValue(writer,localCurrent)){
            case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
        match(actual.retainLivePolicyParentOutput(context,parent,descriptor,writer,localCurrent)){
            case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        match(localCurrent()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        Result<AgentValue>.Ok(value)}))
    let capture:()->Result<HostAcknowledgedLivePolicyFinalOutput294>={=>
        match(session.releaseLivePolicyOutputTransient292()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let value=match(decoded.value){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let descriptor=match(selected.descriptor){case Some(value)=>value
            case None=>return hostPluginResourceError("plugin.live_terminal_descriptor_missing","actual final descriptor changed before transfer")}
        match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let lease=match(session.captureAcknowledgedLivePolicyOutputLease292()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let result=ToolResult(parent.call.callId,value,isError:descriptor.field("is_error").getOrThrow().asBool(),
            receiptId:parent.operationId.value,payloadLease:Some(lease))
        let owner=HostAcknowledgedLivePolicyTerminalDataOwner294(session,lease,descriptor,localCurrent,fullCurrent,contextOwner159:contextOwner159)
        Result<HostAcknowledgedLivePolicyFinalOutput294>.Ok(HostAcknowledgedLivePolicyFinalOutput294(result,owner))}
    var result:Result<HostAcknowledgedLivePolicyFinalOutput294>=try{capture()}
        catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("plugin.live_terminal_capture_failed",
            "same actual final output could not transfer its paid terminal owner")}
    // capture's lexical large-value references have ended. Only the successful
    // typed output keeps the decoded value; every failed transfer drops it
    // before same actual worker/FD/writer/result/custody cleanup and refund.
    decoded.value=hostPluginResourceError<AgentValue>("plugin.live_terminal_transferred","local decoded value was transferred or discarded")
    selected.descriptor=None<AgentValue>
    if(result.isError()){
        session.acknowledgeOutput()
        match(physical.close()){case Result.Err(error)=>result=Result<HostAcknowledgedLivePolicyFinalOutput294>.Err(error);case Result.Ok(_)=>()}
    }
    result
}
