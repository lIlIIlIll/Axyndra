package tool_runtime

import agent_domain.*
import agent_runtime.*

// Actual typed installed executor. This data phase selection is never a
// Native flag/DTO, Source, approval or substitute durable authority.
public enum OwnedPreparedPhaseProgress {
    Legacy(OwnedToolExecutionProgress) | Waiting(OwnedPreparedWaitingPhase)
}
public interface OwnedPreparedPhaseExecutor <: OwnedToolExecutor & OwnedPreparedReferenceExecutor {
    func executePreparedPhase(context:ToolInvocationContext,parent:PreparedToolInvocation,
        control:OwnedToolExecutionControl):Result<OwnedPreparedPhaseProgress>
    func rejectPreparedPhase(context:ToolInvocationContext,parent:PreparedToolInvocation,
        decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<OwnedPreparedPhaseProgress>
    // Exactly one actual approved child, or the actual durable rejection.
    // The Kernel forbids another prepare/wait/terminal during this phase.
    func resumePreparedInput(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,decision:ApprovalDecision,control:OwnedToolExecutionControl,
        custody:OwnedKernelPreparedReferenceCustody):Result<Unit>
    // Called after the entire first action/control helper stack ends and
    // actual holder fields clear. Limited witness cannot unlock Host aliases,
    // authorize Native compute or close/refund independent original funding.
    // Concrete Host must still prove/pay all of its own alias/Source frames.
    func continuePreparedInput(context:ToolInvocationContext,parent:PreparedToolInvocation,
        witness:OwnedPreparedWaitingFieldsWitness,control:OwnedToolExecutionControl,
        custody:OwnedKernelPreparedReferenceCustody):Result<OwnedPreparedPhaseProgress>
}

// Private helper settlement keeps actual cleanup resources across the first
// callback frame. Neither this field nor an error is Known/Source/ACK.
class OwnedPreparedInputActionSettlement {
    var failed:?OwnedToolRetainedFailureExecution=None<OwnedToolRetainedFailureExecution>
    func retainFailure(control:OwnedToolExecutionControl,error:AgentError):Result<Unit>{
        failed=control.retainedFailure();Result.Err(error)
    }
}

// Read-only data guard. It returns no claim/Source/receipt/retirement token.
// Production MUST additionally call the existing actual frozen decision
// validator supplied below. No phase transition or cleanup occurs here.
func preflightOwnedPreparedPhaseDecision(context:ToolInvocationContext,
    publication:OwnedToolExecutionPublication,decision:ApprovalDecision,
    validateFrozen:(ApprovalRequest)->Result<Unit>):Result<Unit>{
    let phase=match(publication.preparedPhase){case Some(value)=>value
        case None=>return ownedPreparedWaitingError<Unit>("tool.prepared_phase_required")}
    let proof=match(phase.pendingProof()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    if(!publication.matchesContext(context) || !proof.awaitingDecision()){
        return ownedPreparedWaitingError<Unit>("tool.live_retained_approval_changed")}
    let plan=proof.child.operationPlan
    // Exact original validateDecisionPolicy one-time/session condition and
    // error. This early check prevents an invalid choice consuming the input.
    let approved=match(decision){
        case ApprovalDecision.Reject | ApprovalDecision.RejectWithReason(_)=>false
        case ApprovalDecision.Approve | ApprovalDecision.ApproveSession=>true}
    if(approved && match(decision){
        case ApprovalDecision.ApproveSession=>
            !networkPolicyModeIsDenied(plan.networkPolicy.mode) || !plan.approvalMetadata.sessionApprovalAllowed
        case _=>false}){
        return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
            "approval.session_scope_forbidden","this operation requires one-time approval"))}
    validateFrozen(proof.approval)
}
