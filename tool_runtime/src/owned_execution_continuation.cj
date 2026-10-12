package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*

// Trusted in-process resource ownership, never a decoded Native result,
// Source factory, authorization callback or replacement effect executor.
// The actual ToolPipeline still independently verifies the canonical parent,
// exact pending child and current Store state before publishing or resuming.
public interface LiveToolExecutionCustody {
    // Only transient worker/loan resources are released here. Actual retained
    // input/proposal/policy/ledger reservations remain owned while waiting.
    func releaseTransient():Result<Unit>
    func close():Result<Unit>
}

// A distinct typed completion boundary. Old ToolExecutionOutcome and the
// entire existing executePrepared result path are kept unchanged.
public enum OwnedToolExecutionProgress {
    Completed(Result<ToolInvocationResult>)
    | Waiting(OwnedToolExecutionContinuation)
    | Terminal(OwnedToolTerminalCompletion)
}

enum OwnedExecutionContinuationPhase {
    Captured | ReleasingTransient | Waiting | Claimed | Consumed | Closing | ClosePending | Closed
}

// Constructor is package-private. No wire enum/string, ledger descriptor,
// ToolResult or plugin-provided cleanup claim can construct this continuation.
// Publication/current Source proof is deliberately NOT implemented by this
// resource state machine: the actual Pipeline owns those checks.
public class OwnedToolExecutionContinuation {
    public let parent:PreparedToolInvocation
    public let child:PreparedToolInvocation
    public let approval:ApprovalRequest
    private let custody:LiveToolExecutionCustody
    private let lock=Mutex()
    private var phase=OwnedExecutionContinuationPhase.Captured
    private var ownsCustody=true
    private var claimedCustodyBorrowed=false
    init(parent:PreparedToolInvocation,child:PreparedToolInvocation,approval:ApprovalRequest,
        custody:LiveToolExecutionCustody){
        this.parent=parent;this.child=child;this.approval=approval;this.custody=custody
    }
    // Called only after actual Source/state/plan/current checks. Cleanup is
    // outside this lock; a failed physical ACK preserves the same custody.
    func releaseForPublication():Result<Unit>{
        lock.lock()
        try{
            match(phase){case OwnedExecutionContinuationPhase.Captured=>phase=OwnedExecutionContinuationPhase.ReleasingTransient
                case _=>return ownedExecutionContinuationError("tool.live_continuation_phase_changed")}
        }finally{lock.unlock()}
        let released=try{custody.releaseTransient()}catch(_:Exception){
            ownedExecutionContinuationError("tool.live_continuation_cleanup_pending")}
        lock.lock()
        try{
            match(released){case Result.Err(error)=>phase=OwnedExecutionContinuationPhase.Captured;Result.Err(error)
                case Result.Ok(_)=>phase=OwnedExecutionContinuationPhase.Waiting;Result.Ok(())}
        }finally{lock.unlock()}
    }
    func awaitingDecision():Bool{
        lock.lock();try{match(phase){case OwnedExecutionContinuationPhase.Waiting=>true;case _=>false}}finally{lock.unlock()}
    }
    // Core obtains one claim only AFTER restoring the same original Run and
    // epoch. The actual Pipeline must then recheck current Source/config/pkg,
    // ceiling, approval, cancellation and complete canonical child ledger.
    func claim():Bool{
        lock.lock();try{
            match(phase){case OwnedExecutionContinuationPhase.Waiting=>phase=OwnedExecutionContinuationPhase.Claimed;true
                case _=>false}
        }finally{lock.unlock()}
    }
    // The actual executor may recover its SAME physical owner only after
    // Pipeline has claimed this continuation. No lookup or second registry
    // is introduced, and no Native value can construct this continuation.
    // The callback borrows cleanup/data custody, never Source or approval.
    // The existing Pipeline separately verifies every returned typed result.
    public func withClaimedCustody(consume:(LiveToolExecutionCustody)->Result<OwnedToolExecutionProgress>):Result<OwnedToolExecutionProgress>{
        let actual=lockClaimedCustody()
        match(actual){
            case Result.Err(error)=>Result<OwnedToolExecutionProgress>.Err(error)
            case Result.Ok(value)=>
                try{consume(value)}catch(_:Exception){
                    Result<OwnedToolExecutionProgress>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "tool.live_custody_callback_failed","claimed execution still owns its original cleanup debt"))}
        }
    }
    private func lockClaimedCustody():Result<LiveToolExecutionCustody>{
        lock.lock()
        try{
            match(phase){
                case OwnedExecutionContinuationPhase.Claimed=>
                    if(!ownsCustody || claimedCustodyBorrowed){
                        return Result<LiveToolExecutionCustody>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                            "tool.live_custody_borrowed","only one actual claimed executor may borrow this custody"))}
                    claimedCustodyBorrowed=true
                    Result<LiveToolExecutionCustody>.Ok(custody)
                case _=>Result<LiveToolExecutionCustody>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "tool.live_custody_not_claimed","custody cannot be read before the original continuation is claimed"))
            }
        }finally{lock.unlock()}
    }
    // Only rollback of an unstarted durable resume transition can release
    // this claim. Executed effects or an admitted child may never be rerun.
    func releaseUnstartedClaim():Result<Unit>{
        lock.lock();try{
            // Once the actual executor has borrowed physical custody, an
            // uncertain callback cannot be relabeled as an unstarted claim.
            if(claimedCustodyBorrowed){return ownedExecutionContinuationError("tool.live_custody_borrowed")}
            match(phase){case OwnedExecutionContinuationPhase.Claimed=>phase=OwnedExecutionContinuationPhase.Waiting;Result.Ok(())
                case _=>ownedExecutionContinuationError("tool.live_continuation_claim_changed")}
        }finally{lock.unlock()}
    }
    // A successor keeps the SAME physical Session/collector ownership.
    // The old publication cannot later close the successor's resources.
    // No decoded cleanup flag or merely equal DTO can transfer custody.
    func sameCustody(value:LiveToolExecutionCustody):Bool{sameLiveToolExecutionCustody(custody,value)}
    func finishClaimWithSuccessor(next:OwnedToolExecutionContinuation):Result<Unit>{
        if(refEq(this,next) || !refEq(parent,next.parent) || !sameLiveToolExecutionCustody(custody,next.custody) || !next.awaitingDecision()){
            return ownedExecutionContinuationError("tool.live_continuation_custody_changed")}
        lock.lock();try{
            match(phase){case OwnedExecutionContinuationPhase.Claimed=>
                ownsCustody=false;phase=OwnedExecutionContinuationPhase.Consumed;Result.Ok(())
                case _=>ownedExecutionContinuationError("tool.live_continuation_claim_changed")}
        }finally{lock.unlock()}
    }
    // Called only after the actual resume invocation returned and any next
    // typed continuation/final output was frozen into its real paid owner.
    // An in-flight claimed child cannot be closed by a concurrent Core drop.
    func finishClaim():Result<Unit>{
        lock.lock();try{
            match(phase){case OwnedExecutionContinuationPhase.Claimed=>phase=OwnedExecutionContinuationPhase.Consumed;Result.Ok(())
                case _=>ownedExecutionContinuationError("tool.live_continuation_claim_changed")}
        }finally{lock.unlock()}
    }
    // After an actual child finishes, the caller freezes/ACKs any next typed
    // continuation or final output before closing this retained custody.
    // Cancellation/rejection/upgrade also retain custody until real cleanup.
    public func close():Result<Unit>{
        lock.lock()
        try{
            if(!ownsCustody){phase=OwnedExecutionContinuationPhase.Closed;return Result.Ok(())}
            match(phase){case OwnedExecutionContinuationPhase.Closed=>return Result.Ok(())
                case OwnedExecutionContinuationPhase.ReleasingTransient | OwnedExecutionContinuationPhase.Closing |
                    OwnedExecutionContinuationPhase.Claimed=>
                    return ownedExecutionContinuationError("tool.live_continuation_cleanup_pending")
                case _=>phase=OwnedExecutionContinuationPhase.Closing}
        }finally{lock.unlock()}
        let closed=try{custody.close()}catch(_:Exception){
            ownedExecutionContinuationError("tool.live_continuation_cleanup_pending")}
        lock.lock()
        try{
            match(closed){case Result.Ok(_)=>phase=OwnedExecutionContinuationPhase.Closed;Result.Ok(())
                case Result.Err(error)=>phase=OwnedExecutionContinuationPhase.ClosePending;Result.Err(error)}
        }finally{lock.unlock()}
    }
}

func ownedExecutionContinuationError(code:String):Result<Unit>{
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired,code,
        "actual live execution continuation still owns its same prepared child and resources"))
}

// Interface values are not necessarily Objects. Only the actual reference
// class identities can share physical custody; equal fields and value copies
// never authorize a successor to release another owner's resources.
func sameLiveToolExecutionCustody(left:LiveToolExecutionCustody,right:LiveToolExecutionCustody):Bool{
    match(left as Object){case Some(leftObject)=>match(right as Object){
        case Some(rightObject)=>refEq(leftObject,rightObject)
        case None=>false}
        case None=>false}
}

// The constructor is private to this package. Only the actual invocation's
// Control can capture a terminal value; equal operation IDs or payload DTOs
// cannot be substituted for its Prepared reference and allocation lease.
class OwnedToolTerminalIdentity {init(){}}
public class OwnedToolTerminalCompletion {
    let parent:PreparedToolInvocation
    let result:ToolResult
    let dataOwner:OperationTerminalDataOwner
    private let identity:OwnedToolTerminalIdentity
    private let lease:ToolResultPayloadLease
    init(parent:PreparedToolInvocation,result:ToolResult,dataOwner:OperationTerminalDataOwner,
        identity:OwnedToolTerminalIdentity){
        this.parent=parent;this.result=result;this.dataOwner=dataOwner;this.identity=identity
        this.lease=result.payloadLease.getOrThrow()
    }
    func capturedBy(actual:OwnedToolTerminalIdentity,prepared:PreparedToolInvocation):Bool{
        refEq(identity,actual) && refEq(parent,prepared) && result.payloadLease.isSome() &&
            refEq(lease,result.payloadLease.getOrThrow()) && result.callId==prepared.call.callId &&
            result.receiptId==prepared.operationId.value
    }
}
