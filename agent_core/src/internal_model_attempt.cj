package agent_core

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.sync.*
import std.time.*

// The existing bounded internal-call loop owns retry and usage accounting.
// This adapter adds an actual, separately claimed Attempt before each dispatch;
// it never creates a Tool, Decision or a second execution ledger.
class CoreInternalAttemptPort <: ModelPort {
    private let provider: ModelPort
    private let runs: RunRepository
    private let decisions: ModelDecisionRuntimePort
    private let control: CoreRunControl
    private let parent: AgentRunRequest
    private let purpose: InternalModelPurpose
    private let catalog180: ToolCatalog
    private let lock = Mutex()
    private var activeRequest = ""
    private var cancelled = false

    init(provider: ModelPort, runs: RunRepository, decisions: ModelDecisionRuntimePort,
        control: CoreRunControl, parent: AgentRunRequest, purpose: InternalModelPurpose, catalog180: ToolCatalog) {
        this.provider = provider; this.runs = runs; this.decisions = decisions
        this.control = control; this.parent = parent; this.purpose = purpose
        this.catalog180 = catalog180
    }
    public func validatePolicySnapshot(model: String, snapshot: ?ModelExecutionCapabilitiesSnapshot): Result<Unit> {
        provider.validatePolicySnapshot(model, snapshot)
    }
    public func transcriptSnapshot(request: ModelRequest): ?String { provider.transcriptSnapshot(request) }
    public func validateTranscriptSnapshot(snapshot: String): Bool { provider.validateTranscriptSnapshot(snapshot) }
    public func cancel(requestId: String): Result<Unit> {
        let selected = { => lock.lock(); try { cancelled = true; activeRequest } finally { lock.unlock() } }()
        if (selected == "") { Result.Ok(()) } else { provider.cancel(selected) }
    }
    private func check(run: RunId, epoch: Int64): Result<Unit> {
        let cancelledNow = { => lock.lock(); try { cancelled } finally { lock.unlock() } }()
        if (cancelledNow) { return Result.Err(AgentError(AgentErrorKind.Cancelled, "model.internal_cancelled", "internal model call was cancelled")) }
        match (control.source.token.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (control.runtime.childCancellationToken(expectedRunId: Some(run), expectedEpoch: Some(epoch))) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(token) => token.check() }
    }
    private func audit(code: String, attempt: ModelAttemptId, semantic: SemanticModelRequestId): Result<AgentEvent> {
        let snapshot = match (runs.find(parent.runId)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let sequence = match (nextInternalEventSequence(runs, parent.runId, snapshot.sequence)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        Result.Ok(AgentEvent(EventMeta(sequence, control.traceId, parent.runId, occurredAtMillis: agentUtcMillis(),
            requestId: Some(RequestId(activeRequest)), semanticRequestId: Some(semantic), attemptId: Some(attempt)),
            AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
                ValueField("code", textValue(code)), ValueField("attempt_id", textValue(attempt.value)),
                ValueField("purpose", textValue(internalModelPurposeName(purpose)))]))))
    }
    private func internalCancelled180(): Bool {
        lock.lock(); try { cancelled } finally { lock.unlock() }
    }
    private func executeOwnedInput180(request: ModelRequest, events: ModelEventSink,
        epoch: Int64): Result<ModelReply> {
        let custody = match (catalog180.reserveModelInputData159(request, settings180: Some(parent.toolContext))) {
            case Some(payment) => let owner = CoreModelInput159(payment, request)
                control.retainModelInput159(owner); Some(owner)
            case None => None<CoreModelInput159>
        }
        try {
            let result = executeOwnedInputCallerFrame180(request, events, epoch, custody)
            match (custody) { case Some(value) => value.returnedCaller159(); case None => () }
            result
        } catch (error: Exception) {
            match (custody) { case Some(value) => value.hold159(error: Some(error)); value.returnedCaller159(); case None => () }
            throw error
        }
    }
    private func executeOwnedInputCallerFrame180(request: ModelRequest, events: ModelEventSink,
        epoch: Int64, custody: ?CoreModelInput159): Result<ModelReply> {
        let admitted = AtomicInt64(0)
        let action = { =>
            while (admitted.load() == 0) { sleep(Duration.millisecond) }
            if (admitted.load() < 0) { return Result<ModelReply>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "model.internal_input_not_admitted", "original internal Model input was not admitted")) }
            match (check(parent.runId, epoch)) { case Result.Err(error) => return Result<ModelReply>.Err(error); case Result.Ok(_) => () }
            executeModelInput159(provider, request, events, custody, parent.toolContext.executionSettings180,
                parent.toolContext.modelFaultCounters180,
                { => control.source.token.isCancelled() || internalCancelled180() })
        }
        let future = match (custody) { case Some(value) => value.start159(action); case None => spawn { action() } }
        // This original Runtime producer actually gets the physical action
        // Future. No unrelated completed-flag/Unit task stands in for it.
        let producer = spawn { let _ = future.get() }
        match (control.runtime.ownTaskWithJoin("internal-model-" + request.requestId, producer,
            expectedRunId: Some(parent.runId), expectedEpoch: Some(epoch))) {
            case Result.Err(error) => admitted.store(-1); return Result.Err(error)
            case Result.Ok(_) => admitted.store(1)
        }
        future.get()
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let active = match (control.runtime.activeRunControl159()) { case Some(value) => value
            case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "model.internal_owner_missing", "internal model Run is not active")) }
        if (active[2].value != parent.runId.value || active[0].value != parent.sessionId.value) {
            return Result.Err(AgentError(AgentErrorKind.Conflict, "model.internal_owner_changed", "internal model Run changed"))
        }
        match (control.runtime.requireModelBoundary(parent.runId, active[3])) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (check(parent.runId, active[3])) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (provider.validatePolicySnapshot(request.model, internalPolicySnapshot(request, Some(parent)))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        // The request count was charged by the canonical Run ledger before this
        // callback. It supplies a durable, non-reused identity across retries.
        let counted = match (runs.find(parent.runId)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (counted.modelRequests < 1) { return Result.Err(AgentError(AgentErrorKind.BudgetExceeded,
            "model.internal_not_charged", "internal model request was not charged")) }
        let id = "internal-" + parent.runId.value + "-" + counted.modelRequests.toString()
        let effective = internalModelRequestIdentity(request, id)
        let input = InternalModelAttemptInput(purpose, active[0], parent.runId, active[3], effective)
        let attemptId = ModelAttemptId(id); let semantic = SemanticModelRequestId(id)
        let now = agentUtcMillis()
        let attempt = DurableModelAttempt(attemptId, semantic, parent.runId, 1, ModelAttemptLifecycle.Created,
            attemptPolicyValue(attemptPolicyFor(effective, AttemptPolicyReason.Initial, ModelAttemptRecoveryPolicy())),
            internalModelPolicyReason(purpose), now, now, providerRequestId: id,
            semanticRequestDigest: input.semanticDigest, wirePolicyDigest: input.wirePolicyDigest,
            transcriptSnapshot: match (provider.transcriptSnapshot(effective)) { case Some(value) => value; case None => "" },
            dispatchState: ModelAttemptDispatchState.Prepared)
        lock.lock(); try { if (cancelled || activeRequest != "") { return Result.Err(AgentError(AgentErrorKind.Cancelled,
            "model.internal_cancelled", "internal model call is cancelled or already executing")) }; activeRequest = id }
            finally { lock.unlock() }
        control.setActiveRequest(id)
        let prepared = AtomicBool(false)
        try {
            let boundary = control.serializeEvent({ =>
                let policyEvent = match (audit("model.internal_attempt_prepared", attemptId, semantic)) {
                    case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(value) => value }
                match (runs.prepareInternalModelAttempt(attempt, policyEvent, input)) {
                    case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
                prepared.store(true)
                let claimEvent = match (audit("model.attempt_dispatch_claimed", attemptId, semantic)) {
                    case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(value) => value }
                match (runs.claimModelAttemptDispatch(attemptId, claimEvent)) {
                    case Result.Ok(true) => Result.Ok(())
                    case Result.Ok(false) => Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "model.attempt_already_dispatched", "internal Attempt cannot be replayed"))
                    case Result.Err(error) => Result.Err(error) }
            })
            match (boundary) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (check(parent.runId, active[3])) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let cancellation = control.source.token.onCancel({ _ => let _ = provider.cancel(id) })
            let actualToken = match (control.runtime.childCancellationToken(expectedRunId: Some(parent.runId), expectedEpoch: Some(active[3]))) {
                case Result.Err(error) => cancellation.dispose(); return Result.Err(error); case Result.Ok(value) => value }
            let runCancellation = actualToken.onCancel({ _ => let _ = provider.cancel(id) })
            let outcome = try { executeOwnedInput180(effective, events, active[3]) }
            catch (failure: OwnedCanonicalDataFailure113) { Result<ModelReply>.Err(failure.error) }
            finally { runCancellation.dispose(); cancellation.dispose() }
            let usage = match (outcome) {
                case Result.Ok(reply) => Some(accountedModelAttemptUsage(reply, parent.pricing))
                case Result.Err(error) => attemptUsageFromError(error, parent.pricing) }
            match (usage) { case Some(value) =>
                match (control.runtime.recordModelUsage(RunModelUsageSample(active[0], active[1],
                    parent.runId, active[3], counted.modelRequests,
                    if (purpose == InternalModelPurpose.ApprovalReview) { ModelLaneRole.Reviewer } else { ModelLaneRole.Compactor },
                    0, value, agentUtcMillis()))) {
                    case Result.Err(error) => return Result.Err(internalModelErrorUsage(error, usage)); case Result.Ok(_) => () }
                case None => () }
            let checked = match (check(parent.runId, active[3])) {
                case Result.Err(error) => Result<ModelReply>.Err(internalModelErrorUsage(error, usage)); case Result.Ok(_) => outcome }
            match (runs.settleInternalModelAttempt(attemptId, input, checked, agentUtcMillis())) {
                case Result.Err(error) =>
                    // A parent approval/context change can never authorize a late
                    // reply. Preserve failure on this exact Attempt, no re-dispatch.
                    let _ = decisions.terminalizeAttempt(attemptId, ModelAttemptLifecycle.Abandoned,
                        "internal_parent_changed_or_settlement_failed", agentUtcMillis())
                    Result.Err(internalModelErrorUsage(error, usage))
                case Result.Ok(_) => checked
            }
        } finally {
            if (prepared.load()) {
                match (runs.modelAttempt(attemptId)) {
                    case Result.Ok(value) => if (value.lifecycle == ModelAttemptLifecycle.Created || value.lifecycle == ModelAttemptLifecycle.Streaming) {
                        let _ = decisions.terminalizeAttempt(attemptId, ModelAttemptLifecycle.Abandoned,
                            "internal_call_interrupted", agentUtcMillis()) }
                    case Result.Err(_) => () }
            }
            control.clearActiveRequest(id)
            lock.lock(); try { activeRequest = "" } finally { lock.unlock() }
        }
    }
}

func internalModelRequestIdentity(value: ModelRequest, requestId: String): ModelRequest {
    ModelRequest(value.model, value.messages, system: value.system, tools: [], thinking: value.thinking,
        maxOutputTokens: value.maxOutputTokens, wireMaxOutputTokens: Some(value.wireMaxOutputTokens),
        resolvedPolicy: value.resolvedPolicy, streaming: value.streaming, parallelToolCalls: false,
        requestId: requestId, serviceTier: value.serviceTier, cachePolicy: value.cachePolicy,
        toolChoice: ModelToolChoice.NoTools, structuredOutput: value.structuredOutput, cacheKey: value.cacheKey,
        transportHardTimeoutMillis: value.transportHardTimeoutMillis)
}

func coreInternalMaintenanceLane(parent: AgentRunRequest): ModelLane {
    let base = coreModelLane(parent, ToolCatalog())
    ModelLane(ModelLaneRole.Compactor, base.providerId, base.modelId, base.protocol, base.capabilities,
        base.contextWindow, base.outputReserve, base.providerSafetyMargin, base.estimatorId,
        base.retryPolicyId, base.cachePolicyId, base.toolSet, base.systemInstructionVersion)
}

// Parent drift or cancellation may reject an otherwise observed provider reply.
// Its actual usage still travels through the existing canonical budget accounting.
func internalModelErrorUsage(error: AgentError, usage: ?ModelUsage): AgentError {
    if (usage.isNone()) { return error }
    let value = usage.getOrThrow(); let fields = ArrayList<ErrorField>()
    for (field in error.fields where !field.name.startsWith("usage_")) { fields.add(field) }
    fields.add(ErrorField("usage_input_tokens", value.inputTokens.toString()))
    fields.add(ErrorField("usage_output_tokens", value.outputTokens.toString()))
    fields.add(ErrorField("usage_reasoning_tokens", value.reasoningTokens.toString()))
    fields.add(ErrorField("usage_cache_read_tokens", value.cacheReadTokens.toString()))
    fields.add(ErrorField("usage_cache_write_tokens", value.cacheWriteTokens.toString()))
    fields.add(ErrorField("usage_source", modelUsageSourceName(value.source)))
    match (value.evidence) { case None => (); case Some(evidence) =>
        fields.add(ErrorField("usage_protocol", evidence.protocol)); fields.add(ErrorField("usage_event", evidence.eventKind))
        fields.add(ErrorField("usage_response_id", evidence.providerResponseId)) }
    AgentError(error.kind, error.code, error.message, retryable: error.retryable, fallbackAllowed: error.fallbackAllowed,
        fields: fields.toArray(), attemptFailure: error.attemptFailure, observation: error.observation)
}
