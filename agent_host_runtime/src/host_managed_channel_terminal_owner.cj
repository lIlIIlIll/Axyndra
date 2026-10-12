package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*
import std.sync.*

// Data only. Actual Session adoption and writer verification create this
// carrier; an artifact hash, Native bool or DTO grants no execution Source.
class HostManagedChannelTerminalFile {
    let artifact:HostArtifact
    init(artifact:HostArtifact){this.artifact=artifact}
}

func hostManagedChannelTerminalDescriptorValid(value:AgentValue,parent:PreparedToolInvocation):Bool{
    let kind=httpIntentText(value,"terminal_kind")
    let fields=if(kind=="protocol"){
        ["schema","terminal_kind","parent_binding_digest","output","is_error","protocol_record"]
    }else{["schema","terminal_kind","parent_binding_digest","output","is_error"]}
    if(!isManagedChannelOwnedParentPlan(parent.operationPlan) || !httpIntentExactFields(value,fields) ||
        httpIntentText(value,"schema")!="axyndra.managed-channel-owned-terminal/v1" ||
        httpIntentText(value,"parent_binding_digest")!=parent.operationPlan.bindingDigest ||
        !["protocol","complete","policy_stop","user_rejected","child_failure"].contains(kind) ||
        value.field("output").isNone() || value.field("is_error").getOrThrow().unifiedKind!=ValueKind.Boolean){return false}
    let failed=value.field("is_error").getOrThrow().asBool()
    if(kind=="complete" && failed){return false}
    if(["policy_stop","user_rejected","child_failure"].contains(kind) && !failed){return false}
    if(kind=="protocol"){
        let record=value.field("protocol_record").getOrThrow()
        if(!httpIntentExactFields(record,["operation_id","request_key","response"]) ||
            httpIntentText(record,"operation_id")=="" || httpIntentText(record,"request_key")=="" ||
            record.field("response").isNone()){return false}
    }
    true
}

// Inspect actual retained Prepared/Root/context data without constructing
// canonical Strings. The old original StoredValue bounds remain unchanged.
func hostManagedChannelTerminalReferencePeak(context:ToolInvocationContext,parent:PreparedToolInvocation):Int64{
    if(parent.source.operationRoot.isNone() || parent.source.runId.value!=context.runId.value ||
        parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch ||
        !isManagedChannelOwnedParentPlan(parent.operationPlan)){
        throw IllegalStateException("actual managed terminal lost its original private parent")}
    let measured=HostManagedGrantRetainedMeasure()
    measured.add(parent.call.arguments);measured.add(parent.operationPlan.canonicalArguments)
    match(parent.source.operationRoot.getOrThrow()){
        case OperationRootSource.Direct(root)=>measured.add(root.call.arguments)
        case OperationRootSource.Committed(root)=>measured.add(root.block.arguments)}
    measured.text(context.workspaceRoot);measured.text(context.cwd)
    measured.text(parent.call.callId);measured.text(parent.operationId.value);measured.text(parent.operationPlan.bindingDigest)
    for(field in context.environment.entries()){measured.text(field.name);measured.text(field.value)}
    measured.text(context.contextProjection.sourceDigest)
    for(contribution in context.contextProjection.contributions()){
        measured.text(contribution.owner);measured.text(contribution.id);measured.text(contribution.sourceRef)
        measured.text(contribution.content)
        for(reference in contribution.references()){
            measured.text(reference.id);measured.text(reference.locator)
            match(reference.content){case Some(value)=>measured.text(value);case None=>()}
            match(reference.contentDigest){case Some(value)=>measured.text(value);case None=>()}}
    }
    if(context.hasOwnedToolSetSnapshot159()){
        let counts=measured.retainedCounts159()
        let updated=context.closedToolSetRetainedCounts159(counts[0],counts[1])
        measured.applyRetainedCounts159(updated[0],updated[1])
    }else{
    match(context.toolSetSnapshot){case None=>();case Some(snapshot)=>
        measured.text(snapshot.id)
        match(snapshot.threadId){case Some(value)=>measured.text(value.value);case None=>()}
        for(entry in snapshot.entries){
            measured.text(entry.name);measured.text(entry.description);measured.add(entry.inputSchema)
            measured.text(entry.executorVersion);measured.text(entry.implementationFingerprint);measured.text(entry.schemaDigest)
            for(capability in entry.requiredCapabilities){measured.text(capability.resource)}}
        for(handler in snapshot.hookHandlers){
            measured.text(handler.event);measured.text(handler.pluginId);measured.text(handler.pluginVersion)
            measured.text(handler.contentDigest);measured.text(handler.packageRoot);measured.text(handler.matcher)
            measured.text(handler.command)}}
    }
    for(descriptor in context.services.descriptors()){measured.text(descriptor.name);measured.text(descriptor.version)}
    match(parent.approval){case Some(value)=>measured.add(value.preview);case None=>()}
    measured.peak()
}

class HostManagedChannelTerminalOwnerSlot {
    var owner:?HostManagedChannelTerminalDataOwner=None<HostManagedChannelTerminalDataOwner>
    init(){}
    func acknowledge():Unit{match(owner){
        case Some(actual)=>match(actual.acknowledgeReleasedLease()){
            case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
        case None=>throw IllegalStateException("actual terminal data owner has not been captured")}}

}

// Private mutex serializes exact actual lease borrow against actual cleanup.
// Full Host current checks precede the Session/Artifact/SQL borrower; only
// captured atomic/fixed-file guards run inside the Store transaction.
class HostManagedChannelTerminalDataOwner <: AcknowledgedOperationTerminalDataOwner {
    private let lock=Mutex()
    private let retainedContextFrameLock159=Mutex()
    private var retainedContextFrames159:Int64=0
    private var retainedContextFrameRevoked159=false
    private let session:HostDocumentDataSession
    private let lease:ToolResultPayloadLease
    private var localCurrent:?()->Result<Unit>
    private var fullCurrent:?()->Result<Unit>
    private var typedAcknowledgementStarted=false
    private var typedAcknowledged=false
    init(session:HostDocumentDataSession,lease:ToolResultPayloadLease,
        localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>){
        this.session=session;this.lease=lease;this.localCurrent=Some(localCurrent);this.fullCurrent=Some(fullCurrent)
    }
    public func withRetainedOutput(actual:ToolResultPayloadLease,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        if(!beginRetainedContextFrame159()){return hostPluginResourceError("managed_channel.terminal_released","actual terminal consumption has already been acknowledged")}
        try{withRetainedOutputContextFrame159(actual,consume)}finally{endRetainedContextFrame159()}
    }
    private func withRetainedOutputContextFrame159(actual:ToolResultPayloadLease,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        if(!refEq(actual,lease)){return hostPluginResourceError("managed_channel.terminal_lease_changed","another allocation cannot borrow this actual output")}
        lock.lock();try{
            if(localCurrent.isNone() || fullCurrent.isNone()){
                return hostPluginResourceError("managed_channel.terminal_released","actual terminal consumption has already been acknowledged")}
            match(fullCurrent.getOrThrow()()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(localCurrent.getOrThrow()()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(session.withManagedChannelTerminalOutput(actual,localCurrent.getOrThrow(),consume)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(localCurrent.getOrThrow()()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            fullCurrent.getOrThrow()()
        }finally{lock.unlock()}
    }
    // Clearing these actual Host callbacks drops original Prepared/context
    // references BEFORE Session refunds the complete paid output allocation.
    func acknowledgeReleasedLease():Result<Unit>{
        lock.lock();try{
            if(!typedAcknowledgementStarted){return hostPluginResourceError("managed_channel.terminal_typed_ack_required",
                "ordinary Unit lease closure cannot acknowledge a retained parent output")}
            if(!claimRetainedContextRetirement159()){
                return hostPluginResourceError("managed_channel.terminal_output_borrowed","actual terminal callback helper has not returned")}
            clearTerminalCallbacksFrame159()
            match(session.acknowledgeManagedChannelTerminal(lease)){
                case Result.Err(error)=>Result.Err(error)
                case Result.Ok(_)=>typedAcknowledged=true;Result.Ok(())}
        }finally{lock.unlock()}
    }
    public func retainCanonicalBacking(actual:ToolResultPayloadLease):Result<LogicalJsonOwnerReservation>{
        if(!beginRetainedContextFrame159()){return hostPluginResourceError("managed_channel.canonical_backing_closed","canonical allocation must transfer before physical acknowledgement")}
        try{retainCanonicalBackingContextFrame159(actual)}finally{endRetainedContextFrame159()}
    }
    private func retainCanonicalBackingContextFrame159(actual:ToolResultPayloadLease):Result<LogicalJsonOwnerReservation>{
        if(!refEq(actual,lease)){return hostPluginResourceError("managed_channel.canonical_backing_lease_changed",
            "another lease cannot retain this actual complete decoded output")}
        lock.lock();try{
            if(typedAcknowledgementStarted){return hostPluginResourceError("managed_channel.canonical_backing_closed",
                "canonical allocation must transfer before physical acknowledgement")}
            session.retainManagedChannelCanonicalBacking(lease)
        }finally{lock.unlock()}
    }
    // Kernel drops every unpublished/failed-capture large result handle
    // before this checked cleanup-only path. No Known fact is manufactured.
    public func closeUnpublishedOutput():Result<Unit>{closeRetainedOutput(lease)}
    public func closeRetainedOutput(actual:ToolResultPayloadLease):Result<Unit>{
        if(!refEq(actual,lease)){return hostPluginResourceError("managed_channel.terminal_cleanup_lease_changed","another lease cannot acknowledge this actual output")}
        // Core has dropped its large retained result before this typed ACK.
        // Retire actual Prepared/context callbacks before own Session refund.
        lock.lock();try{
            typedAcknowledgementStarted=true
        }finally{lock.unlock()}
        // An earlier Unit closure or failed callback cannot acknowledge or
        // suppress retry of this actual same-Session physical cleanup.
        try{actual.close()}catch(_:Exception){()}
        acknowledgeReleasedLease()
    }
    private func beginRetainedContextFrame159():Bool{
        retainedContextFrameLock159.lock();try{
            if(retainedContextFrameRevoked159 || retainedContextFrames159==Int64.Max){return false}
            retainedContextFrames159++;true
        }finally{retainedContextFrameLock159.unlock()}
    }
    private func endRetainedContextFrame159():Unit{
        retainedContextFrameLock159.lock();try{
            if(retainedContextFrames159<=0){throw IllegalStateException("managed terminal context frame did not enter")}
            retainedContextFrames159--
        }finally{retainedContextFrameLock159.unlock()}
    }
    private func claimRetainedContextRetirement159():Bool{
        retainedContextFrameLock159.lock();try{
            if(retainedContextFrames159!=0){return false}
            retainedContextFrameRevoked159=true;true
        }finally{retainedContextFrameLock159.unlock()}
    }
    private func clearTerminalCallbacksFrame159():Unit{
        localCurrent=None;fullCurrent=None
    }
    func actualAcknowledged():Bool{lock.lock();try{typedAcknowledged}finally{lock.unlock()}}
}

// Actual configured endpoint supplies the same already-adopted Session and
// physically completed final writer. Core alone finalizes the canonical parent.
func hostMaterializeManagedChannelParentOutput(session:HostDocumentDataSession,context:ToolInvocationContext,
    parent:PreparedToolInvocation,produce:(HostDocumentDataSession)->Result<HostServiceArtifactWriter>,
    localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>):Result<HostManagedChannelOwnedTerminal>{
    match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let physical=match(session.retainExecutionCustody()){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    var decoded=session.run({actual=>
        let writer=match(produce(actual)){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
        actual.readPrivateManagedChannelTerminal(writer,context,parent,localCurrent)})
    var transferred=false
    try{
        let descriptor=match(decoded){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(session.releaseManagedChannelTerminalTransient()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let slot=HostManagedChannelTerminalOwnerSlot()
        let lease=match(session.captureManagedChannelOutputLease({=>slot.acknowledge()})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let owner=HostManagedChannelTerminalDataOwner(session,lease,localCurrent,fullCurrent);slot.owner=Some(owner)
        let result=ToolResult(parent.call.callId,descriptor.field("output").getOrThrow(),
            isError:descriptor.field("is_error").getOrThrow().asBool(),receiptId:parent.operationId.value,payloadLease:Some(lease))
        transferred=true;Result.Ok(HostManagedChannelOwnedTerminal(result,owner))
    }finally{
        decoded=hostPluginResourceError<AgentValue>("managed_channel.terminal_transferred","local terminal reference has been transferred or discarded")
        if(!transferred){session.acknowledgeOutput();let _=physical.close()}
    }
}
