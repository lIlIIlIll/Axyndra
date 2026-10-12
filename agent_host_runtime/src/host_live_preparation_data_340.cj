package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_ports.*
import tool_runtime.*
import std.sync.*

// Private data routing to the SAME original collector Session. All held
// Root/call fields are copied references only AFTER the full typed invoice.
// Root identity here is never Source or execution authority.
class HostLivePreparationData340 {
    let session:HostDocumentDataSession
    let physical:HostLiveExecutionCustody
    private let root:?OperationRootSource
    private let arguments:AgentValue
    private let callId:String
    private let tool:String
    private let run:RunId
    private let thread:SessionId
    private let epoch:Int64
    var previous:?HostLivePreparationData340
    init(session:HostDocumentDataSession,physical:HostLiveExecutionCustody,root:?OperationRootSource,
        context:ToolInvocationContext,call:ToolCall,previous:?HostLivePreparationData340){
        this.session=session;this.physical=physical;this.root=root;arguments=call.arguments
        callId=call.callId;tool=call.name;run=context.runId;thread=context.sessionId;epoch=context.epoch
        this.previous=previous
    }
    func matches(context:ToolInvocationContext,actualRoot:?OperationRootSource,call:ToolCall):Bool{
        if(context.trustedControl || run.value!=context.runId.value || thread.value!=context.sessionId.value ||
            epoch!=context.epoch || callId!=call.callId || tool!=call.name){return false}
        match((root,actualRoot)){
            case (Some(OperationRootSource.Committed(left)),Some(OperationRootSource.Committed(right)))=>refEq(left,right)
            case (Some(OperationRootSource.Direct(left)),Some(OperationRootSource.Direct(right)))=>refEq(left,right)
            case (None,_)=>refEq(arguments,call.arguments)
            case (_,None)=>refEq(arguments,call.arguments)
            case _=>false
        }
    }
    func pay(context:ToolInvocationContext,root:?OperationRootSource,call:ToolCall,facts:Array<ContextReadFactLink>):Result<Unit>{
        let loan=match(session.retainLivePolicyPreparationBacking340(physical)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(ownedPreparationInputInvoice340(loan,context,root,call,facts)){
            case Result.Err(error)=>Result<Unit>.Err(error);case Result.Ok(_)=>Result<Unit>.Ok(())}
    }
}
