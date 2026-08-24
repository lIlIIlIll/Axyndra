package agent_domain

import std.collection.*

public class LaneId {
    public let value: String
    public init(value: String) { this.value = validatedIdentifier("lane", value) }
}

public class CompositionSnapshotId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("composition snapshot", value)
    }
}

public class ModelLaneSnapshotId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("model lane snapshot", value)
    }
}

public class ContextManifestId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("context manifest", value)
    }
}

public class UsageRecordId {
    public let value: String
    public init(value: String) { this.value = validatedIdentifier("usage record", value) }
}

public class ApprovalId {
    public let value: String
    public init(value: String) { this.value = validatedIdentifier("approval", value) }
}

public class InboxEntryId {
    public let value: String
    public init(value: String) { this.value = validatedIdentifier("inbox entry", value) }
}

public class ExternalHandleId {
    public let value: String
    public init(value: String) { this.value = validatedIdentifier("external handle", value) }
}

public class OwnedTaskId {
    public let value: String
    public init(value: String) { this.value = validatedIdentifier("owned task", value) }
}

public class DeferredContextId {
    public let value: String
    public init(value: String) { this.value = validatedIdentifier("deferred context", value) }
}

// A phase payload is deliberately self-contained. Recovery is forbidden from
// reconstructing omitted fields by reading the previous phase.
public class DurablePhaseState {
    public let payload: AgentValue

    public init(payload: AgentValue) {
        if (payload.kind != ValueKind.Object) {
            throw IllegalArgumentException("Run execution phase payload must be an object")
        }
        this.payload = payload
    }
}

public enum RunExecutionPhase {
    Accepted(DurablePhaseState)
    | ContextCompiling(DurablePhaseState)
    | ContextReady(DurablePhaseState)
    | ModelReady(DurablePhaseState)
    | ModelEffectPending(DurablePhaseState)
    | ModelSettling(DurablePhaseState)
    | DecisionReady(DurablePhaseState)
    | ToolBatchReady(DurablePhaseState)
    | WaitingApproval(DurablePhaseState)
    | ToolEffectPending(DurablePhaseState)
    | ToolSettling(DurablePhaseState)
    | WaitingExternal(DurablePhaseState)
    | Checkpoint(DurablePhaseState)
    | Terminalizing(DurablePhaseState)
}

public func runExecutionPhaseName(value: RunExecutionPhase): String {
    match (value) {
        case RunExecutionPhase.Accepted(_) => "accepted"
        case RunExecutionPhase.ContextCompiling(_) => "context_compiling"
        case RunExecutionPhase.ContextReady(_) => "context_ready"
        case RunExecutionPhase.ModelReady(_) => "model_ready"
        case RunExecutionPhase.ModelEffectPending(_) => "model_effect_pending"
        case RunExecutionPhase.ModelSettling(_) => "model_settling"
        case RunExecutionPhase.DecisionReady(_) => "decision_ready"
        case RunExecutionPhase.ToolBatchReady(_) => "tool_batch_ready"
        case RunExecutionPhase.WaitingApproval(_) => "waiting_approval"
        case RunExecutionPhase.ToolEffectPending(_) => "tool_effect_pending"
        case RunExecutionPhase.ToolSettling(_) => "tool_settling"
        case RunExecutionPhase.WaitingExternal(_) => "waiting_external"
        case RunExecutionPhase.Checkpoint(_) => "checkpoint"
        case RunExecutionPhase.Terminalizing(_) => "terminalizing"
    }
}

public func runExecutionPhasePayload(value: RunExecutionPhase): AgentValue {
    match (value) {
        case RunExecutionPhase.Accepted(state) => state.payload
        case RunExecutionPhase.ContextCompiling(state) => state.payload
        case RunExecutionPhase.ContextReady(state) => state.payload
        case RunExecutionPhase.ModelReady(state) => state.payload
        case RunExecutionPhase.ModelEffectPending(state) => state.payload
        case RunExecutionPhase.ModelSettling(state) => state.payload
        case RunExecutionPhase.DecisionReady(state) => state.payload
        case RunExecutionPhase.ToolBatchReady(state) => state.payload
        case RunExecutionPhase.WaitingApproval(state) => state.payload
        case RunExecutionPhase.ToolEffectPending(state) => state.payload
        case RunExecutionPhase.ToolSettling(state) => state.payload
        case RunExecutionPhase.WaitingExternal(state) => state.payload
        case RunExecutionPhase.Checkpoint(state) => state.payload
        case RunExecutionPhase.Terminalizing(state) => state.payload
    }
}

public class ToolBatchContinuation {
    public let batchId: ToolBatchId
    public let nextOperationOrdinal: Int64
    public let operationIds: Array<OperationId>

    public init(
        batchId: ToolBatchId,
        nextOperationOrdinal: Int64,
        operationIds: Array<OperationId>
    ) {
        if (nextOperationOrdinal < 0 || nextOperationOrdinal > operationIds.size ||
            !uniqueOperationIds(operationIds)) {
            throw IllegalArgumentException("tool batch continuation is invalid")
        }
        this.batchId = batchId
        this.nextOperationOrdinal = nextOperationOrdinal
        this.operationIds = operationIds
    }
}

public class ExternalWaitState {
    public let handleId: ExternalHandleId
    public let kind: String
    public let payload: AgentValue

    public init(handleId: ExternalHandleId, kind: String, payload: AgentValue) {
        if (kind.trimAscii() == "" || payload.kind != ValueKind.Object) {
            throw IllegalArgumentException("external wait state is invalid")
        }
        this.handleId = handleId
        this.kind = kind.trimAscii()
        this.payload = payload
    }
}

public class WorkDebtSnapshot {
    public let unclaimedInputs: Array<InboxEntryId>
    public let activeAttempts: Array<ModelAttemptId>
    public let uncommittedDecisions: Array<ModelDecisionId>
    public let unsettledOperations: Array<OperationId>
    public let pendingApprovals: Array<ApprovalId>
    public let waitingExternal: Array<ExternalHandleId>
    public let activeChildRuns: Array<RunId>
    public let ownedTasks: Array<OwnedTaskId>
    public let deferredContexts: Array<DeferredContextId>

    public init(
        unclaimedInputs!: Array<InboxEntryId> = [],
        activeAttempts!: Array<ModelAttemptId> = [],
        uncommittedDecisions!: Array<ModelDecisionId> = [],
        unsettledOperations!: Array<OperationId> = [],
        pendingApprovals!: Array<ApprovalId> = [],
        waitingExternal!: Array<ExternalHandleId> = [],
        activeChildRuns!: Array<RunId> = [],
        ownedTasks!: Array<OwnedTaskId> = [],
        deferredContexts!: Array<DeferredContextId> = []
    ) {
        requireUniqueWorkDebt(unclaimedInputs, {value => value.value}, "unclaimed input")
        requireUniqueWorkDebt(activeAttempts, {value => value.value}, "active attempt")
        requireUniqueWorkDebt(uncommittedDecisions, {value => value.value}, "decision")
        requireUniqueWorkDebt(unsettledOperations, {value => value.value}, "operation")
        requireUniqueWorkDebt(pendingApprovals, {value => value.value}, "approval")
        requireUniqueWorkDebt(waitingExternal, {value => value.value}, "external wait")
        requireUniqueWorkDebt(activeChildRuns, {value => value.value}, "child Run")
        requireUniqueWorkDebt(ownedTasks, {value => value.value}, "owned task")
        requireUniqueWorkDebt(deferredContexts, {value => value.value}, "deferred context")
        this.unclaimedInputs = unclaimedInputs
        this.activeAttempts = activeAttempts
        this.uncommittedDecisions = uncommittedDecisions
        this.unsettledOperations = unsettledOperations
        this.pendingApprovals = pendingApprovals
        this.waitingExternal = waitingExternal
        this.activeChildRuns = activeChildRuns
        this.ownedTasks = ownedTasks
        this.deferredContexts = deferredContexts
    }

    public func isEmpty(): Bool {
        unclaimedInputs.isEmpty() && activeAttempts.isEmpty() &&
            uncommittedDecisions.isEmpty() && unsettledOperations.isEmpty() &&
            pendingApprovals.isEmpty() && waitingExternal.isEmpty() &&
            activeChildRuns.isEmpty() && ownedTasks.isEmpty() && deferredContexts.isEmpty()
    }
}

// The schema version is intentionally V1 even though the legacy product
// continuation JSON has its own unrelated version history.
public class DurableRunContinuationV1 {
    public let schemaVersion: UInt32 = 1u32
    public let runId: RunId
    public let laneId: LaneId
    public let turnId: SemanticTurnId
    public let stepOrdinal: Int64
    public let phase: RunExecutionPhase
    public let compositionSnapshotId: CompositionSnapshotId
    public let modelLaneSnapshotId: ModelLaneSnapshotId
    public let contextManifestId: ?ContextManifestId
    public let semanticRequestId: ?SemanticModelRequestId
    public let attemptId: ?ModelAttemptId
    public let reservedDecisionId: ?ModelDecisionId
    public let reservedUsageId: ?UsageRecordId
    public let reservedItemIds: Array<ItemId>
    public let toolBatch: ?ToolBatchContinuation
    public let pendingOperationId: ?OperationId
    public let pendingApprovalId: ?ApprovalId
    public let waitingExternal: ?ExternalWaitState
    public let workDebt: WorkDebtSnapshot
    public let recoveryPolicyVersion: UInt32
    public let digest: String

    public init(
        runId: RunId,
        laneId: LaneId,
        turnId: SemanticTurnId,
        stepOrdinal: Int64,
        phase: RunExecutionPhase,
        compositionSnapshotId: CompositionSnapshotId,
        modelLaneSnapshotId: ModelLaneSnapshotId,
        contextManifestId!: ?ContextManifestId = None,
        semanticRequestId!: ?SemanticModelRequestId = None,
        attemptId!: ?ModelAttemptId = None,
        reservedDecisionId!: ?ModelDecisionId = None,
        reservedUsageId!: ?UsageRecordId = None,
        reservedItemIds!: Array<ItemId> = [],
        toolBatch!: ?ToolBatchContinuation = None,
        pendingOperationId!: ?OperationId = None,
        pendingApprovalId!: ?ApprovalId = None,
        waitingExternal!: ?ExternalWaitState = None,
        workDebt!: WorkDebtSnapshot = WorkDebtSnapshot(),
        recoveryPolicyVersion!: UInt32 = 1u32,
        digest!: String = ""
    ) {
        if (stepOrdinal < 0 || recoveryPolicyVersion == 0u32 ||
            !uniqueItemIds(reservedItemIds) ||
            (digest != "" && !isLowerHexDigest(digest))) {
            throw IllegalArgumentException("durable Run continuation is invalid")
        }
        this.runId = runId
        this.laneId = laneId
        this.turnId = turnId
        this.stepOrdinal = stepOrdinal
        this.phase = phase
        this.compositionSnapshotId = compositionSnapshotId
        this.modelLaneSnapshotId = modelLaneSnapshotId
        this.contextManifestId = contextManifestId
        this.semanticRequestId = semanticRequestId
        this.attemptId = attemptId
        this.reservedDecisionId = reservedDecisionId
        this.reservedUsageId = reservedUsageId
        this.reservedItemIds = reservedItemIds
        this.toolBatch = toolBatch
        this.pendingOperationId = pendingOperationId
        this.pendingApprovalId = pendingApprovalId
        this.waitingExternal = waitingExternal
        this.workDebt = workDebt
        this.recoveryPolicyVersion = recoveryPolicyVersion
        this.digest = digest
    }

    public func isSealed(): Bool { isLowerHexDigest(digest) }
}

func requireUniqueWorkDebt<T>(values: Array<T>, id: (T) -> String, kind: String): Unit {
    let seen = HashSet<String>()
    for (value in values) {
        let key = id(value)
        if (seen.contains(key)) {
            throw IllegalArgumentException("duplicate " + kind + " work debt")
        }
        seen.add(key)
    }
}

func uniqueOperationIds(values: Array<OperationId>): Bool {
    let seen = HashSet<String>()
    for (value in values) {
        if (seen.contains(value.value)) { return false }
        seen.add(value.value)
    }
    true
}

func uniqueItemIds(values: Array<ItemId>): Bool {
    let seen = HashSet<String>()
    for (value in values) {
        if (seen.contains(value.value)) { return false }
        seen.add(value.value)
    }
    true
}

func isLowerHexDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102))) {
            return false
        }
    }
    true
}
