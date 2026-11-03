package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*

private func hostManagedEffectRetainInvocationContext159(context:ToolInvocationContext):(ToolInvocationContext,Bool){
    let owned=context.hasOwnedToolSetSnapshot159()
    (if(owned){context.retainInvocationContext159()}else{context},owned)
}

class HostManagedChannelActualEffectLeaseSlot {
    var owner:?HostManagedChannelActualEffectOwner=None<HostManagedChannelActualEffectOwner>
    init(){}
    func close():Unit{match(owner){case Some(actual)=>match(actual.acknowledgeReleasedLease()){
        case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
        case None=>throw IllegalStateException("actual effect allocation has not captured its owner")}}
}

// The exact tiny ACK allocation is created and paid before the physical effect.
// Its I/O scopes must have returned a checked actual ACK before capture().
// Persistent processes stay paid by their original lifecycle lease inventory.
class HostManagedChannelActualEffectOwner <: AcknowledgedOperationTerminalDataOwner {
    public let lease:ToolResultPayloadLease
    private let lock=Mutex()
    private let retainedContextFrameLock159=Mutex()
    private var retainedContextFrames159:Int64=0
    private var retainedContextFrameRevoked159=false
    private let payment:LogicalJsonOwnerReservation
    private var output:?AgentValue=None<AgentValue>
    private var context:?ToolInvocationContext
    private var ownsRetainedContext159=false
    private var retiringContext159:?ToolInvocationContext=None<ToolInvocationContext>
    private var parent:?PreparedToolInvocation
    private var child:?PreparedToolInvocation
    private var closed=false
    private var borrowed=false
    private var typedAcknowledgementStarted=false
    init(context:ToolInvocationContext,parent:PreparedToolInvocation,child:PreparedToolInvocation){
        let paid=reserveNativeDocumentPayload(1)
        try{
            let measure=HostManagedGrantRetainedMeasure();measure.add(child.call.arguments);measure.add(child.operationPlan.canonicalArguments)
            match(child.approval){case Some(value)=>measure.add(value.preview);case None=>()}
            paid.ensureRetainedPeak(hostManagedChannelTerminalReferencePeak(context,parent)+measure.peak()+2097152)
        }catch(error:Exception){paid.close();throw error}
        let retained=try{hostManagedEffectRetainInvocationContext159(context)}
            catch(error:Exception){paid.close();throw error}
        this.context=Some(retained[0]);ownsRetainedContext159=retained[1];this.parent=Some(parent);this.child=Some(child);payment=paid
        let slot=HostManagedChannelActualEffectLeaseSlot();lease=ToolResultPayloadLease({=>slot.close()});slot.owner=Some(this)
    }
    func capture(value:AgentValue):Unit{
        lock.lock();try{
            if(closed || output.isSome()){throw IllegalStateException("actual effect output cannot be replaced")}
            let measure=HostManagedGrantRetainedMeasure();measure.add(value)
            measure.add(child.getOrThrow().operationPlan.canonicalArguments);measure.add(child.getOrThrow().call.arguments)
            payment.ensureRetainedPeak(hostManagedChannelTerminalReferencePeak(context.getOrThrow(),parent.getOrThrow())+measure.peak()+2097152)
            output=Some(value)
        }finally{lock.unlock()}
    }
    public func withRetainedOutput(actual:ToolResultPayloadLease,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        if(!beginRetainedContextFrame159()){return managedChannelDriverError("managed_channel.effect_output_missing")}
        try{withRetainedOutputContextFrame159(actual,consume)}finally{endRetainedContextFrame159()}
    }
    private func withRetainedOutputContextFrame159(actual:ToolResultPayloadLease,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        if(!refEq(actual,lease)){return managedChannelDriverError("managed_channel.effect_output_lease_changed")}
        lock.lock();try{
            if(closed || borrowed || output.isNone()){
                return managedChannelDriverError("managed_channel.effect_output_missing")}
            borrowed=true
            let measure=HostManagedGrantRetainedMeasure();measure.add(output.getOrThrow())
            let peak=hostManagedChannelTerminalReferencePeak(context.getOrThrow(),parent.getOrThrow())+measure.peak()+2097152
            payment.ensureRetainedPeak(peak)
            try{consume(output.getOrThrow(),payment,peak,{=>Result.Ok(())});Result.Ok(())}
            finally{borrowed=false}
        }catch(_:Exception){managedChannelDriverError("managed_channel.effect_output_consumer_failed")}
        finally{lock.unlock()}
    }
    public func closeUnpublishedOutput():Result<Unit>{closeRetainedOutput(lease)}
    public func closeRetainedOutput(actual:ToolResultPayloadLease):Result<Unit>{
        if(!refEq(actual,lease)){return managedChannelDriverError("managed_channel.effect_cleanup_lease_changed")}
        lock.lock();try{typedAcknowledgementStarted=true}finally{lock.unlock()}
        try{actual.close()}catch(_:Exception){()}
        acknowledgeReleasedLease()
    }
    func actualAcknowledged():Bool{lock.lock();try{closed}finally{lock.unlock()}}
    func acknowledgeReleasedLease():Result<Unit>{
        lock.lock();try{
            if(!typedAcknowledgementStarted){return managedChannelDriverError("managed_channel.effect_typed_ack_required")}
            if(closed){return Result.Ok(())}
            if(borrowed){return managedChannelDriverError("managed_channel.effect_output_borrowed")}
            // Core's consumer callback ended before this typed ACK. No current
            // Source/deadline check may prevent release of the SAME allocation.
            if(!claimRetainedContextRetirement159()){return managedChannelDriverError("managed_channel.effect_output_borrowed")}
            let returned=clearRetainedContextFrame159()
            match(returned){case Some(actual)=>actual.returnOwnedToolSetFrame159();case None=>()}
            retiringContext159=None<ToolInvocationContext>
            payment.close();closed=true;Result.Ok(())
        }finally{lock.unlock()}
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
            output=None<AgentValue>;context=None<ToolInvocationContext>
            parent=None<PreparedToolInvocation>;child=None<PreparedToolInvocation>
        retiringContext159
    }
}
func hostManagedChannelMissingActualEffect(code:String):OwnedRetainedToolEffectOutcome{
    // There was no allocation to counterfeit. Kernel retains SAME custody and
    // closes the default-closed unpublished owner through its failure resource.
    OwnedRetainedToolEffectOutcome(ToolExecutionOutcome(managedChannelDriverError<ToolResult>(code)),
        HostManagedChannelMissingOutputOwner())
}
