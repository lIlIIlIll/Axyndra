package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_ports.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import stdx.crypto.digest.*
import yjson.*
import yjson_support.*

private func hostManagedSessionRetainInvocationContext159(context:ToolInvocationContext):(ToolInvocationContext,Bool){
    let owned=context.hasOwnedToolSetSnapshot159()
    (if(owned){context.retainInvocationContext159()}else{context},owned)
}

// Actual class references arrive from the existing service.invocation slot.
// The Native worker supplies progress data; it cannot select a Host Source,
// grant, registry, owner, file or replacement execution custody.
class HostManagedChannelActualOwnedSession <: HostManagedChannelOwnedSession & HostManagedServiceInvocation {
    private let lock=Mutex()
    private let retainedContextFrameLock159=Mutex()
    private var retainedContextFrames159:Int64=0
    private var retainedContextFrameRevoked159=false
    private let stopped=AtomicBool(false)
    private let service:HostPluginManagedService
    private let host:HostJavaScriptPluginHost
    private let resource:HostManagedOwnedChannelResource
    private let endpoint:HostPinnedNativeServiceEndpoint
    private let port:OperationRuntimePort
    private let revision:Int64
    private let payment:LogicalJsonOwnerReservation
    private var context:?ToolInvocationContext
    private var ownsRetainedContext159=false
    private var retiringContext159:?ToolInvocationContext=None<ToolInvocationContext>
    private var parent:?PreparedToolInvocation
    private var progress:?AgentValue=None<AgentValue>
    private let completed=ArrayList<PreparedToolInvocation>()
    private var pending:?AgentValue=None<AgentValue>
    // Only the strict bounded ACK DTO is retained here, independently paid
    // by this original Session. Its child ToolResult/lease is never retained.
    private var accepted:?AgentValue=None<AgentValue>
    private var sequence:Int64=0
    private var opened=false
    private var published=false
    private var closing=false
    private var released=false
    private var busy=false
    private var outputOwner:?HostManagedChannelTerminalDataOwner=None<HostManagedChannelTerminalDataOwner>
    private var terminalPhysical:?HostDocumentDataSession=None<HostDocumentDataSession>
    private var retainedEffect:?HostManagedChannelActualEffectOwner=None<HostManagedChannelActualEffectOwner>
    init(service:HostPluginManagedService,host:HostJavaScriptPluginHost,
        resource:HostManagedOwnedChannelResource,endpoint:HostPinnedNativeServiceEndpoint,
        port:OperationRuntimePort,revision:Int64,context:ToolInvocationContext,parent:PreparedToolInvocation){
        let paid=reserveNativeDocumentPayload(1)
        try{paid.ensureRetainedPeak(hostManagedChannelTerminalReferencePeak(context,parent)+1048576)}
        catch(error:Exception){paid.close();throw error}
        let retained=try{hostManagedSessionRetainInvocationContext159(context)}
            catch(error:Exception){paid.close();throw error}
        this.service=service;this.host=host;this.resource=resource;this.endpoint=endpoint;this.port=port
        this.revision=revision;this.context=Some(retained[0]);ownsRetainedContext159=retained[1];this.parent=Some(parent);payment=paid
    }
    private func beginBorrow():Result<Unit>{
        lock.lock();try{
            if(closing || released || busy || stopped.load() || context.isNone() || parent.isNone()){
                return managedChannelDriverError("managed_channel.actual_invocation_closed")}
            busy=true;Result.Ok(())
        }finally{lock.unlock()}
    }
    private func endBorrow():Unit{lock.lock();try{busy=false}finally{lock.unlock()}}
    private func pay(additional:AgentValue,extraBytes!:Int64=0):Unit{
        let actualContext=context.getOrThrow();let actualParent=parent.getOrThrow()
        let measure=HostManagedGrantRetainedMeasure()
        measure.add(additional)
        match(progress){case Some(value)=>measure.add(value);case None=>()}
        match(pending){case Some(value)=>measure.add(value);case None=>()}
        match(accepted){case Some(value)=>measure.add(value);case None=>()}
        for(child in completed){
            measure.add(child.call.arguments);measure.add(child.operationPlan.canonicalArguments)
            match(child.approval){case Some(value)=>measure.add(value.preview);case None=>()}
            measure.text(child.operationId.value);measure.text(child.source.requestKey);measure.text(child.call.callId)
        }
        payment.ensureRetainedPeak(hostManagedChannelTerminalReferencePeak(actualContext,actualParent)+measure.peak()+
            extraBytes*8+1048576)
    }
    public func validate(actualContext:ToolInvocationContext,actualParent:PreparedToolInvocation):Result<Unit>{
        if(!beginRetainedContextFrame159()){return managedChannelDriverError("managed_channel.actual_parent_changed")}
        try{validateContextFrame159(actualContext,actualParent)}finally{endRetainedContextFrame159()}
    }
    private func validateContextFrame159(actualContext:ToolInvocationContext,actualParent:PreparedToolInvocation):Result<Unit>{
        if(context.isNone() || parent.isNone() || !refEq(parent.getOrThrow(),actualParent) ||
            !hostManagedChannelSameActualContext(context.getOrThrow(),actualContext) || stopped.load()){
            return managedChannelDriverError("managed_channel.actual_parent_changed")}
        service.validateOwnedChannelParent(actualContext,actualParent,revision)
    }
    public func currentBinding(actualContext:ToolInvocationContext,actualParent:PreparedToolInvocation):Result<AgentValue>{
        if(!beginRetainedContextFrame159()){return managedChannelDriverError("managed_channel.actual_parent_changed")}
        try{currentBindingContextFrame159(actualContext,actualParent)}finally{endRetainedContextFrame159()}
    }
    private func currentBindingContextFrame159(actualContext:ToolInvocationContext,actualParent:PreparedToolInvocation):Result<AgentValue>{
        match(validate(actualContext,actualParent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        service.ownedChannelBinding(actualContext,actualParent.call.name,revision)
    }
    private func phase(action:String,fields:Array<ValueField>):Result<Unit>{
        let actualContext=context.getOrThrow();let actualParent=parent.getOrThrow()
        match(validate(actualContext,actualParent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let entries=ArrayList<ValueField>([ValueField("action",textValue(action))]);entries.add(all:fields)
        let arguments=objectValue(entries.toArray())
        // The pinned yjson writer can allocate a whole six-byte escape per
        // source byte, then coexist with old/new doubled writer buffers and
        // the finished String. Prepay that whole bound BEFORE serialization,
        // together with this Session's full original Root and all live states.
        let encodedMeasure=HostManagedGrantRetainedMeasure();encodedMeasure.add(arguments)
        let encodedUpper=encodedMeasure.encodedUpperBound()
        pay(arguments,extraBytes:encodedUpper)
        let encoded=stringifyUnifiedJson(arguments)
        if(encoded.size>encodedUpper){throw LogicalJsonPayloadError("managed phase exceeded its prepaid whole encoding bound")}
        let response=match(host.invokeService(endpoint,encoded,
            JavaScriptHostInvocationIdentity(threadId:actualContext.sessionId.value,runId:actualContext.runId.value,
                epoch:actualContext.epoch,operationId:actualParent.operationId.value,callId:actualParent.call.callId,kind:"service"),
            actualContext,timeoutMillis:resource.callTimeoutMillis(),observer:Some(this),prepared:Some(actualParent))){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try{
            if(response.isError){return managedChannelDriverError("managed_channel.native_phase_unknown")}
            match(validate(actualContext,actualParent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            // The physical RPC owner still pays the incoming complete graph.
            // Prepay every retained alias before returning that owner's lease.
            pay(objectValue([ValueField("arguments",arguments),ValueField("response",response.value)]),extraBytes:encodedUpper)
            progress=Some(response.value);Result.Ok(())
        }finally{response.releasePayload()}
    }
    public func next(actualContext:ToolInvocationContext,actualParent:PreparedToolInvocation):Result<HostManagedChannelOwnedStep>{
        if(!beginRetainedContextFrame159()){return managedChannelDriverError("managed_channel.actual_invocation_closed")}
        try{nextContextFrame159(actualContext,actualParent)}finally{endRetainedContextFrame159()}
    }
    private func nextContextFrame159(actualContext:ToolInvocationContext,actualParent:PreparedToolInvocation):Result<HostManagedChannelOwnedStep>{
        match(beginBorrow()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        try{
            match(validate(actualContext,actualParent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(published){return managedChannelDriverError("managed_channel.terminal_already_consumed")}
            match(retainedEffect){case Some(owner)=>
                if(!owner.actualAcknowledged()){return managedChannelDriverError("managed_channel.actual_child_cleanup_pending")}
                retainedEffect=None<HostManagedChannelActualEffectOwner>;case None=>()}
            match(accepted){case Some(value)=>
                match(phase("channel_effect",value.fields.toArray())){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>accepted=None<AgentValue>}
                case None=>()}
            if(!opened){
                let arguments=actualParent.operationPlan.canonicalArguments
                match(phase("channel_begin",[ValueField("input",arguments.field("input").getOrThrow()),
                    ValueField("configuration",arguments.field("configuration").getOrThrow())])){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>opened=true}
            }else if(progress.isNone()){
                match(phase("channel_next",[])){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            }
            while(true){
                let value=progress.getOrThrow();let status=httpIntentText(value,"status")
                if(status=="unknown"){stopped.store(true);return Result.Ok(HostManagedChannelOwnedStep.Unknown(
                    AgentError(AgentErrorKind.RecoveryRequired,"managed_channel.native_outcome_unknown",
                        "actual protocol progress has no verified terminal; reconciliation is required")))}
                if(status=="effect"){
                    if(!httpIntentExactFields(value,["status","sequence","operation"])){
                        return managedChannelDriverError("managed_channel.native_effect_invalid")}
                    let next=hostManagedChannelExactOrdinal(value.field("sequence").getOrThrow())
                    if(next!=sequence+1 || pending.isSome()){
                        return managedChannelDriverError("managed_channel.native_effect_sequence_changed")}
                    let proposed=value.field("operation").getOrThrow();pay(proposed)
                    pending=Some(proposed);sequence=next;progress=None<AgentValue>
                    return Result.Ok(HostManagedChannelOwnedStep.Effect(proposed,next))
                }
                if(status=="read"){
                    if(!httpIntentExactFields(value,["status","lease_id","stream","max_bytes","wait_ms"]) ||
                        httpIntentText(value,"stream")!="stdout" ||
                        hostManagedChannelExactOrdinal(value.field("max_bytes").getOrThrow())!=16384){
                        return managedChannelDriverError("managed_channel.native_read_invalid")}
                    let binding=match(currentBinding(actualContext,actualParent)){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    let lease=match(resource.adapterLease()){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    if(httpIntentText(value,"lease_id")!=lease.leaseId){
                        return managedChannelDriverError("managed_channel.native_read_lease_changed")}
                    let wait=Int64.parse(value.field("wait_ms").getOrThrow().asNumberText())
                    if(wait<0 || wait>1000 || wait.toString()!=value.field("wait_ms").getOrThrow().asNumberText()){
                        return managedChannelDriverError("managed_channel.native_read_bounds")}
                    progress=None<AgentValue>
                    for(stream in [ProcessChannelStream.Stdout,ProcessChannelStream.Stderr]){
                        let stdout=match(stream){case ProcessChannelStream.Stdout=>true;case ProcessChannelStream.Stderr=>false}
                        let read=match(lease.managedRead(actualContext,actualParent,binding,port,stream,16384,
                            if(stdout){wait}else{0})){
                            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                        if(wait==0 || !read.bytes.isEmpty() || read.eof){
                            let encoded=hostManagedChannelHex(read.bytes)
                            match(phase("channel_read",[ValueField("stream",textValue(
                                if(stdout){"stdout"}else{"stderr"})),
                                ValueField("bytes_hex",textValue(encoded)),ValueField("eof",boolValue(read.eof))])){
                                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                            if(httpIntentText(progress.getOrThrow(),"status")!="read"){break}
                        }
                    }
                    if(progress.isNone()){
                        match(phase("channel_next",[])){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
                    continue
                }
                if(status!="complete"){return managedChannelDriverError("managed_channel.native_progress_invalid")}
                let terminal=match(materialize("complete",value)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                progress=None<AgentValue>;published=true
                return Result.Ok(HostManagedChannelOwnedStep.Complete(terminal))
            }
            return managedChannelDriverError<HostManagedChannelOwnedStep>("managed_channel.actual_progress_failed")
        }catch(_:Exception){managedChannelDriverError("managed_channel.actual_progress_failed")}
        finally{endBorrow()}
    }
    public func acceptChild(actualContext:ToolInvocationContext,actualParent:PreparedToolInvocation,
        child:PreparedToolInvocation,result:ToolResult):Result<Unit>{
        if(!beginRetainedContextFrame159()){return managedChannelDriverError("managed_channel.actual_invocation_closed")}
        try{acceptChildContextFrame159(actualContext,actualParent,child,result)}finally{endRetainedContextFrame159()}
    }
    private func acceptChildContextFrame159(actualContext:ToolInvocationContext,actualParent:PreparedToolInvocation,
        child:PreparedToolInvocation,result:ToolResult):Result<Unit>{
        match(beginBorrow()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        try{
            match(validate(actualContext,actualParent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(pending.isNone() || !owns(child) || result.callId!=child.call.callId ||
                result.receiptId!=child.operationId.value || result.isError || result.payloadLease.isNone() ||
                canonicalAgentValue(pending.getOrThrow())!=canonicalAgentValue(child.operationPlan.canonicalArguments.field("operation").getOrThrow())){
                return managedChannelDriverError("managed_channel.actual_child_ack_changed")}
            match(port.verifyManagedChannelOwnedChildTerminal(actualParent.source.operationRoot.getOrThrow(),actualParent.operationId,
                child.operationId,actualContext.runId,ThreadId(actualContext.sessionId.value),actualContext.epoch,
                actualParent.operationPlan,child.operationPlan,child.source.requestKey,child.call.callId,result,
                {=>validate(actualContext,actualParent)})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            // Retain only the original Prepared/known-prefix metadata. No child
            // ToolResult/output DOM survives the ended callback or typed ACK.
            let childFields=ArrayList<ValueField>([ValueField("arguments",child.call.arguments),
                ValueField("plan",child.operationPlan.canonicalArguments),ValueField("operation_id",textValue(child.operationId.value)),
                ValueField("request_key",textValue(child.source.requestKey)),ValueField("call_id",textValue(child.call.callId))])
            match(child.approval){case Some(value)=>childFields.add(ValueField("preview",value.preview));case None=>()}
            pay(objectValue(childFields.toArray()));completed.add(child)
            if(httpIntentText(pending.getOrThrow(),"kind")=="spawn"){
                match(resource.activateSpawn(actualContext,actualParent,child,result,port)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
            let acknowledged=objectValue([ValueField("sequence",integerValue(sequence)),ValueField("result",result.output)])
            pay(acknowledged);accepted=Some(acknowledged)
            pending=None<AgentValue>;Result.Ok(())
        }finally{endBorrow()}
    }
    public func executeRetainedEffect(childContext:ToolInvocationContext,actualParent:PreparedToolInvocation,
        child:PreparedToolInvocation):OwnedRetainedToolEffectOutcome{
        if(!beginRetainedContextFrame159()){return hostManagedChannelMissingActualEffect("managed_channel.actual_parent_changed")}
        try{executeRetainedEffectContextFrame159(childContext,actualParent,child)}finally{endRetainedContextFrame159()}
    }
    private func executeRetainedEffectContextFrame159(childContext:ToolInvocationContext,actualParent:PreparedToolInvocation,
        child:PreparedToolInvocation):OwnedRetainedToolEffectOutcome{
        if(parent.isNone() || context.isNone() || !refEq(parent.getOrThrow(),actualParent)){
            return hostManagedChannelMissingActualEffect("managed_channel.actual_parent_changed")}
        let actualContext=context.getOrThrow()
        let owned=try{HostManagedChannelActualEffectOwner(actualContext,actualParent,child)}catch(_:Exception){
            return hostManagedChannelMissingActualEffect("managed_channel.effect_capacity")}
        retainedEffect=Some(owned)
        let outcome=try{
            match(beginBorrow()){case Result.Err(error)=>return OwnedRetainedToolEffectOutcome(
                ToolExecutionOutcome(Result<ToolResult>.Err(error)),owned,cleanupLease:Some(owned.lease));case Result.Ok(_)=>()}
            try{
                match(validate(actualContext,actualParent)){case Result.Err(error)=>return OwnedRetainedToolEffectOutcome(
                    ToolExecutionOutcome(Result<ToolResult>.Err(error)),owned,cleanupLease:Some(owned.lease));case Result.Ok(_)=>()}
                if(pending.isNone() || !owns(child) ||
                    canonicalAgentValue(pending.getOrThrow())!=canonicalAgentValue(child.operationPlan.canonicalArguments.field("operation").getOrThrow())){
                    return OwnedRetainedToolEffectOutcome(ToolExecutionOutcome(managedChannelDriverError<ToolResult>(
                        "managed_channel.actual_effect_changed")),owned,cleanupLease:Some(owned.lease))}
                let binding=child.operationPlan.canonicalArguments.field("binding").getOrThrow()
                let effect=resource.execute(actualContext,actualParent,childContext,child,binding,port)
                match(effect){case Result.Err(error)=>ToolExecutionOutcome(Result<ToolResult>.Err(error))
                    case Result.Ok(value)=>owned.capture(value);ToolExecutionOutcome(Result.Ok(ToolResult(child.call.callId,value,
                        receiptId:child.operationId.value,payloadLease:Some(owned.lease))))}
            }finally{endBorrow()}
        }catch(_:Exception){ToolExecutionOutcome(managedChannelDriverError<ToolResult>("managed_channel.actual_effect_unknown"))}
        OwnedRetainedToolEffectOutcome(outcome,owned,cleanupLease:Some(owned.lease))
    }
    private func materialize(fallbackKind:String,value:AgentValue):Result<HostManagedChannelOwnedTerminal>{
        let actualContext=context.getOrThrow();let actualParent=parent.getOrThrow()
        let record=value.field("protocol_record")
        let kind=if(record.isSome()){"protocol"}else{fallbackKind}
        let fields=ArrayList<ValueField>([ValueField("schema",textValue("axyndra.managed-channel-owned-terminal/v1")),
            ValueField("terminal_kind",textValue(kind)),ValueField("parent_binding_digest",textValue(actualParent.operationPlan.bindingDigest)),
            ValueField("output",value.field("result").getOrThrow()),ValueField("is_error",value.field("is_error").getOrThrow())])
        match(record){case None=>();case Some(data)=>
            if(!httpIntentExactFields(data,["child_sequence","response"])){return managedChannelDriverError("managed_channel.protocol_record_invalid")}
            let ordinal=hostManagedChannelExactOrdinal(data.field("child_sequence").getOrThrow())
            var actual:?PreparedToolInvocation=None<PreparedToolInvocation>
            for(child in completed where hostManagedChannelExactOrdinal(child.operationPlan.canonicalArguments.field("sequence").getOrThrow())==ordinal){
                if(actual.isSome()){return managedChannelDriverError("managed_channel.protocol_record_ambiguous")};actual=Some(child)}
            if(actual.isNone() || httpIntentText(actual.getOrThrow().operationPlan.canonicalArguments.field("operation").getOrThrow(),"kind")!="write"){
                return managedChannelDriverError("managed_channel.protocol_record_uncommitted")}
            let child=actual.getOrThrow()
            fields.add(ValueField("protocol_record",objectValue([ValueField("operation_id",textValue(child.operationId.value)),
                ValueField("request_key",textValue(child.source.requestKey)),ValueField("response",data.field("response").getOrThrow())])))}
        let descriptor=objectValue(fields.toArray());pay(descriptor)
        let actualSession=match(host.documentDataSession()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        terminalPhysical=Some(actualSession)
        let terminal=match(hostMaterializeManagedChannelParentOutput(actualSession,actualContext,actualParent,
            {session=>
                let measure=HostManagedGrantRetainedMeasure();measure.add(descriptor)
                // Include the complete encoded coexistence before writer bytes
                // are constructed, alongside this invocation's original Root.
                pay(descriptor,extraBytes:measure.encodedUpperBound())
                hostManagedChannelWriteActualDescriptor(session,descriptor,payment)},
            {=>if(stopped.load() || closing){managedChannelDriverError("managed_channel.actual_terminal_stale")}else{Result.Ok(())}},
            {=>validate(actualContext,actualParent)})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(terminal.dataOwner as HostManagedChannelTerminalDataOwner){case Some(owner)=>outputOwner=Some(owner)
            case None=>return managedChannelDriverError("managed_channel.actual_terminal_owner_changed")}
        Result.Ok(terminal)
    }
    private func stoppedTerminal(kind:String):Result<HostManagedChannelOwnedTerminal>{
        let arguments=parent.getOrThrow().operationPlan.canonicalArguments
        match(phase("channel_abort",[ValueField("input",arguments.field("input").getOrThrow()),
            ValueField("configuration",arguments.field("configuration").getOrThrow()),ValueField("reason",textValue(kind))])){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let terminal=materialize(kind,progress.getOrThrow());progress=None<AgentValue>;published=true;terminal
    }
    public func rejectChild(actualContext:ToolInvocationContext,actualParent:PreparedToolInvocation,
        child:PreparedToolInvocation,decision159:ApprovalDecision):Result<HostManagedChannelOwnedTerminal>{
        if(!beginRetainedContextFrame159()){return managedChannelDriverError("managed_channel.actual_parent_changed")}
        try{rejectChildContextFrame159(actualContext,actualParent,child,decision159)}finally{endRetainedContextFrame159()}
    }
    private func rejectChildContextFrame159(actualContext:ToolInvocationContext,actualParent:PreparedToolInvocation,
        child:PreparedToolInvocation,_:ApprovalDecision):Result<HostManagedChannelOwnedTerminal>{
        match(validate(actualContext,actualParent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(pending.isNone() || !owns(child)){return managedChannelDriverError("managed_channel.rejected_child_changed")}
        match(phase("channel_reject",[ValueField("sequence",integerValue(sequence))])){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        pending=None<AgentValue>
        let terminal=materialize("user_rejected",progress.getOrThrow());progress=None<AgentValue>;published=true;terminal
    }
    public func rejectParent(context159:ToolInvocationContext,parent159:PreparedToolInvocation,decision159:ApprovalDecision):Result<HostManagedChannelOwnedTerminal>{
        if(!beginRetainedContextFrame159()){return managedChannelDriverError("managed_channel.actual_parent_changed")}
        try{rejectParentContextFrame159(context159,parent159,decision159)}finally{endRetainedContextFrame159()}
    }
    private func rejectParentContextFrame159(_:ToolInvocationContext,_:PreparedToolInvocation,_:ApprovalDecision):Result<HostManagedChannelOwnedTerminal>{
        stoppedTerminal("user_rejected")}
    public func preparationDenied(context159:ToolInvocationContext,parent159:PreparedToolInvocation):Result<HostManagedChannelOwnedTerminal>{
        if(!beginRetainedContextFrame159()){return managedChannelDriverError("managed_channel.actual_parent_changed")}
        try{preparationDeniedContextFrame159(context159,parent159)}finally{endRetainedContextFrame159()}
    }
    private func preparationDeniedContextFrame159(_:ToolInvocationContext,_:PreparedToolInvocation):Result<HostManagedChannelOwnedTerminal>{
        stoppedTerminal("policy_stop")}
    public func owns(child:PreparedToolInvocation):Bool{
        if(!beginRetainedContextFrame159()){return false}
        try{ownsContextFrame159(child)}finally{endRetainedContextFrame159()}
    }
    private func ownsContextFrame159(child:PreparedToolInvocation):Bool{
        parent.isSome() && hostManagedChannelSameRoot(parent.getOrThrow(),child) &&
            child.source.parentOperationId.isSome() && child.source.parentOperationId.getOrThrow().value==parent.getOrThrow().operationId.value &&
            child.source.parentCallId==parent.getOrThrow().call.callId && managedChannelOwnedChildAllowed(parent.getOrThrow().operationPlan,child.operationPlan) &&
            hostManagedChannelExactOrdinal(child.operationPlan.canonicalArguments.field("sequence").getOrThrow())==sequence
    }
    public func executeChild(_:ToolInvocationContext,_:PreparedToolInvocation):Result<ToolResult>{
        managedChannelDriverError("managed_channel.retained_child_entry_required")}
    public func finish(_:Result<HostJavaScriptPluginInvocationResult>):Result<ToolResult>{
        managedChannelDriverError("managed_channel.owned_entry_required")}
    public func onProgress(_:String,_:String):JavaScriptHostResult<Unit>{JavaScriptHostResult.Ok(())}
    public func onServiceRequest(_:String,_:String,_:String,_:String):JavaScriptHostResult<String>{
        hostPluginServiceError<String>("extension.service_unsupported","managed owned protocol uses independently admitted Host operations")}
    // Waiting publication follows the ended next()/phase() helpers. Keep
    // the adapter inventory and every input/proposal/Prepared data payment.
    // Only the actual existing endpoint's RPC scope may establish idleness;
    // no process, output lease, terminal, data or physical close ACK is minted.
    public func releaseTransient():Result<Unit>{
        lock.lock();try{
            if(closing || released || busy || stopped.load() || context.isNone() || parent.isNone() ||
                !opened || published || pending.isNone() || progress.isSome() || accepted.isSome() ||
                terminalPhysical.isSome() || outputOwner.isSome() || endpoint.hasActiveInvocation()){
                return managedChannelDriverError("managed_channel.actual_transient_scope_pending")}
            match(retainedEffect){case Some(owner)=>
                if(!owner.actualAcknowledged()){
                    return managedChannelDriverError("managed_channel.actual_child_cleanup_pending")}
                case None=>()}
            // The persistent lifecycle owner and all Session fields stay paid.
            // Publication does not refund or retire the original data aliases.
            Result.Ok(())
        }finally{lock.unlock()}
    }
    public func close():Result<Unit>{
        stopped.store(true)
        lock.lock();try{
            closing=true
            if(released){return Result.Ok(())}
            if(busy){return managedChannelDriverError("managed_channel.actual_cleanup_pending")}
            // Kernel may still own a handed child carrier outside its callback.
            // Wait for that owner's checked typed ACK; never race its output
            // references by refunding the actual allocation from revocation.
            match(retainedEffect){case Some(owner)=>
                if(!owner.actualAcknowledged()){return managedChannelDriverError("managed_channel.actual_child_cleanup_pending")}
                retainedEffect=None<HostManagedChannelActualEffectOwner>;case None=>()}
            // Core owns terminal cleanup and clears result refs first. A service
            // revocation cannot refund or close a still-canonical borrowed DOM.
            match(outputOwner){case Some(owner)=>if(!owner.actualAcknowledged()){
                return managedChannelDriverError("managed_channel.actual_output_cleanup_pending")};case None=>()}
            match(terminalPhysical){case Some(actual)=>match(actual.close()){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>terminalPhysical=None<HostDocumentDataSession>};case None=>()}
            if(!claimRetainedContextRetirement159()){return managedChannelDriverError("managed_channel.actual_cleanup_pending")}
            let returned=clearRetainedContextFrame159()
            match(returned){case Some(actual)=>actual.returnOwnedToolSetFrame159();case None=>()}
            retiringContext159=None<ToolInvocationContext>
            payment.close();released=true
        }finally{lock.unlock()}
        service.acknowledgeOwnedChannelInvocation(this)
    }
    private func beginRetainedContextFrame159():Bool{
        retainedContextFrameLock159.lock();try{
            if(retainedContextFrameRevoked159 || retainedContextFrames159==Int64.Max){return false}
            retainedContextFrames159++;true
        }finally{retainedContextFrameLock159.unlock()}
    }
    private func endRetainedContextFrame159():Unit{
        retainedContextFrameLock159.lock();try{
            if(retainedContextFrames159<=0){throw IllegalStateException("managed context frame did not enter")}
            retainedContextFrames159--
        }finally{retainedContextFrameLock159.unlock()}
    }
    private func claimRetainedContextRetirement159():Bool{
        retainedContextFrameLock159.lock();try{
            // A busy helper has not returned. Keep its view and allow the old
            // retry path; only an actual zero-frame claim closes new entry.
            if(retainedContextFrames159!=0){return false}
            retainedContextFrameRevoked159=true;true
        }finally{retainedContextFrameLock159.unlock()}
    }
    private func clearRetainedContextFrame159():?ToolInvocationContext{
        if(ownsRetainedContext159 && retiringContext159.isNone()){retiringContext159=context}
            progress=None<AgentValue>;pending=None<AgentValue>;accepted=None<AgentValue>;completed.clear()
            outputOwner=None<HostManagedChannelTerminalDataOwner>
            context=None<ToolInvocationContext>;parent=None<PreparedToolInvocation>
        retiringContext159
    }
}

func hostManagedChannelSameActualContext(left:ToolInvocationContext,right:ToolInvocationContext):Bool{
    if(left.runId.value!=right.runId.value || left.sessionId.value!=right.sessionId.value || left.epoch!=right.epoch ||
        !refEq(left.cancellation,right.cancellation) || !refEq(left.budget,right.budget) ||
        !refEq(left.contextProjection,right.contextProjection) || left.workspaceRoot!=right.workspaceRoot || left.cwd!=right.cwd ||
        left.trustedControl!=right.trustedControl || left.approvalModeOverride!=right.approvalModeOverride ||
        left.hasToolSetSnapshot159()!=right.hasToolSetSnapshot159()){return false}
    if(left.hasToolSetSnapshot159() && !left.sameToolSetSnapshot159(right)){return false}
    let a=left.environment.entries();let b=right.environment.entries()
    if(a.size!=b.size){return false}
    for(index in 0..a.size where a[index].name!=b[index].name || a[index].value!=b[index].value){return false}
    true
}

func hostManagedChannelExactOrdinal(value:AgentValue):Int64{
    if(value.unifiedKind!=ValueKind.Number){throw IllegalArgumentException("managed sequence is not an exact integer")}
    let ordinal=Int64.parse(value.asNumberText())
    if(ordinal<1 || ordinal.toString()!=value.asNumberText()){throw IllegalArgumentException("managed sequence is not canonical")}
    ordinal
}
func hostManagedChannelHex(bytes:Array<Byte>):String{
    let alphabet="0123456789abcdef";let value=ArrayList<Byte>()
    for(byte in bytes){value.add(alphabet[Int64(byte)/16]);value.add(alphabet[Int64(byte)%16])}
    String.fromUtf8(value.toArray())
}
func hostManagedChannelWriteActualDescriptor(session:HostDocumentDataSession,value:AgentValue,
    payment:LogicalJsonOwnerReservation):Result<HostServiceArtifactWriter>{
    try{
        let measure=HostManagedGrantRetainedMeasure();measure.add(value);payment.ensureRetainedPeak(measure.peak()+1048576)
        let encoded=encodeAgentValue(value)
        if(encoded.size<1 || encoded.size>8388608){return managedChannelDriverError("managed_channel.terminal_limit")}
        payment.ensureRetainedPeak(measure.peak()+encoded.size*4+1048576)
        let writer=match(session.newWriter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let bytes=encoded.toArray();let hash=SHA256();var offset:Int64=0
        while(offset<bytes.size){let part=bytes[offset..min(bytes.size,offset+16384)].clone();hash.write(part)
            match(writer.appendBytes(offset,part,8388608)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            offset+=part.size}
        match(writer.finish(bytes.size,hostArtifactHex(hash.finish()))){case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>Result.Ok(writer)}
    }catch(_:Exception){managedChannelDriverError("managed_channel.terminal_writer_failed")}
}
