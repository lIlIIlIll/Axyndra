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
    let knownParentPrepared: ?PreparedToolInvocation

    init(
        index: Int64,
        committed: CommittedToolCallRef,
        result: Result<ToolInvocationResult>,
        operationId!: ?OperationId = None,
        operationPlan!: ?NormalizedOperationPlan = None,
        attemptStage!: OperationAttemptStage = OperationAttemptStage.Prepared,
        knownParentPrepared!: ?PreparedToolInvocation = None
    ) {
        this.index = index
        this.block = committed.block
        this.committed = committed
        this.result = result
        this.operationId = operationId
        this.operationPlan = operationPlan
        this.attemptStage = attemptStage
        this.knownParentPrepared = knownParentPrepared
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
    let waiting: ?CorePendingOwnedExecution
    let retained: ?CoreRetainedToolCompletion
    let failedRetained:?CoreRetainedFailureCompletion

    init(outcomes: Array<CoreToolOutcome>, fatal!: ?AgentError = None, waiting!: ?CorePendingOwnedExecution = None,
        retained!:?CoreRetainedToolCompletion=None<CoreRetainedToolCompletion>,
        failedRetained!:?CoreRetainedFailureCompletion=None<CoreRetainedFailureCompletion>) {
        this.outcomes = outcomes
        this.fatal = fatal
        this.waiting = waiting;this.retained=retained;this.failedRetained=failedRetained
    }
}

class CoreToolLoopState {
    var consecutiveCapabilityDenials: Int64 = 0
    var lastCapabilityDeniedTool: String = ""
}

class CoreToolBatchCoordinator {
    private let tools: ToolPipeline
    private let toolHooks: CoreToolHookRuntime

    init(tools: ToolPipeline, toolHooks: CoreToolHookRuntime) {
        this.tools = tools
        this.toolHooks = toolHooks
    }

    // Preparation stops at the first approval request. Calls after that
    // barrier are deliberately not persisted as Prepared operations; they can
    // be prepared after the approval decision without creating orphan work.
    func prepare(
        context: ToolInvocationContext,
        calls: Array<CommittedToolCallRef>,
        maxConcurrent: Int64,
        reserve: CoreToolReservation,
        preparationInput!: (ItemId) -> ?CorePreparationReadInput = { _ => None }
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
                case Result.Err(error) =>
                    // No effects have started. Preserve prepared operation identities
                    // and settle every canonical call, including unadmitted calls.
                    for (work in ready) {
                        immediate.add(CoreToolOutcome(
                            work.index, work.committed, Result.Err(error),
                            operationId: Some(work.prepared.operationId),
                            operationPlan: Some(work.prepared.operationPlan)
                        ))
                    }
                    for (remaining in index..calls.size) {
                        immediate.add(CoreToolOutcome(remaining, calls[remaining], Result.Err(error)))
                    }
                    return Result.Ok(CoreToolBatchPreparation(
                        [], coreSortToolOutcomes(immediate.toArray()), None, None, None, []
                    ))
            }
            var effectiveArguments = block.arguments
            let cachedInput = preparationInput(committed.canonicalItemId)
            let hookDecision = match (cachedInput) {
                case Some(value) => value.hookDecision()
                case None => try { toolHooks.beforeTool(context, committed, block.arguments) }
                    catch (_: Exception) { CoreToolHookDecision.Deny("PreToolUse handler failed; tool call denied") }
            }
            match (hookDecision) {
                case CoreToolHookDecision.Continue => ()
                case CoreToolHookDecision.Modify(arguments) => effectiveArguments = arguments
                case CoreToolHookDecision.Deny(reason) =>
                    let safeReason = if (reason.trimAscii() == "" || reason.size > 512) {
                        "PreToolUse denied the tool call"
                    } else {
                        reason
                    }
                    immediate.add(CoreToolOutcome(
                        index,
                        committed,
                        Result.Ok(ToolInvocationResult.Denied(ToolDenial(
                            block.callId,
                            block.name,
                            AgentError(
                                AgentErrorKind.PermissionDenied,
                                "tool.hook_denied",
                                safeReason
                            )
                        )))
                    ))
                    continue
            }
            match (tools.prepareCommitted(
                context,
                committed,
                effectiveArguments: Some(effectiveArguments),
                contextReadFacts: match (cachedInput) { case Some(value) => value.factLinks(); case None => [] }
            )) {
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
        afterExecute: (CorePreparedTool) -> Result<Unit>,
        beforeWave: (Int64) -> Result<Unit>,
        afterWave: (Int64) -> Result<Unit>
    ): Result<CoreToolBatchExecution> {
        let outcomes = ArrayList<CoreToolOutcome>()
        outcomes.add(all: preparation.immediate)
        for (waveIndex in 0..preparation.waves.size) {
            let wave = preparation.waves[waveIndex]
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
            if (wave.calls.size==1 && (isPluginLivePolicyParentPlan(wave.calls[0].prepared.operationPlan) || isManagedChannelOwnedParentPlan(wave.calls[0].prepared.operationPlan))) {
                let work=wave.calls[0]
                match (beforeExecute(work)) {
                    case Result.Err(error) =>
                        match (afterWave(1)) {
                            case Result.Err(releaseError) => return Result.Ok(CoreToolBatchExecution(
                                coreSortToolOutcomes(outcomes.toArray()),fatal:Some(releaseError)))
                            case Result.Ok(_) => ()
                        }
                        return Result.Ok(CoreToolBatchExecution(coreSortToolOutcomes(outcomes.toArray()),fatal:Some(error)))
                    case Result.Ok(_) => ()
                }
                // An outer Err has no verified terminal outcome. It must not
                // become a fabricated parent ToolResult or a retry authorizer.
                let handoff=CoreExecutionHandoffState()
                let progress:Result<OwnedToolPipelineProgress> = try {
                    match (token.check()) {
                        case Result.Err(error) => Result.Err(error)
                        case Result.Ok(_) => tools.executeOwnedPrepared(context,work.prepared,
                            afterHandoff:{_=>handoff.started=true;Result.Ok(())})
                    }
                } catch (_:Exception) { Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "tool.live_executor_unsettled","owned executor returned without its verified terminal or pending state")) }
                let released=try { afterExecute(work) } catch (_:Exception) {
                    Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "tool.live_slot_unsettled","owned execution slot still needs settlement")) }
                match (progress) {
                    case Result.Err(error) => return Result.Ok(CoreToolBatchExecution(
                        coreSortToolOutcomes(outcomes.toArray()),fatal:Some(match (released) {
                            case Result.Err(failure) => failure; case Result.Ok(_) => error })))
                    case Result.Ok(OwnedToolPipelineProgress.FailedRetained(result,error)) =>
                        if(result.outerErrorData333().isSome()){
                            var paidSettlement:?AgentError=None<AgentError>
                            var paymentBlocked=false
                            match(released){case Result.Err(value)=>
                                match(coreOwnedOuterErrorSource333(result)){
                                    case None=>paymentBlocked=true
                                    case Some(source)=>match(coreOwnedOuterErrorPayAlias333(source,value)){
                                        case Result.Ok(_)=>paidSettlement=Some(value);case Result.Err(_)=>paymentBlocked=true}}
                                case Result.Ok(_)=>()}
                            // Never describe the full original failure here.
                            // Its full typed data and cleanup resource reach Core.
                            return Result.Ok(CoreToolBatchExecution(coreSortToolOutcomes(outcomes.toArray()),
                                failedRetained:Some(CoreRetainedFailureCompletion(result,error,
                                    outerSettlement333:paidSettlement,outerSettlementBlocked333:paymentBlocked))))
                        }
                        return Result.Ok(CoreToolBatchExecution(coreSortToolOutcomes(outcomes.toArray()),
                            failedRetained:Some(CoreRetainedFailureCompletion(result,coreOwnedMergeSettlementError(error,
                                match(released){case Result.Err(value)=>Some(value);case Result.Ok(_)=>None})))))
                    case Result.Ok(OwnedToolPipelineProgress.Retained(result)) =>
                        let suffix=ArrayList<CoreToolWave>()
                        for(next in (waveIndex+1)..preparation.waves.size){suffix.add(preparation.waves[next])}
                        let remaining=CoreToolBatchPreparation(suffix.toArray(),[],preparation.approval,
                            preparation.approvalPrepared,preparation.approvalCall,preparation.deferred)
                        return Result.Ok(CoreToolBatchExecution(coreSortToolOutcomes(outcomes.toArray()),
                            retained:Some(CoreRetainedToolCompletion(work,result,remaining,handoff.started,
                                match(released){case Result.Err(error)=>Some(error);case Result.Ok(_)=>None}))))
                    case Result.Ok(OwnedToolPipelineProgress.RetainedWithDebt(result,error)) =>
                        let suffix=ArrayList<CoreToolWave>()
                        for(next in (waveIndex+1)..preparation.waves.size){suffix.add(preparation.waves[next])}
                        let remaining=CoreToolBatchPreparation(suffix.toArray(),[],preparation.approval,
                            preparation.approvalPrepared,preparation.approvalCall,preparation.deferred)
                        return Result.Ok(CoreToolBatchExecution(coreSortToolOutcomes(outcomes.toArray()),
                            retained:Some(CoreRetainedToolCompletion(work,result,remaining,handoff.started,
                                Some(coreOwnedMergeSettlementError(error,match(released){
                                    case Result.Err(failure)=>Some(failure);case Result.Ok(_)=>None}))))))
                    case Result.Ok(OwnedToolPipelineProgress.Completed(result)) =>
                        outcomes.add(CoreToolOutcome(work.index,work.committed,result,
                            operationId:Some(work.prepared.operationId),operationPlan:Some(work.prepared.operationPlan),
                            attemptStage:if(handoff.started){OperationAttemptStage.Executing}else{OperationAttemptStage.Prepared},
                            knownParentPrepared:if(isPluginLivePolicyParentPlan(work.prepared.operationPlan) || isManagedChannelOwnedParentPlan(work.prepared.operationPlan)){Some(work.prepared)}else{None}))
                        match (released) {
                            case Result.Err(error) => return Result.Ok(CoreToolBatchExecution(
                                coreSortToolOutcomes(outcomes.toArray()),fatal:Some(error)))
                            case Result.Ok(_) => continue
                        }
                    case Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,error)) =>
                        let known=CoreOwnedSlotProgress(Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,error)),
                            settlementError:match(released){case Result.Err(failure)=>Some(failure);case Result.Ok(_)=>None})
                        match (known.progress) {
                            case Result.Ok(OwnedToolPipelineProgress.Completed(value)) =>
                                outcomes.add(CoreToolOutcome(work.index,work.committed,value,
                                    operationId:Some(work.prepared.operationId),operationPlan:Some(work.prepared.operationPlan),
                                    attemptStage:if(handoff.started){OperationAttemptStage.Executing}else{OperationAttemptStage.Prepared},
                            knownParentPrepared:if(isPluginLivePolicyParentPlan(work.prepared.operationPlan) || isManagedChannelOwnedParentPlan(work.prepared.operationPlan)){Some(work.prepared)}else{None}))
                            case Result.Err(failure) => return Result.Ok(CoreToolBatchExecution(
                                coreSortToolOutcomes(outcomes.toArray()),fatal:Some(failure)))
                            case _ => return Result.Ok(CoreToolBatchExecution(
                                coreSortToolOutcomes(outcomes.toArray()),fatal:Some(coreOwnedLiveOwnerMissing())))
                        }
                        // Caller consumes each returned outcome through the
                        // original Parent Receipt/PostHook/output/payload ACK
                        // path before it reports this fatal physical debt.
                        return Result.Ok(CoreToolBatchExecution(coreSortToolOutcomes(outcomes.toArray()),
                            fatal:known.settlementError))
                    case Result.Ok(OwnedToolPipelineProgress.Waiting(publication)) =>
                        if (!handoff.started) { return Result.Ok(CoreToolBatchExecution(
                            coreSortToolOutcomes(outcomes.toArray()),fatal:Some(coreOwnedLiveOwnerMissing()))) }
                        match (released) {
                            case Result.Err(error) => return Result.Ok(CoreToolBatchExecution(
                                coreSortToolOutcomes(outcomes.toArray()),fatal:Some(error)))
                            case Result.Ok(_) => ()
                        }
                        let suffix=ArrayList<CoreToolWave>()
                        for (next in (waveIndex+1)..preparation.waves.size) { suffix.add(preparation.waves[next]) }
                        let remaining=CoreToolBatchPreparation(suffix.toArray(),[],preparation.approval,
                            preparation.approvalPrepared,preparation.approvalCall,preparation.deferred)
                        return Result.Ok(CoreToolBatchExecution(coreSortToolOutcomes(outcomes.toArray()),
                            waiting:Some(CorePendingOwnedExecution(CorePreparedTool(work.index,work.committed,
                                (if(publication.isPreparedPhase()){publication.preparedParent().value().getOrThrow()}else{publication.continuation.parent})),publication,remaining))))
                }
            }

            let futures = ArrayList<Future<Result<ToolInvocationResult>>>()
            var launchFailure: ?AgentError = None
            for (work in wave.calls) {
                match (beforeExecute(work)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) =>
                        launchFailure = Some(error)
                        break
                }
                futures.add(spawn {
                    let result: Result<ToolInvocationResult> = try {
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
                    var transferred = false
                    try {
                        match (afterExecute(work)) {
                            case Result.Ok(_) => transferred = true; result
                            case Result.Err(error) => Result.Err(error)
                        }
                    } catch (_: Exception) {
                        Result.Err(AgentError(AgentErrorKind.Internal, "tool.settlement_panicked",
                            "tool slot settlement escaped its Result boundary"))
                    } finally { if (!transferred) { releaseToolInvocationPayload(result) } }
                })
            }
            for (index in 0..futures.size) {
                let work = wave.calls[index]
                let result = futures[index].get()
                outcomes.add(CoreToolOutcome(
                    work.index,
                    work.committed,
                    result,
                    operationId: Some(work.prepared.operationId),
                    operationPlan: Some(work.prepared.operationPlan),
                    attemptStage: OperationAttemptStage.Executing
                ))
            }
            match (launchFailure) {
                case Some(error) =>
                    let unlaunched = wave.calls.size - futures.size
                    if (unlaunched > 0) {
                        match (afterWave(unlaunched)) {
                            case Result.Ok(_) => ()
                            case Result.Err(releaseError) => return Result.Ok(
                                CoreToolBatchExecution(
                                    coreSortToolOutcomes(outcomes.toArray()),
                                    fatal: Some(releaseError)
                                )
                            )
                        }
                    }
                    return Result.Ok(CoreToolBatchExecution(
                        coreSortToolOutcomes(outcomes.toArray()),
                        fatal: Some(error)
                    ))
                case None => ()
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
    var ownedBarrier: Int64 = 0
    for (call in calls) {
        // Only the new owned family is a serial barrier. It cannot share
        // a wave or let later calls overtake its possible suspension.
        if ((isPluginLivePolicyParentPlan(call.prepared.operationPlan) || isManagedChannelOwnedParentPlan(call.prepared.operationPlan))) {
            let wave = CoreToolWave(); wave.calls.add(call); waves.add(wave)
            ownedBarrier = waves.size; continue
        }
        // A call must follow every earlier conflicting call, even when an
        // earlier free wave has room. Independent calls can still fill holes.
        var earliest: Int64 = ownedBarrier
        for (index in 0..waves.size) {
            if (coreWaveConflicts(waves[index], call)) {
                earliest = max(earliest,index + 1)
            }
        }
        var placed = false
        for (index in earliest..waves.size) {
            let wave = waves[index]
            if (wave.calls.size >= width) { continue }
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
