package agent_core_contract

import yjson_support.*

import yjson.*

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_skills.*
import std.collection.*
import std.sync.*
import std.time.*
import tool_runtime.*

main(): Int64 {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let operations = MemoryOperations()
    let ids = FixtureIds()
    let audit = MemoryAudit()
    let catalog = ToolCatalog()
    let echoTool = EchoTool(observer: Some(conversations))
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "echo",
                "echo text",
                objectValue([])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        echoTool
    ).isOk(), "tool registration")
    let pipeline = ToolPipeline(
        catalog,
        operations,
        audit,
        ids
    )
    let model = TwoStepModel()
    let threadRuntimes = InMemoryThreadRuntimeRegistry(
        ContextProjector("core-contract", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let core = AgentCore(
        model,
        runs,
        pipeline,
        catalog,
        threadRuntimes: Some(threadRuntimes)
    )
    let request = AgentRunRequest(
        RunId("run-1"),
        SessionId("session-1"),
        "fixture",
        "echo hello",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
        parallelToolCalls: true
    )
    let outcome = core.start(request)
    expect(outcome.isOk(), "agent core completes a tool loop")
    expect(match (outcome.value().getOrThrow()) {
        case AgentRunOutcome.Completed(snapshot) => isCompleted(snapshot.status)
        case _ => false
    }, "run completes")
    expect(model.calls == 2, "one execute primitive drives both model turns")
    modelProtocolCapabilityBoundaryContract(model)
    controlledInternalModelCallContract()
    let canonical = threadRuntimes.acquire(
        ThreadId(request.sessionId.value), "agent-core"
    ).value().getOrThrow().threadSnapshot()
    expect(canonical.items.size == 4,
        "canonical Thread contains user, assistant call, result, and answer")
    expect(
        match (canonical.items[2].content) {
            case ThreadItemContent.ToolResult(callId, _, _, _, _) =>
                callId.value == "call-1"
            case _ => false
        },
        "canonical ToolResult retains its call id"
    )
    expect(
        echoTool.persistedResults == 1,
        "post-persist hook runs after canonical ToolResult commit"
    )
    expect(runs.eventLog.size >= 2, "bounded event source receives core events")
    expect(
        hasEvent(runs.eventLog, "tool.execution_started") && hasEvent(runs.eventLog, "tool.execution_completed"),
        "tool execution emits structured start and result events"
    )
    typedLifecycleContract(runs.eventLog, request.runId)
    activeSkillStackContract()
    parallelToolWaveContract()
    partialToolWaveFailureContract()
    approvalBatchBarrierContract()
    toolContextApprovalResumeContract()
    approvalResumeContract()
    nonPendingDecisionDoesNotPersistContract()
    // SQLite receipt/ToolResult crash windows and approval cancellation are
    // covered by the vNext recovery and chaos contracts, not legacy
    // Durable semantic append faults.
    // Corrupt legacy ModelMessage histories are no longer imported into the
    // canonical Thread. Tool-pair rejection/repair now belongs to the
    // ContextProjector and recovery-planner contracts.
    queueModeContract()
    attemptDeadlineContextContract()
    deadlineRetryExactReplayContract()
    toolEvidenceBlocksRetryContract()
    malformedToolArgumentsRetryContract()
    providerTerminalMissingRetryContract()
    cancellationAndRunDeadlineBarriersContract()
    durableDecisionSuppressesRetryRaceContract()
    modelResumeCrashWindowMatrixContract()
    typedTerminalFailureContract()
    outputLimitedBeforeDecisionRecoveryContract()
    outputLimitedRecoveryExhaustionContract()
    modelIdleTimeoutContract()
    idleRetryRecoversContract()
    retryBackoffControlContract()
    partialToolCallNeverEscapesContract()
    completedBlockIsNotDecisionContract()
    attemptPolicyAppliedContract()
    failedAttemptDoesNotPolluteTranscriptContract()
    telemetryPersistenceFailureIsolationContract()
    terminalDecisionPersistenceFailureContract()
    durableDecisionRecoveryDoesNotInvokeProviderContract()
    invalidArgumentContinuesRunContract()
    permissionDeniedToolContinuesBatchContract()
    capabilityDenialLoopContract()
    // Failure and cancellation are Run state/events, never fabricated
    // canonical assistant transcript Items.
    // Interrupted legacy ModelMessage repair is replaced by durable Operation
    // recovery before a Thread is resumed.
    singleRequestInputBudgetContract()
    cumulativeInputTripsExecutionBudgetContract()
    workTurnBudgetDrainsGracefullyContract()
    drainFinalizationHasNoToolSurfaceContract()
    budgetPressureSignalsOnceContract()
    drainPartialReportCompletedContract()
    drainHardCapStopsBoundedContract()
    drainProviderFailureStopsBoundedContract()
    resumeRestoresWorkBudgetContinuityContract()
    drainRespectsRunDeadlineContract()
    drainPreflightBlocksNearCostBoundaryContract()
    workBudgetStopsAtModelRequestLimitContract()
    workCannotUseDrainHeadroomContract()
    drainBlockedAtCostBoundaryContract()
    childBudgetPoolSettlesWorkPlusDrainContract()
    childBudgetPoolSchedulingGatesContract()
    budgetModeOrthogonalToApprovalContract()
    usageAccountingContract()
    contextCompactionContract()
    contextBoundaryContract()
    println("agent_core contract passed")
    0
}

func attemptDeadlineContextContract(): Unit {
    let policy = ModelAttemptRecoveryPolicy(
        attemptTimeoutMillis: 120000,
        hardTimeoutMillis: 150000,
        streamIdleMillis: 30000,
        recentProgressMillis: 1000
    )

    let activeClock = ManualAttemptMonotonicClock()
    let active = AttemptDeadlineContext(policy, activeClock)
    activeClock.advance(29999)
    active.record(ModelEvent.ReasoningDelta("thinking-1"))
    activeClock.advance(29999)
    active.record(ModelEvent.ReasoningDelta("thinking-2"))
    activeClock.advance(29999)
    active.record(ModelEvent.ReasoningDelta("thinking-3"))
    activeClock.advance(29999)
    active.record(ModelEvent.ReasoningDelta("thinking-4"))
    activeClock.advance(29999)
    active.record(ModelEvent.ReasoningDelta("thinking-5"))
    activeClock.advance(29999)
    active.record(ModelEvent.TextDelta("answer"))
    expect(active.evaluate() == AttemptDeadlineAction.Continue &&
        active.diagnostics().elapsedMillis > 150000 &&
        active.diagnostics().softDeadlineMillis == 0 &&
        active.diagnostics().hardDeadlineMillis == 0,
        "T1 continuous reasoning remains active beyond the former 120s/150s deadlines")

    let idleClock = ManualAttemptMonotonicClock()
    let idle = AttemptDeadlineContext(policy, idleClock)
    idleClock.advance(30000)
    expect(idle.evaluate() == AttemptDeadlineAction.StreamIdle,
        "T2 absence of meaningful progress is a typed stream idle timeout")

    let heartbeatClock = ManualAttemptMonotonicClock()
    let heartbeat = AttemptDeadlineContext(policy, heartbeatClock)
    heartbeatClock.advance(29999)
    heartbeat.record(ModelEvent.ProviderProgress(ProviderStreamEvent.UsageDelta(1, 1)))
    heartbeatClock.advance(1)
    expect(heartbeat.evaluate() == AttemptDeadlineAction.StreamIdle,
        "T3 usage telemetry does not mask a stream with no semantic progress")

}

func deadlineRetryExactReplayContract(): Unit {
    let decisions = RecordingModelDecisionPort()
    let model = DeadlineThenAnswerModel()
    let catalog = ToolCatalog()
    let runs = MemoryRuns()
    let result = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, modelDecisionRuntime: Some(decisions)
    ).start(AgentRunRequest(
        RunId("deadline-escalation-run"),
        SessionId("deadline-escalation-session"),
        "fixture", "retry with the same semantic input",
        thinking: ThinkingLevel.High,
        modelCapabilitiesSnapshot: Some(ModelExecutionCapabilitiesSnapshot(
            "fixture",
            ThinkingCapabilities(
                ThinkingControlMode.Budget,
                supportedLevels: canonicalNonOffThinkingLevels()
            ),
            10000
        )),
        budget: ResourceBudget(maxOutputTokens: 10000)
    ))
    expect(result.isOk() && model.requests.size == 2 &&
        decisions.createdAttempts.size == 2,
        "T6 a retry uses a new durable Attempt")
    let first = decisions.createdAttempts[0]
    let second = decisions.createdAttempts[1]
    expect(first.semanticRequestId.value == second.semanticRequestId.value &&
        first.id.value != second.id.value &&
        second.parentAttemptId.getOrThrow().value == first.id.value &&
        first.attemptNo == 1 && second.attemptNo == 2,
        "T6 retries preserve SemanticRequest identity and link a new AttemptId")
    expect(model.requests[0].thinking == ThinkingLevel.Medium &&
        model.requests[1].thinking == ThinkingLevel.Medium,
        "T7 idle recovery retries the same effective thinking policy")
    expect(
        match ((model.requests[0].toolChoice, model.requests[1].toolChoice)) {
            case (ModelToolChoice.Auto, ModelToolChoice.Auto) => true
            case (ModelToolChoice.NoTools, ModelToolChoice.NoTools) => true
            case (ModelToolChoice.Required, ModelToolChoice.Required) => true
            case _ => false
        } && model.requests[1].maxOutputTokens == model.requests[0].maxOutputTokens,
        "T7 RecoveryV1 retry preserves tool choice and completion headroom")
    expect(
        second.policyReason == "retry" &&
        second.policy.field("thinking").getOrThrow().text == "medium" &&
        second.policy.field("soft_deadline_ms").getOrThrow().number == "0" &&
        second.policy.field("hard_deadline_ms").getOrThrow().number == "0",
        "T7 durable AttemptPolicy records an idle-only same-policy retry")
    var scopedDeltas: Int64 = 0
    var starts: Int64 = 0
    var aborted: Int64 = 0
    var committed: Int64 = 0
    for (event in runs.eventLog) {
        match (event.meta.attemptId) {
            case Some(_) => match (event.payload) {
                case AgentEventPayload.Extension(_, detail) =>
                    let code = match (detail.field("code")) {
                        case Some(value) => if (value.unifiedKind == ValueKind.Text) { value.text } else { "" }
                        case None => ""
                    }
                    if (code == "model.tool_started" || code == "model.tool_arguments") {
                        if (event.meta.semanticRequestId.isSome()) { scopedDeltas++ }
                    }
                    if (code == "model.attempt_started") { starts++ }
                    if (code == "model.attempt_aborted") { aborted++ }
                    if (code == "model.decision_committed") { committed++ }
                case AgentEventPayload.TextDelta(_) | AgentEventPayload.ReasoningDelta(_) =>
                    if (event.meta.semanticRequestId.isSome()) { scopedDeltas++ }
                case _ => ()
            }
            case None => ()
        }
    }
    expect(scopedDeltas == 1 && starts == 2 && aborted == 1 && committed == 1,
        "U1/U2/U3 provisional and lifecycle events retain durable Attempt identity")
}

class DeadlineThenAnswerModel <: ModelPort {
    let requests = ArrayList<ModelRequest>()
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        requests.add(request)
        if (requests.size == 1) {
            events(ModelEvent.ReasoningDelta("partial"))
            return Result.Err(AgentError(
                AgentErrorKind.Timeout,
                "fixture.stream_idle",
                "fixture stream idle",
                retryable: true,
                attemptFailure: Some(AttemptFailure(
                    AttemptFailureKind.StreamIdleTimeout,
                    diagnostics: AttemptFailureDiagnostics(
                        elapsedMillis: 120000,
                        lastProgressKind: AttemptProgressKind.ToolArgumentProgress,
                        lastProgressAgeMillis: 120000,
                        toolCallsStarted: 1
                    )
                ))
            ))
        }
        events(ModelEvent.TextDelta("recovered output"))
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "recovered")],
            stopReason: "end_turn", responseId: "deadline-retry-success"
        ))
    }
}

func toolEvidenceBlocksRetryContract(): Unit {
    let decisions = RecordingModelDecisionPort()
    let model = ToolEvidenceTimeoutModel()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let result = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, modelDecisionRuntime: Some(decisions)
    ).start(AgentRunRequest(
        RunId("tool-evidence-no-retry-run"),
        SessionId("tool-evidence-no-retry-session"),
        "fixture", "do not replay provisional tool evidence"
    ))
    expect(result.isError() && model.calls == 1 && decisions.createdAttempts.size == 1 &&
        runs.modelAttempts[0].replayBarrier == ModelAttemptReplayBarrier.ToolEvidence,
        "T6b provisional ToolCall evidence durably prevents A2")
}

func malformedToolArgumentsRetryContract(): Unit {
    let model = MalformedToolArgumentsThenSuccessModel()
    let decisions = RecordingModelDecisionPort()
    let catalog = ToolCatalog()
    let runs = MemoryRuns()
    let threads = InMemoryThreadRuntimeRegistry(
        ContextProjector("malformed-tool-retry-contract", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let result = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog,
        threadRuntimes: Some(threads),
        modelDecisionRuntime: Some(decisions),
        modelAttemptRecovery: ModelAttemptRecoveryPolicy(
            mode: ModelAttemptRecoveryMode.RecoveryV1,
            attemptTimeoutMillis: 5000,
            maxRecoveryRetries: 1
        )
    ).start(AgentRunRequest(
        RunId("malformed-tool-retry-run"),
        SessionId("malformed-tool-retry-session"),
        "fixture", "retry malformed terminal tool arguments"
    ))
    let snapshot = threads.acquire(
        ThreadId("malformed-tool-retry-session"), "agent-core"
    ).value().getOrThrow().threadSnapshot()
    var toolItems: Int64 = 0
    for (item in snapshot.items) {
        if (item.kind == ItemKind.ToolCall || item.kind == ItemKind.ToolResult) {
            toolItems += 1
        }
    }
    let finalSnapshot = runs.find(RunId("malformed-tool-retry-run")).value().getOrThrow()
    var observedFailedUsage = false
    for (event in runs.eventLog) {
        match (event.payload) {
            case AgentEventPayload.ModelRequestAttemptCompleted(value) =>
                if (value.attempt == 1) {
                    observedFailedUsage = match (value.usage) {
                        case Some(usage) => usage.inputTokens == 500 &&
                            usage.outputTokens == 100
                        case None => false
                    }
                }
            case _ => ()
        }
    }
    expect(
        finalSnapshot.usage.inputTokens == 500 && finalSnapshot.usage.outputTokens == 100 &&
        observedFailedUsage && result.isOk() && model.calls == 2 &&
        decisions.attempts == 2 &&
        decisions.decisions == 1 && runs.modelAttempts.size == 2 &&
        runs.modelAttempts[0].replayBarrier == ModelAttemptReplayBarrier.ToolEvidence &&
        decisions.terminalizedIds.size == 1 &&
        decisions.terminalizedIds[0].value == runs.modelAttempts[0].id.value &&
        decisions.terminalizedLifecycles[0] == ModelAttemptLifecycle.Abandoned &&
        snapshot.items.size == 2 && toolItems == 0,
        "malformed terminal tool JSON retries after ToolEvidence without canonical tool items"
    )
}

func providerTerminalMissingRetryContract(): Unit {
    let model = ProviderTerminalMissingThenSuccessModel()
    let decisions = RecordingModelDecisionPort()
    let catalog = ToolCatalog()
    let runs = MemoryRuns()
    let threads = InMemoryThreadRuntimeRegistry(
        ContextProjector("provider-terminal-retry-contract", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let result = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(threads),
        modelDecisionRuntime: Some(decisions),
        modelAttemptRecovery: ModelAttemptRecoveryPolicy(
            mode: ModelAttemptRecoveryMode.RecoveryV1,
            attemptTimeoutMillis: 5000,
            maxRecoveryRetries: 1
        )
    ).start(AgentRunRequest(
        RunId("provider-terminal-retry-run"),
        SessionId("provider-terminal-retry-session"),
        "fixture", "retry provider EOF before terminal"
    ))
    let snapshot = threads.acquire(
        ThreadId("provider-terminal-retry-session"), "agent-core"
    ).value().getOrThrow().threadSnapshot()
    var toolItems: Int64 = 0
    for (item in snapshot.items) {
        if (item.kind == ItemKind.ToolCall || item.kind == ItemKind.ToolResult) {
            toolItems += 1
        }
    }
    var visibleDeltas: Int64 = 0
    var staleVisible = false
    var recoveredVisible = false
    for (event in runs.eventLog) {
        match (event.payload) {
            case AgentEventPayload.TextDelta(value) =>
                visibleDeltas += 1
                if (value == "stale partial") { staleVisible = true }
                if (value == "recovered partial") { recoveredVisible = true }
            case _ => ()
        }
    }
    expect(
        result.isOk() && model.calls == 2 && decisions.attempts == 2 &&
        decisions.decisions == 1 && runs.modelAttempts.size == 2 &&
        runs.modelAttempts[0].replayBarrier == ModelAttemptReplayBarrier.ToolEvidence &&
        decisions.terminalizedIds.size == 1 &&
        decisions.terminalizedIds[0].value == runs.modelAttempts[0].id.value &&
        decisions.terminalizedLifecycles[0] == ModelAttemptLifecycle.Abandoned &&
        snapshot.items.size == 2 && toolItems == 0 && visibleDeltas == 1 &&
        !staleVisible && recoveredVisible,
        "provider EOF retries after ToolEvidence without canonical tool items"
    )
}

func cancellationAndRunDeadlineBarriersContract(): Unit {
    let admissionRuns = MemoryRuns(blockInitialSave: true)
    let admissionModel = CancellationBarrierModel()
    let admissionCatalog = ToolCatalog()
    let admissionCore = AgentCore(
        admissionModel, admissionRuns,
        ToolPipeline(admissionCatalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        admissionCatalog
    )
    let admissionRunId = RunId("cancellation-admission-window-run")
    let admissionFuture = spawn {
        admissionCore.start(AgentRunRequest(
            admissionRunId, SessionId("cancellation-admission-window-session"),
            "fixture", "cancel before the compatibility snapshot is visible"
        ))
    }
    while (!admissionRuns.initialSaveStarted()) {
        sleep(Duration.millisecond)
    }
    let admissionCancel = spawn { admissionCore.cancel(admissionRunId) }
    sleep(Duration.millisecond * 20)
    admissionRuns.releaseInitialSave()
    expect(admissionCancel.get().isOk() && admissionFuture.get().isError() &&
        admissionModel.calls == 0,
        "cancellation uses the active owner before the compatibility snapshot is visible")

    let cancellationRuns = MemoryRuns()
    let cancellationModel = CancellationBarrierModel()
    let cancellationCatalog = ToolCatalog()
    let cancellationCore = AgentCore(
        cancellationModel, cancellationRuns,
        ToolPipeline(
            cancellationCatalog, MemoryOperations(), MemoryAudit(), FixtureIds()
        ),
        cancellationCatalog
    )
    let cancellationRunId = RunId("cancellation-barrier-run")
    let cancellationFuture = spawn {
        cancellationCore.start(AgentRunRequest(
            cancellationRunId, SessionId("cancellation-barrier-session"),
            "fixture", "cancel after dispatch",
            budget: ResourceBudget(maxWallMillis: 60000, maxIdleMillis: 60000)
        ))
    }
    while (!cancellationModel.hasStarted()) {
        sleep(Duration.millisecond * 5)
    }
    expect(cancellationCore.cancel(cancellationRunId).isOk(),
        "user cancellation reaches the active model Attempt")
    let cancelled = cancellationFuture.get()
    expect(cancelled.isError() && cancellationModel.calls == 1 &&
        cancellationRuns.modelAttempts.size == 1 &&
        cancellationRuns.modelAttempts[0].replayBarrier ==
            ModelAttemptReplayBarrier.Cancelled,
        "first cancellation observation durably blocks model replay")

    let deadlineRuns = MemoryRuns()
    let deadlineModel = CancellationBarrierModel()
    let deadlineCatalog = ToolCatalog()
    let deadlineCore = AgentCore(
        deadlineModel, deadlineRuns,
        ToolPipeline(deadlineCatalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        deadlineCatalog
    )
    let deadlineRunId = RunId("run-deadline-barrier-run")
    // Separate admission/dispatch from expiry. A 20 ms wall budget could
    // expire during admission on a loaded full-workspace gate, so it did not
    // deterministically exercise the post-dispatch replay barrier.
    let deadlineFuture = spawn {
        deadlineCore.start(AgentRunRequest(
            deadlineRunId,
            SessionId("run-deadline-barrier-session"),
            "fixture", "expire after dispatch",
            budget: ResourceBudget(maxWallMillis: 5000, maxIdleMillis: 60000)
        ))
    }
    while (!deadlineModel.hasStarted()) {
        sleep(Duration.millisecond * 5)
    }
    let deadline = deadlineFuture.get()
    expect(deadline.isError() && deadlineModel.calls == 1 &&
        deadlineRuns.modelAttempts.size == 1 &&
        deadlineRuns.modelAttempts[0].replayBarrier ==
            ModelAttemptReplayBarrier.RunDeadline,
        "first Run deadline observation durably blocks model replay")
}

class CancellationBarrierModel <: ModelPort {
    private let lock = Mutex()
    var calls: Int64 = 0
    private var started = false
    private var cancelled = false

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request.requestId
        let _ = events
        lock.lock()
        try {
            calls += 1
            started = true
        } finally { lock.unlock() }
        while (!isCancelled()) {
            sleep(Duration.millisecond * 5)
        }
        Result.Err(AgentError(
            AgentErrorKind.Cancelled, "fixture.cancelled", "fixture model cancelled"
        ))
    }

    public func cancel(requestId: String): Result<Unit> {
        let _ = requestId
        lock.lock()
        try { cancelled = true } finally { lock.unlock() }
        Result.Ok(())
    }

    func hasStarted(): Bool {
        lock.lock()
        try { started } finally { lock.unlock() }
    }

    private func isCancelled(): Bool {
        lock.lock()
        try { cancelled } finally { lock.unlock() }
    }
}

class ToolEvidenceTimeoutModel <: ModelPort {
    var calls: Int64 = 0
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request.requestId
        calls += 1
        events(ModelEvent.ToolCallStarted("partial", "write"))
        events(ModelEvent.ToolArgumentsDelta("partial", "{\"path\":"))
        Result.Err(AgentError(
            AgentErrorKind.Timeout,
            "fixture.tool_evidence_timeout",
            "tool evidence raced timeout",
            retryable: true,
            attemptFailure: Some(AttemptFailure(AttemptFailureKind.StreamIdleTimeout))
        ))
    }
}

func durableDecisionSuppressesRetryRaceContract(): Unit {
    let model = DeadlineRaceModel()
    let decisions = TimeoutRaceDecisionPort()
    let catalog = ToolCatalog()
    let result = AgentCore(
        model, MemoryRuns(),
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, modelDecisionRuntime: Some(decisions)
    ).start(AgentRunRequest(
        RunId("deadline-decision-race-run"),
        SessionId("deadline-decision-race-session"),
        "fixture", "race durable decision"
    ))
    expect(result.isOk() && model.calls == 1 && decisions.attempts == 1 &&
        decisions.projected,
        "T8 a durable Decision observed on the timeout path is projected without A2")
}

class DeadlineRaceModel <: ModelPort {
    var calls: Int64 = 0
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request.requestId
        calls += 1
        events(ModelEvent.ReasoningDelta("partial"))
        Result.Err(AgentError(
            AgentErrorKind.Timeout, "fixture.timeout_race", "timeout raced persistence",
            retryable: true,
            attemptFailure: Some(AttemptFailure(
                AttemptFailureKind.AttemptHardDeadlineExceeded
            ))
        ))
    }
}

class TimeoutRaceDecisionPort <: ModelDecisionRuntimePort {
    var lookups: Int64 = 0
    var attempts: Int64 = 0
    var projected = false
    private var activeAttemptId = ModelAttemptId("timeout-race-unbound")
    private var activeSemanticRequestId = SemanticModelRequestId("timeout-race-unbound")
    public func abandonOpenAttempts(runId: RunId, abandonedAtMillis: Int64): Result<Unit> {
        let _ = runId.value
        let _ = abandonedAtMillis
        Result.Ok(())
    }
    public func createAttempt(value: DurableModelAttempt): Result<Unit> {
        activeAttemptId = value.id
        activeSemanticRequestId = value.semanticRequestId
        attempts += 1
        Result.Ok(())
    }
    public func terminalizeAttempt(
        attemptId: ModelAttemptId, lifecycle: ModelAttemptLifecycle,
        failureKind: String, completedAtMillis: Int64
    ): Result<Unit> {
        let _ = attemptId.value
        let _ = lifecycle
        let _ = failureKind
        let _ = completedAtMillis
        Result.Ok(())
    }
    public func persistValidatedDecision(value: ModelDecision): Result<Unit> {
        let _ = value.id.value
        Result.Ok(())
    }
    public func finalizeUsage(
        decisionId: ModelDecisionId, usage: ModelUsage, finalizedAtMillis: Int64
    ): Result<Unit> {
        let _ = decisionId.value
        let _ = usage.outputTokens
        let _ = finalizedAtMillis
        Result.Ok(())
    }
    public func uncommittedDecision(runId: RunId): Result<?ModelDecision> {
        let _ = runId.value
        lookups += 1
        Result.Ok(if (lookups == 1 || projected) { None } else { Some(ModelDecision(
            ModelDecisionId("timeout-race-decision"),
            activeAttemptId,
            activeSemanticRequestId,
            [DurableDecisionBlock(
                DecisionBlockId("timeout-race-block"), 0,
                ModelBlock(ModelBlockKind.Text, text: "durable winner")
            )],
            TerminalEvidence(
                "fixture", "message_stop", messageTerminalObserved: true,
                streamEofObserved: true, adapterVersion: "race-v1"
            ),
            DecisionValidationStatus.Validated,
            CompletionDisposition.Complete,
            DecisionOutcome.Response,
            "race-content", "race-replay", 1,
            providerId: "fixture", providerResponseId: "race-response",
            createdAtMillis: 1
        )) })
    }
    public func recordCanonicalProjection(
        decisionId: ModelDecisionId, sources: Array<CommittedToolCallSource>
    ): Result<Unit> {
        let _ = decisionId.value
        let _ = sources.size
        projected = true
        Result.Ok(())
    }
    public func committedToolCallSources(
        runId: RunId
    ): Result<Array<CommittedToolCallSource>> {
        let _ = runId.value
        Result.Ok([])
    }
}

func modelResumeCrashWindowMatrixContract(): Unit {
    preparedAttemptResumeContract()
    claimedAttemptRestartContract()
    claimedA2NeverCreatesA3Contract()
    durableDecisionResumeStartsNoProviderContract()
}

func preparedAttemptResumeContract(): Unit {
    let runs = MemoryRuns(failClaimBeforeCommitAt: 1)
    let decisions = RecordingModelDecisionPort()
    let model = ResumeAnswerModel()
    let catalog = ToolCatalog()
    let request = AgentRunRequest(
        RunId("prepared-resume-run"), SessionId("prepared-resume-session"),
        "fixture", "resume prepared attempt"
    )
    let core = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(resumeThreadRegistry("prepared-resume")),
        modelDecisionRuntime: Some(decisions)
    )
    let first = core.start(request)
    expect(first.isError() && model.calls == 0 && runs.modelAttempts.size == 1 &&
        runs.modelAttempts[0].dispatchState == ModelAttemptDispatchState.Prepared,
        "R1 crash before dispatch leaves A1 Prepared")
    runs.failClaimBeforeCommitAt = 0
    let resumed = core.resume(request)
    match (resumed) {
        case Result.Ok(_) => ()
        case Result.Err(error) => throw IllegalStateException(
            "R1 resume failed: " + error.code + ": " + error.message
        )
    }
    expect(
        resumed.isOk() && model.calls == 1 && runs.modelAttempts.size == 1,
        "R1 Prepared A1 resumes exactly once without creating A2 " +
            "calls=" + model.calls.toString() +
            " attempts=" + runs.modelAttempts.size.toString()
    )
}

func claimedAttemptRestartContract(): Unit {
    let runs = MemoryRuns(failClaimAfterCommitAt: 1)
    let decisions = RecordingModelDecisionPort()
    let model = ResumeAnswerModel()
    let catalog = ToolCatalog()
    let request = AgentRunRequest(
        RunId("claimed-resume-run"), SessionId("claimed-resume-session"),
        "fixture", "resume claimed attempt"
    )
    let first = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(resumeThreadRegistry("claimed-resume-first")),
        modelDecisionRuntime: Some(decisions)
    ).start(request)
    expect(first.isError() && model.calls == 0 &&
        runs.modelAttempts[0].dispatchState == ModelAttemptDispatchState.DispatchClaimed,
        "R2 crash after A1 dispatch freezes a claimed parent")
    runs.failClaimAfterCommitAt = 0
    let resumed = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(resumeThreadRegistry("claimed-resume-second")),
        modelDecisionRuntime: Some(decisions)
    ).resume(request)
    expect(resumed.isOk() && model.calls == 1 && runs.modelAttempts.size == 2 &&
        runs.modelAttempts[0].lifecycle == ModelAttemptLifecycle.Abandoned &&
        runs.modelAttempts[1].attemptNo == 2 &&
        hasEvent(runs.eventLog, "model.restart_retry_possible_duplicate"),
        "R2 A1 to A2 restart boundary commits and dispatches once")
}

func claimedA2NeverCreatesA3Contract(): Unit {
    let runs = MemoryRuns(failClaimAfterCommitAt: 1)
    let decisions = RecordingModelDecisionPort()
    let model = ResumeAnswerModel()
    let catalog = ToolCatalog()
    let request = AgentRunRequest(
        RunId("claimed-a2-run"), SessionId("claimed-a2-session"),
        "fixture", "never create A3"
    )
    let firstCore = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(resumeThreadRegistry("claimed-a2-first")),
        modelDecisionRuntime: Some(decisions)
    )
    expect(firstCore.start(request).isError(), "R3 A1 claim crash is injected")
    runs.failClaimAfterCommitAt = 2
    let secondCore = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(resumeThreadRegistry("claimed-a2-second")),
        modelDecisionRuntime: Some(decisions)
    )
    expect(secondCore.resume(request).isError() && runs.modelAttempts.size == 2 &&
        runs.modelAttempts[1].dispatchState == ModelAttemptDispatchState.DispatchClaimed,
        "R3 A2 claim crash is durable")
    runs.failClaimAfterCommitAt = 0
    let thirdCore = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(resumeThreadRegistry("claimed-a2-third")),
        modelDecisionRuntime: Some(decisions)
    )
    expect(thirdCore.resume(request).isError() && model.calls == 0 &&
        runs.modelAttempts.size == 2,
        "R3 claimed A2 fails recovery without creating A3 or provider I/O")
}

func durableDecisionResumeStartsNoProviderContract(): Unit {
    let runs = MemoryRuns(failClaimAfterCommitAt: 1)
    let decisions = RecordingModelDecisionPort()
    let model = ResumeAnswerModel()
    let catalog = ToolCatalog()
    let request = AgentRunRequest(
        RunId("durable-resume-run"), SessionId("durable-resume-session"),
        "fixture", "reuse durable decision"
    )
    let firstCore = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(resumeThreadRegistry("durable-resume-first")),
        modelDecisionRuntime: Some(decisions)
    )
    expect(firstCore.start(request).isError(), "R4 dispatch crash is injected")
    let attempt = runs.modelAttempts[0]
    decisions.recoveredDecision = Some(ModelDecision(
        ModelDecisionId("durable-resume-decision"),
        attempt.id, attempt.semanticRequestId,
        [DurableDecisionBlock(
            DecisionBlockId("durable-resume-block"), 0,
            ModelBlock(ModelBlockKind.Text, text: "durable response")
        )],
        TerminalEvidence(
            "fixture", "message_stop", messageTerminalObserved: true,
            streamEofObserved: true, adapterVersion: "resume-v1"
        ),
        DecisionValidationStatus.Validated,
        CompletionDisposition.Complete,
        DecisionOutcome.Response,
        "durable-content", "durable-replay", 1,
        providerId: "fixture", providerResponseId: "durable-response",
        createdAtMillis: 1
    ))
    runs.failClaimAfterCommitAt = 0
    let resumed = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(resumeThreadRegistry("durable-resume-second")),
        modelDecisionRuntime: Some(decisions)
    ).resume(request)
    expect(resumed.isOk() && model.calls == 0 && runs.modelAttempts.size == 1 &&
        decisions.projected,
        "R4 durable Decision resumes with zero provider starts")
}

func resumeThreadRegistry(name: String): ThreadRuntimeRegistry {
    InMemoryThreadRuntimeRegistry(
        ContextProjector(name, ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
}

class ResumeAnswerModel <: ModelPort {
    var calls: Int64 = 0
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request.requestId
        calls += 1
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "resumed")],
            stopReason: "end_turn", responseId: "resume-answer"
        ))
    }
}

func typedTerminalFailureContract(): Unit {
    let limited = runTerminalFailureModel(
        OutputLimitedModel(), "output-limited-run", "output-limited-session"
    )
    expect(limited.isError() && match (limited.error()) {
        case Some(error) => match (error.attemptFailure) {
            case Some(value) => value.kind == AttemptFailureKind.OutputLimitedBeforeDecision
            case None => false
        }
        case None => false
    }, "T11 output-limited-before-decision is typed separately from transport timeout")
    let missing = runTerminalFailureModel(
        MissingTerminalModel(), "missing-terminal-run", "missing-terminal-session"
    )
    expect(missing.isError() && match (missing.error()) {
        case Some(error) => match (error.attemptFailure) {
            case Some(value) => value.kind == AttemptFailureKind.ProviderTerminalMissing
            case None => false
        }
        case None => false
    }, "T12 provider EOF without terminal evidence is ProviderTerminalMissing")
}

func runTerminalFailureModel(
    model: ModelPort,
    runId: String,
    sessionId: String
): Result<AgentRunOutcome> {
    let catalog = ToolCatalog()
    AgentCore(
        model, MemoryRuns(),
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog
    ).start(AgentRunRequest(RunId(runId), SessionId(sessionId), "fixture", "fail"))
}

class OutputLimitedModel <: ModelPort {
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request.requestId
        events(ModelEvent.ProviderProgress(
            ProviderStreamEvent.MessageTerminalObserved(TerminalEvidence(
                "fixture", "message_stop", rawStopReason: "max_tokens",
                messageTerminalObserved: true, streamEofObserved: true,
                adapterVersion: "terminal-failure-v1"
            ))
        ))
        Result.Ok(ModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "partial")],
            stopReason: "max_tokens", acceptedOutput: false,
            providerId: "fixture", responseId: "limited",
            terminalEvidence: Some(TerminalEvidence(
                "fixture", "message_stop", rawStopReason: "max_tokens",
                messageTerminalObserved: true, streamEofObserved: true,
                adapterVersion: "terminal-failure-v1"
            )),
            completionDisposition: CompletionDisposition.OutputLimited,
            decisionOutcome: DecisionOutcome.Response,
            validationVersion: 1
        ))
    }
}

class MissingTerminalModel <: ModelPort {
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request.requestId
        events(ModelEvent.TextDelta("partial"))
        events(ModelEvent.ProviderProgress(ProviderStreamEvent.StreamTransportClosed))
        Result.Ok(ModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "partial")],
            stopReason: "end_turn", acceptedOutput: true,
            providerId: "fixture", responseId: "missing-terminal",
            completionDisposition: CompletionDisposition.ProtocolIncomplete,
            decisionOutcome: DecisionOutcome.Response,
            validationVersion: 1
        ))
    }
}

func outputLimitedBeforeDecisionRecoveryContract(): Unit {
    let model = ReasoningStarvationModel()
    let decisions = RecordingModelDecisionPort()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let echo = EchoTool()
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("echo", "echo", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        echo
    ).isOk(), "reasoning-starvation fixture tool registers")
    let result = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog,
        modelDecisionRuntime: Some(decisions),
        modelAttemptRecovery: ModelAttemptRecoveryPolicy(
            mode: ModelAttemptRecoveryMode.RecoveryV1,
            maxRecoveryRetries: 1
        )
    ).start(AgentRunRequest(
        RunId("reasoning-starvation-run"),
        SessionId("reasoning-starvation-session"),
        "deepseek/profile-model",
        "produce one complete tool decision",
        thinking: ThinkingLevel.High,
        userRequestedThinking: Some(ThinkingLevel.High),
        thinkingSource: ThinkingPreferenceSource.ExplicitUser,
        modelCapabilitiesSnapshot: Some(ModelExecutionCapabilitiesSnapshot(
            "deepseek/profile-model",
            ThinkingCapabilities(
                ThinkingControlMode.Effort,
                supportedLevels: [ThinkingLevel.Low, ThinkingLevel.High]
            ),
            4096
        )),
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
        budget: ResourceBudget(maxOutputTokens: 4096)
    ))
    expect(result.isOk() && model.calls == 3 && model.thinkingLevels.size == 3 &&
        model.thinkingLevels[0] == ThinkingLevel.High &&
        model.thinkingLevels[1] == ThinkingLevel.Low &&
        model.thinkingLevels[2] == ThinkingLevel.High,
        "output-limited child attempt lowers only that semantic request and the next turn restores requested thinking")
    expect(decisions.createdAttempts.size == 3 &&
        decisions.createdAttempts[0].parentAttemptId.isNone() &&
        decisions.createdAttempts[1].parentAttemptId.isSome() &&
        decisions.createdAttempts[1].policyReason == "output_limit_recovery" &&
        decisions.createdAttempts[1].policy.field("thinking_source").getOrThrow().text == "explicit_user" &&
        echo.persistedResults == 1,
        "child Attempt is durable before I/O, retains requested-policy audit, and only the accepted retry tool executes")
}

class ReasoningStarvationModel <: ModelPort {
    var calls: Int64 = 0
    let thinkingLevels = ArrayList<ThinkingLevel>()

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls += 1
        thinkingLevels.add(request.thinking)
        if (calls == 1) {
            events(ModelEvent.ReasoningDelta("long reasoning"))
            events(ModelEvent.ToolCallStarted("partial-call", "echo"))
            events(ModelEvent.ToolArgumentsDelta("partial-call", "{\"text\":"))
            let terminal = TerminalEvidence(
                "openai_chat_completions", "finish_reason",
                rawStopReason: "max_tokens", messageTerminalObserved: true,
                streamEofObserved: true, adapterVersion: "deepseek-regression-v1"
            )
            events(ModelEvent.ProviderProgress(
                ProviderStreamEvent.MessageTerminalObserved(terminal)
            ))
            return Result.Ok(ModelReply(
                [ModelBlock(ModelBlockKind.Reasoning, text: "long reasoning")],
                stopReason: "max_tokens", acceptedOutput: false,
                providerId: "deepseek-openai", responseId: "limited-1",
                usage: Some(ModelUsage(outputTokens: 100, reasoningTokens: 90)),
                terminalEvidence: Some(terminal),
                completionDisposition: CompletionDisposition.OutputLimited,
                decisionOutcome: DecisionOutcome.Unknown,
                validationVersion: 1
            ))
        }
        if (calls == 2) {
            events(ModelEvent.ToolCallStarted("accepted-call", "echo"))
            events(ModelEvent.ToolArgumentsDelta("accepted-call", "{}"))
            events(ModelEvent.ToolCallCompleted("accepted-call"))
            events(ModelEvent.Completed)
            return Result.Ok(contractModelReply(
                [ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "accepted-call", name: "echo", arguments: objectValue([])
                )],
                stopReason: "tool_calls", providerId: "deepseek-openai",
                responseId: "accepted-2"
            ))
        }
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "done")],
            stopReason: "stop", providerId: "deepseek-openai",
            responseId: "final-3"
        ))
    }
}

func outputLimitedRecoveryExhaustionContract(): Unit {
    let model = AlwaysOutputLimitedModel()
    let decisions = RecordingModelDecisionPort()
    let catalog = ToolCatalog()
    let result = AgentCore(
        model, MemoryRuns(),
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog,
        modelDecisionRuntime: Some(decisions),
        modelAttemptRecovery: ModelAttemptRecoveryPolicy(maxRecoveryRetries: 1)
    ).start(AgentRunRequest(
        RunId("reasoning-exhausted-run"), SessionId("reasoning-exhausted-session"),
        "deepseek/exhausted", "never reaches a decision",
        thinking: ThinkingLevel.High,
        modelCapabilitiesSnapshot: Some(ModelExecutionCapabilitiesSnapshot(
            "deepseek/exhausted",
            ThinkingCapabilities(
                ThinkingControlMode.Effort,
                supportedLevels: [ThinkingLevel.Low, ThinkingLevel.High]
            ),
            2048
        )),
        budget: ResourceBudget(maxOutputTokens: 2048)
    ))
    expect(result.isError() && model.calls == 2 && decisions.decisions == 0 &&
        match (result.error()) {
            case Some(error) => error.code == "model.output_limited_before_decision" &&
                error.field("recovery_attempts") == Some("1") &&
                error.field("reasoning_tokens") == Some("90") &&
                error.field("effective_wire_output_tokens") == Some("2048") &&
                error.field("effective_thinking_level") == Some("low") &&
                error.field("parent_attempt_id").isSome() &&
                error.field("reasoning_share").isSome() &&
                error.field("decision_boundary_accepted") == Some("false")
            case None => false
        },
        "output-limited recovery is bounded and reports the reasoning-starvation root cause")
}

class AlwaysOutputLimitedModel <: ModelPort {
    var calls: Int64 = 0
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls += 1
        events(ModelEvent.ReasoningDelta("reasoning"))
        let terminal = TerminalEvidence(
            "openai_chat_completions", "finish_reason",
            rawStopReason: "max_tokens", messageTerminalObserved: true,
            streamEofObserved: true, adapterVersion: "deepseek-exhaustion-v1"
        )
        events(ModelEvent.ProviderProgress(
            ProviderStreamEvent.MessageTerminalObserved(terminal)
        ))
        Result.Ok(ModelReply(
            [ModelBlock(ModelBlockKind.Reasoning, text: "reasoning")],
            stopReason: "max_tokens", acceptedOutput: false,
            providerId: "deepseek-openai", responseId: "limited-" + calls.toString(),
            usage: Some(ModelUsage(outputTokens: 100, reasoningTokens: 90)),
            terminalEvidence: Some(terminal),
            completionDisposition: CompletionDisposition.OutputLimited,
            validationVersion: 1
        ))
    }
}

func activeSkillStackContract(): Unit {
    let model = SkillObservingModel()
    let core = AgentCore(
        model,
        MemoryRuns(),
        ToolPipeline(ToolCatalog(), MemoryOperations(), MemoryAudit(), FixtureIds()),
        ToolCatalog()
    )
    let descriptor = SkillDescriptor(
        "review", "review", "Review changed code", ["review"], "skill://review"
    )
    let result = core.start(AgentRunRequest(
        RunId("skill-run"),
        SessionId("skill-session"),
        "fixture",
        "review this",
        skillStack: SkillStackSnapshot([
            SkillActivation(descriptor, "Inspect correctness and cite evidence.")
        ], [])
    ))
    expect(result.isOk(), "active Skill Run completes")
    expect(
        model.system.contains("<active_skills trust=\"user_selected\" capabilities=\"none\">") &&
            model.system.contains("Inspect correctness and cite evidence."),
        "active Skill instructions enter the frozen model system prefix"
    )
}

func controlledInternalModelCallContract(): Unit {
    let runs = MemoryRuns()
    let runId = RunId("internal-model-run")
    let sessionId = SessionId("internal-model-session")
    runs.save(RunSnapshot(
        runId,
        sessionId,
        RunState.WaitingApproval,
        modelRequests: 1,
        inputTokens: 10,
        outputTokens: 2,
        costMicros: Some(10)
    )).value().getOrThrow()
    let provider = DetailedUsageModel()
    let control = ControlledModelPort(provider, runs: Some(runs))
    let parent = AgentRunRequest(
        runId,
        sessionId,
        "fixture",
        "review pending tool",
        budget: ResourceBudget(
            maxInputTokens: 1000,
            maxOutputTokens: 100,
            maxModelRequests: 2,
            maxCostMicros: 1000
        ),
        pricing: Some(ModelPricing(
            inputMicrosPerMillion: Some(1000000),
            outputMicrosPerMillion: Some(2000000),
            cacheReadMicrosPerMillion: Some(500000),
            cacheWriteMicrosPerMillion: Some(1500000)
        ))
    )
    let request = ModelRequest(
        "fixture",
        [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "review")])],
        tools: [],
        maxOutputTokens: 100,
        streaming: false,
        parallelToolCalls: false,
        requestId: "internal-review-request",
        toolChoice: ModelToolChoice.NoTools
    )
    let first = control.executeInternal(
        request,
        InternalModelCallOptions(timeoutMillis: 1000, parent: Some(parent))
    )
    let charged = runs.find(runId).value().getOrThrow()
    let second = control.executeInternal(
        request,
        InternalModelCallOptions(timeoutMillis: 1000, parent: Some(parent))
    )
    let durableUsageEvent = runs.eventLog.size == 2 && match (runs.eventLog[0].payload) {
        case AgentEventPayload.ModelUsageUpdated(usage) =>
            usage.inputTokens == 100 && usage.outputTokens == 20 &&
            usage.reasoningTokens == 5 && usage.cacheReadTokens == 30 &&
            usage.cacheWriteTokens == 10 && usage.costMicros == Some(130) &&
            match (runs.eventLog[0].meta.requestId) {
                case Some(value) => value.value == "internal-review-request"
                case None => false
            }
        case _ => false
    }
    let durableAttemptEvent = runs.eventLog.size == 2 && match (runs.eventLog[1].payload) {
        case AgentEventPayload.ModelRequestAttemptCompleted(value) =>
            value.requestId.value == "internal-review-request" &&
            value.model == "fixture" && value.attempt == 1 &&
            value.outcome == ModelRequestOutcome.Succeeded &&
            match (value.usage) {
                case Some(usage) => usage.inputTokens == 100 &&
                    usage.outputTokens == 20 && usage.costMicros == Some(130)
                case None => false
            }
        case _ => false
    }
    expect(
        first.isOk() && provider.calls == 1 && charged.modelRequests == 2 &&
            charged.sequence == 2 && durableUsageEvent && durableAttemptEvent &&
            charged.inputTokens == 110 && charged.outputTokens == 22 &&
            charged.reasoningTokens == 5 && charged.cacheReadTokens == 30 &&
            charged.cacheWriteTokens == 10 && charged.costMicros == Some(140) &&
            second.isError() && second.error().getOrThrow().kind == AgentErrorKind.BudgetExceeded,
        "internal reviewer calls share retry, timeout, durable usage, cost, and parent request budgets"
    )
    let cancelledRuns = MemoryRuns()
    let cancelledRunId = RunId("internal-model-cancelled")
    cancelledRuns.save(RunSnapshot(
        cancelledRunId,
        sessionId,
        RunState.Cancelled
    )).value().getOrThrow()
    let cancelledProvider = DetailedUsageModel()
    let cancelledControl = ControlledModelPort(
        cancelledProvider,
        runs: Some(cancelledRuns)
    )
    let cancelledParent = AgentRunRequest(
        cancelledRunId,
        sessionId,
        "fixture",
        "cancelled parent",
        budget: ResourceBudget(deadlineMillis: agentUtcMillis() + 60000)
    )
    let cancelled = cancelledControl.executeInternal(
        request,
        InternalModelCallOptions(
            timeoutMillis: 1000,
            parent: Some(cancelledParent)
        )
    )
    expect(
        cancelled.isError() &&
            cancelled.error().getOrThrow().kind == AgentErrorKind.Cancelled &&
            cancelledProvider.calls == 0,
        "internal model control rejects a cancelled parent before a wire request"
    )
    let expiredRuns = MemoryRuns()
    let expiredRunId = RunId("internal-model-expired")
    expiredRuns.save(RunSnapshot(
        expiredRunId,
        sessionId,
        RunState.Running
    )).value().getOrThrow()
    let expiredProvider = DetailedUsageModel()
    let expired = ControlledModelPort(
        expiredProvider,
        runs: Some(expiredRuns)
    ).executeInternal(
        request,
        InternalModelCallOptions(
            timeoutMillis: 1000,
            parent: Some(AgentRunRequest(
                expiredRunId,
                sessionId,
                "fixture",
                "expired parent",
                budget: ResourceBudget(deadlineMillis: agentUtcMillis() - 1)
            ))
        )
    )
    expect(
        expired.isError() && expired.error().getOrThrow().code ==
            "budget.deadline_exceeded" && expiredProvider.calls == 0,
        "internal model control enforces the absolute parent deadline before execution"
    )
}

func nonPendingDecisionDoesNotPersistContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let core = AgentCore(
        TerminalModel(),
        runs,
        ToolPipeline(
            catalog,
            MemoryOperations(),
            MemoryAudit(),
            FixtureIds()
        ),
        catalog
    )
    let request = AgentRunRequest(
        RunId("not-pending-run"),
        SessionId("not-pending-session"),
        "fixture",
        "must not decide"
    )
    runs.save(RunSnapshot(
        request.runId,
        request.sessionId,
        RunState.Failed
    )).value().getOrThrow()
    let approval = ApprovalRequest(
        OperationId("not-pending-operation"),
        "not-pending-call",
        "write_preview",
        Capability(CapabilityKind.WorkspaceWrite),
        sessionId: request.sessionId.value,
        argumentHash: "not-pending-hash"
    )
    match (core.decide(request, approval, ApprovalDecision.Approve)) {
        case Result.Err(error) => expect(
            error.code == "run.not_awaiting_approval" &&
                runs.savedDecision.isNone(),
            "a non-pending run cannot pollute the durable decision store"
        )
        case _ => throw IllegalStateException(
            "a non-pending run accepted an approval decision"
        )
    }
}

func modelProtocolCapabilityBoundaryContract(model: TwoStepModel): Unit {
    expect(
        model.requests.size == 2 &&
            model.requests[0].parallelToolCalls &&
            model.requests[1].parallelToolCalls,
        "agent core preserves the host-negotiated parallel tool-call setting"
    )
    expect(
        requestContainsToolResult(model.requests[1], "call-1"),
        "the second captured request follows the persisted tool result"
    )
}

func requestContainsToolResult(request: ModelRequest, callId: String): Bool {
    for (message in request.messages) {
        for (block in message.blocks where
             block.kind == ModelBlockKind.ToolResult && block.callId == callId) {
            return true
        }
    }
    false
}

func typedLifecycleContract(events: ArrayList<AgentEvent>, runId: RunId): Unit {
    var sawStarted = false
    var sawRunning = false
    var sawAssistant = false
    var sawBudget = false
    var sawUsage = false
    var sawTurn = false
    var sawCompleted = false
    var sawCorrelatedTool = false
    for (event in events) {
        expect(
            event.meta.traceId.value == "trace-" + runId.value &&
                event.meta.runId.value == runId.value &&
                event.meta.occurredAtMillis > 0,
            "every active-run event carries stable typed correlation metadata"
        )
        match (event.payload) {
            case AgentEventPayload.RunStarted => sawStarted = true
            case AgentEventPayload.RunStateChanged(RunState.Created, RunState.Running, _) => sawRunning = true
            case AgentEventPayload.AssistantStarted(_) => sawAssistant = true
            case AgentEventPayload.BudgetUpdated(_) => sawBudget = true
            case AgentEventPayload.ModelUsageUpdated(_) => sawUsage = true
            case AgentEventPayload.TurnCompleted(_) => sawTurn = true
            case AgentEventPayload.RunCompleted => sawCompleted = true
            case AgentEventPayload.Extension(AgentEventKind.Tool, detail) =>
                match (detail.field("code")) {
                    case Some(code) => if (code.text == "tool.execution_started") {
                        sawCorrelatedTool = event.meta.toolBatchId.isSome() &&
                            event.meta.toolCallId.isSome()
                    }
                    case None => ()
                }
            case _ => ()
        }
    }
    expect(
        sawStarted && sawRunning && sawAssistant && sawBudget && sawUsage &&
            sawTurn && sawCompleted && sawCorrelatedTool,
        "runtime lifecycle, budgets, model usage, turns, and tool calls use typed events"
    )
}

func parallelToolWaveContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let probe = ToolWaveProbe()
    let sharedX = sharedToolConcurrency(accesses: [ToolResourceAccess(
        "workspace",
        "/x",
        ToolAccessMode.Write
    )])
    let sharedY = sharedToolConcurrency(accesses: [ToolResourceAccess(
        "workspace",
        "/y",
        ToolAccessMode.Write
    )])
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("wave_a", "wave a", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead),
            concurrency: sharedX
        ),
        WaveTool("wave_a", 45, probe)
    ).isOk(), "wave a registration")
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("wave_b", "wave b", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead),
            concurrency: sharedX
        ),
        WaveTool("wave_b", 1, probe)
    ).isOk(), "wave b registration")
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("wave_c", "wave c", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead),
            concurrency: sharedY
        ),
        WaveTool("wave_c", 45, probe)
    ).isOk(), "wave c registration")
    let model = ParallelBatchModel()
    let decisions = RecordingModelDecisionPort()
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog,
        modelDecisionRuntime: Some(decisions)
    )
    let result = core.start(AgentRunRequest(
        RunId("parallel-wave-run"),
        SessionId("parallel-wave-session"),
        "fixture",
        "run parallel wave",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
        budget: ResourceBudget(maxConcurrentTools: 2)
    ))
    expect(result.isOk(), "resource-planned parallel tool run completes")
    expect(
        probe.maxActive == 2 && !probe.waveBStartedBeforeAFinished,
        "independent resources overlap while conflicting writes execute in a later wave"
    )
    let ids = transcriptToolResultIds(coreMessages(
        core, SessionId("parallel-wave-session")
    ))
    expect(
        ids.size == 3 && ids[0] == "wave-call-a" && ids[1] == "wave-call-b" &&
            ids[2] == "wave-call-c" && model.observedStableResultOrder,
        "parallel completion is joined back into model call order"
    )
    expect(
        decisions.persisted.size == 2 &&
            decisions.persisted[0].blocks.size == 3,
        "complete multi-tool response becomes one durable atomic Decision"
    )
}

func approvalBatchBarrierContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let safe = EchoTool()
    let write = EchoTool()
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("batch_safe", "safe batch tool", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead),
            concurrency: sharedToolConcurrency()
        ),
        safe
    ).isOk(), "approval batch safe registration")
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("batch_write", "approved batch tool", objectValue([])),
            Capability(CapabilityKind.WorkspaceWrite),
            sideEffecting: true
        ),
        write
    ).isOk(), "approval batch write registration")
    let model = ApprovalBatchModel()
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog
    )
    let request = AgentRunRequest(
        RunId("approval-batch-run"),
        SessionId("approval-batch-session"),
        "fixture",
        "run approval batch",
        capabilities: CapabilitySet(values: [
            Capability(CapabilityKind.WorkspaceRead),
            Capability(CapabilityKind.WorkspaceWrite)
        ])
    )
    let approval = match (core.start(request).value().getOrThrow()) {
        case AgentRunOutcome.AwaitingApproval(_, value) => value
        case _ => throw IllegalStateException("approval batch did not pause")
    }
    expect(
        approval.callId == "approval-call-b" && safe.executions == 1 && write.executions == 0 &&
            transcriptToolResultIds(coreMessages(
                core, SessionId("approval-batch-session")
            )).size == 1,
        "the first approval is a barrier and later calls remain unprepared"
    )
    let completed = core.decide(request, approval, ApprovalDecision.Approve)
    expect(completed.isOk(), "approval batch resumes and completes")
    let ids = transcriptToolResultIds(coreMessages(
        core, SessionId("approval-batch-session")
    ))
    expect(
        safe.executions == 2 && write.executions == 1 && ids.size == 3 &&
            ids[0] == "approval-call-a" && ids[1] == "approval-call-b" &&
            ids[2] == "approval-call-c" && model.observedStableResultOrder,
        "approval resume executes deferred calls once and preserves original result order"
    )
}

func toolContextApprovalResumeContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let probe = ToolContextProbe("/workspace/context-contract")
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("batch_safe", "safe context probe", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead),
            concurrency: sharedToolConcurrency()
        ),
        probe
    ).isOk(), "context probe safe registration")
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("batch_write", "approved context probe", objectValue([])),
            Capability(CapabilityKind.WorkspaceWrite),
            sideEffecting: true
        ),
        probe
    ).isOk(), "context probe write registration")
    let model = BlockingApprovalBatchModel()
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog
    )
    let request = AgentRunRequest(
        RunId("tool-context-resume-run"),
        SessionId("tool-context-resume-session"),
        "fixture",
        "probe tool context",
        capabilities: CapabilitySet(values: [
            Capability(CapabilityKind.WorkspaceRead),
            Capability(CapabilityKind.WorkspaceWrite)
        ]),
        toolContext: ToolContextDescriptor(
            workspaceRoot: "/workspace/context-contract",
            cwd: "/workspace/context-contract/src",
            environment: ToolEnvironmentView(entries: [
                ToolEnvironmentEntry("CONTEXT_VISIBLE", "explicit")
            ]),
            services: ToolServiceView(descriptors: [
                ToolServiceDescriptor(ToolServiceKind.Custom, "context-probe", version: "1")
            ])
        )
    )
    let approval = match (core.start(request).value().getOrThrow()) {
        case AgentRunOutcome.AwaitingApproval(_, value) => value
        case _ => throw IllegalStateException("tool context contract did not pause")
    }
    expect(
        probe.invocationCount() == 1 && probe.metadataMatches(),
        "start binds the explicit immutable ToolContextDescriptor"
    )
    let resumed = spawn {
        core.decide(request, approval, ApprovalDecision.Approve)
    }
    let deadline = MonoTime.now() + Duration.second * 2
    while ((!model.resumeModelStarted() || probe.invocationCount() < 3) && MonoTime.now() < deadline) {
        sleep(Duration.millisecond * 5)
    }
    expect(
        model.resumeModelStarted() && probe.invocationCount() == 3 && probe.metadataMatches(),
        "approval resume preserves tool context for every deferred invocation"
    )
    expect(core.cancel(request.runId).isOk(), "active resumed run can be cancelled")
    let resumedResult = resumed.get()
    expect(
        resumedResult.isError() && probe.cancelledInvocationCount() == 3,
        "start and approval-resume contexts share the current run cancellation source"
    )
}

func partialToolWaveFailureContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let successful = EchoTool()
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("wave_fatal", "fatal wave tool", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead),
            concurrency: sharedToolConcurrency()
        ),
        FatalWaveTool()
    ).isOk(), "fatal wave registration")
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("wave_success", "successful wave tool", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead),
            concurrency: sharedToolConcurrency()
        ),
        successful
    ).isOk(), "successful wave registration")
    let core = AgentCore(
        PartialFailureBatchModel(),
        runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog
    )
    let result = core.start(AgentRunRequest(
        RunId("partial-wave-run"),
        SessionId("partial-wave-session"),
        "fixture",
        "run partial failure wave",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
        budget: ResourceBudget(maxConcurrentTools: 2)
    ))
    let ids = transcriptToolResultIds(coreMessages(
        core, SessionId("partial-wave-session")
    ))
    var hasSuccessfulResult = false
    for (id in ids where id == "partial-call-success") {
        hasSuccessfulResult = true
    }
    expect(
        result.isError() && match (result.error()) {
            case Some(error) => error.code == "fixture.wave_fatal"
            case None => false
        } && successful.executions == 1 && hasSuccessfulResult,
        "a fatal sibling fails the run only after every sibling has a canonical terminal result"
    )
}

func coreMessages(core: AgentCore, sessionId: SessionId): ArrayList<ModelMessage> {
    let values = ArrayList<ModelMessage>()
    for (message in modelMessagesFromCanonicalItems(
        core.threadSnapshot(sessionId).value().getOrThrow().items
    )) {
        values.add(message)
    }
    values
}

func transcriptToolResultIds(messages: ArrayList<ModelMessage>): Array<String> {
    let ids = ArrayList<String>()
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolResult) {
            ids.add(block.callId)
        }
    }
    ids.toArray()
}

func transcriptToolResults(messages: ArrayList<ModelMessage>): Array<ModelBlock> {
    let results = ArrayList<ModelBlock>()
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolResult) {
            results.add(block)
        }
    }
    results.toArray()
}

func partialToolCallNeverEscapesContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = PartialStreamFailureModel()
    let decisions = RecordingModelDecisionPort()
    let threads = InMemoryThreadRuntimeRegistry(
        ContextProjector("partial-decision-contract", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(
            catalog,
            MemoryOperations(),
            MemoryAudit(),
            FixtureIds()
        ),
        catalog,
        threadRuntimes: Some(threads),
        modelDecisionRuntime: Some(decisions)
    )
    let result = core.start(AgentRunRequest(
        RunId("partial-stream-run"),
        SessionId("partial-stream-session"),
        "fixture",
        "do not duplicate partial stream"
    ))
    let snapshot = runs.find(RunId("partial-stream-run")).value().getOrThrow()
    expect(
        result.isError() && model.calls == 1 && snapshot.modelRequests == 1 &&
            decisions.attempts == 1 && decisions.decisions == 0 &&
            match (result.error()) {
                case Some(error) =>
                    error.field("partial_stream") == Some("true")
                case None => false
            },
        "partial ToolCall is not replayed and creates no durable Decision"
    )
    let canonical = threads.acquire(
        ThreadId("partial-stream-session"), "agent-core"
    ).value().getOrThrow().threadSnapshot()
    expect(canonical.items.size == 1,
        "partial ToolCall creates no canonical assistant/tool Item")
}

class PartialStreamFailureModel <: ModelPort {
    var calls: Int64 = 0

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request
        calls += 1
        events(ModelEvent.ToolCallStarted("partial-call", "write"))
        events(ModelEvent.ToolArgumentsDelta("partial-call", "{\"path\":\"/tmp"))
        Result.Err(
            AgentError(
                AgentErrorKind.Transport,
                "fixture.partial_stream_failed",
                "stream failed after a visible delta",
                retryable: true
            )
        )
    }
}

func completedBlockIsNotDecisionContract(): Unit {
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = CompletedThenPartialModel()
    let decisions = RecordingModelDecisionPort()
    let threads = InMemoryThreadRuntimeRegistry(
        ContextProjector("multi-partial-contract", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let core = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(threads),
        modelDecisionRuntime: Some(decisions)
    )
    let result = core.start(AgentRunRequest(
        RunId("multi-partial-run"), SessionId("multi-partial-session"),
        "fixture", "one complete block is not a decision"
    ))
    let canonical = threads.acquire(
        ThreadId("multi-partial-session"), "agent-core"
    ).value().getOrThrow().threadSnapshot()
    expect(result.isError() && decisions.decisions == 0 && canonical.items.size == 1,
        "completed Tool A plus partial Tool B produces no Decision or canonical ToolCall")
}

class CompletedThenPartialModel <: ModelPort {
    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request.requestId
        events(ModelEvent.ToolCallStarted("call-a", "read"))
        events(ModelEvent.ToolArgumentsDelta("call-a", "{}"))
        events(ModelEvent.ToolCallCompleted("call-a"))
        events(ModelEvent.ToolCallStarted("call-b", "write"))
        events(ModelEvent.ToolArgumentsDelta("call-b", "{\"path\":"))
        Result.Err(AgentError(
            AgentErrorKind.Transport, "fixture.multi_partial",
            "transport closed before provider terminal", retryable: true
        ))
    }
}

func attemptPolicyAppliedContract(): Unit {
    let model = PolicyCaptureModel()
    let decisions = RecordingModelDecisionPort()
    let catalog = ToolCatalog()
    let result = AgentCore(
        model, MemoryRuns(),
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, modelDecisionRuntime: Some(decisions)
    ).start(AgentRunRequest(
        RunId("policy-runtime-run"), SessionId("policy-runtime-session"),
        "policy-model", "capture policy", thinking: ThinkingLevel.Low,
        budget: ResourceBudget(maxOutputTokens: 4321)
    ))
    let policy = decisions.lastPolicy.getOrThrow()
    expect(result.isOk() && model.request.getOrThrow().thinking == ThinkingLevel.Low &&
        model.request.getOrThrow().maxOutputTokens == 4321 &&
        policy.field("thinking").getOrThrow().text == "low" &&
        policy.field("tool_choice").getOrThrow().text == "auto" &&
        policy.field("max_output_tokens").getOrThrow().number == "4321",
        "durable AttemptPolicy exactly matches the effective adapter request")
}

class PolicyCaptureModel <: ModelPort {
    var request: ?ModelRequest = None
    public func execute(
        value: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        request = Some(value)
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "done")],
            stopReason: "end_turn", providerId: "policy-contract",
            responseId: "policy-response"
        ))
    }
}

func failedAttemptDoesNotPolluteTranscriptContract(): Unit {
    let model = PartialThenSuccessModel()
    let decisions = RecordingModelDecisionPort()
    let catalog = ToolCatalog()
    let threads = InMemoryThreadRuntimeRegistry(
        ContextProjector("attempt-retry-contract", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let result = AgentCore(
        model, MemoryRuns(),
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(threads),
        modelDecisionRuntime: Some(decisions),
        modelAttemptRecovery: ModelAttemptRecoveryPolicy(
            mode: ModelAttemptRecoveryMode.RecoveryV1,
            attemptTimeoutMillis: 5000,
            maxRecoveryRetries: 1
        )
    ).start(AgentRunRequest(
        RunId("attempt-retry-run"), SessionId("attempt-retry-session"),
        "fixture", "retry partial decision"
    ))
    let snapshot = threads.acquire(
        ThreadId("attempt-retry-session"), "agent-core"
    ).value().getOrThrow().threadSnapshot()
    var toolItems: Int64 = 0
    for (item in snapshot.items) {
        if (item.kind == ItemKind.ToolCall) { toolItems += 1 }
    }
    expect(result.isOk() && model.calls == 2 && decisions.attempts == 2 &&
        decisions.decisions == 1 && snapshot.items.size == 2 && toolItems == 0,
        "failed Attempt partial output never enters the canonical transcript")
}

class PartialThenSuccessModel <: ModelPort {
    var calls: Int64 = 0
    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request.requestId
        calls += 1
        if (calls == 1) {
            events(ModelEvent.ReasoningDelta("aborted partial reasoning"))
            return Result.Err(AgentError(
                AgentErrorKind.Timeout, "fixture.partial_timeout",
                "provider deadline reached before terminal", retryable: true
            ))
        }
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "success")],
            stopReason: "end_turn", responseId: "retry-success"
        ))
    }
}

class MalformedToolArgumentsThenSuccessModel <: ModelPort {
    var calls: Int64 = 0
    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request.requestId
        calls += 1
        if (calls == 1) {
            events(ModelEvent.ToolCallStarted("malformed", "task"))
            events(ModelEvent.ToolArgumentsDelta("malformed", "{\"tasks\":["))
            return Result.Err(AgentError(
                AgentErrorKind.Protocol,
                "llm.tool_arguments_not_executable",
                "tool arguments are not a complete JSON object",
                retryable: true,
                attemptFailure: Some(AttemptFailure(
                    AttemptFailureKind.MalformedToolArguments
                )),
                fields: [
                    ErrorField("usage_input_tokens", "500"),
                    ErrorField("usage_output_tokens", "100")
                ]
            ))
        }
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "recovered")],
            stopReason: "end_turn", responseId: "malformed-tool-retry-success"
        ))
    }
}

class ProviderTerminalMissingThenSuccessModel <: ModelPort {
    var calls: Int64 = 0
    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request.requestId
        calls += 1
        if (calls == 1) {
            events(ModelEvent.TextDelta("stale partial"))
            events(ModelEvent.ToolCallStarted("truncated", "task"))
            events(ModelEvent.ToolArgumentsDelta("truncated", "{\"tasks\":["))
            return Result.Err(AgentError(
                AgentErrorKind.Protocol,
                "llm.stream_terminal_missing",
                "stream ended without a protocol terminal",
                retryable: true,
                attemptFailure: Some(AttemptFailure(
                    AttemptFailureKind.ProviderTerminalMissing
                ))
            ))
        }
        events(ModelEvent.TextDelta("recovered partial"))
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "recovered")],
            stopReason: "end_turn", responseId: "provider-terminal-retry-success"
        ))
    }
}

func telemetryPersistenceFailureIsolationContract(): Unit {
    let model = TelemetryThenCompleteModel()
    let decisions = RecordingModelDecisionPort()
    let catalog = ToolCatalog()
    let threads = InMemoryThreadRuntimeRegistry(
        ContextProjector("telemetry-failure-contract", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let result = AgentCore(
        model, MemoryRuns(failStreamTelemetry: true),
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(threads), modelDecisionRuntime: Some(decisions)
    ).start(AgentRunRequest(
        RunId("telemetry-failure-run"), SessionId("telemetry-failure-session"),
        "fixture", "telemetry is not correctness"
    ))
    let snapshot = threads.acquire(
        ThreadId("telemetry-failure-session"), "agent-core"
    ).value().getOrThrow().threadSnapshot()
    expect(result.isOk() && model.calls == 1 && decisions.decisions == 1 &&
        snapshot.items.size == 2,
        "stream telemetry persistence failure neither invalidates the Decision nor retries the model")
}

class TelemetryThenCompleteModel <: ModelPort {
    var calls: Int64 = 0
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request
        calls += 1
        events(ModelEvent.TextDelta("provisional"))
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "canonical")],
            stopReason: "end_turn", responseId: "telemetry-failure-response"
        ))
    }
}

func durableDecisionRecoveryDoesNotInvokeProviderContract(): Unit {
    let model = NeverInvokedRecoveryModel()
    let decisionPort = RecoverableDecisionPort()
    let catalog = ToolCatalog()
    let threads = InMemoryThreadRuntimeRegistry(
        ContextProjector("decision-recovery-contract", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let result = AgentCore(
        model, MemoryRuns(),
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(threads),
        modelDecisionRuntime: Some(decisionPort)
    ).start(AgentRunRequest(
        RunId("decision-recovery-run"), SessionId("decision-recovery-session"),
        "fixture", "resume durable decision"
    ))
    let snapshot = threads.acquire(
        ThreadId("decision-recovery-session"), "agent-core"
    ).value().getOrThrow().threadSnapshot()
    expect(result.isOk() && model.calls == 0 && decisionPort.projected &&
        snapshot.items.size == 2 && snapshot.items[1].id.value ==
            "decision-item-recovery-decision-block-0",
        "durable Decision with missing canonical projection is reprojected without provider invocation")
}

func terminalDecisionPersistenceFailureContract(): Unit {
    let model = PolicyCaptureModel()
    let decisions = RecordingModelDecisionPort(rejectPersistence: true)
    let catalog = ToolCatalog()
    let threads = InMemoryThreadRuntimeRegistry(
        ContextProjector("decision-persist-failure", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let result = AgentCore(
        model, MemoryRuns(),
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(threads),
        modelDecisionRuntime: Some(decisions)
    ).start(AgentRunRequest(
        RunId("decision-persist-failure-run"),
        SessionId("decision-persist-failure-session"), "fixture", "terminal then crash"
    ))
    let snapshot = threads.acquire(
        ThreadId("decision-persist-failure-session"), "agent-core"
    ).value().getOrThrow().threadSnapshot()
    expect(result.isError() && decisions.attempts == 1 && decisions.decisions == 0 &&
        snapshot.items.size == 1,
        "provider-terminal Decision that fails before durability produces no canonical output")
}

class NeverInvokedRecoveryModel <: ModelPort {
    var calls: Int64 = 0
    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request.requestId
        let _ = events
        calls += 1
        Result.Err(AgentError(
            AgentErrorKind.Internal, "fixture.provider_must_not_run",
            "provider was invoked while a durable Decision awaited projection"
        ))
    }
}

class RecoverableDecisionPort <: ModelDecisionRuntimePort {
    var projected: Bool = false
    private let decision = ModelDecision(
        ModelDecisionId("recovery-decision"),
        ModelAttemptId("recovery-attempt"),
        SemanticModelRequestId("recovery-semantic-request"),
        [DurableDecisionBlock(
            DecisionBlockId("recovery-decision-block-0"), 0,
            ModelBlock(ModelBlockKind.Text, text: "recovered")
        )],
        TerminalEvidence(
            "fixture", "fixture_terminal", rawStopReason: "end_turn",
            messageTerminalObserved: true, streamEofObserved: true,
            adapterVersion: "fixture-v1"
        ),
        DecisionValidationStatus.Validated,
        CompletionDisposition.Complete,
        DecisionOutcome.Response,
        "content-recovery", "replay-recovery", 1,
        providerId: "fixture", providerResponseId: "recovery-response",
        createdAtMillis: 1
    )

    public func abandonOpenAttempts(runId: RunId, abandonedAtMillis: Int64): Result<Unit> {
        let _ = runId.value
        let _ = abandonedAtMillis
        Result.Ok(())
    }
    public func createAttempt(attempt: DurableModelAttempt): Result<Unit> {
        let _ = attempt.id.value
        Result.Ok(())
    }
    public func terminalizeAttempt(
        attemptId: ModelAttemptId, lifecycle: ModelAttemptLifecycle,
        failureKind: String, completedAtMillis: Int64
    ): Result<Unit> {
        let _ = attemptId.value
        let _ = lifecycle
        let _ = failureKind
        let _ = completedAtMillis
        Result.Ok(())
    }
    public func persistValidatedDecision(value: ModelDecision): Result<Unit> {
        let _ = value.id.value
        Result.Ok(())
    }
    public func finalizeUsage(
        decisionId: ModelDecisionId, usage: ModelUsage, finalizedAtMillis: Int64
    ): Result<Unit> {
        let _ = decisionId.value
        let _ = usage.outputTokens
        let _ = finalizedAtMillis
        Result.Ok(())
    }
    public func uncommittedDecision(runId: RunId): Result<?ModelDecision> {
        let _ = runId.value
        Result.Ok(if (projected) { None } else { Some(decision) })
    }
    public func recordCanonicalProjection(
        decisionId: ModelDecisionId, sources: Array<CommittedToolCallSource>
    ): Result<Unit> {
        let _ = sources.size
        if (decisionId.value != decision.id.value) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict, "fixture.decision_drift", "decision identity drift"
            ))
        }
        projected = true
        Result.Ok(())
    }
    public func committedToolCallSources(
        runId: RunId
    ): Result<Array<CommittedToolCallSource>> {
        let _ = runId.value
        Result.Ok([])
    }
}

func contextBoundaryContract(): Unit {
    let callA = ModelBlock(ModelBlockKind.ToolCall, callId: "call-a", name: "read")
    let callB = ModelBlock(ModelBlockKind.ToolCall, callId: "call-b", name: "grep")
    let resultA = ModelBlock(ModelBlockKind.ToolResult, callId: "call-a", name: "read")
    let resultB = ModelBlock(ModelBlockKind.ToolResult, callId: "call-b", name: "grep")
    let oneRound = [
        ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "inspect")]),
        ModelMessage(ModelRole.Assistant, [callA]),
        ModelMessage(ModelRole.User, [resultA]),
        ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.Text, text: "done")])
    ]
    expect(findSafeCutPoint(oneRound, 2) == 3, "cut target on tool result drops the whole crossed tool round")
    expect(findSafeCutPoint(oneRound, 1) == 1, "cut target on assistant tool call retains the complete pair")

    let parallelRound = [
        ModelMessage(ModelRole.Assistant, [callA, callB]),
        ModelMessage(ModelRole.User, [resultA]),
        ModelMessage(ModelRole.User, [resultB]),
        ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.Text, text: "parallel done")])
    ]
    expect(
        isToolProtocolComplete(parallelRound) && findSafeCutPoint(parallelRound, 1) == 3 &&
            findSafeCutPoint(parallelRound, 2) == 3,
        "parallel tool calls and results remain an indivisible protocol group"
    )

    let consecutive = [
        ModelMessage(ModelRole.Assistant, [callA]),
        ModelMessage(ModelRole.User, [resultA]),
        ModelMessage(ModelRole.Assistant, [callB]),
        ModelMessage(ModelRole.User, [resultB]),
        ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.Text, text: "all done")])
    ]
    for (candidate in 0..consecutive.size) {
        let start = findSafeCutPoint(consecutive, candidate)
        let retained = ArrayList<ModelMessage>()
        for (index in start..consecutive.size) {
            retained.add(consecutive[index])
        }
        expect(
            isToolProtocolComplete(retained.toArray()),
            "every safe suffix preserves tool protocol for candidate " + candidate.toString()
        )
    }

    var huge = ""
    for (_ in 0..6000) {
        huge += "界"
    }
    let oversized = [
        ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "large output")]),
        ModelMessage(ModelRole.Assistant, [callA]),
        ModelMessage(ModelRole.User, [ModelBlock(
            ModelBlockKind.ToolResult,
            callId: "call-a",
            name: "read",
            arguments: objectValue([ValueField("content", textValue(huge))])
        )]),
        ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.Text, text: "done")])
    ]
    let oversizedWindow = buildRequestContext(oversized, ResourceBudget(maxInputTokens: 1000))
    expect(
        !oversizedWindow.overBudget && oversizedWindow.estimatedTokens <= 1000 &&
            oversizedWindow.truncatedToolResults == 1 && isToolProtocolComplete(oversizedWindow.messages),
        "oversized tool output is truncated without orphaning its tool call"
    )
    let requestTools = [ModelToolDefinition(
        "read",
        "Read a bounded workspace file",
        objectValue([ValueField("type", textValue("object"))])
    )]
    let budgetedWindow = buildRequestContext(
        oversized,
        ResourceBudget(maxInputTokens: 1200),
        system: "System instructions and capability policy reserve input budget.",
        tools: requestTools
    )
    expect(
        !budgetedWindow.overBudget && budgetedWindow.estimatedTokens <= 1200,
        "request budget includes system prompt, tool definitions, framing, and conversation messages"
    )
    let oversizedPrompt = buildRequestContext(
        [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: huge)])],
        ResourceBudget(maxInputTokens: 500)
    )
    expect(
        oversizedPrompt.overBudget && oversizedPrompt.messages.isEmpty(),
        "an oversized current user message fails the request budget instead of being silently omitted"
    )
    let incompleteCall = [
        ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "start")]),
        ModelMessage(ModelRole.Assistant, [callA]),
        ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.Text, text: "recovered")])
    ]
    let repairedBoundary = findSafeCutPoint(incompleteCall, 0)
    expect(
        repairedBoundary == 2 && isToolProtocolComplete(incompleteCall[repairedBoundary..incompleteCall.size]),
        "a retained request never contains an assistant tool call without its required result"
    )

    let shortMessages = ArrayList<ModelMessage>()
    for (index in 0..20) {
        shortMessages.add(ModelMessage(
            ModelRole.User,
            [ModelBlock(ModelBlockKind.Text, text: "ok " + index.toString())]
        ))
    }
    let largeMessages = ArrayList<ModelMessage>()
    var large = ""
    for (_ in 0..1200) {
        large += "x"
    }
    for (_ in 0..8) {
        largeMessages.add(ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: large)]))
    }
    let policy = ContextCompactionPolicy(emergencyMessageLimit: 512)
    let triggerBudget = ResourceBudget(maxInputTokens: 1000)
    expect(
        !shouldCompactContext(shortMessages.toArray(), triggerBudget, policy) &&
            shouldCompactContext(largeMessages.toArray(), triggerBudget, policy),
        "token budget drives normal compaction while message count remains an emergency fallback"
    )
}

func modelIdleTimeoutContract(): Unit {
    let model = StalledModel()
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(
            catalog,
            MemoryOperations(),
            MemoryAudit(),
            FixtureIds()
        ),
        catalog
    )
    let result = core.start(AgentRunRequest(
        RunId("idle-timeout-run"),
        SessionId("idle-timeout-session"),
        "fixture",
        "wait forever",
        budget: ResourceBudget(
            maxWallMillis: 5000,
            maxIdleMillis: 30
        )
    ))
    expect(
        result.isError() && model.cancelled && match (result.error()) {
            case Some(error) => error.kind == AgentErrorKind.Timeout &&
                error.code == "model.stream_idle_timeout" && match (error.attemptFailure) {
                    case Some(value) => value.kind == AttemptFailureKind.StreamIdleTimeout
                    case None => false
                }
            case None => false
        },
        "an idle provider stream is cancelled and classified as a timeout"
    )
    let snapshot = runs.find(RunId("idle-timeout-run")).value().getOrThrow()
    let (succeeded, failed, cancelled) = requestOutcomeCounts(runs.eventLog)
    expect(
        snapshot.modelRequests == 2 && snapshot.turns == 1 &&
            snapshot.status == RunState.Failed && succeeded == 0 &&
            failed == 2 && cancelled == 0,
        "the bounded initial and escalated idle attempts are durably recorded"
    )
}

func idleRetryRecoversContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = StallThenAnswerModel()
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(
            catalog,
            MemoryOperations(),
            MemoryAudit(),
            FixtureIds()
        ),
        catalog
    )
    let result = core.start(AgentRunRequest(
        RunId("idle-recover-run"),
        SessionId("idle-recover-session"),
        "fixture",
        "recover from idle",
        budget: ResourceBudget(
            maxWallMillis: 5000,
            maxIdleMillis: 30
        )
    ))
    expect(
        result.isOk(),
        "an idle stall that recovers on retry completes the run"
    )
    expect(
        match (result.value().getOrThrow()) {
            case AgentRunOutcome.Completed(snapshot) =>
                isCompleted(snapshot.status) && snapshot.modelRequests == 2
            case _ => false
        },
        "the retried model call is accounted in the completed run"
    )
    let (succeeded, failed, cancelled) = requestOutcomeCounts(runs.eventLog)
    expect(
        succeeded == 1 && failed == 1 && cancelled == 0,
        "a failed attempt followed by a successful retry remains one failure and one success"
    )
}

func retryBackoffControlContract(): Unit {
    let wallModel = RetryAfterModel()
    let wallConversations = MemoryConversations()
    let wallRuns = MemoryRuns()
    let wallCatalog = ToolCatalog()
    let wallCore = AgentCore(
        wallModel,
        wallRuns,
        ToolPipeline(
            wallCatalog,
            MemoryOperations(),
            MemoryAudit(),
            FixtureIds()
        ),
        wallCatalog
    )
    let wallStarted = MonoTime.now()
    let wallResult = wallCore.start(AgentRunRequest(
        RunId("retry-after-wall-run"),
        SessionId("retry-after-wall-session"),
        "fixture",
        "respect wall budget during provider backoff",
        budget: ResourceBudget(
            maxWallMillis: 40,
            maxIdleMillis: 1000
        )
    ))
    let wallElapsed = (MonoTime.now() - wallStarted).toMilliseconds()
    expect(
        wallResult.isError() && wallModel.callCount() == 1 &&
            wallElapsed < 1000 && match (wallResult.error()) {
                case Some(error) => error.code == "model.wall_timeout"
                case None => false
            },
        "provider Retry-After cannot outlive the run wall budget"
    )

    let deadlineModel = RetryAfterModel()
    let deadlineConversations = MemoryConversations()
    let deadlineRuns = MemoryRuns()
    let deadlineCatalog = ToolCatalog()
    let deadlineCore = AgentCore(
        deadlineModel,
        deadlineRuns,
        ToolPipeline(
            deadlineCatalog,
            MemoryOperations(),
            MemoryAudit(),
            FixtureIds()
        ),
        deadlineCatalog
    )
    let deadlineStarted = MonoTime.now()
    let deadlineResult = deadlineCore.start(AgentRunRequest(
        RunId("retry-after-deadline-run"),
        SessionId("retry-after-deadline-session"),
        "fixture",
        "respect absolute deadline during provider backoff",
        budget: ResourceBudget(
            maxWallMillis: 5000,
            maxIdleMillis: 1000,
            deadlineMillis: DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() + 100
        )
    ))
    let deadlineElapsed = (MonoTime.now() - deadlineStarted).toMilliseconds()
    expect(
        deadlineResult.isError() && deadlineModel.callCount() == 1 &&
            deadlineElapsed < 1000 && match (deadlineResult.error()) {
                case Some(error) => error.code == "budget.deadline_exceeded"
                case None => false
            },
        "provider Retry-After polling enforces the absolute deadline"
    )

    let cancelModel = RetryAfterModel()
    let cancelConversations = MemoryConversations()
    let cancelRuns = MemoryRuns()
    let cancelCatalog = ToolCatalog()
    let cancelCore = AgentCore(
        cancelModel,
        cancelRuns,
        ToolPipeline(
            cancelCatalog,
            MemoryOperations(),
            MemoryAudit(),
            FixtureIds()
        ),
        cancelCatalog
    )
    let cancelRunId = RunId("retry-after-cancel-run")
    let cancelFuture = spawn {
        cancelCore.start(AgentRunRequest(
            cancelRunId,
            SessionId("retry-after-cancel-session"),
            "fixture",
            "cancel provider backoff",
            budget: ResourceBudget(
                maxWallMillis: 5000,
                maxIdleMillis: 1000
            )
        ))
    }
    let callDeadline = MonoTime.now() + Duration.millisecond * 1000
    while (cancelModel.callCount() == 0 && MonoTime.now() < callDeadline) {
        sleep(Duration.millisecond * 5)
    }
    expect(cancelModel.callCount() == 1, "retry fixture reaches provider backoff")
    let cancelStarted = MonoTime.now()
    expect(cancelCore.cancel(cancelRunId).isOk(), "retry backoff accepts user cancellation")
    let finishDeadline = MonoTime.now() + Duration.millisecond * 1000
    while (cancelFuture.tryGet().isNone() && MonoTime.now() < finishDeadline) {
        sleep(Duration.millisecond * 5)
    }
    expect(
        cancelFuture.tryGet().isSome(),
        "retry backoff polls cancellation instead of sleeping for the provider hint"
    )
    let cancelResult = cancelFuture.get()
    let cancelElapsed = (MonoTime.now() - cancelStarted).toMilliseconds()
    expect(
        cancelResult.isError() && cancelElapsed < 1000 &&
            cancelModel.callCount() == 1 && match (cancelResult.error()) {
                case Some(error) => error.kind == AgentErrorKind.Cancelled
                case None => false
            },
        "cancellation stops retry backoff before another wire attempt"
    )
}

class StallThenAnswerModel <: ModelPort {
    var calls: Int64 = 0

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        calls += 1
        if (calls == 1) {
            // First attempt stalls without emitting any event.
            sleep(Duration.millisecond * 200)
            return Result.Err(AgentError(
                AgentErrorKind.Timeout,
                "model.idle_timeout",
                "test stall"
            ))
        }
        events(ModelEvent.Completed)
        Result.Ok(
            contractModelReply(
                [ModelBlock(ModelBlockKind.Text, text: "recovered")],
                stopReason: "end_turn"
            )
        )
    }
}

class RetryAfterModel <: ModelPort {
    private let lock = Mutex()
    private var calls: Int64 = 0

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request
        let _ = events
        lock.lock()
        try { calls += 1 } finally { lock.unlock() }
        Result.Err(AgentError(
            AgentErrorKind.RateLimited,
            "model.rate_limited",
            "retry later",
            retryable: true,
            fields: [ErrorField("retry_after_ms", "600000")]
        ))
    }

    public func cancel(requestId: String): Result<Unit> {
        let _ = requestId
        Result.Ok(())
    }

    func callCount(): Int64 {
        lock.lock()
        try { calls } finally { lock.unlock() }
    }
}

func invalidArgumentContinuesRunContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let tool = InvalidArgumentTool()
    expect(
        catalog.register(
            ToolDescriptor(
                ModelToolDefinition(
                    "strict",
                    "strict tool",
                    objectValue([])
                ),
                Capability(CapabilityKind.WorkspaceRead)
            ),
            tool
        ).isOk(),
        "invalid-argument tool registration"
    )
    let model = InvalidArgumentModel()
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(
            catalog,
            MemoryOperations(),
            MemoryAudit(),
            FixtureIds()
        ),
        catalog
    )
    let outcome = core.start(AgentRunRequest(
        RunId("invalid-arg-run"),
        SessionId("invalid-arg-session"),
        "fixture",
        "start invalid argument contract",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    ))
    expect(
        outcome.isOk(),
        "run continues past an invalid tool argument"
    )
    expect(
        match (outcome.value().getOrThrow()) {
            case AgentRunOutcome.Completed(snapshot) =>
                isCompleted(snapshot.status) && snapshot.turns == 2
            case _ => false
        },
        "run completes both turns after the invalid argument"
    )
    // The failed tool call is recorded as an is_error tool result the model
    // can read back, not a run-terminating failure.
    let invalidMessages = coreMessages(core, SessionId("invalid-arg-session"))
    let invalidResults = transcriptToolResults(invalidMessages)
    expect(
        invalidResults.size == 1 && invalidResults[0].isError,
        "invalid tool arguments become is_error tool results"
    )
}

func permissionDeniedToolContinuesBatchContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    expect(
        catalog.register(
            ToolDescriptor(
                ModelToolDefinition("read", "read a file", objectValue([])),
                Capability(CapabilityKind.WorkspaceRead)
            ),
            PermissionDeniedTool()
        ).isOk(),
        "permission-denied tool registration"
    )
    expect(
        catalog.register(
            ToolDescriptor(
                ModelToolDefinition("echo", "echo text", objectValue([])),
                Capability(CapabilityKind.WorkspaceRead)
            ),
            EchoTool()
        ).isOk(),
        "batch echo tool registration"
    )
    let model = PermissionDeniedBatchModel()
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog
    )
    let outcome = core.start(AgentRunRequest(
        RunId("permission-tool-run"),
        SessionId("permission-tool-session"),
        "fixture",
        "read three files",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    ))
    expect(outcome.isOk(), "a workspace path denial does not fail the agent run")
    expect(
        match (outcome.value().getOrThrow()) {
            case AgentRunOutcome.Completed(snapshot) => snapshot.status == RunState.Completed && snapshot.turns == 2
            case _ => false
        },
        "the model receives the failed result and completes the next turn"
    )
    let canonicalMessages = coreMessages(core, SessionId("permission-tool-session"))
    let results = transcriptToolResults(canonicalMessages)
    expect(results.size == 3, "every call in the batch receives a tool result")
    expect(
        results[0].kind == ModelBlockKind.ToolResult && results[0].callId == "call-outside" &&
            results[0].isError && results[0].arguments.field("error").getOrThrow().text ==
            "workspace.path_escape",
        "workspace denial is an is_error tool result bound to its original call id"
    )
    expect(
        results[1].callId == "call-next-1" && !results[1].isError &&
            results[2].callId == "call-next-2" && !results[2].isError,
        "a denied tool does not discard later calls from the same model reply"
    )
    expect(
        noErrorBlocks(canonicalMessages.toArray()),
        "recoverable tool denial does not append a top-level assistant error"
    )
}

func capabilityDenialLoopContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let restrictedTool = EchoTool()
    expect(
        catalog.register(
            ToolDescriptor(
                ModelToolDefinition("write", "write a file", objectValue([])),
                Capability(CapabilityKind.WorkspaceWrite)
            ),
            restrictedTool
        ).isOk(),
        "capability-denial loop tool registration"
    )
    let model = RepeatedCapabilityDeniedModel()
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog
    )
    let outcome = core.start(AgentRunRequest(
        RunId("capability-denial-loop-run"),
        SessionId("capability-denial-loop-session"),
        "fixture",
        "keep requesting an unavailable tool",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    ))
    var resultCount: Int64 = 0
    for (message in coreMessages(core, SessionId("capability-denial-loop-session"))) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolResult) {
            resultCount += 1
        }
    }
    expect(
        match (outcome) {
            case Result.Err(error) => error.kind == AgentErrorKind.PermissionDenied && error.code ==
                "run.capability_denial_loop" && error.field("consecutive_denials") == Some("3") && error
                .field("last_tool") == Some("write")
            case _ => false
        } && model.calls == 3 && resultCount == 3 && restrictedTool.executions == 0,
        "three consecutive capability denials terminate early after persisting every result"
    )

    let resetConversations = MemoryConversations()
    let resetCatalog = ToolCatalog()
    let resetRestricted = EchoTool()
    let allowed = EchoTool()
    expect(
        resetCatalog.register(
            ToolDescriptor(
                ModelToolDefinition("write", "write a file", objectValue([])),
                Capability(CapabilityKind.WorkspaceWrite)
            ),
            resetRestricted
        ).isOk() && resetCatalog.register(
            ToolDescriptor(
                ModelToolDefinition("echo", "echo text", objectValue([])),
                Capability(CapabilityKind.WorkspaceRead)
            ),
            allowed
        ).isOk(),
        "capability-denial reset tools register"
    )
    let resetModel = ResetCapabilityDeniedModel()
    let resetOutcome = AgentCore(
        resetModel,
        MemoryRuns(),
        ToolPipeline(resetCatalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        resetCatalog
    ).start(AgentRunRequest(
        RunId("capability-denial-reset-run"),
        SessionId("capability-denial-reset-session"),
        "fixture",
        "reset denial counter with a successful tool",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    ))
    expect(
        resetOutcome.isOk() && resetModel.calls == 5 && allowed.executions == 1 && resetRestricted.executions == 0,
        "a successful tool result resets the consecutive capability-denial counter"
    )
}

func noErrorBlocks(messages: Array<ModelMessage>): Bool {
    for (message in messages) {
        for (block in message.blocks) {
            if (block.kind == ModelBlockKind.Error) {
                return false
            }
        }
    }
    true
}

class OversizedUsageModel <: ModelPort {
    var calls: Int64 = 0
    var lastRequest: ?ModelRequest = None

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        calls += 1
        lastRequest = Some(request)
        events(ModelEvent.Completed)
        if (calls == 1) {
            Result.Ok(contractModelReply(
                [ModelBlock(ModelBlockKind.Text, text: "oversized")],
                stopReason: "end_turn",
                inputTokens: 200000,
                outputTokens: 1
            ))
        } else {
            Result.Ok(contractModelReply(
                [ModelBlock(ModelBlockKind.Text, text: "fine")],
                stopReason: "end_turn",
                inputTokens: 10,
                outputTokens: 1
            ))
        }
    }
}

class InvalidArgumentTool <: ToolExecutor {
    var executions: Int64 = 0

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        executions += 1
        Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "tool.invalid_argument",
            "invalid argument for test",
            fields: [ErrorField("tool", call.name)]
        ))
    }
}

class PermissionDeniedTool <: ToolExecutor {
    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        Result.Err(AgentError(
            AgentErrorKind.PermissionDenied,
            "workspace.path_escape",
            "path escapes the configured workspace",
            fields: [ErrorField("path", "/tmp/cube_lib/test1.js")]
        ))
    }
}

class PermissionDeniedBatchModel <: ModelPort {
    var calls: Int64 = 0

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        calls += 1
        events(ModelEvent.Completed)
        if (calls == 1) {
            Result.Ok(contractModelReply([
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "call-outside",
                    name: "read",
                    arguments: objectValue([ValueField("path", textValue("/tmp/cube_lib/test1.js"))])
                ),
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "call-next-1",
                    name: "echo",
                    arguments: objectValue([ValueField("text", textValue("one"))])
                ),
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "call-next-2",
                    name: "echo",
                    arguments: objectValue([ValueField("text", textValue("two"))])
                )
            ]))
        } else {
            Result.Ok(contractModelReply(
                [ModelBlock(ModelBlockKind.Text, text: "used a permitted alternative")],
                stopReason: "end_turn"
            ))
        }
    }
}

class InvalidArgumentModel <: ModelPort {
    var calls: Int64 = 0

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        calls += 1
        events(ModelEvent.Completed)
        if (calls == 1) {
            Result.Ok(
            contractModelReply(
                    [
                        ModelBlock(
                            ModelBlockKind.ToolCall,
                            callId: "call-invalid",
                            name: "strict",
                            arguments: objectValue([])
                        )
                    ]
                )
            )
        } else {
            Result.Ok(
            contractModelReply(
                    [ModelBlock(ModelBlockKind.Text, text: "done")],
                    stopReason: "end_turn"
                )
            )
        }
    }
}

class MultiTurnModel <: ModelPort {
    var calls: Int64 = 0
    let turns: Int64
    let inputTokensPerCall: Int64
    var lastMessagesSize: Int64 = 0
    var observedMessages: Array<ModelMessage> = []

    public init(turns!: Int64 = 6, inputTokensPerCall!: Int64 = 3000) {
        this.turns = max(1, turns)
        this.inputTokensPerCall = max(0, inputTokensPerCall)
    }

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        calls += 1
        lastMessagesSize = request.messages.size
        observedMessages = request.messages
        events(ModelEvent.Completed)
        if (calls < turns) {
            Result.Ok(contractModelReply([ModelBlock(
                ModelBlockKind.ToolCall,
                callId: "call-" + calls.toString(),
                name: "echo",
                arguments: objectValue([
                    ValueField("text", textValue("t" + calls.toString()))
                ])
            )], inputTokens: inputTokensPerCall, outputTokens: 50))
        } else {
            Result.Ok(contractModelReply(
                [ModelBlock(ModelBlockKind.Text, text: "done")],
                stopReason: "end_turn",
                inputTokens: inputTokensPerCall,
                outputTokens: 50
            ))
        }
    }
}

func singleRequestInputBudgetContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let echoTool = EchoTool(observer: Some(conversations))
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "echo",
                "echo text",
                objectValue([])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        echoTool
    ).isOk(), "tool registration")
    let model = MultiTurnModel(turns: 2, inputTokensPerCall: 5000)
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog
    )
    let result = core.start(AgentRunRequest(
        RunId("single-input-budget-run"),
        SessionId("single-input-budget-session"),
        "fixture",
        "go",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
        budget: ResourceBudget(maxInputTokens: 1000)
    ))
    expect(
        result.isError() && match (result.error()) {
            case Some(error) =>
                error.kind == AgentErrorKind.BudgetExceeded &&
                    error.code == "run.budget_exceeded"
            case None => false
        },
        "a single request whose input exceeds maxInputTokens fails the run"
    )
}

func cumulativeInputTripsExecutionBudgetContract(): Unit {
    // Request-window validation and cumulative Run accounting are separate
    // dimensions; the latter is opt-in through maxTotalInputTokens.
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let echoTool = EchoTool(observer: Some(conversations))
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "echo",
                "echo text",
                objectValue([])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        echoTool
    ).isOk(), "tool registration")
    let model = MultiTurnModel(turns: 6, inputTokensPerCall: 3000)
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog
    )
    let result = core.start(AgentRunRequest(
        RunId("cumulative-input-run"),
        SessionId("cumulative-input-session"),
        "fixture",
        "go",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
        budget: ResourceBudget(
            maxInputTokens: 10000,
            maxTotalInputTokens: 10000
        )
    ))
    expect(result.isError() && match (result.error()) {
        case Some(error) =>
            error.kind == AgentErrorKind.BudgetExceeded &&
                error.code == "budget.total_input_tokens_exceeded"
        case None => false
    }, "cumulative model usage is reserved by the v3 execution budget ledger")
}

class BudgetProbeModel <: ModelPort {
    var calls: Int64 = 0
    var workRequests: Int64 = 0
    var drainWireCalls: Int64 = 0
    var lastRequestToolsEmpty: Bool = false
    var lastRequestToolChoiceNoTools: Bool = false
    let drainToolCall: Bool
    let drainFailures: Int64
    let sleepMillisPerWorkCall: Int64
    let usagePerCall: ?ModelUsage

    init(
        drainToolCall!: Bool = false,
        drainFailures!: Int64 = 0,
        sleepMillisPerWorkCall!: Int64 = 0,
        usagePerCall!: ?ModelUsage = None
    ) {
        this.drainToolCall = drainToolCall
        this.drainFailures = drainFailures
        this.sleepMillisPerWorkCall = sleepMillisPerWorkCall
        this.usagePerCall = usagePerCall
    }

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        calls += 1
        lastRequestToolsEmpty = request.tools.isEmpty()
        lastRequestToolChoiceNoTools = match (request.toolChoice) {
            case ModelToolChoice.NoTools => true
            case _ => false
        }
        if (request.tools.isEmpty()) {
            drainWireCalls += 1
            if (drainWireCalls <= drainFailures) {
                return Result.Err(AgentError(
                    AgentErrorKind.Transport,
                    "fixture.drain_transport",
                    "drain transport failure",
                    retryable: true
                ))
            }
            if (drainToolCall) {
                return Result.Ok(contractModelReply([ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "drain-call",
                    name: "echo",
                    arguments: objectValue([ValueField("text", textValue("nope"))])
                )], stopReason: "tool_use"))
            }
            events(ModelEvent.Completed)
            return Result.Ok(contractModelReply(
                [ModelBlock(ModelBlockKind.Text, text: "drain report: completed work; next step: resume from checkpoint")],
                stopReason: "end_turn",
                usage: usagePerCall
            ))
        }
        workRequests += 1
        if (sleepMillisPerWorkCall > 0) {
            sleep(Duration.millisecond * sleepMillisPerWorkCall)
        }
        return Result.Ok(contractModelReply([ModelBlock(
            ModelBlockKind.ToolCall,
            callId: "call-" + calls.toString(),
            name: "echo",
            arguments: objectValue([ValueField("text", textValue("t" + calls.toString()))])
        )], usage: usagePerCall))
    }
}

func countBudgetSignals(
    events: ArrayList<AgentEvent>,
    code: String
): Int64 {
    var count: Int64 = 0
    for (event in events) {
        match (event.detail.field("code")) {
            case Some(value) => if (value.text == code) { count += 1 }
            case None => ()
        }
    }
    count
}

func budgetDrainCore(
    model: BudgetProbeModel,
    runs: MemoryRuns,
    catalog: ToolCatalog,
    runId: String,
    sessionId: String,
    maxTurns!: Int64,
    maxModelRequests!: Int64 = 64,
    maxDrainTurns!: Int64 = 2,
    deadlineMillis!: Int64 = 0,
    maxDrainModelRequests!: Int64 = 2,
    maxCostMicros!: Int64 = 0,
    pricing!: ?ModelPricing = None,
    sleepyTool!: Bool = false
): Result<AgentRunOutcome> {
    let executor: ToolExecutor = if (sleepyTool) {
        SleepEchoTool()
    } else {
        EchoTool()
    }
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("echo", "echo text", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        executor
    ).isOk(), "tool registration")
    AgentCore(
        model,
        runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog
    ).start(AgentRunRequest(
        RunId(runId),
        SessionId(sessionId),
        "fixture", "go",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
        pricing: pricing,
        budget: ResourceBudget(
            maxTurns: maxTurns,
            maxModelRequests: maxModelRequests,
            maxDrainModelRequests: maxDrainModelRequests,
            maxDrainTurns: maxDrainTurns,
            maxCostMicros: maxCostMicros,
            deadlineMillis: deadlineMillis
        )
    ))
}

func completedSnapshotOrThrow(
    result: Result<AgentRunOutcome>,
    label: String
): RunSnapshot {
    match (result) {
        case Result.Ok(outcome) => match (outcome) {
            case AgentRunOutcome.Completed(snapshot) => snapshot
            case _ => throw IllegalStateException(label + ": run did not complete")
        }
        case Result.Err(error) => throw IllegalStateException(
            label + ": " + error.code + ": " + error.message
        )
    }
}

func workTurnBudgetDrainsGracefullyContract(): Unit {
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = BudgetProbeModel()
    let result = budgetDrainCore(
        model, runs, catalog,
        "turn-budget-drain-run", "turn-budget-drain-session", maxTurns: 32
    )
    let completed = completedSnapshotOrThrow(
        result, "32-turn budget must drain gracefully"
    )
    expect(
        completed.status == RunState.Completed && completed.turns == 32 &&
            model.workRequests == 32 && model.drainWireCalls == 1,
        "work turns stop at 32 and the bounded drain finalizes without " +
            "budget.turns_exceeded"
    )
}

func drainFinalizationHasNoToolSurfaceContract(): Unit {
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = BudgetProbeModel()
    let result = budgetDrainCore(
        model, runs, catalog,
        "drain-no-tools-run", "drain-no-tools-session", maxTurns: 4
    )
    let completed = completedSnapshotOrThrow(
        result, "drain must complete"
    )
    expect(
        completed.status == RunState.Completed && model.lastRequestToolsEmpty &&
            model.lastRequestToolChoiceNoTools && completed.toolCalls == 4,
        "drain finalization carries no tool surface and commits no new tool work"
    )
}

func budgetPressureSignalsOnceContract(): Unit {
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = BudgetProbeModel()
    let result = budgetDrainCore(
        model, runs, catalog,
        "budget-pressure-run", "budget-pressure-session", maxTurns: 4
    )
    let completed = completedSnapshotOrThrow(result, "pressure run completes")
    expect(
        completed.status == RunState.Completed &&
            countBudgetSignals(runs.eventLog, "budget.pressure") == 1 &&
            countBudgetSignals(runs.eventLog, "budget.draining") == 1,
        "budget pressure is signaled exactly once and draining once on drain entry"
    )
}

func drainPartialReportCompletedContract(): Unit {
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = BudgetProbeModel()
    let result = budgetDrainCore(
        model, runs, catalog,
        "drain-report-run", "drain-report-session", maxTurns: 4
    )
    let completed = completedSnapshotOrThrow(result, "drain report run completes")
    expect(
        completed.summary.startsWith("budget drained") &&
            hasEvent(runs.eventLog, "run.completed") &&
            hasEvent(runs.eventLog, "budget.draining"),
        "the drained run completes normally and marks the partial report"
    )
}

func drainHardCapStopsBoundedContract(): Unit {
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = BudgetProbeModel(drainToolCall: true)
    let result = budgetDrainCore(
        model, runs, catalog,
        "drain-tool-run", "drain-tool-session", maxTurns: 4
    )
    expect(result.isError() && match (result.error()) {
        case Some(error) =>
            error.kind == AgentErrorKind.BudgetExceeded &&
                error.code == "budget.drain_exhausted" &&
                model.workRequests == 4 && model.drainWireCalls == 1
        case None => false
    }, "drain refusing tool work stops bounded with budget.drain_exhausted")
}

func drainProviderFailureStopsBoundedContract(): Unit {
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = BudgetProbeModel(drainFailures: 99)
    let result = budgetDrainCore(
        model, runs, catalog,
        "drain-fail-run", "drain-fail-session", maxTurns: 4
    )
    expect(result.isError() && model.workRequests == 4 &&
        model.drainWireCalls == 2,
        "a failing drain finalization is bounded by the attempt retry policy")
}

func resumeRestoresWorkBudgetContinuityContract(): Unit {
    let runs = MemoryRuns(failClaimAfterCommitAt: 3)
    let decisions = RecordingModelDecisionPort()
    let catalog = ToolCatalog()
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("echo", "echo text", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        EchoTool()
    ).isOk(), "tool registration")
    let model = BudgetProbeModel()
    let request = AgentRunRequest(
        RunId("budget-resume-run"), SessionId("budget-resume-session"),
        "fixture", "go",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
        budget: ResourceBudget(maxTurns: 4)
    )
    let first = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(resumeThreadRegistry("budget-resume-first")),
        modelDecisionRuntime: Some(decisions)
    ).start(request)
    expect(first.isError() && model.workRequests == 2,
        "budget resume crash is injected after two settled work turns")
    runs.failClaimAfterCommitAt = 0
    let resumed = AgentCore(
        model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog, threadRuntimes: Some(resumeThreadRegistry("budget-resume-second")),
        modelDecisionRuntime: Some(decisions)
    ).resume(request)
    let completed = completedSnapshotOrThrow(
        resumed, "budget resume must complete"
    )
    expect(
        completed.status == RunState.Completed && completed.turns == 4 &&
            model.workRequests == 4,
        "resume restores the consumed work budget and allows exactly the " +
            "remaining one work turn plus the drain"
    )
}

func drainRespectsRunDeadlineContract(): Unit {
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = BudgetProbeModel()
    let result = budgetDrainCore(
        model, runs, catalog,
        "drain-deadline-run", "drain-deadline-session",
        maxTurns: 1, deadlineMillis: agentUtcMillis() + 100,
        sleepyTool: true
    )
    expect(result.isError() && match (result.error()) {
        case Some(error) =>
            error.code == "run.deadline_exceeded" && model.drainWireCalls == 0
        case None => false
    }, "an expired run deadline admits no drain finalization request")
    let final = runs.find(RunId("drain-deadline-run"))
    expect(final.isOk() && final.value().getOrThrow().turns == 1,
        "the deadline failure still persists a durable usage checkpoint")
}

func workBudgetStopsAtModelRequestLimitContract(): Unit {
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = BudgetProbeModel()
    let result = budgetDrainCore(
        model, runs, catalog,
        "drain-request-split-run", "drain-request-split-session",
        maxTurns: 2, maxDrainModelRequests: 1, maxDrainTurns: 1
    )
    let completed = completedSnapshotOrThrow(result, "split ledger must drain")
    expect(
        completed.status == RunState.Completed && completed.turns == 2 &&
            model.workRequests == 2 && model.drainWireCalls == 1,
        "exhausted work model requests still admit the bounded drain " +
            "finalization request"
    )
}

func workCannotUseDrainHeadroomContract(): Unit {
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = BudgetProbeModel()
    let result = budgetDrainCore(
        model, runs, catalog,
        "drain-headroom-run", "drain-headroom-session",
        maxTurns: 4, maxModelRequests: 2, maxDrainModelRequests: 1, maxDrainTurns: 1
    )
    expect(result.isError() && match (result.error()) {
        case Some(error) =>
            error.kind == AgentErrorKind.BudgetExceeded &&
                error.code == "budget.model_requests_exceeded" &&
                model.workRequests == 2 && model.drainWireCalls == 0
        case None => false
    }, "work model requests stop at maxModelRequests while drain headroom " +
        "stays untouched")
}

func drainBlockedAtCostBoundaryContract(): Unit {
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = BudgetProbeModel(usagePerCall: Some(ModelUsage(
        inputTokens: 100, outputTokens: 20
    )))
    let result = budgetDrainCore(
        model, runs, catalog,
        "drain-cost-boundary-run", "drain-cost-boundary-session",
        maxTurns: 2, maxCostMicros: 280,
        pricing: Some(ModelPricing(
            inputMicrosPerMillion: Some(1000000),
            outputMicrosPerMillion: Some(2000000)
        ))
    )
    let completed = completedSnapshotOrThrow(
        result, "cost boundary must drain without provider request"
    )
    expect(
        completed.status == RunState.Completed && model.drainWireCalls == 0 &&
            completed.summary == "run drained at hard budget limit without " +
                "finalization request",
        "a cost-exhausted budget admits no drain finalization request"
    )
}


func drainPreflightBlocksNearCostBoundaryContract(): Unit {
    // 240/280 spent after one work turn. The old at-limit probe would pass
    // (240 < 280) and the drain request could push the run past the cap
    // before accounting caught it. The worst-case preflight blocks here and
    // delivers the durable checkpoint instead.
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = BudgetProbeModel(usagePerCall: Some(ModelUsage(
        inputTokens: 200, outputTokens: 20
    )))
    let result = budgetDrainCore(
        model, runs, catalog,
        "drain-preflight-run", "drain-preflight-session",
        maxTurns: 1, maxCostMicros: 280,
        pricing: Some(ModelPricing(
            inputMicrosPerMillion: Some(1000000),
            outputMicrosPerMillion: Some(2000000)
        ))
    )
    let completed = completedSnapshotOrThrow(
        result, "near-boundary cost must drain without provider request"
    )
    expect(
        completed.status == RunState.Completed && model.drainWireCalls == 0 &&
            completed.summary == "run drained at hard budget limit without " +
                "finalization request" &&
            completed.costMicros == Some(240),
        "the drain preflight blocks on worst-case cost before the cap is crossed"
    )
}

func childBudgetPoolSettlesWorkPlusDrainContract(): Unit {
    let parent = ExecutionBudget(
        maxTotalInputTokens: 1000,
        maxTotalOutputTokens: 1000,
        maxCostMicros: 1000
    )
    let pool = ChildBudgetPool(parent, 4)
    let childBudget = ExecutionBudget(
        maxTotalInputTokens: 800,
        maxTotalOutputTokens: 800,
        maxCostMicros: 600
    )
    let lease = match (pool.reserve("child-1", childBudget)) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(
            "child reserve failed: " + error.code
        )
    }
    let combined = ExecutionUsage(
        inputTokens: 130, outputTokens: 70, costMicros: 280
    )
    match (lease.settle(combined)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => throw IllegalStateException(
            "child settle failed: " + error.code
        )
    }
    let snapshot = pool.snapshot()
    expect(
        snapshot.activeReservations == 0 &&
            snapshot.consumed.inputTokens == 130 &&
            snapshot.consumed.outputTokens == 70 &&
            snapshot.consumed.costMicros == 280,
        "child budget settlement covers work plus drain usage without residue"
    )
}

func childBudgetPoolSchedulingGatesContract(): Unit {
    let parent = ExecutionBudget(maxCostMicros: 1000)
    let childBudget = ExecutionBudget(maxCostMicros: 100)
    let capped = ChildBudgetPool(parent, 1)
    let first = capped.reserve("c-1", childBudget)
    expect(first.isOk(), "first child reserves")
    let second = capped.reserve("c-2", childBudget)
    expect(second.isError() && second.error().getOrThrow().code ==
        "child.max_children_exceeded",
        "the total children gate still blocks after the cap")
    let concurrent = ChildBudgetPool(parent, 8, maxConcurrentChildren: 1)
    let unbounded = concurrent.reserve("d-3", ExecutionBudget())
    expect(unbounded.isError() && unbounded.error().getOrThrow().code ==
        "child.unbounded_cost_reservation",
        "unbounded cost children stay rejected under a bounded parent")
    let active = concurrent.reserve("d-1", childBudget)
    expect(active.isOk(), "first concurrent child reserves")
    let blocked = concurrent.reserve("d-2", childBudget)
    expect(blocked.isError() && blocked.error().getOrThrow().code ==
        "child.max_concurrent_children_exceeded",
        "the concurrency gate still blocks a second live lease")
    let overSettle = active.value().getOrThrow().settle(ExecutionUsage(costMicros: 101))
    expect(overSettle.isError() && overSettle.error().getOrThrow().code ==
        "child.actual_usage_exceeds_reservation",
        "settling above the reserved child budget stays rejected")
    expect(active.value().getOrThrow().settle(ExecutionUsage(costMicros: 80)).isOk(),
        "settling within the reservation releases the concurrency slot")
    expect(concurrent.reserve("d-4", childBudget).isOk(),
        "a settled lease frees its concurrency slot for the next child")
}

func budgetModeOrthogonalToApprovalContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let operations = MemoryOperations()
    let catalog = ToolCatalog()
    let tool = EchoTool(observer: Some(conversations))
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("echo", "side effect fixture", objectValue([])),
            Capability(CapabilityKind.WorkspaceWrite),
            sideEffecting: true
        ),
        tool
    ).isOk(), "side effect tool registration")
    let model = BudgetProbeModel()
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds()),
        catalog
    )
    let request = AgentRunRequest(
        RunId("budget-approval-run"), SessionId("budget-approval-session"),
        "fixture", "go",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceWrite)]),
        budget: ResourceBudget(maxTurns: 2)
    )
    let first = core.start(request).value().getOrThrow()
    let firstApproval = match (first) {
        case AgentRunOutcome.AwaitingApproval(_, value) => value
        case _ => throw IllegalStateException("first approval must pause the run")
    }
    let second = core.decide(request, firstApproval, ApprovalDecision.Approve)
    let secondApproval = match (second.value().getOrThrow()) {
        case AgentRunOutcome.AwaitingApproval(_, value) => value
        case _ => throw IllegalStateException("second approval must pause the run")
    }
    let completed = core.decide(request, secondApproval, ApprovalDecision.Approve)
    let snapshot = completedSnapshotOrThrow(completed, "approval resume completes")
    expect(
        snapshot.status == RunState.Completed && snapshot.turns == 2 &&
            model.drainWireCalls == 1 && tool.executions == 2,
        "BudgetMode never blocks WaitingApproval and the drained run still " +
            "finishes through the approval path"
    )
}


func usageAccountingContract(): Unit {
    let catalog = ToolCatalog()
    let pricedRuns = MemoryRuns()
    let pricedModel = DetailedUsageModel()
    let pricedCore = AgentCore(
        pricedModel,
        pricedRuns,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog
    )
    let priced = pricedCore.start(AgentRunRequest(
        RunId("priced-usage-run"),
        SessionId("priced-usage-session"),
        "fixture",
        "account usage",
        serviceTier: "priority",
        pricing: Some(ModelPricing(
            inputMicrosPerMillion: Some(1000000),
            outputMicrosPerMillion: Some(2000000),
            cacheReadMicrosPerMillion: Some(500000),
            cacheWriteMicrosPerMillion: Some(1500000)
        ))
    )).value().getOrThrow()
    let pricedSnapshot = match (priced) {
        case AgentRunOutcome.Completed(snapshot) => snapshot
        case _ => throw IllegalStateException("priced usage run did not complete")
    }
    expect(
        !pricedRuns.snapshots.isEmpty() && pricedRuns.snapshots[0].modelRequests == 0 &&
            pricedRuns.snapshots[0].costMicros.isNone(),
        "a new run with no model request keeps cost unknown"
    )
    expect(
        pricedSnapshot.inputTokens == 100 && pricedSnapshot.outputTokens == 20 &&
            pricedSnapshot.reasoningTokens == 5 && pricedSnapshot.cacheReadTokens == 30 &&
            pricedSnapshot.cacheWriteTokens == 10 && match (pricedSnapshot.costMicros) {
                case Some(value) => value == 130
                case None => false
            } && pricedSnapshot.lastInputTokens == 100 && pricedSnapshot.lastOutputTokens == 20 &&
            pricedSnapshot.lastRequestDurationMillis >= 0 && pricedModel.observedServiceTier == "priority",
        "canonical usage, explicit fixed-point cost, last-request metrics, and service tier reach the final snapshot"
    )

    let unknownRuns = MemoryRuns()
    let unknownCatalog = ToolCatalog()
    let unknown = AgentCore(
        DetailedUsageModel(),
        unknownRuns,
        ToolPipeline(unknownCatalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        unknownCatalog
    ).start(AgentRunRequest(
        RunId("unknown-price-run"),
        SessionId("unknown-price-session"),
        "fixture",
        "unknown price"
    )).value().getOrThrow()
    expect(match (unknown) {
        case AgentRunOutcome.Completed(snapshot) => snapshot.modelRequests == 1 && snapshot.costMicros.isNone()
        case _ => false
    }, "usage without explicit catalog pricing keeps cost unknown")
}

func contextCompactionContract(): Unit {
    // 8 turns grow the history far beyond maxContextMessages 6; the final
    // request must carry at most 6 messages and must not start on an orphan
    // tool result whose paired assistant call was compacted away.
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let echoTool = EchoTool(observer: Some(conversations))
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "echo",
                "echo text",
                objectValue([])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        echoTool
    ).isOk(), "tool registration")
    let model = MultiTurnModel(turns: 8, inputTokensPerCall: 3000)
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
        catalog
    )
    let result = core.start(AgentRunRequest(
        RunId("compact-run"),
        SessionId("compact-session"),
        "fixture",
        "go",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
        budget: ResourceBudget(maxInputTokens: 100000, maxContextMessages: 6)
    ))
    expect(result.isOk(), "compacted run completes")
    expect(
        model.lastMessagesSize <= 6,
        "the final request keeps at most maxContextMessages messages"
    )
    var firstIsOrphanResult = false
    if (!model.observedMessages.isEmpty()) {
        let first = model.observedMessages[0]
        var allResults = first.role == ModelRole.User && !first.blocks.isEmpty()
        for (block in first.blocks where block.kind != ModelBlockKind.ToolResult) {
            allResults = false
        }
        firstIsOrphanResult = allResults
    }
    expect(
        !firstIsOrphanResult,
        "compaction never leaves an orphan tool result at the window start"
    )
}

func queueModeContract(): Unit {
    let immediate = runSteeringContract(RunInterruptMode.Immediate)
    expect(
        immediate.tool.executions == 1 && immediate.model.calls == 2 && immediate.model.toolResultMessages == 1 &&
            immediate.model.toolResultBlocks == 2 && hasEvent(
        immediate.runs.eventLog,
        "tool.execution_skipped"
        ) && hasEvent(
            immediate.runs.eventLog,
            "interaction.injected"
        ),
        "immediate steering skips remaining tools and injects all messages"
    )
    let waiting = runSteeringContract(RunInterruptMode.Wait)
    expect(
        waiting.tool.executions == 2 && waiting.model.calls == 2 && waiting.model.toolResultMessages == 1 &&
            waiting.model.toolResultBlocks == 2 && !hasEvent(
        waiting.runs.eventLog,
        "tool.execution_skipped"
        ) && hasEvent(
            waiting.runs.eventLog,
            "interaction.injected"
        ),
        "wait steering finishes the tool batch before injection"
    )

    let oneAtATime = TestInteractions(steeringMode: QueueDeliveryMode.OneAtATime)
    let oneResult = runSteeringContract(
        RunInterruptMode.Immediate,
        interactions: oneAtATime
    )
    expect(
        oneResult.model.calls == 3,
        "one-at-a-time steering delivers one message per model turn"
    )

    let followAll = TestInteractions(followUpMode: QueueDeliveryMode.All)
    followAll.addFollowUp("follow one")
    followAll.addFollowUp("follow two")
    let allFollowModel = runFollowUpContract(followAll)
    expect(
        allFollowModel.calls == 2,
        "all follow-ups are delivered together after the agent would stop"
    )
    let followOne = TestInteractions(followUpMode: QueueDeliveryMode.OneAtATime)
    followOne.addFollowUp("follow one")
    followOne.addFollowUp("follow two")
    let oneFollowModel = runFollowUpContract(followOne)
    expect(
        oneFollowModel.calls == 3,
        "one-at-a-time follow-ups each receive a model turn"
    )
}

class SteeringContractResult {
    let tool: SteeringTool
    let model: TwoToolModel
    let runs: MemoryRuns

    init(tool: SteeringTool, model: TwoToolModel, runs: MemoryRuns) {
        this.tool = tool
        this.model = model
        this.runs = runs
    }
}

func runSteeringContract(
    interruptMode: RunInterruptMode,
    interactions!: ?TestInteractions = None
): SteeringContractResult {
    let source = match (interactions) {
        case Some(value) => value
        case None => TestInteractions(steeringMode: QueueDeliveryMode.All)
    }
    source.currentInterruptMode = interruptMode
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let tool = SteeringTool(source)
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition("echo", "echo text", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        tool
    ).isOk(), "steering tool registration")
    let model = TwoToolModel()
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(
            catalog,
            MemoryOperations(),
            MemoryAudit(),
            FixtureIds()
        ),
        catalog
    )
    let outcome = core.start(
        AgentRunRequest(
            RunId("queue-run"),
            SessionId("queue-session"),
            "fixture",
            "start queue contract",
            capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
            interactions: Some(source)
        )
    )
    expect(outcome.isOk(), "steering contract completes: " + match (outcome) {
        case Result.Err(error) => error.describe()
        case _ => "ok"
    })
    SteeringContractResult(tool, model, runs)
}

func runFollowUpContract(interactions: TestInteractions): TerminalModel {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let catalog = ToolCatalog()
    let model = TerminalModel()
    let core = AgentCore(
        model,
        runs,
        ToolPipeline(
            catalog,
            MemoryOperations(),
            MemoryAudit(),
            FixtureIds()
        ),
        catalog
    )
    let outcome = core.start(
        AgentRunRequest(
            RunId("follow-run"),
            SessionId("follow-session"),
            "fixture",
            "start follow-up contract",
            interactions: Some(interactions)
        )
    )
    expect(outcome.isOk(), "follow-up contract completes")
    model
}

func approvalResumeContract(): Unit {
    let conversations = MemoryConversations()
    let runs = MemoryRuns()
    let operations = MemoryOperations()
    let ids = FixtureIds()
    let catalog = ToolCatalog()
    let tool = EchoTool()
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "write_preview",
                "side effect fixture",
                objectValue([])
            ),
            Capability(CapabilityKind.WorkspaceWrite),
            sideEffecting: true
        ),
        tool
    ).isOk(), "side-effect tool registration")
    let core = AgentCore(
        TwoStepModel(toolName: "write_preview"),
        runs,
        ToolPipeline(catalog, operations, MemoryAudit(), ids),
        catalog
    )
    let request = AgentRunRequest(
        RunId("approval-run"),
        SessionId("approval-session"),
        "fixture",
        "write hello",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceWrite)])
    )
    let pending = core.start(request).value().getOrThrow()
    let approval = match (pending) {
        case AgentRunOutcome.AwaitingApproval(_, value) => value
        case _ => throw IllegalStateException("contract failed: side effect must pause")
    }
    expect(tool.executions == 0, "approval pause happens before execution")
    let mismatched = ApprovalRequest(
        approval.operationId,
        approval.callId,
        approval.toolName,
        approval.capability,
        preview: approval.preview,
        sessionId: approval.sessionId,
        argumentHash: approval.argumentHash + "-changed",
        riskFlags: approval.riskFlags,
        review: approval.review,
        metadata: approval.metadata,
        decisionSource: approval.decisionSource
    )
    match (core.decide(request, mismatched, ApprovalDecision.Approve)) {
        case Result.Err(error) => expect(
            error.kind == AgentErrorKind.Conflict && tool.executions == 0,
            "approval argument hash is bound before execution"
        )
        case _ => throw IllegalStateException("mismatched approval binding executed")
    }
    let completed = core.decide(
        request,
        approval,
        ApprovalDecision.Approve
    )
    expect(completed.isOk(), "approved run resumes: " + match (completed.error()) {
        case Some(error) => error.describe()
        case None => "ok"
    })
    expect(match (completed.value().getOrThrow()) {
        case AgentRunOutcome.Completed(snapshot) => snapshot.modelRequests == 2 && snapshot.turns == 2 &&
            snapshot.toolCalls == 1
        case _ => false
    }, "approved run reaches completion with cumulative budgets")
    expect(tool.executions == 1, "approved operation executes exactly once")
    expect(
        eventIndex(runs.eventLog, "approval.approved") >= 0 && eventIndex(
            runs.eventLog,
            "approval.approved"
        ) < eventIndex(runs.eventLog, "tool.execution_completed"),
        "approval decision is journaled before the approved tool settles"
    )
    var previous: Int64 = 0
    for (event in runs.eventLog) {
        expect(event.sequence > previous, "event sequence survives approval resume")
        previous = event.sequence
    }
}

func eventIndex(events: ArrayList<AgentEvent>, code: String): Int64 {
    for (index in 0..events.size) {
        if (typedEventMatches(events[index], code)) { return index }
        match (events[index].detail.field("code")) {
            case Some(value) => if (value.text == code) { return index }
            case None => ()
        }
    }
    -1
}

func hasEvent(events: ArrayList<AgentEvent>, code: String): Bool {
    for (event in events) {
        if (typedEventMatches(event, code)) { return true }
        match (event.detail.field("code")) {
            case Some(value) =>
                if (value.text == code) {
                    return true
                }
            case None => ()
        }
    }
    false
}

func requestOutcomeCounts(
    events: ArrayList<AgentEvent>
): (Int64, Int64, Int64) {
    var succeeded: Int64 = 0
    var failed: Int64 = 0
    var cancelled: Int64 = 0
    for (event in events) {
        match (event.payload) {
            case AgentEventPayload.ModelRequestAttemptCompleted(value) =>
                match (value.outcome) {
                    case ModelRequestOutcome.Succeeded => succeeded += 1
                    case ModelRequestOutcome.Failed => failed += 1
                    case ModelRequestOutcome.Cancelled => cancelled += 1
                }
            case _ => ()
        }
    }
    (succeeded, failed, cancelled)
}

func typedEventMatches(event: AgentEvent, code: String): Bool {
    match (event.payload) {
        case AgentEventPayload.TextDelta(_) => code == "model.text_delta"
        case AgentEventPayload.ReasoningDelta(_) => code == "model.reasoning_delta"
        case AgentEventPayload.ModelUsageUpdated(_) => code == "model.usage"
        case _ => false
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException("contract failed: ${message}")
    }
}

func contractModelReply(
    blocks: Array<ModelBlock>,
    stopReason!: String = "",
    inputTokens!: Int64 = 0,
    outputTokens!: Int64 = 0,
    acceptedOutput!: Bool = true,
    providerId!: String = "contract",
    responseId!: String = "contract-response",
    reasoningTokens!: Int64 = 0,
    cacheReadTokens!: Int64 = 0,
    cacheWriteTokens!: Int64 = 0,
    costMicros!: ?Int64 = None,
    usage!: ?ModelUsage = None,
    structuredOutput!: ?AgentValue = None
): ModelReply {
    var hasTool = false
    var hasRefusal = false
    for (block in blocks) {
        if (block.kind == ModelBlockKind.ToolCall) { hasTool = true }
        if (block.kind == ModelBlockKind.Refusal) { hasRefusal = true }
    }
    ModelReply(
        blocks, stopReason: stopReason, inputTokens: inputTokens,
        outputTokens: outputTokens, acceptedOutput: acceptedOutput,
        providerId: providerId, responseId: responseId,
        reasoningTokens: reasoningTokens, cacheReadTokens: cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens, costMicros: costMicros,
        usage: usage, structuredOutput: structuredOutput,
        terminalEvidence: Some(TerminalEvidence(
            "contract", "message_stop", rawStopReason: stopReason,
            messageTerminalObserved: true, streamEofObserved: true,
            adapterVersion: "agent-core-contract-v1"
        )),
        completionDisposition: if (hasTool) {
            CompletionDisposition.ToolUse
        } else { CompletionDisposition.Complete },
        decisionOutcome: if (hasRefusal) {
            DecisionOutcome.Refusal
        } else if (hasTool) {
            DecisionOutcome.ToolCalls
        } else { DecisionOutcome.Response },
        validationVersion: 1
    )
}

class RecordingModelDecisionPort <: ModelDecisionRuntimePort {
    var attempts: Int64 = 0
    var decisions: Int64 = 0
    var lastPolicy: ?AgentValue = None
    let persisted = ArrayList<ModelDecision>()
    let createdAttempts = ArrayList<DurableModelAttempt>()
    var recoveredDecision: ?ModelDecision = None
    let terminalizedIds = ArrayList<ModelAttemptId>()
    let terminalizedLifecycles = ArrayList<ModelAttemptLifecycle>()
    var projected = false
    private let rejectPersistence: Bool

    init(rejectPersistence!: Bool = false) {
        this.rejectPersistence = rejectPersistence
    }

    public func abandonOpenAttempts(runId: RunId, abandonedAtMillis: Int64): Result<Unit> {
        let _ = runId.value
        let _ = abandonedAtMillis
        Result.Ok(())
    }

    public func createAttempt(attempt: DurableModelAttempt): Result<Unit> {
        attempts += 1
        lastPolicy = Some(attempt.policy)
        createdAttempts.add(attempt)
        Result.Ok(())
    }

    public func terminalizeAttempt(
        attemptId: ModelAttemptId,
        lifecycle: ModelAttemptLifecycle,
        failureKind: String,
        completedAtMillis: Int64
    ): Result<Unit> {
        terminalizedIds.add(attemptId)
        terminalizedLifecycles.add(lifecycle)
        let _ = failureKind
        let _ = completedAtMillis
        Result.Ok(())
    }

    public func persistValidatedDecision(decision: ModelDecision): Result<Unit> {
        if (rejectPersistence) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "fixture.decision_persist_interrupted",
                "fault injection before durable Decision commit"
            ))
        }
        decisions += 1
        persisted.add(decision)
        Result.Ok(())
    }

    public func finalizeUsage(
        decisionId: ModelDecisionId,
        usage: ModelUsage,
        finalizedAtMillis: Int64
    ): Result<Unit> {
        let _ = decisionId.value
        let _ = usage.outputTokens
        let _ = finalizedAtMillis
        Result.Ok(())
    }

    public func uncommittedDecision(runId: RunId): Result<?ModelDecision> {
        let _ = runId.value
        if (projected) {
            return Result.Ok(None)
        }
        match (recoveredDecision) {
            case Some(value) => Result.Ok(Some(value))
            case None => Result.Ok(if (persisted.isEmpty()) {
                None
            } else {
                Some(persisted[persisted.size - 1])
            })
        }
    }


    public func committedToolCallSources(
        runId: RunId
    ): Result<Array<CommittedToolCallSource>> {
        let _ = runId.value
        Result.Ok([])
    }

    public func recordCanonicalProjection(
        decisionId: ModelDecisionId,
        sources: Array<CommittedToolCallSource>
    ): Result<Unit> {
        let _ = decisionId.value
        let _ = sources.size
        projected = true
        Result.Ok(())
    }
}

func isCompleted(status: RunState): Bool {
    match (status) {
        case RunState.Completed => true
        case _ => false
    }
}

class RepeatedCapabilityDeniedModel <: ModelPort {
    var calls: Int64 = 0

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request
        calls += 1
        events(ModelEvent.Completed)
        Result.Ok(
            contractModelReply(
                [
                    ModelBlock(
                        ModelBlockKind.ToolCall,
                        callId: "restricted-" + calls.toString(),
                        name: "write",
                        arguments: objectValue([])
                    )
                ]
            )
        )
    }
}

class ResetCapabilityDeniedModel <: ModelPort {
    var calls: Int64 = 0

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request
        calls += 1
        events(ModelEvent.Completed)
        if (calls == 5) {
            return Result.Ok(
            contractModelReply(
                    [ModelBlock(ModelBlockKind.Text, text: "done")],
                    stopReason: "end_turn"
                )
            )
        }
        let tool = if (calls == 2) { "echo" } else { "write" }
        Result.Ok(
            contractModelReply(
                [
                    ModelBlock(
                        ModelBlockKind.ToolCall,
                        callId: "reset-" + calls.toString(),
                        name: tool,
                        arguments: objectValue([])
                    )
                ]
            )
        )
    }
}

class TwoStepModel <: ModelPort {
    var calls: Int64 = 0
    let requests = ArrayList<ModelRequest>()
    let toolName: String

    public init(toolName!: String = "echo") {
        this.toolName = toolName
    }

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        requests.add(request)
        calls += 1
        events(ModelEvent.Completed)
        if (calls == 1) {
            Result.Ok(
            contractModelReply(
                    [
                        ModelBlock(
                            ModelBlockKind.ToolCall,
                            callId: "call-1",
                            name: toolName,
                            arguments: objectValue([ValueField("text", textValue("hello"))])
                        )
                    ]
                )
            )
        } else {
            Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "hello")], stopReason: "end_turn"))
        }
    }
}

class RecoveryAwareModel <: ModelPort {
    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        events(ModelEvent.Completed)
        for (message in request.messages) {
            for (block in message.blocks where block.kind == ModelBlockKind.ToolResult && block.callId == "call-1") {
                return Result.Ok(contractModelReply(
                    [ModelBlock(ModelBlockKind.Text, text: "recovered")],
                    stopReason: "end_turn"
                ))
            }
        }
        Result.Ok(contractModelReply([
            ModelBlock(
                ModelBlockKind.ToolCall,
                callId: "call-1",
                name: "write_preview",
                arguments: objectValue([ValueField("text", textValue("once"))])
            )
        ]))
    }
}

class StalledModel <: ModelPort {
    private let lock = Mutex()
    var cancelled = false

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request
        let _ = events
        // Each attempt is an independent stall: reset the cancelled flag so a
        // retried call stalls again until its own idle timeout fires.
        lock.lock()
        try {
            cancelled = false
        } finally {
            lock.unlock()
        }
        while (true) {
            lock.lock()
            let stopped = try {
                cancelled
            } finally {
                lock.unlock()
            }
            if (stopped) {
                return Result.Err(AgentError(
                    AgentErrorKind.Cancelled,
                    "fixture.cancelled",
                    "fixture model cancelled"
                ))
            }
            sleep(Duration.millisecond * 5)
        }
        Result.Err(AgentError(
            AgentErrorKind.Internal,
            "fixture.unreachable",
            "unreachable"
        ))
    }

    public func cancel(requestId: String): Result<Unit> {
        let _ = requestId
        lock.lock()
        try {
            cancelled = true
        } finally {
            lock.unlock()
        }
        Result.Ok(())
    }
}

class SleepEchoTool <: ToolExecutor {
    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        sleep(Duration.millisecond * 200)
        Result.Ok(ToolResult(call.callId, call.arguments))
    }

    public func afterResultPersisted(
        context: ToolInvocationContext,
        result: ToolResult
    ): Result<Unit> {
        let _ = context
        let _ = result
        Result.Ok(())
    }
}


class EchoTool <: ToolExecutor {
    var executions: Int64 = 0
    var persistedResults: Int64 = 0
    var persistedConversationSize: Int64 = 0
    private let observer: ?MemoryConversations

    init(observer!: ?MemoryConversations = None) {
        this.observer = observer
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        executions += 1
        Result.Ok(
            ToolResult(
                call.callId,
                call.arguments
            )
        )
    }

    public func afterResultPersisted(
        context: ToolInvocationContext,
        result: ToolResult
    ): Result<Unit> {
        let _ = context
        let _ = result
        persistedResults += 1
        match (observer) {
            case Some(value) => persistedConversationSize = value.messages.size
            case None => ()
        }
        Result.Ok(())
    }
}

class ToolContextProbe <: ToolExecutor {
    private let expectedRoot: String
    private let lock = Mutex()
    private let registrations = ArrayList<CancellationRegistration>()
    private var invocations: Int64 = 0
    private var cancelledInvocations: Int64 = 0
    private var valid = true

    init(expectedRoot: String) {
        this.expectedRoot = expectedRoot
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        lock.lock()
        try {
            invocations += 1
            valid = valid && context.workspaceRoot == expectedRoot &&
                context.cwd == expectedRoot + "/src" &&
                context.environment.value("CONTEXT_VISIBLE") == Some("explicit") &&
                context.services.contains(ToolServiceKind.Custom, name: "context-probe") &&
                !context.cancellation.isCancelled()
            registrations.add(context.cancellation.onCancel({_ => markCancelled()}))
        } finally {
            lock.unlock()
        }
        Result.Ok(ToolResult(call.callId, call.arguments))
    }

    func invocationCount(): Int64 {
        lock.lock()
        try { invocations } finally { lock.unlock() }
    }

    func cancelledInvocationCount(): Int64 {
        lock.lock()
        try { cancelledInvocations } finally { lock.unlock() }
    }

    func metadataMatches(): Bool {
        lock.lock()
        try { valid } finally { lock.unlock() }
    }

    private func markCancelled(): Unit {
        lock.lock()
        try { cancelledInvocations += 1 } finally { lock.unlock() }
    }
}

class DecisionBoundTool <: ToolExecutor {
    private let runs: MemoryRuns
    var executions: Int64 = 0
    var decisionDurableAtExecution = false

    init(runs: MemoryRuns) {
        this.runs = runs
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let _ = context
        executions += 1
        decisionDurableAtExecution = runs.savedDecision.isSome()
        Result.Ok(ToolResult(call.callId, call.arguments, isError: true))
    }
}

class TestInteractions <: AgentInteractionSource {
    let steering = ArrayList<AgentQueuedInput>()
    let followUps = ArrayList<AgentQueuedInput>()
    var steeringMode: QueueDeliveryMode
    var followUpMode: QueueDeliveryMode
    var currentInterruptMode = RunInterruptMode.Immediate

    init(
        steeringMode!: QueueDeliveryMode = QueueDeliveryMode.OneAtATime,
        followUpMode!: QueueDeliveryMode = QueueDeliveryMode.OneAtATime
    ) {
        this.steeringMode = steeringMode
        this.followUpMode = followUpMode
    }

    func addSteering(value: String): Unit {
        steering.add(AgentQueuedInput(value))
    }

    func addFollowUp(value: String): Unit {
        followUps.add(AgentQueuedInput(value))
    }

    public func takeSteering(): Array<AgentQueuedInput> {
        take(steering, steeringMode)
    }

    public func hasSteering(): Bool {
        !steering.isEmpty()
    }

    public func takeFollowUps(): Array<AgentQueuedInput> {
        take(followUps, followUpMode)
    }

    public func interruptMode(): RunInterruptMode {
        currentInterruptMode
    }

    private func take(
        source: ArrayList<AgentQueuedInput>,
        mode: QueueDeliveryMode
    ): Array<AgentQueuedInput> {
        if (source.isEmpty()) {
            return []
        }
        match (mode) {
            case QueueDeliveryMode.OneAtATime =>
                let first = source[0]
                source.remove(at: 0)
                [first]
            case QueueDeliveryMode.All =>
                let values = source.toArray()
                source.clear()
                values
        }
    }
}

class SteeringTool <: ToolExecutor {
    private let interactions: TestInteractions
    var executions: Int64 = 0

    init(interactions: TestInteractions) {
        this.interactions = interactions
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let _ = context
        executions += 1
        if (executions == 1) {
            interactions.addSteering("steer one")
            interactions.addSteering("steer two")
        }
        Result.Ok(ToolResult(call.callId, call.arguments))
    }
}

class ToolWaveProbe {
    private let lock = Mutex()
    private var active: Int64 = 0
    var maxActive: Int64 = 0
    var waveAFinished = false
    var waveBStartedBeforeAFinished = false

    func entered(name: String): Unit {
        lock.lock()
        try {
            if (name == "wave_b" && !waveAFinished) {
                waveBStartedBeforeAFinished = true
            }
            active += 1
            maxActive = max(maxActive, active)
        } finally {
            lock.unlock()
        }
    }

    func left(name: String): Unit {
        lock.lock()
        try {
            if (name == "wave_a") {
                waveAFinished = true
            }
            active -= 1
        } finally {
            lock.unlock()
        }
    }
}

class WaveTool <: ToolExecutor {
    private let name: String
    private let delayMillis: Int64
    private let probe: ToolWaveProbe

    init(name: String, delayMillis: Int64, probe: ToolWaveProbe) {
        this.name = name
        this.delayMillis = delayMillis
        this.probe = probe
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let _ = context
        probe.entered(name)
        sleep(Duration.millisecond * delayMillis)
        probe.left(name)
        Result.Ok(ToolResult(call.callId, objectValue([
            ValueField("tool", textValue(name))
        ])))
    }
}

class ParallelBatchModel <: ModelPort {
    var calls: Int64 = 0
    var observedStableResultOrder = false

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        calls += 1
        events(ModelEvent.Completed)
        if (calls == 1) {
            return Result.Ok(contractModelReply([
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "wave-call-a",
                    name: "wave_a",
                    arguments: objectValue([])
                ),
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "wave-call-b",
                    name: "wave_b",
                    arguments: objectValue([])
                ),
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "wave-call-c",
                    name: "wave_c",
                    arguments: objectValue([])
                )
            ]))
        }
        let ids = modelRequestToolResultIds(request)
        observedStableResultOrder = ids.size == 3 && ids[0] == "wave-call-a" &&
            ids[1] == "wave-call-b" && ids[2] == "wave-call-c"
            Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "parallel done")],
            stopReason: "end_turn"
        ))
    }
}

class FatalWaveTool <: ToolExecutor {
    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let _ = context
        let _ = call
        Result.Err(AgentError(
            AgentErrorKind.Internal,
            "fixture.wave_fatal",
            "injected fatal tool failure"
        ))
    }
}

class PartialFailureBatchModel <: ModelPort {
    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply([
            ModelBlock(
                ModelBlockKind.ToolCall,
                callId: "partial-call-fatal",
                name: "wave_fatal",
                arguments: objectValue([])
            ),
            ModelBlock(
                ModelBlockKind.ToolCall,
                callId: "partial-call-success",
                name: "wave_success",
                arguments: objectValue([])
            )
        ]))
    }
}

class ApprovalBatchModel <: ModelPort {
    var calls: Int64 = 0
    var observedStableResultOrder = false

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        calls += 1
        events(ModelEvent.Completed)
        if (calls == 1) {
            return Result.Ok(contractModelReply([
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "approval-call-a",
                    name: "batch_safe",
                    arguments: objectValue([])
                ),
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "approval-call-b",
                    name: "batch_write",
                    arguments: objectValue([])
                ),
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "approval-call-c",
                    name: "batch_safe",
                    arguments: objectValue([])
                )
            ]))
        }
        let ids = modelRequestToolResultIds(request)
        observedStableResultOrder = ids.size == 3 && ids[0] == "approval-call-a" &&
            ids[1] == "approval-call-b" && ids[2] == "approval-call-c"
            Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "approval batch done")],
            stopReason: "end_turn"
        ))
    }
}

class BlockingApprovalBatchModel <: ModelPort {
    private let lock = Mutex()
    private var calls: Int64 = 0
    private var resumed = false
    private var cancelled = false

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let call = nextCall()
        if (call == 1) {
            events(ModelEvent.Completed)
            return Result.Ok(contractModelReply([
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "approval-call-a",
                    name: "batch_safe",
                    arguments: objectValue([])
                ),
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "approval-call-b",
                    name: "batch_write",
                    arguments: objectValue([])
                ),
                ModelBlock(
                    ModelBlockKind.ToolCall,
                    callId: "approval-call-c",
                    name: "batch_safe",
                    arguments: objectValue([])
                )
            ]))
        }
        let _ = request
        lock.lock()
        try { resumed = true } finally { lock.unlock() }
        while (!wasCancelled()) {
            sleep(Duration.millisecond * 5)
        }
        Result.Err(AgentError(
            AgentErrorKind.Cancelled,
            "fixture.context_cancelled",
            "context cancellation fixture stopped"
        ))
    }

    public func cancel(requestId: String): Result<Unit> {
        let _ = requestId
        lock.lock()
        try { cancelled = true } finally { lock.unlock() }
        Result.Ok(())
    }

    func resumeModelStarted(): Bool {
        lock.lock()
        try { resumed } finally { lock.unlock() }
    }

    private func nextCall(): Int64 {
        lock.lock()
        try {
            calls += 1
            calls
        } finally {
            lock.unlock()
        }
    }

    private func wasCancelled(): Bool {
        lock.lock()
        try { cancelled } finally { lock.unlock() }
    }
}

func modelRequestToolResultIds(request: ModelRequest): Array<String> {
    let ids = ArrayList<String>()
    for (message in request.messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolResult) {
            ids.add(block.callId)
        }
    }
    ids.toArray()
}

class TwoToolModel <: ModelPort {
    var calls: Int64 = 0
    var toolResultMessages: Int64 = 0
    var toolResultBlocks: Int64 = 0

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        calls += 1
        if (calls > 1) {
            for (message in request.messages) {
                var count: Int64 = 0
                for (block in message.blocks where block.kind == ModelBlockKind.ToolResult) {
                    count += 1
                }
                if (count > 0) {
                    toolResultMessages += 1
                    toolResultBlocks += count
                }
            }
        }
        events(ModelEvent.Completed)
        if (calls == 1) {
            Result.Ok(
            contractModelReply(
                    [
                        ModelBlock(
                            ModelBlockKind.ToolCall,
                            callId: "queue-call-1",
                            name: "echo",
                            arguments: objectValue([])
                        ),
                        ModelBlock(
                            ModelBlockKind.ToolCall,
                            callId: "queue-call-2",
                            name: "echo",
                            arguments: objectValue([])
                        )
                    ]
                )
            )
        } else {
            Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "queue handled")], stopReason: "end_turn"))
        }
    }
}

class TerminalModel <: ModelPort {
    var calls: Int64 = 0

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request
        calls += 1
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "done")], stopReason: "end_turn"))
    }
}

class SkillObservingModel <: ModelPort {
    var system: String = ""

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        system = request.system
        events(ModelEvent.Completed)
            Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "reviewed")],
            stopReason: "end_turn"
        ))
    }
}

class DetailedUsageModel <: ModelPort {
    var observedServiceTier: String = ""
    var calls: Int64 = 0

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        calls += 1
        observedServiceTier = request.serviceTier
        events(ModelEvent.Completed)
            Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "accounted")],
            stopReason: "end_turn",
            usage: Some(ModelUsage(
                inputTokens: 100,
                outputTokens: 20,
                reasoningTokens: 5,
                cacheReadTokens: 30,
                cacheWriteTokens: 10
            ))
        ))
    }
}

class MemoryConversations {
    let messages = ArrayList<ModelMessage>()
}
class MemoryRuns <: RunRepository {
    let snapshots = ArrayList<RunSnapshot>()
    let eventLog = ArrayList<AgentEvent>()
    let modelAttempts = ArrayList<DurableModelAttempt>()
    let failStreamTelemetry: Bool
    var failClaimBeforeCommitAt: Int64
    var failClaimAfterCommitAt: Int64
    var claims: Int64 = 0
    var savedContinuation: ?RunContinuation = None
    var savedDecision: ?ApprovalDecisionReceipt = None
    let savedDecisions = ArrayList<ApprovalDecisionReceipt>()
    private let initialSaveLock = Mutex()
    private let blockInitialSave: Bool
    private var initialSaveEntered: Bool = false
    private var initialSaveReleased: Bool = false

    public init(
        failStreamTelemetry!: Bool = false,
        failClaimBeforeCommitAt!: Int64 = 0,
        failClaimAfterCommitAt!: Int64 = 0,
        blockInitialSave!: Bool = false
    ) {
        this.failStreamTelemetry = failStreamTelemetry
        this.failClaimBeforeCommitAt = failClaimBeforeCommitAt
        this.failClaimAfterCommitAt = failClaimAfterCommitAt
        this.blockInitialSave = blockInitialSave
    }

    public func save(snapshot: RunSnapshot): Result<Unit> {
        if (blockInitialSave && snapshots.isEmpty()) {
            initialSaveLock.lock()
            initialSaveEntered = true
            initialSaveLock.unlock()
            while (true) {
                initialSaveLock.lock()
                let released = initialSaveReleased
                initialSaveLock.unlock()
                if (released) { break }
                sleep(Duration.millisecond)
            }
        }
        snapshots.add(snapshot)
        Result.Ok(())
    }

    public func initialSaveStarted(): Bool {
        initialSaveLock.lock()
        try { initialSaveEntered } finally { initialSaveLock.unlock() }
    }

    public func releaseInitialSave(): Unit {
        initialSaveLock.lock()
        try { initialSaveReleased = true } finally { initialSaveLock.unlock() }
    }

    public func find(runId: RunId): Result<RunSnapshot> {
        if (snapshots.isEmpty()) {
            Result.Err(missing("run"))
        } else {
            Result.Ok(snapshots[snapshots.size - 1])
        }
    }

    public func events(runId: RunId, after: Int64): Result<EventPage> {
        Result.Ok(EventPage(eventLog.toArray(), eventLog.size + 1))
    }

    public func append(event: AgentEvent): Result<Unit> {
        if (failStreamTelemetry && event.meta.attemptId.isSome() && match (event.payload) {
            case AgentEventPayload.TextDelta(_) | AgentEventPayload.ReasoningDelta(_) => true
            case AgentEventPayload.Extension(_, detail) => match (detail.field("code")) {
                case Some(value) => value.unifiedKind == ValueKind.Text &&
                    value.text == "model.tool_arguments"
                case None => false
            }
            case _ => false
        }) {
            return Result.Err(AgentError(
                AgentErrorKind.Internal,
                "fixture.telemetry_persistence_failed",
                "fixture rejects provisional stream telemetry"
            ))
        }
        if ((!eventLog.isEmpty() &&
            event.sequence != eventLog[eventLog.size - 1].sequence + 1) ||
            (eventLog.isEmpty() && event.sequence != 1)) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "fixture.event_sequence",
                    "event sequence must increase"
                )
            )
        }
        eventLog.add(event)
        Result.Ok(())
    }

    public func saveContinuation(value: RunContinuation): Result<Unit> {
        savedContinuation = Some(value)
        Result.Ok(())
    }

    public func continuation(runId: RunId): Result<RunContinuation> {
        match (savedContinuation) {
            case Some(value) => if (value.runId.value == runId.value) {
                Result.Ok(value)
            } else {
                Result.Err(missing("continuation"))
            }
            case None => Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "run.continuation_recovery_required",
                "pending approval continuation is missing"
            ))
        }
    }

    public func pendingContinuation(sessionId: SessionId): Result<?RunContinuation> {
        if (snapshots.isEmpty() || snapshots[snapshots.size - 1].status != RunState.WaitingApproval ||
            snapshots[snapshots.size - 1].sessionId.value != sessionId.value) {
            return Result.Ok(None)
        }
        match (continuation(snapshots[snapshots.size - 1].runId)) {
            case Result.Ok(value) => Result.Ok(Some(value))
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func pendingRecoveryContinuation(
        sessionId: SessionId
    ): Result<?RunContinuation> {
        match (savedContinuation) {
            case Some(value) => if (value.sessionId.value == sessionId.value &&
                value.kind == RunContinuationKind.RunningModel) {
                Result.Ok(Some(value))
            } else { Result.Ok(None) }
            case None => Result.Ok(None)
        }
    }

    public func prepareModelAttempt(
        attempt: DurableModelAttempt,
        event: AgentEvent,
        continuation: RunContinuation
    ): Result<Unit> {
        for (existing in modelAttempts where existing.id.value == attempt.id.value) {
            if (existing.semanticRequestDigest == attempt.semanticRequestDigest &&
                existing.wirePolicyDigest == attempt.wirePolicyDigest &&
                eventLogContainsExact(event)) {
                savedContinuation = Some(continuation)
                return Result.Ok(())
            }
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "fixture.model_attempt_conflict",
                "prepared model Attempt identity drift"
            ))
        }
        match (append(event)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        modelAttempts.add(attempt)
        savedContinuation = Some(continuation)
        Result.Ok(())
    }

    public func prepareRestartModelAttempt(
        parent: DurableModelAttempt,
        attempt: DurableModelAttempt,
        policyEvent: AgentEvent,
        duplicateEvent: AgentEvent,
        continuation: RunContinuation
    ): Result<Unit> {
        let current = match (savedContinuation) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "fixture.restart_continuation_missing",
                "restart continuation is missing"
            ))
        }
        if (current.runningModel.isNone() ||
            current.runningModel.getOrThrow().activeAttemptId.value != parent.id.value ||
            attempt.parentAttemptId.isNone() ||
            attempt.parentAttemptId.getOrThrow().value != parent.id.value ||
            duplicateEvent.sequence != policyEvent.sequence + 1) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "fixture.restart_boundary_conflict",
                "restart model boundary identity drift"
            ))
        }
        var parentIndex: Int64 = -1
        for (index in 0..modelAttempts.size where
            modelAttempts[index].id.value == parent.id.value) {
            parentIndex = index
        }
        if (parentIndex < 0 ||
            modelAttempts[parentIndex].dispatchState !=
                ModelAttemptDispatchState.DispatchClaimed ||
            modelAttempts[parentIndex].replayBarrier !=
                ModelAttemptReplayBarrier.NoBarrier) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "fixture.restart_parent_invalid",
                "restart parent Attempt is not recoverable"
            ))
        }
        match (append(policyEvent)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (append(duplicateEvent)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        modelAttempts[parentIndex] = fixtureAttemptAbandoned(
            modelAttempts[parentIndex], duplicateEvent.meta.occurredAtMillis
        )
        modelAttempts.add(attempt)
        savedContinuation = Some(continuation)
        Result.Ok(())
    }

    public func modelAttempt(
        attemptId: ModelAttemptId
    ): Result<DurableModelAttempt> {
        for (attempt in modelAttempts where attempt.id.value == attemptId.value) {
            return Result.Ok(attempt)
        }
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "fixture.model_attempt_missing",
            "durable model Attempt is missing"
        ))
    }

    public func claimModelAttemptDispatch(
        attemptId: ModelAttemptId,
        event: AgentEvent
    ): Result<Bool> {
        claims += 1
        if (failClaimBeforeCommitAt == claims) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "fixture.crash_before_dispatch_claim",
                "fault injected before dispatch claim commit"
            ))
        }
        for (index in 0..modelAttempts.size where
            modelAttempts[index].id.value == attemptId.value) {
            let attempt = modelAttempts[index]
            if (attempt.dispatchState == ModelAttemptDispatchState.DispatchClaimed) {
                return Result.Ok(false)
            }
            if (attempt.dispatchState != ModelAttemptDispatchState.Prepared ||
                attempt.replayBarrier != ModelAttemptReplayBarrier.NoBarrier) {
                return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "fixture.model_attempt_not_dispatchable",
                    "durable model Attempt is not dispatchable"
                ))
            }
            match (append(event)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            modelAttempts[index] = fixtureAttemptWithDispatch(attempt, event.meta.occurredAtMillis)
            if (failClaimAfterCommitAt == claims) {
                return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "fixture.crash_after_dispatch_claim",
                    "fault injected after dispatch claim commit"
                ))
            }
            return Result.Ok(true)
        }
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "fixture.model_attempt_missing",
            "durable model Attempt is missing"
        ))
    }

    public func markModelAttemptReplayBarrier(
        attemptId: ModelAttemptId,
        barrier: ModelAttemptReplayBarrier,
        event: AgentEvent
    ): Result<Unit> {
        for (index in 0..modelAttempts.size where
            modelAttempts[index].id.value == attemptId.value) {
            let attempt = modelAttempts[index]
            if (attempt.replayBarrier == barrier) {
                return if (eventLogContainsExact(event)) { Result.Ok(()) } else {
                    Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "fixture.model_barrier_event_missing",
                        "model replay barrier event identity drift"
                    ))
                }
            }
            if (attempt.replayBarrier != ModelAttemptReplayBarrier.NoBarrier) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "fixture.model_barrier_conflict",
                    "model replay barrier identity drift"
                ))
            }
            match (append(event)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            modelAttempts[index] = fixtureAttemptWithBarrier(attempt, barrier)
            return Result.Ok(())
        }
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "fixture.model_attempt_missing",
            "durable model Attempt is missing"
        ))
    }

    public func clearModelExecutionContinuation(
        runId: RunId,
        activeAttemptId: ModelAttemptId
    ): Result<Unit> {
        match (savedContinuation) {
            case Some(value) => match (value.runningModel) {
                case Some(checkpoint) => if (value.runId.value != runId.value ||
                    checkpoint.activeAttemptId.value != activeAttemptId.value) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "fixture.model_continuation_conflict",
                        "model continuation Attempt binding drift"
                    ))
                }
                case None => return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "fixture.model_continuation_kind",
                    "continuation is not a model execution"
                ))
            }
            case None => return Result.Ok(())
        }
        savedContinuation = None
        Result.Ok(())
    }

    private func eventLogContainsExact(event: AgentEvent): Bool {
        for (existing in eventLog where existing.sequence == event.sequence) {
            return existing.runId.value == event.runId.value &&
                existing.kind == event.kind &&
                fixtureAgentValuesEqual(existing.detail, event.detail)
        }
        false
    }

    public func saveDecision(value: ApprovalDecisionReceipt): Result<Unit> {
        for (existing in savedDecisions where
            existing.operationId.value == value.operationId.value) {
            if (sameFixtureDecision(existing, value)) {
                return Result.Ok(())
            }
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "persistence.conflict",
                "approval decision receipt cannot be changed"
            ))
        }
        savedDecisions.add(value)
        if (savedDecision.isNone()) {
            savedDecision = Some(value)
        }
        Result.Ok(())
    }

    public func decision(operationId: OperationId): Result<ApprovalDecisionReceipt> {
        for (value in savedDecisions where
            value.operationId.value == operationId.value) {
            return Result.Ok(value)
        }
        Result.Err(missing("decision"))
    }

    public func recordDecision(
        value: ApprovalDecisionReceipt
    ): Result<RunSnapshot> {
        if (snapshots.isEmpty()) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "run.decision_recovery_required",
                "approval decision run snapshot is missing"
            ))
        }
        let snapshot = snapshots[snapshots.size - 1]
        if (snapshot.runId.value != value.runId.value ||
            snapshot.sessionId.value != value.sessionId.value) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "run.decision_recovery_required",
                "approval decision run binding is corrupt"
            ))
        }
        match (snapshot.status) {
            case RunState.WaitingApproval => match (saveDecision(value)) {
                case Result.Ok(_) => Result.Ok(snapshot)
                case Result.Err(error) => Result.Err(error)
            }
            case RunState.Completed => match (savedDecision) {
                case Some(existing) => if (sameFixtureDecision(existing, value)) {
                    Result.Ok(snapshot)
                } else {
                    Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "persistence.conflict",
                        "completed run approval decision cannot be changed"
                    ))
                }
                case None => Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "run.decision_recovery_required",
                    "completed approval run has no durable decision receipt"
                ))
            }
            case _ => Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "run.not_awaiting_approval",
                "run is not waiting for an approval decision"
            ))
        }
    }
}

func fixtureAttemptWithDispatch(
    value: DurableModelAttempt,
    dispatchStartedAtMillis: Int64
): DurableModelAttempt {
    DurableModelAttempt(
        value.id, value.semanticRequestId, value.runId, value.attemptNo,
        value.lifecycle, value.policy, value.policyReason,
        value.startedAtMillis, value.lastActivityAtMillis,
        parentAttemptId: value.parentAttemptId,
        completedAtMillis: value.completedAtMillis,
        providerRequestId: value.providerRequestId,
        providerResponseId: value.providerResponseId,
        failureKind: value.failureKind,
        semanticRequestDigest: value.semanticRequestDigest,
        wirePolicyDigest: value.wirePolicyDigest,
        dispatchState: ModelAttemptDispatchState.DispatchClaimed,
        replayBarrier: value.replayBarrier,
        dispatchStartedAtMillis: Some(dispatchStartedAtMillis),
        providerTerminalAtMillis: value.providerTerminalAtMillis
    )
}

func fixtureAgentValuesEqual(left: AgentValue, right: AgentValue): Bool {
    if (left.unifiedKind != right.unifiedKind) { return false }
    match (left.unifiedKind) {
        case ValueKind.Null => true
        case ValueKind.Boolean => left.boolean == right.boolean
        case ValueKind.Number => left.number == right.number
        case ValueKind.Text => left.text == right.text
        case ValueKind.List =>
            if (left.items.size != right.items.size) { return false }
            for (index in 0..left.items.size) {
                if (!fixtureAgentValuesEqual(left.items[index], right.items[index])) {
                    return false
                }
            }
            true
        case ValueKind.Object =>
            if (left.fields.size != right.fields.size) { return false }
            for (field in left.fields) {
                match (right.field(field.name)) {
                    case Some(value) => if (!fixtureAgentValuesEqual(field.value, value)) {
                        return false
                    }
                    case None => return false
                }
            }
            true
    }
}

func fixtureAttemptWithBarrier(
    value: DurableModelAttempt,
    barrier: ModelAttemptReplayBarrier
): DurableModelAttempt {
    DurableModelAttempt(
        value.id, value.semanticRequestId, value.runId, value.attemptNo,
        value.lifecycle, value.policy, value.policyReason,
        value.startedAtMillis, value.lastActivityAtMillis,
        parentAttemptId: value.parentAttemptId,
        completedAtMillis: value.completedAtMillis,
        providerRequestId: value.providerRequestId,
        providerResponseId: value.providerResponseId,
        failureKind: value.failureKind,
        semanticRequestDigest: value.semanticRequestDigest,
        wirePolicyDigest: value.wirePolicyDigest,
        dispatchState: value.dispatchState,
        replayBarrier: barrier,
        dispatchStartedAtMillis: value.dispatchStartedAtMillis,
        providerTerminalAtMillis: if (barrier == ModelAttemptReplayBarrier.ProviderTerminal) {
            Some(agentUtcMillis())
        } else { value.providerTerminalAtMillis }
    )
}

func fixtureAttemptAbandoned(
    value: DurableModelAttempt,
    completedAtMillis: Int64
): DurableModelAttempt {
    DurableModelAttempt(
        value.id, value.semanticRequestId, value.runId, value.attemptNo,
        ModelAttemptLifecycle.Abandoned, value.policy, value.policyReason,
        value.startedAtMillis, completedAtMillis,
        parentAttemptId: value.parentAttemptId,
        completedAtMillis: Some(completedAtMillis),
        providerRequestId: value.providerRequestId,
        providerResponseId: value.providerResponseId,
        failureKind: "process_restart_possible_duplicate",
        semanticRequestDigest: value.semanticRequestDigest,
        wirePolicyDigest: value.wirePolicyDigest,
        dispatchState: value.dispatchState,
        replayBarrier: value.replayBarrier,
        dispatchStartedAtMillis: value.dispatchStartedAtMillis,
        providerTerminalAtMillis: value.providerTerminalAtMillis
    )
}

func sameFixtureDecision(
    left: ApprovalDecisionReceipt,
    right: ApprovalDecisionReceipt
): Bool {
    left.operationId.value == right.operationId.value && left.runId.value == right.runId.value &&
        left.sessionId.value == right.sessionId.value && left.callId == right.callId &&
        left.argumentHash == right.argumentHash && left.decision == right.decision
}

class MemoryOperations <: OperationRepository {
    private let lock = Mutex()
    private let records = ArrayList<OperationRecord>()
    private let receipts = ArrayList<OperationReceipt>()

    public func prepare(value: OperationRecord): Result<Unit> {
        lock.lock()
        try {
            for (record in records where record.operationId.value == value.operationId.value) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "operation.exists",
                    "operation already exists"
                ))
            }
            records.add(value)
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func transition(
        operationId: OperationId,
        expected: OperationStatus,
        next: OperationStatus
    ): Result<Unit> {
        lock.lock()
        try {
            for (index in 0..records.size where records[index].operationId.value == operationId.value) {
                let old = records[index]
                if (old.status != expected) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "operation.status_conflict",
                        "operation status changed"
                    ))
                }
                records[index] = OperationRecord(
                    old.operationId,
                    old.runId,
                    next,
                    old.capability,
                    old.requestDigest,
                    call: old.call
                )
                return Result.Ok(())
            }
            Result.Err(missing("operation"))
        } finally {
            lock.unlock()
        }
    }

    public func find(operationId: OperationId): Result<OperationRecord> {
        lock.lock()
        try {
            for (value in records where value.operationId.value == operationId.value) {
                return Result.Ok(value)
            }
            Result.Err(missing("operation"))
        } finally {
            lock.unlock()
        }
    }

    public func receipt(operationId: OperationId): Result<OperationReceipt> {
        lock.lock()
        try {
            for (value in receipts where value.operationId.value == operationId.value) {
                return Result.Ok(value)
            }
            Result.Err(missing("receipt"))
        } finally {
            lock.unlock()
        }
    }

    public func saveReceipt(value: OperationReceipt): Result<Unit> {
        lock.lock()
        try {
            for (index in 0..receipts.size where receipts[index].operationId.value == value.operationId.value) {
                receipts[index] = value
                return Result.Ok(())
            }
            receipts.add(value)
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }
}

class FixtureIds <: IdGenerator {
    var operation: Int64 = 0

    public func nextRunId(): RunId {
        RunId("generated-run")
    }
    public func nextSessionId(): SessionId {
        SessionId("generated-session")
    }
    public func nextOperationId(): OperationId {
        operation += 1
        OperationId("operation-${operation}")
    }
}

class MemoryAudit <: AuditPort {
    public func append(event: AgentEvent): Result<Unit> {
        Result.Ok(())
    }
}

func missing(resource: String): AgentError {
    AgentError(
        AgentErrorKind.InvalidInput,
        "fixture.missing",
        "fixture resource is missing",
        fields: [ErrorField("resource", resource)]
    )
}
