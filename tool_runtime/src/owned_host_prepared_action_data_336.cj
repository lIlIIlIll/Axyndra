package tool_runtime

import agent_domain.*
import std.sync.*

// Allocation/data only. The actual Host supplies a child of its retained
// Session; no Source, decision, Known, retirement or effect is authorized.
public func ownedHostJsonOccurrenceInvoice336(backing:LogicalJsonOwnerReservation,
    first:AgentValue,second:AgentValue,third:AgentValue):Result<Int64>{
    try{
        backing.ensureRetainedPeak(8192)
        let measure=OwnedPreparedReferenceMeasure(backing,8192)
        measure.retainedJson336(first);measure.retainedJson336(second);measure.retainedJson336(third)
        let peak=measure.peak();backing.ensureRetainedPeak(peak);Result<Int64>.Ok(peak)
    }catch(_:Exception){ownedPreparedWaitingError<Int64>("tool.host_metadata_occurrence_unpaid")}
}

// This object replaces the actual Host input helper's retained child/decision/
// approval fields. Its independent full same-bank invoice is never refunded.
public class OwnedHostPreparedActionData336 {
    private let backing:LogicalJsonOwnerReservation
    private let base:Int64
    private let lock=Mutex()
    private var child:?PreparedToolInvocation
    private var decision:?ApprovalDecision
    private var approval:?ApprovalRequest
    private var acting=false
    private var consumed=false
    private var failed=false
    init(backing:LogicalJsonOwnerReservation,base:Int64,child:PreparedToolInvocation,decision:ApprovalDecision){
        this.backing=backing;this.base=base;this.child=Some(child)
        this.decision=Some(decision);this.approval=child.approval
    }
    private func inputFrame(consume:(PreparedToolInvocation,ApprovalDecision,?ApprovalRequest)->Result<Unit>):Result<Unit>{
        try{consume(child.getOrThrow(),decision.getOrThrow(),approval)}
        catch(_:Exception){ownedPreparedWaitingError<Unit>("tool.host_input_callback_failed")}
    }
    public func consumeInput336(consume:(PreparedToolInvocation,ApprovalDecision,?ApprovalRequest)->Result<Unit>):Result<Unit>{
        lock.lock();try{
            if(acting || consumed || failed || child.isNone() || decision.isNone()){
                return ownedPreparedWaitingError<Unit>("tool.host_input_phase_changed")}
            acting=true
        }finally{lock.unlock()}
        // The complete helper arguments and callback frame end first.
        let returned=inputFrame(consume)
        lock.lock();try{
            acting=false
            match(returned){case Result.Err(error)=>failed=true;Result<Unit>.Err(error)
                case Result.Ok(_)=>child=None<PreparedToolInvocation>;decision=None<ApprovalDecision>
                    approval=None<ApprovalRequest>;consumed=true;Result<Unit>.Ok(())}
        }finally{lock.unlock()}
    }
    public func retainLedgerOccurrence336(value:AgentValue):Result<Unit>{
        lock.lock();try{
            let measure=OwnedPreparedReferenceMeasure(backing,base)
            measure.retainedJson336(value);let extra=measure.peak()
            if(extra>Int64.Max-base){return ownedPreparedWaitingError<Unit>("tool.host_input_invoice_overflow")}
            backing.ensureRetainedPeak(base+extra);Result<Unit>.Ok(())
        }catch(_:Exception){ownedPreparedWaitingError<Unit>("tool.host_input_invoice_unpaid")}
        finally{lock.unlock()}
    }
    public func inputFieldsCleared336():Bool{lock.lock();try{
        consumed && !acting && !failed && child.isNone() && decision.isNone() && approval.isNone()
    }finally{lock.unlock()}}
    public func closeAfterRetirement336():Result<Unit>{
        ownedPreparedWaitingError<Unit>("tool.host_input_external_escapers_pending")}
}

public func retainOwnedHostPreparedActionData336(backing:LogicalJsonOwnerReservation,
    child:PreparedToolInvocation,decision:ApprovalDecision):Result<OwnedHostPreparedActionData336>{
    try{
        backing.ensureRetainedPeak(8192)
        let measure=OwnedPreparedReferenceMeasure(backing,8192);measure.prepared(child)
        let decisionBytes=match(decision){case ApprovalDecision.RejectWithReason(reason)=>reason.size;case _=>0}
        let measured=measure.peak()
        if(decisionBytes>Int64.Max/8 || decisionBytes*8>Int64.Max-measured){
            return ownedPreparedWaitingError<OwnedHostPreparedActionData336>("tool.host_input_invoice_overflow")}
        let peak=measured+decisionBytes*8;backing.ensureRetainedPeak(peak)
        Result.Ok(OwnedHostPreparedActionData336(backing,peak,child,decision))
    }catch(_:OwnedPreparedOpaqueReferenceError){
        ownedPreparedWaitingError<OwnedHostPreparedActionData336>("tool.host_input_opaque_source")}
    catch(_:Exception){ownedPreparedWaitingError<OwnedHostPreparedActionData336>("tool.host_input_invoice_unpaid")}
}
