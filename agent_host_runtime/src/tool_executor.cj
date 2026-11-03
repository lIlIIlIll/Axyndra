package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_ports.*
import agent_store.*
import tool_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.sync.*

class HostDirectToolSchedule {
    private let context: ToolInvocationContext
    private let runtime: AgentThreadRuntime
    private let source: DirectToolCallRef
    private let frames: NestedToolSlotFrames
    private let lock = Mutex()
    private var active = false

    init(context: ToolInvocationContext, runtime: AgentThreadRuntime, source: DirectToolCallRef) {
        this.context = context; this.runtime = runtime; this.source = source
        this.frames = NestedToolSlotFrames(source.operationId, source.call.name)
    }

    func begin(): Result<Unit> {
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (context.chargeBudget(BudgetCharge(toolCalls: 1, toolsStarted: 1))) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => lock.lock(); try { active = true } finally { lock.unlock() }
        }
        Result.Ok(())
    }

    private func releaseReturnedSlot(): Unit {
        if (!frames.takeRelease()) { return }
        lock.lock()
        let release = try { let value = active; active = false; value } finally { lock.unlock() }
        if (release) { let _ = context.budget.releaseTools() }
    }

    func frame(parent: OperationId, child: OperationId, name: String, entering: Bool): Result<Unit> {
        let result = if (entering) { frames.enter(parent, child, name) } else { frames.leave(child) }
        releaseReturnedSlot(); result
    }

    func child(parent: OperationId, action: () -> Result<Unit>): Result<Unit> {
        lock.lock()
        let current = try { active } finally { lock.unlock() }
        if (!current) { return Result.Err(AgentError(AgentErrorKind.Conflict,
            "tool.nested_parent_invalid", "nested execution does not own the active direct slot")) }
        match (frames.begin(parent)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        var activated = false
        var returned = false
        try {
            match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (runtime.attestDirectToolCall(source.canonicalItemId, source.operationId, source.runId, source.epoch)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
            }
            // Every edge charges the original ledger. No additional active
            // slot is acquired while the waiting parent gives its slot away.
            match (context.chargeBudget(BudgetCharge(toolCalls: 1))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
            }
            match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (frames.activate(parent)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => activated = true }
            let outcome = action()
            returned = true
            match (frames.returnChild(parent)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            outcome
        } finally {
            if (activated && !returned) { let _ = frames.returnChild(parent) }
            else if (!activated) { let _ = frames.restore(parent) }
            releaseReturnedSlot()
        }
    }

    func finish(): Unit { frames.finishRoot(); releaseReturnedSlot() }
}

public class HostTrustedControlToolExecutor {
    private let pipeline: ToolPipeline
    private let operations: OperationRuntimePort
    private let runtime: AgentThreadRuntime
    private let hostServiceAdmission: ?HostServiceRunAdmission
    private let externalAdmission: ?ExternalCallAdmission
    private let directPreparationOwner: ?HostDirectPreparationOwner
    private let ownedFailures113: HostOwnedCheckpointFailureQueue113
    private let ownedRuntimeRegistry204: ?SqliteThreadRuntimeRegistry

    public init(
        pipeline: ToolPipeline,
        operations: OperationRuntimePort,
        runtime: AgentThreadRuntime,
        hostServiceAdmission!: ?HostServiceRunAdmission = None,
        externalAdmission!: ?ExternalCallAdmission = None,
        directPreparationOwner!: ?HostDirectPreparationOwner = None,
        ownedFailures113!: HostOwnedCheckpointFailureQueue113 = HostOwnedCheckpointFailureQueue113(),
        ownedRuntimeRegistry204!: ?SqliteThreadRuntimeRegistry = None<SqliteThreadRuntimeRegistry>
    ) {
        this.pipeline = pipeline
        this.operations = operations
        this.runtime = runtime
        this.hostServiceAdmission = hostServiceAdmission
        this.externalAdmission = externalAdmission
        this.directPreparationOwner = directPreparationOwner
        this.ownedFailures113 = ownedFailures113
        this.ownedRuntimeRegistry204 = ownedRuntimeRegistry204
    }

    public func invokeOwnedCheckpointFailure113(context: ToolInvocationContext, call: ToolCall,
        approvalDecision!: ?ApprovalDecision = None<ApprovalDecision>): OwnedHostDirectToolResult113 {
        context.bindPaidExecutionFailureSink173(ownedFailures113)
        ownedFailures113.take(context.runId, invoke(context, call, approvalDecision: approvalDecision))
    }
    public func takeOwnedCheckpointFailure113(run: RunId): OwnedHostDirectToolResult113 {
        ownedFailures113.take(run, Result<ToolInvocationResult>.Err(hostOwnedCheckpointFailurePending113()))
    }

    public func invoke(
        context: ToolInvocationContext,
        call: ToolCall,
        approvalDecision!: ?ApprovalDecision
    ): Result<ToolInvocationResult> {
        if (approvalDecision.isSome() && pipeline.requiresSeparatePreparationDecision(context, call)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "context.read_separate_approval_required", "read-backed tools require separate frozen read and mutation reviews through Application command approval")) }
        match(pipeline.retainPreparationInput340(context,None<OperationRootSource>,call,[])){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        // Opt-in resolver is evaluated once with this actual Run/context and
        // the installed executor's existing paid input custody. Some cannot
        // borrow the caller's mutation decision; no read/parent is admitted.
        var optionalReadResolvedAbsent = false
        if (approvalDecision.isSome() && pipeline.hasPreparationRead(context, call)) {
            match (pipeline.preparationRead(context, call)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(Some(_)) => return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                    "context.read_separate_approval_required", "read-backed tools require separate frozen read and mutation reviews through Application command approval"))
                case Result.Ok(None) => optionalReadResolvedAbsent = true
            }
        }
        var effectivePreparationOwner = if (optionalReadResolvedAbsent) { Option<HostDirectPreparationOwner>.None } else { directPreparationOwner }
        if (!optionalReadResolvedAbsent && directPreparationOwner.isSome() && pipeline.hasPreparationRead(context, call)) {
            let owner = directPreparationOwner.getOrThrow()
            if (!owner.allowDeferred) {
                match (owner.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                // A pure optional resolver returning None needs only the
                // ordinary pre-parent policy review. No read owner is granted.
                let readResolution = pipeline.preparationRead(context, call)
                match (readResolution) {
                    case Result.Ok(None) => effectivePreparationOwner = None
                    case _ => return HostDirectPreparationFlow(pipeline, operations, runtime, this,
                        owner, context, call).start(readResolution: Some(readResolution))
                }
            } else {
                return HostDirectPreparationFlow(pipeline, operations, runtime, this,
                    owner, context, call).start()
            }
        }
        let preparation = match (externalAdmission) {
            case Some(admission) => pipeline.prepareExternal(context, call, admission)
            case None => pipeline.prepare(context, call)
        }
        var prepared = match (preparation) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(ToolPreparation.Ready(value)) => value
            case Result.Ok(ToolPreparation.NeedsApproval(value, request)) =>
                match (approvalDecision) {
                    case Some(_) => value
                    case None => if (effectivePreparationOwner.isSome()) { value }
                        else { return Result.Ok(ToolInvocationResult.NeedsApproval(request)) }
                }
            case Result.Ok(ToolPreparation.Completed(value)) =>
                return Result.Ok(ToolInvocationResult.Completed(value))
            case Result.Ok(ToolPreparation.Denied(value)) =>
                return Result.Ok(ToolInvocationResult.Denied(value))
        }
        let active = match (runtime.activeRunControl159()) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "runtime.no_active_run",
                "direct tool Run is no longer active"
            ))
        }
        if (active[2].value != context.runId.value || active[3] != context.epoch) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "runtime.run_stale",
                "direct tool context belongs to a replaced Run"
            ))
        }
        let before = runtime.threadSnapshot()
        let callItemId = ItemId(
            "direct-tool-call-" + context.runId.value + "-" + call.callId
        )
        if (externalAdmission.isSome()) {
            match (runtime.commitExternalToolCall(externalAdmission.getOrThrow(), callItemId,
                prepared.operationId, call, context.runId, context.epoch, createdAtMillis: agentUtcMillis())) {
                case Result.Ok(_) => (); case Result.Err(error) => return Result.Err(error)
            }
        } else { match (hostServiceAdmission) {
            case Some(admission) => match (runtime.commitHostServiceToolCall(
                admission, callItemId, prepared.operationId, call, context.runId, context.epoch,
                createdAtMillis: agentUtcMillis()
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            case None => match (runtime.commitResult(ResultEnvelope(
                    before.thread.id,
                    active[1],
                    active[2],
                    active[3],
                    before.nextResultSequence,
                    ThreadItemDraft(
                        callItemId,
                        ThreadItemContent.ToolCall(
                            CanonicalToolCallId(call.callId), call.name, call.arguments
                        ),
                        ItemProvenance("direct_tool", runId: Some(active[2]),
                            operationId: Some(prepared.operationId)),
                        createdAtMillis: agentUtcMillis()
                    )
                ))) {
                    case SemanticCommitDecision.Committed(_, _) => ()
                    case SemanticCommitDecision.Stale(reason) => return Result.Err(AgentError(
                        AgentErrorKind.Conflict, reason.code, reason.message
                    ))
                    case SemanticCommitDecision.Rejected(error) => return Result.Err(error)
            }
        } }
        let directRoot = match (runtime.attestDirectToolCall(
            callItemId, prepared.operationId, context.runId, context.epoch
        )) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        // The parent call is already attested, so these two failures must still
        // record its terminal ToolResult; a bare Err here would leave the call
        // pending and block every Turn settlement path.
        match (pipeline.prepareDirectPreparedData204(context, prepared, directRoot, operations)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return settleUnpreparedDirectParent(operations, runtime, context, directRoot, call, error)
        }
        prepared = match (pipeline.bindDirectRoot(context, prepared, directRoot)) {
            case Result.Err(error) => return settleUnpreparedDirectParent(operations, runtime, context, directRoot, call, error)
            case Result.Ok(value) => value
        }
        match (effectivePreparationOwner) {
            case Some(owner) => HostDirectPreparationFlow(pipeline, operations, runtime, this,
                owner, context, call).finishPrepared(context, prepared, directRoot)
            case None => executeCanonicalPrepared(context, prepared, directRoot, approvalDecision)
        }
    }

    private func resolvePreparedRuntimeFrame204(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, resultItem: ItemId, callId: CanonicalToolCallId,
        stage: OperationAttemptStage, execution: Result<ToolInvocationResult>,
        receiptId: String, observedAtMillis: Int64): Result<Unit> {
        match (ownedRuntimeRegistry204) {
            case Some(registry) => match (pipeline.copyPreparedPlanUtf8204(context, prepared)) {
                case Some(bytes) =>
                    let answer = registry.resolveOperationOwnedUtf8204(runtime, bytes, resultItem,
                        prepared.operationId, callId, stage, execution, receiptId, observedAtMillis,
                        expectedRunId: context.runId, expectedEpoch: context.epoch)
                    // The Registry's complete private Runtime/SQL consumer
                    // returned only Unit. This closes only sender-owned bytes.
                    bytes.closeAfterWholeCaller204(); answer
                case None => resolvePreparedRuntimeRaw204(context, prepared, resultItem, callId, stage,
                    execution, receiptId, observedAtMillis)
            }
            case None => resolvePreparedRuntimeRaw204(context, prepared, resultItem, callId, stage,
                execution, receiptId, observedAtMillis)
        }
    }
    private func resolvePreparedRuntimeRaw204(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, resultItem: ItemId, callId: CanonicalToolCallId,
        stage: OperationAttemptStage, execution: Result<ToolInvocationResult>,
        receiptId: String, observedAtMillis: Int64): Result<Unit> {
        // The compatibility getter records the actual original Raw escape.
        match (runtime.resolveOperation(resultItem, prepared.operationId, callId,
            prepared.operationPlan, stage, execution, receiptId, observedAtMillis,
            expectedRunId: Some(context.runId), expectedEpoch: Some(context.epoch))) {
            case Result.Ok(_) => Result.Ok(()); case Result.Err(error) => Result.Err(error) }
    }

    // Shared scheduler, handoff and atomic Receipt/ToolResult settlement for
    // ordinary Direct and the Runtime-sealed Task source.
    public func executeCanonicalPrepared(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        directRoot: DirectToolCallRef, approvalDecision: ?ApprovalDecision,
        approvalAlreadyWaiting!: Bool = false, preparationError!: ?AgentError = None): Result<ToolInvocationResult> {
        let call = prepared.call
        let projection = match (pipeline.captureDirectPostCanonicalObserver(context, prepared)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
        let schedule = HostDirectToolSchedule(context, runtime, directRoot)
        let handedOff = AtomicBool(false)
        let enteredExecution = AtomicBool(false)
        context.setOwnedTaskHandler({ name, task => runtime.ownTask(name, task,
            expectedRunId: Some(context.runId), expectedEpoch: Some(context.epoch)) })
        context.setDerivedToolFrameHandler({ parent, child, name, entering => schedule.frame(parent, child, name, entering) })
        context.setNestedToolScheduler({ parent, action => schedule.child(parent, action) })
        let execution: Result<ToolInvocationResult> = if (preparationError.isSome()) {
            Result.Err(preparationError.getOrThrow())
        } else if (hostServiceAdmission.isSome() && prepared.authorization != PreparedAuthorization.ApprovalRequired && match (approvalDecision) {
            case Some(ApprovalDecision.Reject) | Some(ApprovalDecision.RejectWithReason(_)) => true
            case _ => false
        }) {
            // The actual Host-service source and Direct root were already
            // committed and bound. An explicit rejection also applies when
            // policy prepared this invocation without a pending approval.
            let reason = match (approvalDecision) {
                case Some(ApprovalDecision.RejectWithReason(value)) => value
                case _ => ""
            }
            Result.Ok(ToolInvocationResult.Denied(ToolDenial(call.callId, call.name,
                AgentError(AgentErrorKind.PermissionDenied, "tool.approval_rejected",
                    if (reason.trimAscii() == "") { "user rejected the pending tool operation" }
                    else { "user rejected the pending tool operation: " + reason }))))
        } else { match (schedule.begin()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => try { match (prepared.authorization) {
            case PreparedAuthorization.ApprovalRequired => match (approvalDecision) {
                case Some(decision) => if (pipeline.preparedIsContextRead204(context, prepared) && approvalAlreadyWaiting) {
                    pipeline.decideContextRead(context, prepared, decision, { _ => handedOff.store(true); Result.Ok(()) })
                } else { match (if (approvalAlreadyWaiting) { Result<Unit>.Ok(()) } else {
                    operations.waitForApproval(prepared.operationId, context.runId)
                }) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(_) => match (pipeline.authorize(
                        context,
                        prepared,
                        decision,
                        decisionSource: ApprovalDecisionSource.User
                    )) {
                        case Result.Err(error) => Result.Err(error)
                        case Result.Ok(ToolAuthorization.Ready(authorized)) =>
                            pipeline.executePrepared(context, authorized, { _ =>
                                handedOff.store(true)
                                Result.Ok(())
                            }, afterExecutionAdmission: { => enteredExecution.store(true) })
                        case Result.Ok(ToolAuthorization.Completed(result)) =>
                            Result.Ok(ToolInvocationResult.Completed(result))
                        case Result.Ok(ToolAuthorization.Denied(denial)) =>
                            Result.Ok(ToolInvocationResult.Denied(denial))
                    }
                }
                }
                case None => Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "plugin.acquisition_approval_missing",
                    "prepared plugin acquisition reached execution without user approval"
                ))
            }
            case _ => pipeline.executePrepared(context, prepared, { _ =>
                handedOff.store(true)
                Result.Ok(())
            }, afterExecutionAdmission: { => enteredExecution.store(true) })
        } } finally { schedule.finish() }
        } }
        var resultTransferred = false
        try {
        // Every actual root consumes the immutable Receipt and result slots
        // reserved by Store before handoff. Executor labels are descriptive.
        let receiptId = "receipt-" + prepared.operationId.value
        let resultItem = ItemId("result-" + prepared.operationId.value)
        let canonicalExecution: Result<ToolInvocationResult> = match (execution) {
            case Result.Ok(ToolInvocationResult.Completed(value)) =>
                Result.Ok(ToolInvocationResult.Completed(ToolResult(value.callId,
                    value.output, isError: value.isError, receiptId: receiptId,
                    payloadLease: value.payloadLease)))
            case _ => execution
        }
        match (resolvePreparedRuntimeFrame204(context, prepared, resultItem,
            CanonicalToolCallId(call.callId),
            if (enteredExecution.load() || handedOff.load()) { OperationAttemptStage.Executing } else { OperationAttemptStage.Prepared },
            canonicalExecution, receiptId, agentUtcMillis())) {
            case Result.Ok(_) =>
                if(pipeline.preparedIsFrozenPluginChild204(context, prepared)) {
                    let persisted: Result<Unit> = match(canonicalExecution) {
                        case Result.Ok(outcome) => pipeline.afterResultPersisted(context,call.name,outcome)
                        case Result.Err(_) => Result<Unit>.Ok(())
                    }
                    match(persisted) {
                        case Result.Err(error)=>return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                            "operation.direct_persisted_hook_failed","canonical result is durable but its retained delivery did not finish",
                            fields:[ErrorField("cause",error.code)]))
                        case Result.Ok(_)=>()
                    }
                }
                match (projection) {
                    case Some(actual) =>
                        let observed = match (canonicalExecution) {
                            case Result.Ok(ToolInvocationResult.Completed(value)) => if (!value.isError) {
                                match (runtime.captureDirectPostCanonicalProjection(directRoot, context.budget)) {
                                    case Result.Err(error) => Result<Unit>.Err(error)
                                    case Result.Ok(boundary) => try {
                                        match (pipeline.afterDirectResultPersistedOwned113(context, prepared, value, actual, boundary)) {
                                            case OwnedPostCanonicalObserverDispatch113.Existing(original) => original
                                            case OwnedPostCanonicalObserverDispatch113.Owned(OwnedFailureDataOutcome113.Value(_)) => Result<Unit>.Ok(())
                                            case OwnedPostCanonicalObserverDispatch113.Owned(OwnedFailureDataOutcome113.Failure(consumer)) =>
                                                // Transfer before the actual projection boundary's
                                                // producer retires. The immutable canonical result
                                                // and Receipt above remain Completed and unchanged.
                                                match (ownedFailures113.capture(context.runId, prepared.call.callId, consumer)) {
                                                    case Result.Err(_) => Result<Unit>.Err(hostOwnedCheckpointFailurePending113())
                                                    case Result.Ok(kind) => Result<Unit>.Err(hostOwnedCheckpointFailureMarker113(kind)) }
                                        }
                                    } finally { boundary.close() }
                                }
                            } else { Result<Unit>.Ok(()) }
                            case _ => Result<Unit>.Ok(()) }
                        match (observed) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    case None => () }
                resultTransferred = true; canonicalExecution
            case Result.Err(error) => Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "operation.direct_settlement_failed", "Direct execution could not publish its canonical Receipt and result",
                fields: [ErrorField("cause", error.code)]))
        }
        } finally { if (!resultTransferred) { releaseToolInvocationPayload(execution) } }
        } finally { match (projection) { case Some(value) => value.close(); case None => () } }
    }
}
