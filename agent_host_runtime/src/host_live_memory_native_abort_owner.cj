package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*

class HostLiveMemoryNativeAbortEffectDataOwner326 <: AcknowledgedOperationTerminalDataOwner {
    private let lock=Mutex()
    private var session:?HostDocumentDataSession=None<HostDocumentDataSession>
    private var actual:?HostAcknowledgedLivePolicyTerminalDataOwner294=None<HostAcknowledgedLivePolicyTerminalDataOwner294>
    private var lease:?ToolResultPayloadLease=None<ToolResultPayloadLease>
    private var storeDebt:?PluginLivePolicySettlementCleanupDebt326=None<PluginLivePolicySettlementCleanupDebt326>
    private var outerErrorData331:?PluginLivePolicyOuterErrorDataOwner331=None<PluginLivePolicyOuterErrorDataOwner331>
    private var closed=false
    private let frame334:?PluginLivePolicyOuterErrorFrame334
    private var storeAcknowledged334=false
    init(frame!:?PluginLivePolicyOuterErrorFrame334=None<PluginLivePolicyOuterErrorFrame334>){this.frame334=frame}
    func adopt(value:HostDocumentDataSession):Unit{
        lock.lock();try{if(closed || session.isSome()){throw IllegalStateException("actual effect Session cannot be adopted twice")};session=Some(value)}finally{lock.unlock()}}
    func publish(value:HostAcknowledgedLivePolicyTerminalDataOwner294,lease:ToolResultPayloadLease):Unit{
        lock.lock();try{if(closed || session.isNone() || actual.isSome()){throw IllegalStateException("actual effect data owner cannot publish twice")}
            actual=Some(value);this.lease=Some(lease)}finally{lock.unlock()}}
    func adoptStoreDebt326(value:PluginLivePolicySettlementCleanupDebt326):Unit{
        lock.lock();try{
            if(closed || session.isNone() || storeDebt.isSome()){
                throw IllegalStateException("actual native-abort Store debt cannot be substituted or adopted twice")}
            storeDebt=Some(value)
        }finally{lock.unlock()}
    }
    func adoptOuterErrorData331(actual:PluginLivePolicyOuterErrorDataOwner331):Unit{
        lock.lock();try{
            if(closed || session.isNone() || outerErrorData331.isSome()){
                throw IllegalStateException("same actual Session cannot adopt a replacement outer error owner")}
            outerErrorData331=Some(actual)
        }finally{lock.unlock()}
    }
    func actualOuterErrorData331(error:AgentError):?PluginLivePolicyOuterErrorDataOwner331{
        lock.lock();try{match(outerErrorData331){case Some(value)=>
            if(value.matchesError(error)){Some(value)}else{None<PluginLivePolicyOuterErrorDataOwner331>}
            case None=>None<PluginLivePolicyOuterErrorDataOwner331>}
        }finally{lock.unlock()}
    }
    private func requireReturnedOuterErrorFrame334(frame:PluginLivePolicyOuterErrorFrame334):Result<Unit>{
        lock.lock();try{
            if(!frame.hasReturned() || outerErrorData331.isNone()){
                return hostPluginResourceError("plugin.live_error_frame_pending","actual effect adapter must return before physical cleanup")}
            if(storeAcknowledged334){return Result<Unit>.Ok(())}
            match(storeDebt){case Some(debt)=>match(debt as PluginLivePolicyOuterErrorPhysicalDebt334){
                case Some(actual)=>if(actual.matchesReturnedErrorFrame334(frame,outerErrorData331.getOrThrow())){
                    return Result<Unit>.Ok(())};case None=>()};case None=>()}
            hostPluginResourceError("plugin.live_error_frame_changed","actual private Store debt and copied data must match the same returned frame")
        }finally{lock.unlock()}
    }
    private func requireOuterErrorConsumerRetirement331():Result<Unit>{
        lock.lock();let framed=try{if(outerErrorData331.isSome()){frame334}else{None<PluginLivePolicyOuterErrorFrame334>}}finally{lock.unlock()}
        match(framed){case Some(frame)=>return requireReturnedOuterErrorFrame334(frame);case None=>()}
        lock.lock();let selected=try{outerErrorData331}finally{lock.unlock()}
        match(selected){case Some(actual)=>
            match(actual.closeAfterConsumerRetirement()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            if(!actual.isConsumerRetired()){
                return hostPluginResourceError<Unit>("plugin.live_error_external_aliases_pending","actual raw Core/registry/event/caller error aliases remain paid")}
            case None=>()}
        Result<Unit>.Ok(())
    }
    private func closeStoreDebt326():Result<Unit>{
        lock.lock();let selected=try{storeDebt}finally{lock.unlock()}
        match(selected){case None=>return Result<Unit>.Ok(())
            case Some(debt)=>
                match(debt.closeAfterFailure()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                if(!debt.isAcknowledged()){
                    return hostPluginResourceError("plugin.live_database_cleanup_pending","same actual Store debt has not acknowledged physical cleanup")}
                lock.lock();try{
                    match(storeDebt){case Some(actual)=>
                        if(!hostSameLivePolicySettlementDebt68(actual,debt)){throw IllegalStateException("actual Store cleanup owner changed during its checked ACK")}
                        case None=>throw IllegalStateException("actual Store cleanup owner disappeared during its checked ACK")}
                    storeAcknowledged334=true;storeDebt=None<PluginLivePolicySettlementCleanupDebt326>
                }finally{lock.unlock()}
        }
        Result<Unit>.Ok(())
    }
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
        match(requireOuterErrorConsumerRetirement331()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        // The checked helper frame ends before any Session ACK/refund.
        match(closeStoreDebt326()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        lock.lock();let selected=try{actual}finally{lock.unlock()}
        match(selected){case Some(value)=>value.closeRetainedOutput(lease)
            case None=>hostPluginResourceError("plugin.live_effect_output_unpublished","actual effect never captured this output lease")}
    }
    public func closeUnpublishedOutput():Result<Unit>{
        match(requireOuterErrorConsumerRetirement331()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        // The checked helper frame ends before any Session ACK/refund.
        match(closeStoreDebt326()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
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

// Exact resource identity only; interface value implementations cannot ACK another owner.
private func hostSameLivePolicySettlementDebt68(left:PluginLivePolicySettlementCleanupDebt326,
    right:PluginLivePolicySettlementCleanupDebt326):Bool{
    match(left as Object){case Some(leftObject)=>match(right as Object){
        case Some(rightObject)=>refEq(leftObject,rightObject)
        case None=>false}
        case None=>false}
}
