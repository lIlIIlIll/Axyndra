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
    func prepareProgramSubOperation(
        operationId: OperationId,
        runId: RunId,
        toolCallItemId: ItemId,
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
    func loadCall(operationId: OperationId, runId: RunId): Result<ToolCall>
    func loadCommittedToolResult(
        operationId: OperationId,
        runId: RunId
    ): Result<?ToolResult>
}

class MemoryOperationPlanEntry {
    let operationId: OperationId
    let runId: RunId
    let plan: NormalizedOperationPlan
    var call: ?ToolCall
    var toolCallItemId: ?ItemId

    init(
        operationId: OperationId,
        runId: RunId,
        plan: NormalizedOperationPlan,
        call!: ?ToolCall = None,
        toolCallItemId!: ?ItemId = None
    ) {
        this.operationId = operationId
        this.runId = runId
        this.plan = plan
        this.call = call
        this.toolCallItemId = toolCallItemId
    }
}

class MemoryCommittedToolResultEntry {
    let operationId: OperationId
    let runId: RunId
    var result: ToolResult

    init(operationId: OperationId, runId: RunId, result: ToolResult) {
        this.operationId = operationId
        this.runId = runId
        this.result = result
    }
}

public class InMemoryOperationRuntimePort <: OperationRuntimePort {
    private let lock = Mutex()
    public var executions: Int64 = 0
    private let executedOperationIds = ArrayList<String>()
    private let committedResults = ArrayList<MemoryCommittedToolResultEntry>()
    // Test and diagnostics surface: counts canonical prepared Operations.
    public func preparedOperationCount(): Int64 {
        lock.lock()
        try { entries.size }
        finally { lock.unlock() }
    }
    private let entries = ArrayList<MemoryOperationPlanEntry>()

    public init() {}

    public func prepare(
        operationId: OperationId,
        runId: RunId,
        toolCall: CommittedToolCallRef,
        plan: NormalizedOperationPlan
    ): Result<Unit> {
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
            entries.add(MemoryOperationPlanEntry(
                operationId,
                runId,
                plan,
                call: Some(ToolCall(
                    toolCall.block.callId,
                    toolCall.block.name,
                    toolCall.block.arguments
                )),
                toolCallItemId: Some(toolCall.canonicalItemId)
            ))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }
    public func prepareProgramSubOperation(
        operationId: OperationId,
        runId: RunId,
        toolCallItemId: ItemId,
        plan: NormalizedOperationPlan
    ): Result<Unit> {
        lock.lock()
        try {
            for (entry in entries where entry.operationId.value == operationId.value) {
                if (entry.runId.value == runId.value &&
                    entry.plan.bindingDigest == plan.bindingDigest) {
                    match (entry.toolCallItemId) {
                        case Some(value) =>
                            if (value.value != toolCallItemId.value) {
                                return operationPortConflict(
                                    "operation.tool_call_item_conflict",
                                    "Operation is bound to another canonical ToolCall Item"
                                )
                            }
                        case None =>
                            entry.toolCallItemId = Some(toolCallItemId)
                            entry.call = Some(ToolCall(
                                operationId.value,
                                plan.toolName,
                                plan.canonicalArguments
                            ))
                    }
                    return Result.Ok(())
                }
                return operationPortConflict(
                    "operation.prepare_conflict", "Operation already has another plan"
                )
            }
            entries.add(MemoryOperationPlanEntry(
                operationId,
                runId,
                plan,
                call: Some(ToolCall(
                    operationId.value,
                    plan.toolName,
                    plan.canonicalArguments
                )),
                toolCallItemId: Some(toolCallItemId)
            ))
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
        match (loadPlan(operationId, runId)) {
            case Result.Ok(plan) => if (plan.bindingDigest == executionPlan.bindingDigest) {
                lock.lock()
                try {
                    var seen = false
                    for (value in executedOperationIds where value == operationId.value) {
                        let _ = value
                        seen = true
                        break
                    }
                    if (!seen) {
                        executedOperationIds.add(operationId.value)
                        executions += 1
                    }
                    Result.Ok(())
                } finally {
                    lock.unlock()
                }
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

    public func recordCommittedToolResult(
        operationId: OperationId,
        runId: RunId,
        result: ToolResult
    ): Result<Unit> {
        match (loadPlan(operationId, runId)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        lock.lock()
        try {
            for (entry in committedResults where
                entry.operationId.value == operationId.value &&
                entry.runId.value == runId.value) {
                entry.result = result
                return Result.Ok(())
            }
            committedResults.add(MemoryCommittedToolResultEntry(operationId, runId, result))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func loadCommittedToolResult(
        operationId: OperationId,
        runId: RunId
    ): Result<?ToolResult> {
        lock.lock()
        try {
            for (entry in committedResults where
                entry.operationId.value == operationId.value && entry.runId.value == runId.value) {
                return Result.Ok(Some(entry.result))
            }
            Result.Ok(None)
        } finally {
            lock.unlock()
        }
    }

    public func loadPlan(
        operationId: OperationId,
        runId: RunId
    ): Result<NormalizedOperationPlan> {
        lock.lock()
        var foundOperation = false
        try {
            for (entry in entries where entry.operationId.value == operationId.value) {
                foundOperation = true
                if (entry.runId.value == runId.value) {
                    return Result.Ok(entry.plan)
                }
            }
            operationPortConflict(
                if (foundOperation) { "tool.approval_run_mismatch" } else { "operation.not_found" },
                if (foundOperation) {
                    "Operation belongs to another Run"
                } else {
                    "Operation plan was not prepared"
                }
            )
        } finally {
            lock.unlock()
        }
    }
    public func loadCall(
        operationId: OperationId,
        runId: RunId
    ): Result<ToolCall> {
        lock.lock()
        var foundOperation = false
        try {
            for (entry in entries where entry.operationId.value == operationId.value) {
                foundOperation = true
                if (entry.runId.value != runId.value) {
                    continue
                }
                match (entry.call) {
                    case Some(value) => return Result.Ok(value)
                    case None => return operationPortConflict(
                        "operation.call_not_found",
                        "canonical ToolCall is not available for this Operation"
                    )
                }
            }
            operationPortConflict(
                if (foundOperation) { "tool.approval_run_mismatch" } else { "operation.not_found" },
                if (foundOperation) {
                    "Operation belongs to another Run"
                } else {
                    "Operation plan was not prepared"
                }
            )
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
