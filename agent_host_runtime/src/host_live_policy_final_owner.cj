package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// Actual Host-private construction below captures ONE finished Session and
// its actual allocation lease. Native output/ACK/DTO cannot implement this
// owner. No operation-ID registry or decoded resource recovery is introduced.
class HostLivePolicyTerminalDataOwner <: OperationTerminalDataOwner {
    private let session:HostDocumentDataSession
    private let lease:ToolResultPayloadLease
    private let ownership=Mutex()
    private var borrowed=false
    private var descriptor:?AgentValue
    private var localCurrent:?(() -> Result<Unit>)
    private var fullCurrent:?(() -> Result<Unit>)
    init(session:HostDocumentDataSession,lease:ToolResultPayloadLease,descriptor:AgentValue,
        localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>){
        this.session=session;this.lease=lease;this.descriptor=Some(descriptor)
        this.localCurrent=Some(localCurrent);this.fullCurrent=Some(fullCurrent)
    }
    public func withRetainedOutput(actual:ToolResultPayloadLease,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        match(beginRetainedOutputFrame159(actual)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        try{withRetainedOutputFrame159(actual,consume)}
        finally{ownership.lock();try{borrowed=false}finally{ownership.unlock()}}
    }
    private func beginRetainedOutputFrame159(actual:ToolResultPayloadLease):Result<Unit>{
        ownership.lock();try{
            if(!refEq(actual,lease)){return hostPluginResourceError("plugin.live_terminal_lease_changed","another allocation lease cannot borrow this output")}
            if(borrowed || descriptor.isNone() || localCurrent.isNone() || fullCurrent.isNone()){
                return hostPluginResourceError("plugin.live_terminal_output_borrowed","same actual output is consumed or already borrowed")}
            borrowed=true;Result<Unit>.Ok(())
        }finally{ownership.unlock()}
    }
    private func withRetainedOutputFrame159(actual:ToolResultPayloadLease,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        // Admission holds borrowed=true until this ENTIRE frame returns.
        // Therefore close cannot clear these exact descriptor/guard aliases.
        let frozen=descriptor.getOrThrow()
        let local=localCurrent.getOrThrow();let full=fullCurrent.getOrThrow()
        try{
            match(full()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(local()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(session.withLivePolicyTerminalOutput(actual,frozen,local,consume)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(local()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            full()
        }finally{}
    }
    public func closeRetainedOutput(actual:ToolResultPayloadLease):Result<Unit>{
        ownership.lock();try{
            if(!refEq(actual,lease)){
                return hostPluginResourceError("plugin.live_terminal_lease_changed","another allocation lease cannot close this actual output")}
            if(borrowed){return hostPluginResourceError("plugin.live_terminal_output_borrowed","actual terminal output borrower must finish before cleanup")}
            // Remove this descriptor handle before the same Session refunds.
            // The real consumer must likewise drop its large ToolResult handle.
            descriptor=None<AgentValue>;localCurrent=None<(() -> Result<Unit>)>;fullCurrent=None<(() -> Result<Unit>)>
        }finally{ownership.unlock()}
        // No Source/current check may obstruct disposal. Err leaves this same
        // owner/lease/Session available; a true completed ACK is idempotent.
        session.closeRetainedLivePolicyOutput292(actual)
    }

}
class HostLivePolicyTerminalUnit250 {var value:Result<Unit>=Result.Ok(());init(){}}
class HostLivePolicyFinalOutput {
    let result:ToolResult
    let owner:HostLivePolicyTerminalDataOwner
    init(result:ToolResult,owner:HostLivePolicyTerminalDataOwner){this.result=result;this.owner=owner}
}

// Produce must return the actually adopted final writer AFTER its Native loan
// has been released/physically collected. Its complete bytes are decoded into
// the original shared pool before publication. The data-only terminal audit
// cannot finalize a Parent Receipt or canonical item; Core remains sole owner.
func hostMaterializeLivePolicyParentOutput(session:HostDocumentDataSession,context:ToolInvocationContext,
    parent:PreparedToolInvocation,descriptor:AgentValue,produce:(HostDocumentDataSession)->Result<HostServiceArtifactWriter>,
    localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>):Result<HostLivePolicyFinalOutput>{
    if(!pluginLivePolicyTerminalDataValid(descriptor,parent.operationId.value,parent.operationPlan.bindingDigest)){
        return hostPluginResourceError("plugin.live_terminal_descriptor_changed","final output requires its exact bounded parent descriptor")}
    match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let physical=match(session.retainExecutionCustody()){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    var decoded=session.run({actual=>
        match(localCurrent()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        let writer=match(produce(actual)){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
        // New tool-only decoder preserves the old context four-MiB body.
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
        match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let lease=match(session.captureLivePolicyOutputLease()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
        let result=ToolResult(parent.call.callId,value,isError:descriptor.field("is_error").getOrThrow().asBool(),
            receiptId:parent.operationId.value,payloadLease:Some(lease))
        let owner=HostLivePolicyTerminalDataOwner(session,lease,descriptor,localCurrent,fullCurrent)
        transferred=true;Result.Ok(HostLivePolicyFinalOutput(result,owner))
    }finally{
        decoded=hostPluginResourceError<AgentValue>("plugin.live_terminal_transferred","local output reference was transferred or discarded")
        if(!transferred){session.acknowledgeOutput();let _=physical.close()}
    }
}
