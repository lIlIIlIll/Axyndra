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
    func prepareTrustedControlOperation(
        operationId: OperationId,
        runId: RunId,
        toolCallItemId: ItemId,
        plan: NormalizedOperationPlan
    ): Result<Unit>
    func prepareDerivedOperation(
        operationId: OperationId,
        parentOperationId: OperationId,
        runId: RunId,
        rootToolCall: CommittedToolCallRef,
        requestKey: String,
        plan: NormalizedOperationPlan
    ): Result<OperationId>
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
    func settleDerivedOperation(
        runId: RunId,
        parentOperationId: OperationId,
        receipt: VNextOperationReceipt
    ): Result<Unit> {
        let _ = runId
        let _ = parentOperationId
        let _ = receipt
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "operation.derived_settlement_unavailable",
            "the Operation runtime cannot persist derived receipts"
        ))
    }
    func loadDerivedOperationReceipt(
        operationId: OperationId,
        runId: RunId
    ): Result<?VNextOperationReceipt> {
        let _ = operationId
        let _ = runId
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "operation.derived_receipt_unavailable",
            "the Operation runtime cannot load derived receipts"
        ))
    }
    func loadDerivedOperationState(
        operationId: OperationId,
        runId: RunId
    ): Result<String> {
        let _ = operationId
        let _ = runId
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "operation.derived_state_unavailable",
            "the Operation runtime cannot inspect derived handoff state"
        ))
    }
}
class MemoryOperationPlanEntry {
    let operationId: OperationId
    let runId: RunId
    let plan: NormalizedOperationPlan
    var call: ?ToolCall
    var toolCallItemId: ?ItemId
    let rootToolCall: ?CommittedToolCallRef
    let parentOperationId: ?OperationId
    let requestKey: ?String
    let callSequence: Int64
    var handoffCommitted: Bool = false
    var state: String = "prepared"

    init(
        operationId: OperationId,
        runId: RunId,
        plan: NormalizedOperationPlan,
        call!: ?ToolCall = None,
        toolCallItemId!: ?ItemId = None,
        rootToolCall!: ?CommittedToolCallRef = None,
        parentOperationId!: ?OperationId = None,
        requestKey!: ?String = None,
        callSequence!: Int64 = 0
    ) {
        this.operationId = operationId
        this.runId = runId
        this.plan = plan
        this.call = call
        this.toolCallItemId = toolCallItemId
        this.rootToolCall = rootToolCall
        this.parentOperationId = parentOperationId
        this.requestKey = requestKey
        this.callSequence = callSequence
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

class MemoryDerivedOperationReceiptEntry {
    let operationId: OperationId
    let runId: RunId
    let parentOperationId: OperationId
    let receipt: VNextOperationReceipt

    init(
        operationId: OperationId,
        runId: RunId,
        parentOperationId: OperationId,
        receipt: VNextOperationReceipt
    ) {
        this.operationId = operationId
        this.runId = runId
        this.parentOperationId = parentOperationId
        this.receipt = receipt
    }
}

public class InMemoryOperationRuntimePort <: OperationRuntimePort {
    private let lock = Mutex()
    public var executions: Int64 = 0
    private let executedOperationIds = ArrayList<String>()
    private let committedResults = ArrayList<MemoryCommittedToolResultEntry>()
    private let derivedReceipts = ArrayList<MemoryDerivedOperationReceiptEntry>()
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
                    plan.toolName,
                    plan.canonicalArguments
                )),
                toolCallItemId: Some(toolCall.canonicalItemId),
                rootToolCall: Some(toolCall)
            ))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }
    public func prepareTrustedControlOperation(
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

    public func prepareDerivedOperation(
        operationId: OperationId,
        parentOperationId: OperationId,
        runId: RunId,
        rootToolCall: CommittedToolCallRef,
        requestKey: String,
        plan: NormalizedOperationPlan
    ): Result<OperationId> {
        if (requestKey.trimAscii() == "" || operationId.value == parentOperationId.value ||
            rootToolCall.block.name != "run_program" || plan.toolName == "run_program" ||
            plan.effectClass != OperationEffectClass.ReadOnly) {
            return operationPortConflict(
                "operation.derived_admission_invalid",
                "derived Operation admission is invalid"
            )
        }
        lock.lock()
        try {
            var activeRoot = false
            for (entry in entries where
                entry.operationId.value == parentOperationId.value &&
                entry.runId.value == runId.value) {
                let topLevel = match (entry.parentOperationId) {
                    case Some(_) => false
                    case None => true
                }
                match (entry.rootToolCall) {
                    case Some(source) =>
                        if (topLevel && entry.handoffCommitted &&
                            entry.plan.toolName == "run_program" &&
                            source.decisionId.value == rootToolCall.decisionId.value &&
                            source.scopedToolCallId.value == rootToolCall.scopedToolCallId.value &&
                            source.canonicalItemId.value == rootToolCall.canonicalItemId.value) {
                            activeRoot = true
                        }
                    case None => ()
                }
            }
            if (!activeRoot) {
                return operationPortConflict(
                    "operation.derived_parent_invalid",
                    "derived Operation parent is not an active committed run_program root"
                )
            }
            for (entry in entries) {
                let sameParent = match (entry.parentOperationId) {
                    case Some(parent) => parent.value == parentOperationId.value
                    case None => false
                }
                let sameKey = match (entry.requestKey) {
                    case Some(value) => value == requestKey
                    case None => false
                }
                if (sameParent && sameKey) {
                    if (entry.runId.value == runId.value &&
                        entry.toolCallItemId.getOrThrow().value == rootToolCall.canonicalItemId.value &&
                        entry.plan.bindingDigest == plan.bindingDigest) {
                        return Result.Ok(entry.operationId)
                    }
                    return operationPortConflict(
                        "operation.derived_request_conflict",
                        "derived request key is already bound to another plan"
                    )
                }
                if (entry.operationId.value == operationId.value) {
                    return operationPortConflict(
                        "operation.derived_identity_conflict",
                        "derived Operation ID is already in use"
                    )
                }
            }
            var nextSequence: Int64 = 1
            for (entry in entries) {
                match (entry.parentOperationId) {
                    case Some(parent) =>
                        if (parent.value == parentOperationId.value &&
                            entry.callSequence >= nextSequence) {
                            nextSequence = entry.callSequence + 1
                        }
                    case None => ()
                }
            }
            entries.add(MemoryOperationPlanEntry(
                operationId,
                runId,
                plan,
                call: Some(ToolCall(requestKey, plan.toolName, plan.canonicalArguments)),
                toolCallItemId: Some(rootToolCall.canonicalItemId),
                parentOperationId: Some(parentOperationId),
                requestKey: Some(requestKey),
                callSequence: nextSequence
            ))
            Result.Ok(operationId)
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
                    for (entry in entries where entry.operationId.value == operationId.value &&
                        entry.runId.value == runId.value) {
                        entry.state = "executing"
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
        lock.lock()
        try {
            var isExecuting = false
            for (executedId in executedOperationIds where executedId == operationId.value) {
                isExecuting = true
            }
            if (!isExecuting) {
                return operationPortConflict(
                    "operation.handoff_without_execution",
                    "Operation cannot hand off before execution preparation"
                )
            }
            for (entry in entries where entry.operationId.value == operationId.value) {
                if (entry.runId.value != runId.value) {
                    return operationPortConflict(
                        "operation.handoff_run_mismatch",
                        "Operation belongs to another Run"
                    )
                }
                entry.handoffCommitted = true
                return Result.Ok(())
            }
            operationPortConflict("operation.not_found", "Operation plan was not prepared")
        } finally {
            lock.unlock()
        }
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
    public func settleDerivedOperation(
        runId: RunId,
        parentOperationId: OperationId,
        receipt: VNextOperationReceipt
    ): Result<Unit> {
        lock.lock()
        try {
            var child: ?MemoryOperationPlanEntry = None
            var parentActive = false
            for (entry in entries) {
                if (entry.operationId.value == receipt.operationId.value &&
                    entry.runId.value == runId.value) {
                    match (entry.parentOperationId) {
                        case Some(parent) => if (parent.value == parentOperationId.value) {
                            child = Some(entry)
                        }
                        case None => ()
                    }
                }
                if (entry.operationId.value == parentOperationId.value &&
                    entry.runId.value == runId.value && entry.state == "executing") {
                    parentActive = true
                }
            }
            let selected = match (child) {
                case Some(value) => value
                case None => return operationPortConflict(
                    "operation.derived_settlement_owner_invalid",
                    "derived receipt does not belong to this parent Operation"
                )
            }
            for (existing in derivedReceipts where
                existing.operationId.value == receipt.operationId.value &&
                existing.runId.value == runId.value) {
                if (existing.parentOperationId.value == parentOperationId.value &&
                    existing.receipt.receiptId == receipt.receiptId &&
                    existing.receipt.outcome == receipt.outcome &&
                    canonicalAgentValue(existing.receipt.detail) == canonicalAgentValue(receipt.detail) &&
                    canonicalAgentValue(existing.receipt.verification) == canonicalAgentValue(receipt.verification)) {
                    return Result.Ok(())
                }
                return operationPortConflict(
                    "operation.derived_receipt_conflict",
                    "derived Operation already has another Receipt"
                )
            }
            if (!parentActive || !selected.handoffCommitted ||
                selected.state != "executing" || receipt.operationId.value != selected.operationId.value) {
                return operationPortConflict(
                    "operation.derived_settlement_state_invalid",
                    "derived Operation did not reach a live execution handoff"
                )
            }
            selected.state = match (receipt.outcome) {
                case OperationOutcome.Completed => "committed"
                case OperationOutcome.Rejected => "rejected"
                case OperationOutcome.Cancelled => "cancelled"
                case OperationOutcome.TimedOut => "timed_out"
                case OperationOutcome.Failed => "failed"
                case OperationOutcome.Unknown => "recovery_required"
            }
            derivedReceipts.add(MemoryDerivedOperationReceiptEntry(
                selected.operationId, runId, parentOperationId, receipt
            ))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func loadDerivedOperationReceipt(
        operationId: OperationId,
        runId: RunId
    ): Result<?VNextOperationReceipt> {
        lock.lock()
        try {
            for (entry in derivedReceipts where
                entry.operationId.value == operationId.value) {
                if (entry.runId.value == runId.value) {
                    return Result.Ok(Some(entry.receipt))
                }
                return operationPortConflict(
                    "tool.approval_run_mismatch",
                    "derived Receipt belongs to another Run"
                )
            }
            Result.Ok(None)
        } finally {
            lock.unlock()
        }
    }


    public func loadDerivedOperationState(
        operationId: OperationId,
        runId: RunId
    ): Result<String> {
        lock.lock()
        try {
            for (entry in entries where entry.operationId.value == operationId.value) {
                if (entry.runId.value != runId.value) {
                    return operationPortConflict(
                        "tool.approval_run_mismatch",
                        "derived Operation belongs to another Run"
                    )
                }
                if (entry.parentOperationId.isNone()) {
                    return operationPortConflict(
                        "operation.not_derived",
                        "Operation is not a derived child"
                    )
                }
                return Result.Ok(entry.state)
            }
            operationPortConflict(
                "operation.not_found",
                "derived Operation was not prepared"
            )
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
