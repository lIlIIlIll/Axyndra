package agent_runtime

import agent_domain.*
import yjson.*
import yjson_support.*

// Read preparation retains only immutable Run identity and prompt projection.
// It never carries a ModelLane/catalog graph or a model-view ownership share.
// The existing private ContextReadSeal and live owner validator remain the
// authority boundary; this DATA class provides no action or permission.
public class ActiveRunIdentitySnapshot159 {
    public let threadId: ThreadId
    public let turnId: SemanticTurnId
    public let runId: RunId
    public let epoch: Int64
    public let contextSnapshot: InvocationContextProjection
    public let state: RunState
    public let transitionSequence: Int64
    public let executionLaneId: LaneId
    init(threadId: ThreadId, turnId: SemanticTurnId, runId: RunId, epoch: Int64,
        contextSnapshot: InvocationContextProjection, state: RunState,
        transitionSequence: Int64, executionLaneId: LaneId) {
        this.threadId = threadId; this.turnId = turnId; this.runId = runId
        this.epoch = epoch; this.contextSnapshot = contextSnapshot; this.state = state
        this.transitionSequence = transitionSequence; this.executionLaneId = executionLaneId
    }
}

class ContextReadSeal {}

// Only the active Runtime owner mints this. No parser or recovery constructor
// exists. It identifies a preparation window, never filesystem permission.
public class ContextReadAdmission {
    public let run: ActiveRunIdentitySnapshot159
    public let ownerNamespace: String
    public let packageDigest: String
    public let configurationDigest: String
    public let requestId: String
    public let parentCallItemId: String
    public let parentKind: String
    public let parentOperationId: String
    public let parentDecisionId: String
    public let parentScopedCallId: String
    let seal: ContextReadSeal
    let validateOwner: () -> Result<Unit>
    private let inputJson: String
    private let callId: String

    init(run: ActiveRunIdentitySnapshot159, ownerNamespace: String, packageDigest: String,
        configurationDigest: String, requestId: String, parentCallItemId: String,
        parentDecisionId: String, parentScopedCallId: String, parentKind: String, parentOperationId: String, call: ToolCall, seal: ContextReadSeal, validateOwner: () -> Result<Unit>) {
        this.run = run; this.ownerNamespace = ownerNamespace; this.packageDigest = packageDigest
        this.configurationDigest = configurationDigest; this.requestId = requestId
        this.parentKind = parentKind; this.parentOperationId = parentOperationId; this.parentCallItemId = parentCallItemId; this.parentDecisionId = parentDecisionId; this.parentScopedCallId = parentScopedCallId; this.seal = seal; this.validateOwner = validateOwner
        this.inputJson = stringifyUnifiedJson(call.arguments); this.callId = call.callId
    }
    public func validateLive(): Result<Unit> { validateOwner() }
    func matchesCallIdentity(call: ToolCall): Bool { call.name == HOST_CONTEXT_READ_TOOL && call.callId == callId }
    public func matchesInput(call: ToolCall): Bool {
        call.name == HOST_CONTEXT_READ_TOOL && call.callId == callId &&
            canonicalAgentValue(call.arguments) == canonicalAgentValue(parseUnifiedJson(inputJson, maxBytes: 65536))
    }
    public func matchesCanonicalOrigin(value: DirectCallOrigin, plan: NormalizedOperationPlan): Bool {
        isContextReadPlan(plan) && sameDirectCallOrigin(value, DirectCallOrigin.ContextRead(origin(plan)))
    }
    func origin(plan: NormalizedOperationPlan): ContextReadOrigin {
        ContextReadOrigin(ownerNamespace, packageDigest, configurationDigest,
            contextReadProjectionDigest(run.contextSnapshot), contextReadPlanDigest(plan), requestId, parentCallItemId,
            parentDecisionId: parentDecisionId, parentScopedCallId: parentScopedCallId,
            parentKind: parentKind, parentOperationId: parentOperationId)
    }
}

class ContextReadGuard {
    let admission: ContextReadAdmission
    let origin: ContextReadOrigin
    let callDigest: String
    init(admission: ContextReadAdmission, plan: NormalizedOperationPlan, call: ToolCall) {
        this.admission = admission; this.origin = admission.origin(plan); this.callDigest = externalToolCallDigest(call)
    }
    func validate(call: ToolCall): Result<Unit> {
        if (call.name != HOST_CONTEXT_READ_TOOL || externalToolCallDigest(call) != callDigest) {
            return contextReadDenied("context.read_source_mutated")
        }
        admission.validateLive()
    }
    func validatePlan(plan: NormalizedOperationPlan): Result<Unit> {
        if (!isContextReadPlan(plan) || contextReadPlanDigest(plan) != origin.readPlanDigest) {
            return contextReadDenied("context.read_plan_changed")
        }
        admission.validateLive()
    }
}

func contextReadDenied<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, code,
        "context read requires its exact live Run, source, projection and read-only plan"))
}
