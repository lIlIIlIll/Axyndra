package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*

// Actual mutable Kernel waiting-input fields. No public raw Prepared/plan/
// approval getters. This does NOT replace the old immutable Waiting route,
// claim a durable decision, execute an effect or unlock Host metadata.
// Original adopted full-input funding stays alive after these fields clear.
enum OwnedPreparedWaitingFieldPhase { Captured | Acting | Consumed | Failed }

public class OwnedPreparedWaitingFieldsWitness {
    private let actual:OwnedPreparedWaitingPhase
    private init(actual:OwnedPreparedWaitingPhase){this.actual=actual}
    static func issue(actual:OwnedPreparedWaitingPhase):Result<OwnedPreparedWaitingFieldsWitness>{
        if(!actual.fieldsCleared()){
            return ownedPreparedWaitingError<OwnedPreparedWaitingFieldsWitness>("tool.prepared_waiting_fields_live")}
        Result.Ok(OwnedPreparedWaitingFieldsWitness(actual))
    }
    // Actual private phase/funding/reference identity only. No new issuer,
    // Source, approval, global Host retirement or invoice refund.
    public func claimHostWaitingScope336(custody:OwnedKernelPreparedReferenceCustody,
        debt:OwnedKernelPreparedReferenceDebt):Bool{actual.claimHostWaitingScope336(custody,debt)}
    public func matchesHostWaitingScope336(custody:OwnedKernelPreparedReferenceCustody,
        debt:OwnedKernelPreparedReferenceDebt):Bool{actual.matchesHostWaitingScope336(custody,debt)}
    public func isKernelInputFieldsCleared():Bool{actual.fieldsCleared()}
}

public class OwnedPreparedWaitingPhase {
    private let lock=Mutex()
    // Permanent parent/source/context/callback/Host and unknown public
    // escapers remain independently OPEN. The actual same-bank adopted
    // debt is deliberately never closed or relabeled as fully retired here.
    private let funding:OwnedKernelPreparedReferenceDebt
    private let actualCustody:OwnedKernelPreparedReferenceCustody
    private var proof:?OwnedToolExecutionContinuation
    private var child:?PreparedToolInvocation
    private var approval:?ApprovalRequest
    private var state=OwnedPreparedWaitingFieldPhase.Captured
    private var hostScopeClaimed336=false
    private var borrowers:Int64=0
    init(proof:OwnedToolExecutionContinuation,funding:OwnedKernelPreparedReferenceDebt,
        custody:OwnedKernelPreparedReferenceCustody){
        this.funding=funding;this.actualCustody=custody;this.proof=Some(proof)
        this.child=Some(proof.child);this.approval=Some(proof.approval)
    }
    func pendingProof():Result<OwnedToolExecutionContinuation>{
        lock.lock();try{
            if(!(match(state){case OwnedPreparedWaitingFieldPhase.Captured=>true;case _=>false}) || borrowers!=0 || proof.isNone()){
                return ownedPreparedWaitingError<OwnedToolExecutionContinuation>("tool.prepared_waiting_phase_changed")}
            Result.Ok(proof.getOrThrow())
        }finally{lock.unlock()}
    }
    func inputCustody():OwnedKernelPreparedReferenceCustody{actualCustody}
    func actingProof():Result<OwnedToolExecutionContinuation>{
        lock.lock();try{
            if(!(match(state){case OwnedPreparedWaitingFieldPhase.Acting=>true;case _=>false}) || borrowers!=1 || proof.isNone()){
                return ownedPreparedWaitingError<OwnedToolExecutionContinuation>("tool.prepared_waiting_phase_changed")}
            Result.Ok(proof.getOrThrow())
        }finally{lock.unlock()}
    }
    // Parent is already the independently held original Core work. This
    // loan does not retire that permanent Source/data owner or refund debt.
    func pendingParent():Result<PreparedToolInvocation>{
        match(pendingProof()){case Result.Err(error)=>Result.Err(error);case Result.Ok(value)=>Result.Ok(value.parent)}
    }
    func withPendingApproval<T>(consume:(ApprovalRequest)->Result<T>):Result<T>{
        match(pendingProof()){case Result.Err(error)=>Result.Err(error);case Result.Ok(value)=>consume(value.approval)}
    }
    private func enter():Result<Unit>{
        lock.lock();try{
            match(state){case OwnedPreparedWaitingFieldPhase.Captured=>()
                case _=>return ownedPreparedWaitingError<Unit>("tool.prepared_waiting_phase_changed")}
            if(proof.isNone() || child.isNone() || approval.isNone() || borrowers!=0 ||
                !funding.matchesCustody(actualCustody)){
                return ownedPreparedWaitingError<Unit>("tool.prepared_waiting_fields_changed")}
            state=OwnedPreparedWaitingFieldPhase.Acting;borrowers=1;Result.Ok(())
        }finally{lock.unlock()}
    }
    // This lexical helper ends, INCLUDING its complete Prepared/approval
    // arguments and callback frame, before the caller clears holder fields.
    // A callback returning does not prove arbitrary external aliases died;
    // the witness below therefore cannot refund/unlock/retire those aliases.
    private func inputFrame(consume:(PreparedToolInvocation,ApprovalRequest)->Result<Unit>):Result<Unit>{
        try{consume(child.getOrThrow(),approval.getOrThrow())}
        catch(_:Exception){ownedPreparedWaitingError<Unit>("tool.prepared_waiting_callback_failed")}
        finally{lock.lock();try{borrowers=0}finally{lock.unlock()}}
    }
    public func consumeInputPhase(consume:(PreparedToolInvocation,ApprovalRequest)->Result<Unit>):Result<OwnedPreparedWaitingFieldsWitness>{
        match(enter()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let result=inputFrame(consume)
        lock.lock();try{
            match(result){
                case Result.Err(error)=>
                    state=OwnedPreparedWaitingFieldPhase.Failed
                    // Uncertain callback/physical effects keep EVERY actual
                    // field and funding. Never replay action or mint witness.
                    return Result.Err(error)
                case Result.Ok(_)=>()
            }
            if(borrowers!=0 || proof.isNone() || child.isNone() || approval.isNone()){
                state=OwnedPreparedWaitingFieldPhase.Failed
                return ownedPreparedWaitingError<OwnedPreparedWaitingFieldsWitness>("tool.prepared_waiting_fields_live")}
            child=None<PreparedToolInvocation>;approval=None<ApprovalRequest>
            proof=None<OwnedToolExecutionContinuation>;state=OwnedPreparedWaitingFieldPhase.Consumed
        }finally{lock.unlock()}
        OwnedPreparedWaitingFieldsWitness.issue(this)
    }
    func fieldsCleared():Bool{lock.lock();try{
        match(state){case OwnedPreparedWaitingFieldPhase.Consumed=>borrowers==0 &&
            proof.isNone() && child.isNone() && approval.isNone();case _=>false}
    }finally{lock.unlock()}}
    // Shared by every freshly returned witness of THIS actual private
    // phase. Re-minting a fields witness cannot replay a consumed Host claim.
    func claimHostWaitingScope336(custody:OwnedKernelPreparedReferenceCustody,
        debt:OwnedKernelPreparedReferenceDebt):Bool{
        lock.lock();try{
            if(hostScopeClaimed336 || !refEq(funding,debt) || !funding.matchesCustody(custody) ||
                !sameLiveToolExecutionCustody(actualCustody,custody) || borrowers!=0 ||
                proof.isSome() || child.isSome() || approval.isSome()) {return false}
            match(state){case OwnedPreparedWaitingFieldPhase.Consumed=>hostScopeClaimed336=true;true;case _=>false}
        }finally{lock.unlock()}
    }
    func matchesHostWaitingScope336(custody:OwnedKernelPreparedReferenceCustody,
        debt:OwnedKernelPreparedReferenceDebt):Bool{
        lock.lock();try{
            !hostScopeClaimed336 && refEq(funding,debt) && funding.matchesCustody(custody) &&
                sameLiveToolExecutionCustody(actualCustody,custody) && borrowers==0 &&
                proof.isNone() && child.isNone() && approval.isNone() &&
                (match(state){case OwnedPreparedWaitingFieldPhase.Consumed=>true;case _=>false})
        }finally{lock.unlock()}
    }
    public func fieldsWitness():Result<OwnedPreparedWaitingFieldsWitness>{OwnedPreparedWaitingFieldsWitness.issue(this)}
    public func closeAfterInputRetirement():Result<Unit>{
        ownedPreparedWaitingError<Unit>("tool.prepared_waiting_independent_escapers_pending")}
}

func ownedPreparedWaitingError<T>(code:String):Result<T>{Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
    code,"actual waiting phase retains independently owned parent/source/Host aliases and funding"))}
