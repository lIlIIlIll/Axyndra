package tool_runtime

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Private-constructor routing object, minted only by the actual Pipeline
// after same-transaction pending proof and real physical cleanup succeeded.
// This has no wire decoder, Source factory, effect grant or cleanup callback.
public class OwnedToolExecutionPublication {
    private let legacyContinuation:?OwnedToolExecutionContinuation
    public let preparedPhase:?OwnedPreparedWaitingPhase
    public prop continuation:OwnedToolExecutionContinuation{get(){
        match(legacyContinuation){case Some(value)=>value;case None=>
            throw IllegalStateException("paid prepared phase has no public raw continuation")}
    }}
    public let runId:RunId
    public let threadId:ThreadId
    public let laneId:LaneId
    public let epoch:Int64
    public let parentOperationId:OperationId
    public let childOperationId:OperationId
    public let parentCallId:String
    public let childCallId:String
    public let projectionDigest:String
    public let parentPlanDigest:String
    public let childPlanDigest:String
    public let approvalArgumentHash:String
    init(context:ToolInvocationContext,value:OwnedToolExecutionContinuation){
        this.legacyContinuation=Some(value);this.preparedPhase=None<OwnedPreparedWaitingPhase>;this.runId=context.runId;this.threadId=ThreadId(context.sessionId.value);this.epoch=context.epoch
        let binding=value.parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        this.laneId=LaneId(httpIntentText(binding,"lane_id"))
        this.parentOperationId=value.parent.operationId;this.childOperationId=value.child.operationId
        this.parentCallId=value.parent.call.callId;this.childCallId=value.child.call.callId
        this.projectionDigest=contextReadProjectionDigest(context.contextProjection)
        this.parentPlanDigest=value.parent.operationPlan.bindingDigest;this.childPlanDigest=value.child.operationPlan.bindingDigest
        this.approvalArgumentHash=value.approval.argumentHash
    }
    init(context:ToolInvocationContext,phase:OwnedPreparedWaitingPhase,value:OwnedToolExecutionContinuation){
        this.legacyContinuation=None<OwnedToolExecutionContinuation>;this.preparedPhase=Some(phase);this.runId=context.runId;this.threadId=ThreadId(context.sessionId.value);this.epoch=context.epoch
        let binding=value.parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        this.laneId=LaneId(httpIntentText(binding,"lane_id"))
        this.parentOperationId=value.parent.operationId;this.childOperationId=value.child.operationId
        this.parentCallId=value.parent.call.callId;this.childCallId=value.child.call.callId
        this.projectionDigest=contextReadProjectionDigest(context.contextProjection)
        this.parentPlanDigest=value.parent.operationPlan.bindingDigest;this.childPlanDigest=value.child.operationPlan.bindingDigest
        this.approvalArgumentHash=value.approval.argumentHash
    }
    public func isPreparedPhase():Bool{preparedPhase.isSome()}
    public func preparedParent():Result<PreparedToolInvocation>{
        match(preparedPhase){case Some(value)=>value.pendingParent();case None=>Result.Ok(continuation.parent)}
    }
    public func withPreparedApproval<T>(consume:(ApprovalRequest)->Result<T>):Result<T>{
        match(preparedPhase){case Some(value)=>value.withPendingApproval(consume)
            case None=>consume(continuation.approval)}
    }
    public func matchesPreparedParent(context:ToolInvocationContext,parent:PreparedToolInvocation,approval:ApprovalRequest):Bool{
        let phase=match(preparedPhase){case Some(value)=>value;case None=>return false}
        let value=match(phase.pendingProof()){case Result.Ok(actual)=>actual;case Result.Err(_)=>return false}
        matchesContext(context) && refEq(value.parent,parent) && sameRetainedOwnedApproval(value.approval,approval)
    }
    private func preparedContextMatches(context:ToolInvocationContext):Bool{
        let phase=preparedPhase.getOrThrow()
        let value=match(phase.pendingProof()){case Result.Ok(actual)=>actual;case Result.Err(_)=>return false}
        runId.value==context.runId.value && threadId.value==context.sessionId.value && epoch==context.epoch &&
            projectionDigest==contextReadProjectionDigest(context.contextProjection) &&
            value.parent.operationId.value==parentOperationId.value && value.child.operationId.value==childOperationId.value &&
            value.parent.call.callId==parentCallId && value.child.call.callId==childCallId &&
            value.parent.operationPlan.bindingDigest==parentPlanDigest && value.child.operationPlan.bindingDigest==childPlanDigest &&
            value.approval.operationId.value==childOperationId.value && value.approval.callId==childCallId &&
            value.approval.argumentHash==approvalArgumentHash
    }
    // Pure routing comparison only. The caller repeats the actual Store,
    // Source, registry/current config, capability and cancellation proof first.
    public func matchesContext(context:ToolInvocationContext):Bool{
        if(preparedPhase.isSome()){return preparedContextMatches(context)}
        runId.value==context.runId.value && threadId.value==context.sessionId.value && epoch==context.epoch &&
            projectionDigest==contextReadProjectionDigest(context.contextProjection) &&
            continuation.parent.operationId.value==parentOperationId.value && continuation.child.operationId.value==childOperationId.value &&
            continuation.parent.call.callId==parentCallId && continuation.child.call.callId==childCallId &&
            continuation.parent.operationPlan.bindingDigest==parentPlanDigest && continuation.child.operationPlan.bindingDigest==childPlanDigest &&
            continuation.approval.operationId.value==childOperationId.value && continuation.approval.callId==childCallId &&
            continuation.approval.argumentHash==approvalArgumentHash
    }
}
