package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*

// Native progress is data. Only the actual Host session implementation can
// produce these values after checking its current endpoint and physical RPC.
// A proposal still passes the normal Tool policy and the complete Store Source.
// Constructed only by the actual Host Session after its one retained
// decoder and fixed-file owner capture the precise terminal allocation.
// Native JSON and an ordinary Completed DTO cannot construct this carrier.
class HostManagedChannelOwnedTerminal {
    private var result:?ToolResult
    let dataOwner:AcknowledgedOperationTerminalDataOwner
    init(result:ToolResult,dataOwner:AcknowledgedOperationTerminalDataOwner){this.result=Some(result);this.dataOwner=dataOwner}
    // Consume this actual Host carrier exactly once. A failed Store capture
    // must drop this large reference before asking its actual owner to ACK.
    func takeResult():Result<ToolResult>{
        let actual=match(result){case Some(value)=>value
            case None=>return managedChannelDriverError("managed_channel.terminal_already_consumed")}
        result=None<ToolResult>;Result.Ok(actual)
    }
}

enum HostManagedChannelOwnedStep {
    Effect(AgentValue, Int64)
    | Complete(HostManagedChannelOwnedTerminal)
    | Unknown(AgentError)
}

// One invocation's physical custody. Implementations use the existing Host
// endpoint/collector and lifecycle inventory, never a plugin-selected registry.
// No method accepts a serialized Root, permission or replacement Session.
interface HostManagedChannelOwnedSession <: LiveToolExecutionCustody {
    func validate(context:ToolInvocationContext,parent:PreparedToolInvocation):Result<Unit>
    func currentBinding(context:ToolInvocationContext,parent:PreparedToolInvocation):Result<AgentValue>
    func next(context:ToolInvocationContext,parent:PreparedToolInvocation):Result<HostManagedChannelOwnedStep>
    func acceptChild(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,result:ToolResult):Result<Unit>
    // Only Kernel supplies the actual parent and this SAME invocation custody.
    // This method never looks up a Root or Session by a serialized identifier.
    func executeRetainedEffect(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation):OwnedRetainedToolEffectOutcome
    func rejectChild(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,decision:ApprovalDecision):Result<HostManagedChannelOwnedTerminal>
    func rejectParent(context:ToolInvocationContext,parent:PreparedToolInvocation,
        decision:ApprovalDecision):Result<HostManagedChannelOwnedTerminal>
    func preparationDenied(context:ToolInvocationContext,parent:PreparedToolInvocation):Result<HostManagedChannelOwnedTerminal>
}

interface HostManagedChannelOwnedEndpoint {
    func begin(context:ToolInvocationContext,parent:PreparedToolInvocation):Result<HostManagedChannelOwnedSession>
    func acquireHandoffLease(context:ToolInvocationContext,parent:PreparedToolInvocation):Result<ToolExecutionHandoffLease>
    func cancel(run:RunId):Result<Unit>
}

// Instantiated only by the actual configured Host catalog factory. The normal
// ToolExecutor entry refuses this family, including Approved inputs.
class HostManagedChannelOwnedDriver <: ToolExecutor & ManagedChannelOwnedExecutor & OwnedPersistedToolResultObserver {
    private let endpoint:HostManagedChannelOwnedEndpoint
    init(endpoint:HostManagedChannelOwnedEndpoint){this.endpoint=endpoint}

    public func execute(_:ToolInvocationContext,_:PreparedToolInvocation):Result<ToolResult>{
        managedChannelDriverError<ToolResult>("managed_channel.owned_entry_required")
    }
    public func acquireHandoffLease(context:ToolInvocationContext,parent:PreparedToolInvocation):Result<ToolExecutionHandoffLease>{
        // Required actual installed generation/publication pin. This family
        // cannot inherit the ordinary executor's default no-op handoff lease.
        endpoint.acquireHandoffLease(context,parent)
    }
    // The original actual persisted callback was NOP. This explicit typed
    // route keeps that body and retains neither the paid alias nor its DOM.
    public func afterOwnedResultPersisted(context:ToolInvocationContext,
        held:OwnedCanonicalThreadItemAliasCustody):Result<Unit>{
        let _=context;let _=held;Result.Ok(())
    }
    public func cancel(run:RunId):Result<Unit>{endpoint.cancel(run)}

    public func executeOwned(context:ToolInvocationContext,parent:PreparedToolInvocation,
        control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        let session=match(endpoint.begin(context,parent)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
        drive(context,parent,control,session)
    }
    public func resumeOwned(context:ToolInvocationContext,pending:OwnedToolExecutionContinuation,
        decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        // The original claimed continuation lends the exact same physical
        // custody. No endpoint registry lookup or package-private comparison
        // can recreate it from Prepared IDs or Native session descriptors.
        pending.withClaimedCustody({custody=>
            let session=match(custody as HostManagedChannelOwnedSession){
                case Some(actual)=>actual;case None=>return managedChannelDriverError<OwnedToolExecutionProgress>("managed_channel.custody_changed")}
            match(session.validate(context,pending.parent)){case Result.Err(error)=>return Result.Err(error);case _=>()}
            let approved=match(control.approvedPendingChild()){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            match(decision){
                case ApprovalDecision.Approve | ApprovalDecision.ApproveSession=>
                    let child=match(approved){case Some(value)=>value;case None=>return managedChannelDriverError<OwnedToolExecutionProgress>("managed_channel.approved_child_missing")}
                    if(child.operationId.value!=pending.child.operationId.value || child.source.requestKey!=pending.child.source.requestKey){
                        return managedChannelDriverError<OwnedToolExecutionProgress>("managed_channel.approved_child_changed")}
                    match(executeChild(context,pending.parent,child,control,session)){
                        case Result.Err(error)=>return Result.Err(error);case _=>()}
                    drive(context,pending.parent,control,session)
                case _=>knownParent(pending.parent,session.rejectChild(context,pending.parent,pending.child,decision),control)
            }
        })
    }
    public func rejectOwned(context:ToolInvocationContext,parent:PreparedToolInvocation,
        decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        let session=match(endpoint.begin(context,parent)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
        knownParent(parent,session.rejectParent(context,parent,decision),control)
    }

    private func drive(context:ToolInvocationContext,parent:PreparedToolInvocation,control:OwnedToolExecutionControl,
        session:HostManagedChannelOwnedSession):Result<OwnedToolExecutionProgress>{
        while(true){
            match(session.validate(context,parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let step=match(session.next(context,parent)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            match(step){
                case HostManagedChannelOwnedStep.Unknown(error)=>return Result.Err(error)
                case HostManagedChannelOwnedStep.Complete(result)=>return knownParent(parent,Result.Ok(result),control)
                case HostManagedChannelOwnedStep.Effect(operation,sequence)=>
                    let binding=match(session.currentBinding(context,parent)){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    let key="managed-channel:"+parent.call.callId+":"+sequence.toString()
                    let args=objectValue([ValueField("binding",binding),ValueField("sequence",numberValue(sequence.toString())),
                        ValueField("request_key",textValue(key)),ValueField("operation",operation)])
                    if(!managedChannelRuntimeChildValueValid(args)){
                        return managedChannelDriverError("managed_channel.proposal_invalid")}
                    let kind=httpIntentText(operation,"kind")
                    let name=if(kind=="write"){HOST_MANAGED_CHANNEL_WRITE_TOOL}
                        else if(kind=="spawn"){HOST_MANAGED_CHANNEL_SPAWN_TOOL}else{HOST_MANAGED_CHANNEL_CLOSE_TOOL}
                    let call=ToolCall(parent.call.callId+":managed:"+sequence.toString(),name,args)
                    let preparation=match(control.prepareChild(context,call,key)){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    match(preparation){
                        case ToolPreparation.Ready(child)=>
                            match(executeChild(context,parent,child,control,session)){
                                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        case ToolPreparation.NeedsApproval(child,_)=>return control.awaitChild(child,session)
                        case ToolPreparation.Completed(result)=>
                            // A policy shortcut is not an executed child. Its
                            // temporary output is discarded before freezing the
                            // parent's verified no-effect terminal.
                            result.releasePayload()
                            return knownParent(parent,session.preparationDenied(context,parent),control)
                        case ToolPreparation.Denied(_)=>return knownParent(parent,session.preparationDenied(context,parent),control)
                    }
            }
        }
        managedChannelDriverError("managed_channel.driver_unreachable")
    }
    private func executeChild(context:ToolInvocationContext,parent:PreparedToolInvocation,child:PreparedToolInvocation,
        control:OwnedToolExecutionControl,session:HostManagedChannelOwnedSession):Result<Unit>{
        let returned=match(control.executeRetainedChild(context,child,session)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let accepted=returned.withOutput({output=>
            if(output.callId!=child.call.callId || output.receiptId!=child.operationId.value || output.payloadLease.isNone()){
                return managedChannelDriverError("managed_channel.child_output_changed")}
            // The actual Pipeline already verified/committed this complete
            // child. The callback may consume it into the SAME paid Session,
            // and ends before Kernel clears its large handle and closes owner.
            session.acceptChild(context,parent,child,output)
        })
        match(returned.closeAfterConsumption()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(!returned.isAcknowledged()){
            return managedChannelDriverError("managed_channel.child_cleanup_pending")}
        accepted
    }
    // Failed capture still owns its actual output. Unit lease release is
    // no physical cleanup proof; actual cleanup debt remains on failure.
    private func closeTerminal(owner:AcknowledgedOperationTerminalDataOwner,
        lease:ToolResultPayloadLease):Result<Unit>{owner.closeRetainedOutput(lease)}
    private func knownParent(parent:PreparedToolInvocation,result:Result<HostManagedChannelOwnedTerminal>,
        control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        match(result){
            case Result.Err(error)=>Result.Err(error)
            case Result.Ok(terminal)=>
                var output=Some(match(terminal.takeResult()){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value})
                let lease=match(output.getOrThrow().payloadLease){case Some(value)=>value
                    case None=>return managedChannelDriverError("managed_channel.parent_cleanup_owner_missing")}
                if(output.getOrThrow().callId!=parent.call.callId || output.getOrThrow().receiptId!=parent.operationId.value){
                    output=None<ToolResult>
                    match(closeTerminal(terminal.dataOwner,lease)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    return managedChannelDriverError("managed_channel.parent_output_changed")}
                // A parsed DAP success=false remains a known business result.
                // The actual Control captures this exact terminal/data owner;
                // Store independently checks its Source, known child ledger,
                // full output bytes and physical fixed-FD before Core settles.
                let captured=control.completeParent(output.getOrThrow(),terminal.dataOwner)
                // Successful Control/Kernel owns the sole retained carrier.
                // Failure closes only after all local large references ended.
                output=None<ToolResult>
                if(captured.isError()){
                    match(closeTerminal(terminal.dataOwner,lease)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
                captured
        }
    }

}

func managedChannelDriverError<T>(code:String):Result<T>{
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired,code,
        "managed channel lacks its actual current prepared stage or physical owner"))
}
