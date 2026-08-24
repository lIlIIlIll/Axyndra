package agent_runtime

import std.collection.*
import std.sync.*
import agent_domain.*

public interface OperationRuntimePort {
    func prepare(
        operationId: OperationId,
        runId: RunId,
        toolCall: CommittedToolCallRef,
        plan: NormalizedOperationPlan
    ): Result<Unit>
    func waitForApproval(operationId: OperationId, runId: RunId): Result<Unit>
    func recordApproval(
        approvalId: String,
        operationId: OperationId,
        runId: RunId,
        reviewedPlan: NormalizedOperationPlan,
        capabilityCeiling: CapabilitySet,
        approved: Bool,
        source: String,
        expiresAtMillis: ?Int64
    ): Result<Unit>
    func markExecuting(
        operationId: OperationId,
        runId: RunId,
        executionPlan: NormalizedOperationPlan,
        nowMillis: Int64,
        approvalRequired: Bool
    ): Result<Unit>
    func markExecutionHandoff(
        operationId: OperationId,
        runId: RunId,
        threadId: ThreadId,
        observedAtMillis: Int64
    ): Result<Unit>
    func loadPlan(operationId: OperationId, runId: RunId): Result<NormalizedOperationPlan>
}

class MemoryOperationPlanEntry {
    let operationId: OperationId
    let runId: RunId
    let plan: NormalizedOperationPlan

    init(operationId: OperationId, runId: RunId, plan: NormalizedOperationPlan) {
        this.operationId = operationId
        this.runId = runId
        this.plan = plan
    }
}

public class InMemoryOperationRuntimePort <: OperationRuntimePort {
    private let lock = Mutex()
    private let entries = ArrayList<MemoryOperationPlanEntry>()

    public init() {}

    public func prepare(
        operationId: OperationId,
        runId: RunId,
        toolCall: CommittedToolCallRef,
        plan: NormalizedOperationPlan
    ): Result<Unit> {
        let _ = toolCall.canonicalItemId.value
        lock.lock()
        try {
            for (entry in entries where entry.operationId.value == operationId.value) {
                if (entry.runId.value == runId.value &&
                    entry.plan.bindingDigest == plan.bindingDigest) {
                    return Result.Ok(())
                }
                return operationPortConflict(
                    "operation.prepare_conflict", "Operation already has another plan"
                )
            }
            entries.add(MemoryOperationPlanEntry(operationId, runId, plan))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func waitForApproval(operationId: OperationId, runId: RunId): Result<Unit> {
        require(operationId, runId)
    }

    public func recordApproval(
        approvalId: String,
        operationId: OperationId,
        runId: RunId,
        reviewedPlan: NormalizedOperationPlan,
        capabilityCeiling: CapabilitySet,
        approved: Bool,
        source: String,
        expiresAtMillis: ?Int64
    ): Result<Unit> {
        let _ = approvalId
        let _ = capabilityCeiling.values
        let _ = approved
        let _ = source
        let _ = expiresAtMillis
        match (loadPlan(operationId, runId)) {
            case Result.Ok(plan) => if (plan.bindingDigest == reviewedPlan.bindingDigest) {
                Result.Ok(())
            } else {
                operationPortConflict(
                    "operation.approval_plan_drift", "approved Operation plan changed"
                )
            }
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func markExecuting(
        operationId: OperationId,
        runId: RunId,
        executionPlan: NormalizedOperationPlan,
        nowMillis: Int64,
        approvalRequired: Bool
    ): Result<Unit> {
        let _ = nowMillis
        let _ = approvalRequired
        match (loadPlan(operationId, runId)) {
            case Result.Ok(plan) => if (plan.bindingDigest == executionPlan.bindingDigest) {
                Result.Ok(())
            } else {
                operationPortConflict(
                    "operation.execution_plan_drift", "executed Operation plan changed"
                )
            }
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func markExecutionHandoff(
        operationId: OperationId,
        runId: RunId,
        threadId: ThreadId,
        observedAtMillis: Int64
    ): Result<Unit> {
        let _ = threadId.value
        let _ = observedAtMillis
        require(operationId, runId)
    }

    public func loadPlan(
        operationId: OperationId,
        runId: RunId
    ): Result<NormalizedOperationPlan> {
        lock.lock()
        try {
            for (entry in entries where entry.operationId.value == operationId.value &&
                entry.runId.value == runId.value) {
                return Result.Ok(entry.plan)
            }
            operationPortConflict("operation.not_found", "Operation plan was not prepared")
        } finally {
            lock.unlock()
        }
    }

    private func require(operationId: OperationId, runId: RunId): Result<Unit> {
        match (loadPlan(operationId, runId)) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }
}

func operationPortConflict<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, code, message))
}
