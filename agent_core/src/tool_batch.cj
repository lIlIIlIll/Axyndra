package agent_core

import agent_domain.*
import agent_runtime.*
import std.collection.*
import tool_runtime.*

type CoreToolReservation = (CommittedToolCallRef) -> Result<Unit>

class CorePreparedTool {
    let index: Int64
    let block: ModelBlock
    let prepared: PreparedToolInvocation
    let committed: CommittedToolCallRef

    init(index: Int64, committed: CommittedToolCallRef, prepared: PreparedToolInvocation) {
        this.index = index
        this.block = committed.block
        this.prepared = prepared
        this.committed = committed
    }
}

class CoreToolOutcome {
    let index: Int64
    let block: ModelBlock
    let result: Result<ToolInvocationResult>
    var operationId: ?OperationId
    var operationPlan: ?NormalizedOperationPlan
    var attemptStage: OperationAttemptStage
    let committed: CommittedToolCallRef

    init(
        index: Int64,
        committed: CommittedToolCallRef,
        result: Result<ToolInvocationResult>,
        operationId!: ?OperationId = None,
        operationPlan!: ?NormalizedOperationPlan = None,
        attemptStage!: OperationAttemptStage = OperationAttemptStage.Prepared
    ) {
        this.index = index
        this.block = committed.block
        this.committed = committed
        this.result = result
        this.operationId = operationId
        this.operationPlan = operationPlan
        this.attemptStage = attemptStage
    }

    func bindOperation(
        id: OperationId,
        plan: NormalizedOperationPlan,
        stage: OperationAttemptStage
    ): Unit {
        operationId = Some(id)
        operationPlan = Some(plan)
        attemptStage = stage
    }
}

class CoreToolWave {
    let calls = ArrayList<CorePreparedTool>()
}

class CoreToolBatchPreparation {
    let waves: Array<CoreToolWave>
    let immediate: Array<CoreToolOutcome>
    let approval: ?ApprovalRequest
    let approvalPrepared: ?PreparedToolInvocation
    let approvalCall: ?CommittedToolCallRef
    let deferred: Array<CommittedToolCallRef>

    init(
        waves: Array<CoreToolWave>,
        immediate: Array<CoreToolOutcome>,
        approval: ?ApprovalRequest,
        approvalPrepared: ?PreparedToolInvocation,
        approvalCall: ?CommittedToolCallRef,
        deferred: Array<CommittedToolCallRef>
    ) {
        this.waves = waves
        this.immediate = immediate
        this.approval = approval
        this.approvalPrepared = approvalPrepared
        this.approvalCall = approvalCall
        this.deferred = deferred
    }
}

class CoreToolBatchExecution {
    let outcomes: Array<CoreToolOutcome>
    let fatal: ?AgentError

    init(outcomes: Array<CoreToolOutcome>, fatal!: ?AgentError = None) {
        this.outcomes = outcomes
        this.fatal = fatal
    }
}

class CoreToolLoopState {
    var consecutiveCapabilityDenials: Int64 = 0
    var lastCapabilityDeniedTool: String = ""
}

class CoreToolBatchCoordinator {
    private let tools: ToolPipeline

    init(tools: ToolPipeline) {
        this.tools = tools
    }

    // Preparation stops at the first approval request. Calls after that
    // barrier are deliberately not persisted as Prepared operations; they can
    // be prepared after the approval decision without creating orphan work.
    func prepare(
        context: ToolInvocationContext,
        calls: Array<CommittedToolCallRef>,
        maxConcurrent: Int64,
        reserve: CoreToolReservation
    ): Result<CoreToolBatchPreparation> {
        let ready = ArrayList<CorePreparedTool>()
        let immediate = ArrayList<CoreToolOutcome>()
        let deferred = ArrayList<CommittedToolCallRef>()
        var approval: ?ApprovalRequest = None
        var approvalPrepared: ?PreparedToolInvocation = None
        var approvalCall: ?CommittedToolCallRef = None
        var stopped = false
        for (index in 0..calls.size) {
            let committed = calls[index]
            let block = committed.block
            if (stopped) {
                deferred.add(committed)
                continue
            }
            match (reserve(committed)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            let call = ToolCall(block.callId, block.name, block.arguments)
            match (tools.prepareCommitted(context, committed)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(ToolPreparation.Ready(value)) =>
                    ready.add(CorePreparedTool(index, committed, value))
                case Result.Ok(ToolPreparation.Completed(result)) =>
                    immediate.add(CoreToolOutcome(
                        index,
                        committed,
                        Result.Ok(ToolInvocationResult.Completed(result))
                    ))
                case Result.Ok(ToolPreparation.Denied(denial)) =>
                    immediate.add(CoreToolOutcome(
                        index,
                        committed,
                        Result.Ok(ToolInvocationResult.Denied(denial))
                    ))
                case Result.Ok(ToolPreparation.NeedsApproval(value, request)) =>
                    approval = Some(request)
                    approvalPrepared = Some(value)
                    approvalCall = Some(committed)
                    stopped = true
            }
        }
        Result.Ok(CoreToolBatchPreparation(
            corePlanToolWaves(ready.toArray(), maxConcurrent),
            immediate.toArray(),
            approval,
            approvalPrepared,
            approvalCall,
            deferred.toArray()
        ))
    }

    func execute(
        context: ToolInvocationContext,
        preparation: CoreToolBatchPreparation,
        token: CancellationToken,
        beforeExecute: (CorePreparedTool) -> Result<Unit>,
        beforeWave: (Int64) -> Result<Unit>,
        afterWave: (Int64) -> Result<Unit>
    ): Result<CoreToolBatchExecution> {
        let outcomes = ArrayList<CoreToolOutcome>()
        outcomes.add(all: preparation.immediate)
        for (wave in preparation.waves) {
            if (token.isCancelled()) {
                return Result.Ok(CoreToolBatchExecution(
                    coreSortToolOutcomes(outcomes.toArray()),
                    fatal: Some(coreToolCancellationError(token))
                ))
            }
            match (beforeWave(wave.calls.size)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Ok(CoreToolBatchExecution(
                    coreSortToolOutcomes(outcomes.toArray()),
                    fatal: Some(error)
                ))
            }
            let futures = ArrayList<Future<Result<ToolInvocationResult>>>()
            for (work in wave.calls) {
                match (beforeExecute(work)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Ok(CoreToolBatchExecution(
                        coreSortToolOutcomes(outcomes.toArray()),
                        fatal: Some(error)
                    ))
                }
                futures.add(spawn {
                    try {
                        match (token.check()) {
                            case Result.Ok(_) => tools.executePrepared(context, work.prepared)
                            case Result.Err(error) => Result.Err(error)
                        }
                    } catch (_: Exception) {
                        Result.Err(AgentError(
                            AgentErrorKind.Internal,
                            "tool.executor_panicked",
                            "tool executor escaped its Result boundary",
                            fields: [
                                ErrorField("tool", work.block.name),
                                ErrorField("call_id", work.block.callId)
                            ]
                        ))
                    }
                })
            }
            for (index in 0..wave.calls.size) {
                let work = wave.calls[index]
                outcomes.add(CoreToolOutcome(
                    work.index,
                    work.committed,
                    futures[index].get(),
                    operationId: Some(work.prepared.operationId),
                    operationPlan: Some(work.prepared.operationPlan),
                    attemptStage: OperationAttemptStage.Executing
                ))
            }
            match (afterWave(wave.calls.size)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Ok(CoreToolBatchExecution(
                    coreSortToolOutcomes(outcomes.toArray()),
                    fatal: Some(error)
                ))
            }
        }
        Result.Ok(CoreToolBatchExecution(coreSortToolOutcomes(outcomes.toArray())))
    }
}

func corePlanToolWaves(
    calls: Array<CorePreparedTool>,
    maxConcurrent: Int64
): Array<CoreToolWave> {
    let waves = ArrayList<CoreToolWave>()
    let width = max(1, maxConcurrent)
    for (call in calls) {
        var placed = false
        for (wave in waves) {
            if (wave.calls.size >= width || coreWaveConflicts(wave, call)) {
                continue
            }
            wave.calls.add(call)
            placed = true
            break
        }
        if (!placed) {
            let wave = CoreToolWave()
            wave.calls.add(call)
            waves.add(wave)
        }
    }
    waves.toArray()
}

func coreWaveConflicts(wave: CoreToolWave, candidate: CorePreparedTool): Bool {
    for (existing in wave.calls where toolConcurrencyConflicts(
        existing.prepared.concurrency,
        candidate.prepared.concurrency
    )) {
        return true
    }
    false
}

func coreSortToolOutcomes(values: Array<CoreToolOutcome>): Array<CoreToolOutcome> {
    let result = ArrayList<CoreToolOutcome>()
    for (value in values) {
        result.add(value)
        var index = result.size - 1
        while (index > 0 && result[index].index < result[index - 1].index) {
            let previous = result[index - 1]
            result[index - 1] = result[index]
            result[index] = previous
            index -= 1
        }
    }
    result.toArray()
}

func coreToolCancellationError(token: CancellationToken): AgentError {
    match (token.reason()) {
        case Some(reason) => AgentError(
            if (reason.kind == CancellationReasonKind.Budget ||
                reason.kind == CancellationReasonKind.Deadline) {
                AgentErrorKind.BudgetExceeded
            } else {
                AgentErrorKind.Cancelled
            },
            reason.code,
            reason.message
        )
        case None => AgentError(
            AgentErrorKind.Cancelled,
            "run.cancelled",
            "tool batch was cancelled"
        )
    }
}
