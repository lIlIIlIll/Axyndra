package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import yjson_support.*

// Existing ContextRead admission, Store facts and Direct scheduler are reused.
// A command never substitutes a model Decision or injects a fact envelope.
class HostDirectPreparationFlow {
    private let pipeline: ToolPipeline
    private let operations: OperationRuntimePort
    private let runtime: AgentThreadRuntime
    private let executor: HostTrustedControlToolExecutor
    private let owner: HostDirectPreparationOwner
    private let context: ToolInvocationContext
    private let call: ToolCall
    private var parent: ?DirectToolCallRef = None
    private var firstRead:?ToolPreparationRead=None
    private var sequence:?ToolPreparationReadSequence=None
    private var retained:Array<ContextReadFact>=[]
    init(pipeline: ToolPipeline, operations: OperationRuntimePort, runtime: AgentThreadRuntime,
        executor: HostTrustedControlToolExecutor, owner: HostDirectPreparationOwner,
        context: ToolInvocationContext, call: ToolCall) {
        this.pipeline = pipeline; this.operations = operations; this.runtime = runtime
        this.executor = executor; this.owner = owner; this.context = context
        this.call = ToolCall(call.callId, call.name, parseUnifiedJson(stringifyUnifiedJson(call.arguments), maxBytes: 8388608))
    }
    func start(readResolution!: ?Result<?ToolPreparationRead> = None): Result<ToolInvocationResult> {
        match (owner.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let operationId = OperationId("operation-direct-preparation-" + context.runId.value + "-" + call.callId)
        let source = match (commitDirectPreparationParent(runtime, context, call, operationId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        parent = Some(source)
        let read = match (match (readResolution) {
            case Some(value) => value
            case None => pipeline.preparationReadDirect340(context, source, call)
        }) {
            case Result.Err(error) => return rejectParent(error)
            // A resolver is optional for each actual input. Its pure no-read
            // result continues the already committed original Direct parent.
            case Result.Ok(None) => return finishWithoutRead(source)
            case Result.Ok(Some(value)) => value }
        firstRead=Some(read);sequence=read.sequence
        return readStage(read)
    }
    private func readStage(read:ToolPreparationRead):Result<ToolInvocationResult>{
        let source=parent.getOrThrow()
        if(sequence.isSome()){
            match(verifiedFacts(read,None<ContextReadFact>)){case Result.Err(error)=>return rejectParent(error);case Result.Ok(_)=>()}}
        let requestId = "direct-context-read-" + modelPolicySha256Text(source.canonicalItemId.value)+
            if(retained.isEmpty()){""}else{"-"+retained.size.toString()}
        let readCall = ToolCall(requestId, HOST_CONTEXT_READ_TOOL, read.request())
        let admission = match (runtime.beginContextRead(readCall, read.ownerNamespace, read.packageDigest,
            read.configurationDigest, requestId, context.runId, context.epoch,
            contextReadProjectionDigest(context.contextProjection), parent: Some(OperationRootSource.Direct(source)))) {
            case Result.Err(error) => return rejectParent(error); case Result.Ok(value) => value }
        let readContext = directPreparationContext(context)
        let result = readStageContextFrame159(read, readContext, readCall, admission)
        // A NeedsApproval result may belong to a later parent stage.
        // Keep this share only when its actual retained callback owns it.
        if (readContext.hasOwnedToolSetSnapshot159() && !owner.retainsStageSnapshotFrame159(readContext)) { readContext.returnOwnedToolSetFrame159() }
        result
    }
    private func readStageContextFrame159(read: ToolPreparationRead, readContext: ToolInvocationContext,
        readCall: ToolCall, admission: ContextReadAdmission): Result<ToolInvocationResult> {
        let preparation = match (pipeline.prepareContextRead(readContext, readCall, admission, read: Some(read))) {
            case Result.Err(error) => return rejectParent(error); case Result.Ok(value) => value }
        var prepared = match (preparation) {
            case ToolPreparation.Ready(value) => value
            case ToolPreparation.NeedsApproval(value, _) => value
            case ToolPreparation.Denied(denial) => return rejectParent(denial.reason)
            case ToolPreparation.Completed(_) => return rejectParent(AgentError(AgentErrorKind.PermissionDenied,
                "context.read_preparation_failed", "Direct read preparation did not produce an executable plan")) }
        let readSource = match (runtime.commitContextReadToolCall(admission,
            ItemId("context-read-item-" + prepared.operationId.value), prepared.operationId,
            ToolCall(readCall.callId, readCall.name, prepared.operationPlan.canonicalArguments), prepared.operationPlan,
            createdAtMillis: agentUtcMillis())) {
            case Result.Err(error) => return rejectParent(error); case Result.Ok(value) => value }
        match (pipeline.prepareDirectPreparedData204(readContext, prepared, readSource, operations)) {
            case Result.Err(error) => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "context.read_prepare_unsettled", "canonical Direct read could not record its preparation: " + error.code))
            case Result.Ok(_) => () }
        prepared = match (pipeline.bindDirectRoot(readContext, prepared, readSource)) {
            case Result.Err(error) => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "context.read_bind_unsettled", "canonical read retained its prepared obligation: " + error.code))
            case Result.Ok(value) => value }
        let frozen = prepared
        return executeStage(readContext, frozen, readSource, { result => afterRead(read, frozen.operationId, result) })
    }
    private func finishWithoutRead(source: DirectToolCallRef): Result<ToolInvocationResult> {
        match (owner.current()) { case Result.Err(error) => return rejectParent(error); case Result.Ok(_) => () }
        let preparation = match (pipeline.prepareAttestedDirect(context, source)) {
            case Result.Err(error) => return rejectParent(error); case Result.Ok(value) => value }
        let prepared = match (preparation) {
            case ToolPreparation.Ready(value) => value
            case ToolPreparation.NeedsApproval(value, _) => value
            case ToolPreparation.Denied(denial) => return rejectParent(denial.reason)
            case ToolPreparation.Completed(_) => return rejectParent(AgentError(AgentErrorKind.PermissionDenied,
                "command.preparation_failed", "continued Direct preparation was rejected")) }
        // The parent ToolCall is already committed. Every other failure path in
        // this flow settles it through rejectParent, which records a terminal
        // ToolResult; returning a bare Err here left the call pending forever,
        // so the Turn could not settle even as Failed (thread.incomplete_tool_round).
        match (pipeline.prepareDirectPreparedData204(context, prepared, source, operations)) {
            case Result.Err(error) => return rejectParent(error); case Result.Ok(_) => () }
        executeStage(context, prepared, source, { value => value })
    }
    func finishPrepared(stageContext: ToolInvocationContext, prepared: PreparedToolInvocation,
        source: DirectToolCallRef): Result<ToolInvocationResult> {
        executeStage(stageContext, prepared, source, { value => value })
    }
    private func executeStage(stageContext: ToolInvocationContext, prepared: PreparedToolInvocation,
        source: DirectToolCallRef, next: (Result<ToolInvocationResult>) -> Result<ToolInvocationResult>): Result<ToolInvocationResult> {
        if (prepared.authorization == PreparedAuthorization.ApprovalRequired) {
            if (!owner.allowDeferred) {
                return next(executor.executeCanonicalPrepared(stageContext, prepared, source, None<ApprovalDecision>,
                    preparationError: Some(AgentError(AgentErrorKind.PermissionDenied,
                        "command.user_approval_owner_required", "this read-backed Direct tool requires an actual user approval owner")))) }
            let approval = match (prepared.approval) { case Some(value) => value
                case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "command.approval_missing", "canonical approval has no review description")) }
            match (operations.waitForApproval(prepared.operationId, context.runId)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (runtime.pauseForApproval()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (owner.retain(approval, { decision, cancelling =>
                match (requireDirectPreparationOwner(runtime, context, RunState.WaitingApproval)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                match (runtime.resumeAfterApproval()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let check = if (cancelling) { Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,
                    "command.cancelled", "user command was cancelled before execution")) } else { owner.current() }
                match (check) { case Result.Err(error) => next(executor.executeCanonicalPrepared(stageContext, prepared, source,
                        None<ApprovalDecision>, preparationError: Some(error), approvalAlreadyWaiting: true))
                    case Result.Ok(_) => next(executor.executeCanonicalPrepared(stageContext, prepared, source,
                        Some(decision), approvalAlreadyWaiting: true)) }
            }, { decision => pipeline.validateRetainedApprovalChoice(stageContext, prepared, decision) },
                ownedStageSnapshotFrame159: if (refEq(stageContext, context) || !stageContext.hasOwnedToolSetSnapshot159()) { None<ToolInvocationContext> } else { Some(stageContext) })) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            return Result.Ok(ToolInvocationResult.NeedsApproval(approval))
        }
        let check = owner.current()
        let result = match (check) {
            case Result.Err(error) => executor.executeCanonicalPrepared(stageContext, prepared, source, None<ApprovalDecision>, preparationError: Some(error))
            case Result.Ok(_) => executor.executeCanonicalPrepared(stageContext, prepared, source, None<ApprovalDecision>) }
        next(result)
    }
    private func afterRead(read:ToolPreparationRead,operation:OperationId,result:Result<ToolInvocationResult>):Result<ToolInvocationResult>{
        if(sequence.isNone()){return afterSingleRead(read,operation,result)}
        afterSequenceRead(read,operation,result)
    }
    private func afterSingleRead(read: ToolPreparationRead, operation: OperationId,
        result: Result<ToolInvocationResult>): Result<ToolInvocationResult> {
        try {
            match (result) {
                case Result.Ok(ToolInvocationResult.Completed(value)) => if (value.isError) {
                    return rejectParent(AgentError(AgentErrorKind.PermissionDenied,
                        "context.read_rejected", "the Direct preparation read was rejected")) }
                case Result.Err(error) =>
                    // A missing/unknown read Receipt must remain recovery debt.
                    if (operations.loadContextReadFact(operation, context.runId).isError() && error.kind == AgentErrorKind.RecoveryRequired) {
                        return Result.Err(error) }
                    return rejectParent(error)
                case _ => return rejectParent(AgentError(AgentErrorKind.PermissionDenied,
                    "context.read_rejected", "the Direct preparation read did not complete")) }
            let fact = match (operations.loadContextReadFact(operation, context.runId)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let effective = match (read.complete(context, [fact])) {
                case Result.Err(error) => return rejectParent(error); case Result.Ok(value) => value }
            match (owner.current()) { case Result.Err(error) => return rejectParent(error); case Result.Ok(_) => () }
            let source = parent.getOrThrow()
            let preparation = match (pipeline.prepareDirectWithContextReads(context, source, effective, [fact.link()])) {
                case Result.Err(error) => return rejectParent(error); case Result.Ok(value) => value }
            let prepared = match (preparation) {
                case ToolPreparation.Ready(value) => value
            case ToolPreparation.NeedsApproval(value, _) => value
                case ToolPreparation.Denied(denial) => return rejectParent(denial.reason)
                case ToolPreparation.Completed(_) => return rejectParent(AgentError(AgentErrorKind.PermissionDenied,
                    "command.preparation_failed", "continued Direct preparation was rejected")) }
            // Same settlement obligation as the single-read path above: the
            // parent call must receive a terminal ToolResult on this failure.
            match (pipeline.prepareDirectPreparedData204(context, prepared, source, operations)) {
                case Result.Err(error) => return rejectParent(error); case Result.Ok(_) => () }
            executeStage(context, prepared, source, { value => value })
        } finally { match (result) { case Result.Ok(ToolInvocationResult.Completed(value)) => value.releasePayload(); case _ => () } }
    }
    private func verifiedFacts(read:ToolPreparationRead,next:?ContextReadFact):Result<Array<ContextReadFact>>{
        match(owner.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(requireDirectPreparationOwner(runtime,context,RunState.Running)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let source=parent.getOrThrow();let first=firstRead.getOrThrow()
        if(context.cancellation.isCancelled() || read.ownerNamespace!=first.ownerNamespace || read.packageDigest!=first.packageDigest ||
            read.configurationDigest!=first.configurationDigest || contextReadProjectionDigest(runtime.activeRunControl159().getOrThrow()[5])!=
                contextReadProjectionDigest(context.contextProjection)){return directPreparationError("context.read_sequence_owner_changed")}
        match(runtime.attestDirectToolCall(source.canonicalItemId,source.operationId,context.runId,context.epoch)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(read.validateBoundary(context,read.request())){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let facts=ArrayList<ContextReadFact>()
        for(saved in retained){let actual=match(operations.loadContextReadFact(saved.operationId,context.runId)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(canonicalAgentValue(saved.link().toValue())!=canonicalAgentValue(actual.link().toValue())){
                return directPreparationError("context.read_sequence_fact_changed")};facts.add(actual)}
        match(next){case Some(value)=>
            for(saved in facts where saved.operationId.value==value.operationId.value){return directPreparationError("context.read_sequence_fact_reused")}
            let actual=match(operations.loadContextReadFact(value.operationId,context.runId)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(item)=>item}
            if(canonicalAgentValue(actual.link().toValue())!=canonicalAgentValue(value.link().toValue())){
                return directPreparationError("context.read_sequence_fact_changed")}
            facts.add(actual);case None=>()}
        for(value in facts){let origin=value.origin
            if(value.runId.value!=context.runId.value || origin.parentKind!="direct" || origin.parentCallItemId!=source.canonicalItemId.value ||
                origin.parentOperationId!=source.operationId.value || origin.parentDecisionId!="" || origin.parentScopedCallId!="" ||
                origin.ownerNamespace!=first.ownerNamespace || origin.packageDigest!=first.packageDigest || origin.configurationDigest!=first.configurationDigest ||
                origin.projectionDigest!=contextReadProjectionDigest(context.contextProjection)){
                return directPreparationError("context.read_sequence_fact_owner_changed")}}
        Result.Ok(facts.toArray())
    }
    private func afterSequenceRead(read:ToolPreparationRead,operation:OperationId,result:Result<ToolInvocationResult>):Result<ToolInvocationResult>{
        try{
            match(result){case Result.Ok(ToolInvocationResult.Completed(value))=>if(value.isError){
                return rejectParent(AgentError(AgentErrorKind.PermissionDenied,"context.read_rejected","Direct preparation read rejected"))}
                case Result.Err(error)=>
                    if(operations.loadContextReadFact(operation,context.runId).isError() && error.kind==AgentErrorKind.RecoveryRequired){return Result.Err(error)}
                    return rejectParent(error)
                case _=>return rejectParent(AgentError(AgentErrorKind.PermissionDenied,"context.read_rejected","Direct preparation read did not complete"))}
            let fact=match(operations.loadContextReadFact(operation,context.runId)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let facts=match(verifiedFacts(read,Some(fact))){case Result.Err(error)=>return rejectParent(error);case Result.Ok(value)=>value}
            let selected=sequence.getOrThrow()
            let next=match(selected.advance(context,facts)){case Result.Err(error)=>return rejectParent(error);case Result.Ok(value)=>value}
            match(verifiedFacts(read,Some(fact))){case Result.Err(error)=>return rejectParent(error);case Result.Ok(_)=>()}
            match(next){
                case ToolPreparationReadNext.Read(value)=>
                    let first=firstRead.getOrThrow()
                    if(facts.size>=selected.maximumReads || value.ownerNamespace!=first.ownerNamespace || value.packageDigest!=first.packageDigest ||
                        value.configurationDigest!=first.configurationDigest || value.sequence.isSome()){
                        return rejectParent(AgentError(AgentErrorKind.Conflict,"context.read_sequence_stage_limit","bounded sequence owner or stage limit changed"))}
                    retained=facts;return readStage(value)
                case ToolPreparationReadNext.Ready(effective)=>
                    if(validateContextReadSequenceInputProjection(effective,facts.map{item=>item.link()}).isError()){
                        return rejectParent(AgentError(AgentErrorKind.PermissionDenied,"context.read_sequence_projection_invalid","sequence omitted or changed an actual fact output"))}
                    let frozen=try{parseUnifiedJson(stringifyUnifiedJson(effective),maxBytes:8388608)}catch(_:Exception){
                        return rejectParent(AgentError(AgentErrorKind.InvalidInput,"context.read_sequence_projection_invalid","final sequence input exceeds its existing bound"))}
                    retained=facts
                    let source=parent.getOrThrow()
                    let preparation=match(pipeline.prepareDirectWithContextReads(context,source,frozen,facts.map{item=>item.link()})){
                        case Result.Err(error)=>return rejectParent(error);case Result.Ok(value)=>value}
                    let prepared=match(preparation){case ToolPreparation.Ready(value)=>value;case ToolPreparation.NeedsApproval(value,_)=>value
                        case ToolPreparation.Denied(denial)=>return rejectParent(denial.reason)
                        case ToolPreparation.Completed(_)=>return rejectParent(AgentError(AgentErrorKind.PermissionDenied,"command.preparation_failed","continued Direct preparation rejected"))}
                    // The bounded sequence path carries the same settlement
                    // obligation: the committed parent must get its terminal
                    // ToolResult, otherwise the Turn cannot settle at all.
                    match(pipeline.prepareDirectPreparedData204(context,prepared,source,operations)){case Result.Err(error)=>return rejectParent(error);case Result.Ok(_)=>()}
                    executeStage(context,prepared,source,{value=>value})
            }
        }finally{match(result){case Result.Ok(ToolInvocationResult.Completed(value))=>value.releasePayload();case _=>()}}
    }
    private func rejectParent(cause: AgentError): Result<ToolInvocationResult> {
        settleUnpreparedDirectParent(operations, runtime, context, parent.getOrThrow(), call, cause)
    }
}

// A Direct parent whose ToolCall is already committed must always receive a
// terminal ToolResult, even when preparation fails before execution. Without
// it the Turn can never settle - `settleTurn`/`cancelRun` refuse every outcome
// (completed, failed, recovery-required, cancelled) while a committed call is
// pending - so an early `Result.Err` from preparation would strand the Run.
// Only a canonical UserDirect origin can be rejected this way; any other origin
// keeps its original recovery debt instead of fabricating a rejection.
func settleUnpreparedDirectParent(operations: OperationRuntimePort, runtime: AgentThreadRuntime,
    context: ToolInvocationContext, source: DirectToolCallRef, call: ToolCall,
    cause: AgentError): Result<ToolInvocationResult> {
    let plan = match (operations.prepareDirectRejection(source)) {
        case Result.Err(error) => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "context.read_parent_unsettled", "original Direct call retained its debt: " + error.code))
        case Result.Ok(value) => value }
    let result = ToolResult(call.callId, rejectedDirectPreparationOutput(), isError: true,
        receiptId: "receipt-" + source.operationId.value)
    let execution = Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(result))
    match (runtime.resolveOperation(ItemId("result-" + source.operationId.value),
        source.operationId, CanonicalToolCallId(call.callId), plan, OperationAttemptStage.Prepared,
        execution, result.receiptId, agentUtcMillis(), expectedRunId: Some(context.runId), expectedEpoch: Some(context.epoch))) {
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(_) =>
            // The original cause is the only accurate explanation of why the
            // Direct call was rejected, so it is preserved instead of being
            // replaced by a synthetic success result. The rejection itself is
            // still recorded above (prepareDirectRejection + resolveOperation
            // at Prepared), so no execution fact is lost, and the caller that
            // branches on `isError` now also learns the real reason.
            Result.Err(cause) }
}
func requireDirectPreparationOwner(runtime: AgentThreadRuntime, context: ToolInvocationContext, expected: RunState): Result<Unit> {
    let active = match (runtime.activeRunControl159()) { case Some(value) => value
        case None => return directPreparationError("runtime.no_active_run") }
    if (active[2].value != context.runId.value || active[3] != context.epoch || active[4] != expected) {
        return directPreparationError("runtime.run_stale") }
    Result.Ok(())
}
func directPreparationContext(context: ToolInvocationContext): ToolInvocationContext {
    ToolInvocationContext(context.runId, context.sessionId, context.capabilities, epoch: context.epoch,
        cancellation: context.cancellation, toolContext: ToolContextDescriptor(workspaceRoot: context.workspaceRoot,
            cwd: context.cwd, environment: context.environment, services: context.services, executionSettings180: context.executionSettings180, modelFaultCounters180: context.modelFaultCounters180),
        approvalModeOverride: context.approvalModeOverride, outputSink: context.outputSink,
        budget: context.budget, budgetModeFn: context.budgetModeFn, contextProjection: context.contextProjection,
        toolSetSnapshot: context.legacyToolSetSnapshot159,
            ownedToolSetSnapshot159: context.forkOwnedToolSetSnapshot159(), trustedControl: false)
}
func commitDirectPreparationParent(runtime: AgentThreadRuntime, context: ToolInvocationContext,
    call: ToolCall, operation: OperationId): Result<DirectToolCallRef> {
    match (requireDirectPreparationOwner(runtime, context, RunState.Running)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let active = runtime.activeRunControl159().getOrThrow(); let snapshot = runtime.threadSnapshot()
    let item = ItemId("direct-tool-call-" + context.runId.value + "-" + call.callId)
    match (runtime.commitResult(ResultEnvelope(snapshot.thread.id, active[1], active[2], active[3],
        snapshot.nextResultSequence, ThreadItemDraft(item,
            ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
            ItemProvenance("direct_tool", runId: Some(active[2]), operationId: Some(operation)), createdAtMillis: agentUtcMillis())))) {
        case SemanticCommitDecision.Committed(_, _) => ()
        case SemanticCommitDecision.Rejected(error) => return Result.Err(error)
        case SemanticCommitDecision.Stale(reason) => return Result.Err(AgentError(AgentErrorKind.Conflict, reason.code, reason.message)) }
    runtime.attestDirectToolCall(item, operation, context.runId, context.epoch)
}
