package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

private class HostLivePolicySelectedFinal263 {
    var descriptor:?AgentValue=None<AgentValue>
    init(){}
}

// The descriptor is selected only by the actual same-Session producer after
// copying a current SQL/GC-pinned fixed file. No decoded value constructs a
// resource owner. This is the original final factory's physical lifecycle;
// Core still owns canonical Parent Receipt, result item, hooks and output ACK.
func hostMaterializeSelectedLivePolicyParentOutput(session:HostDocumentDataSession,context:ToolInvocationContext,
    parent:PreparedToolInvocation,produce:(HostDocumentDataSession,(AgentValue)->Unit)->Result<HostServiceArtifactWriter>,
    localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>):Result<HostLivePolicyFinalOutput>{
    match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let physical=match(session.retainExecutionCustody()){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let selected=HostLivePolicySelectedFinal263()
    var decoded=session.run({actual=>
        match(localCurrent()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        let writer=match(produce(actual,{descriptor=>
            if(selected.descriptor.isSome() ||
                !pluginLivePolicyTerminalDataValid(descriptor,parent.operationId.value,parent.operationPlan.bindingDigest)){
                throw IllegalStateException("same actual final producer selected a foreign or repeated descriptor")}
            // The producer must call this from the actual short running
            // metadata borrower, whose payment remains held by this Session.
            selected.descriptor=Some(descriptor)})){
            case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
        let descriptor=match(selected.descriptor){case Some(value)=>value
            case None=>return hostPluginResourceError<AgentValue>("plugin.live_terminal_descriptor_missing","actual final producer did not freeze its bounded descriptor")}
        let output=match(actual.readPrivateLiveToolValue(writer,localCurrent)){
            case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
        match(actual.retainLivePolicyParentOutput(context,parent,descriptor,writer,localCurrent)){
            case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        match(localCurrent()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        Result<AgentValue>.Ok(output)})
    var transferred=false
    try{
        match(physical.releaseTransient()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let value=match(decoded){case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
        let descriptor=match(selected.descriptor){case Some(actual)=>actual
            case None=>return hostPluginResourceError("plugin.live_terminal_descriptor_missing","actual descriptor vanished before same-owner transfer")}
        match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let lease=match(session.captureLivePolicyOutputLease()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
        let result=ToolResult(parent.call.callId,value,isError:descriptor.field("is_error").getOrThrow().asBool(),
            receiptId:parent.operationId.value,payloadLease:Some(lease))
        let owner=HostLivePolicyTerminalDataOwner(session,lease,descriptor,localCurrent,fullCurrent)
        transferred=true;Result<HostLivePolicyFinalOutput>.Ok(HostLivePolicyFinalOutput(result,owner))
    }finally{
        decoded=hostPluginResourceError<AgentValue>("plugin.live_terminal_transferred","local output reference was transferred or discarded")
        selected.descriptor=None<AgentValue>
        if(!transferred){session.acknowledgeOutput();let _=physical.close()}
    }
}
