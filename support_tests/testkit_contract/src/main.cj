package testkit_contract

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_testkit.*
import tool_runtime.*

main(): Int64 {
    scriptedModelContract()
    cancellationContract()
    scriptedToolContract()
    memoryPortsContract()
    memoryOutputLimitRecoveryBoundaryContract()
    scriptedPolicyContract()
    deterministicControlContract()
    benchmarkContract()
    println("testkit contract passed")
    0
}

func scriptedPolicyContract(): Unit {
    let policy = ScriptedCapabilityPolicy([
        ScriptedPolicyStep(PermissionRequirement.Confirm, reason: "review fixture"),
        ScriptedPolicyStep(PermissionRequirement.Deny, reason: "deny fixture")
    ])
    let descriptor = ToolDescriptor(
        ModelToolDefinition("policy_fixture", "policy fixture", objectValue([])),
        Capability(CapabilityKind.WorkspaceWrite),
        sideEffecting: true
    )
    let context = ToolInvocationContext(
        RunId("policy-run"),
        SessionId("policy-session"),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceWrite)])
    )
    let plan = normalizedToolOperationPlan(
        context,
        ToolCall("policy-call", "policy_fixture", objectValue([])),
        descriptor
    )
    expect(policy.evaluate(context, plan).requirement == PermissionRequirement.Confirm,
        "scripted policy returns its first production-domain decision")
    expect(policy.evaluate(context, plan).requirement == PermissionRequirement.Deny,
        "scripted policy advances deterministically")
    expect(policy.calls().size == 2 && policy.calls()[0].toolName == "policy_fixture",
        "scripted policy records read-only request projections")
}

func scriptedModelContract(): Unit {
    let reply = ModelReply(
        [ModelBlock(ModelBlockKind.Text, text: "done")],
        stopReason: "end_turn"
    )
    let model = ScriptedModelPort([
        modelFailureStep(
            AgentError(AgentErrorKind.Transport, "fixture.truncated", "truncated SSE"),
            events: [ModelEvent.TextDelta("par"), ModelEvent.TextDelta("par")]
        ),
        modelReplyStep(reply, events: [ModelEvent.TextDelta("done"), ModelEvent.Completed])
    ])
    let recorded = RecordingModelEvents()
    let first = model.execute(request("request-1"), recorded.sink())
    expect(first.isError(), "a scripted partial stream terminates with its configured failure")
    expect(recorded.snapshot().size == 2, "duplicate deltas remain observable")
    expect(model.execute(request("request-2"), recorded.sink()).isOk(), "the next scripted retry succeeds")
    expect(model.requests().size == 2 && model.calls() == 2, "model requests are deterministic and inspectable")
}

func cancellationContract(): Unit {
    let model = ScriptedModelPort([modelCancellationStep(cancellationWaitMillis: 1000)])
    let future = spawn { model.execute(request("cancel-me"), { _ => () }) }
    sleep(Duration.millisecond * 5)
    expect(model.cancel("cancel-me").isOk(), "scripted cancellation is accepted")
    waitForFuture(future, "scripted model cancellation did not settle")
    let result = future.get()
    expect(result.isError() && model.wasCancelled("cancel-me"), "a stalled request exits through cancellation")
}

func scriptedToolContract(): Unit {
    let tool = ScriptedToolExecutor([
        ScriptedToolStep(result: Some(textValue("ok"))),
        ScriptedToolStep(waitForCancellation: true, cancellationWaitMillis: 1000)
    ])
    let context = ToolInvocationContext(
        RunId("run-1"),
        SessionId("session-1"),
        CapabilitySet()
    )
    expect(tool.executeCall(context, ToolCall("call-1", "fixture", objectValue([]))).isOk(),
        "scripted tool returns its configured result")
    let waiting = spawn {
        tool.executeCall(context, ToolCall("call-2", "fixture", objectValue([])))
    }
    sleep(Duration.millisecond * 5)
    let _ = tool.cancel(RunId("run-1"))
    waitForFuture(waiting, "scripted tool cancellation did not settle")
    expect(waiting.get().isError(), "a hanging tool can reproduce cancellation races")
    expect(tool.calls().size == 2, "tool calls are recorded")
}

func memoryPortsContract(): Unit {
    let session = SessionId("memory-session")
    let otherSession = SessionId("memory-session-other")
    let runs = MemoryRunRepository()
    let run = RunId("memory-run")
    expect(runs.save(RunSnapshot(run, session, RunState.Running)).isOk(),
        "memory run repository stores a snapshot")
    expect(runs.append(AgentEvent(
        EventMeta(1, TraceId("testkit-contract"), run),
        AgentEventPayload.RunStarted
    )).isOk(),
        "memory run repository appends events")
    expect(runs.events(run, 0).value().getOrThrow().events.size == 1,
        "memory run repository pages recorded events")
    expect(runs.append(AgentEvent(
        EventMeta(1, TraceId("testkit-contract"), run),
        AgentEventPayload.Audit("duplicate", objectValue([]))
    )).isError(),
        "memory run events reject duplicate sequence numbers")

    let approvalRun = RunId("approval-run")
    let approvalOperation = OperationId("approval-operation")
    expect(runs.save(RunSnapshot(approvalRun, session, RunState.WaitingApproval)).isOk(),
        "memory run repository stores an approval snapshot")
    let pending = continuation(
        approvalRun,
        session,
        approvalOperation,
        "approval-call",
        "approval-hash"
    )
    expect(runs.saveContinuation(pending).isOk() && runs.saveContinuation(pending).isOk(),
        "an identical continuation can be replayed idempotently")
    expect(runs.saveContinuation(continuation(
        approvalRun,
        session,
        approvalOperation,
        "approval-call",
        "different-hash"
    )).isError(), "a continuation binding cannot be overwritten")
    let decision = ApprovalDecisionReceipt(
        approvalOperation,
        approvalRun,
        session,
        "approval-call",
        "approval-hash",
        ApprovalDecision.Approve
    )
    expect(runs.recordDecision(decision).isOk() && runs.recordDecision(decision).isOk(),
        "the same approval decision can be replayed atomically")
    expect(runs.saveContinuation(RunContinuation(
        approvalRun,
        session,
        "drifted-model",
        "fixture prompt",
        ApprovalRequest(
            OperationId("next-approval-operation"),
            "next-approval-call",
            "fixture-tool",
            Capability(CapabilityKind.WorkspaceRead),
            sessionId: session.value,
            argumentHash: "next-approval-hash"
        )
    )).isError(), "an approval receipt cannot authorize request drift")
    expect(runs.recordDecision(ApprovalDecisionReceipt(
        approvalOperation,
        approvalRun,
        session,
        "approval-call",
        "approval-hash",
        ApprovalDecision.Reject
    )).isError(), "an approval decision cannot be changed")

    let missingRun = RunId("missing-continuation-run")
    expect(runs.save(RunSnapshot(missingRun, otherSession, RunState.WaitingApproval)).isOk() &&
        errorKind(runs.pendingContinuation(otherSession)) == Some(AgentErrorKind.RecoveryRequired),
        "an awaiting-approval snapshot without continuation requires recovery")
    let duplicateRun = RunId("duplicate-pending-run")
    expect(runs.save(RunSnapshot(duplicateRun, session, RunState.WaitingApproval)).isOk() &&
        errorKind(runs.pendingContinuation(session)) == Some(AgentErrorKind.RecoveryRequired),
        "multiple pending approval runs are rejected as ambiguous")

    let operations = InMemoryOperationRuntimePort()
    let operation = OperationId("memory-operation")
    let plan = NormalizedOperationPlan(
        "read",
        objectValue([]),
        [Capability(CapabilityKind.WorkspaceRead)],
        OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Never,
        "digest"
    )
    let item = ItemId("memory-tool-call")
    expect(operations.prepareTrustedControlOperation(
        operation, run, item, plan
    ).isOk(), "memory operation runtime prepares canonical work")
    expect(operations.loadPlan(operation, run).isOk(),
        "memory operation runtime retains normalized plans")
    expect(operations.prepareTrustedControlOperation(
        operation, run, item, plan
    ).isOk(), "identical canonical preparation is idempotent")
    expect(operations.prepareTrustedControlOperation(
        operation, run, ItemId("other-tool-call"), plan
    ).isError(), "canonical ToolCall Item binding cannot drift")

    let audit = RecordingAuditPort()
    expect(audit.append(AgentEvent(
        EventMeta(2, TraceId("testkit-contract"), run),
        AgentEventPayload.Audit("recording", objectValue([]))
    )).isOk() && audit.events().size == 1,
        "recording audit exposes captured events")
}

func memoryOutputLimitRecoveryBoundaryContract(): Unit {
    memoryOutputLimitRecoveryCase("exact", true)
    memoryOutputLimitRecoveryCase("messages", false)
    memoryOutputLimitRecoveryCase("capabilities", false)
    memoryOutputLimitRecoveryCase("policy_scalar", false)
    memoryOutputLimitRecoveryCase("wire_only", false)
    memoryOutputLimitRecoveryCase("images", false)
    memoryOutputLimitRecoveryCase("execution_lane", false)
}

func memoryOutputLimitRecoveryCase(mutation: String, shouldAccept: Bool): Unit {
    let runId = RunId("memory-recovery-" + mutation)
    let sessionId = SessionId("memory-recovery-session")
    let semanticId = SemanticModelRequestId("memory-recovery-semantic")
    let parentId = ModelAttemptId("memory-recovery-a1")
    let childId = ModelAttemptId("memory-recovery-a2")
    let stableRequestId = "memory-recovery-request"
    let model = "fixture-model"
    let requested = RequestedModelPolicy(
        ThinkingLevel.Medium,
        RequestOutputBudget(4096, minVisibleResponseTokens: 128),
        userRequestedThinking: Some(ThinkingLevel.Medium),
        thinkingSource: ThinkingPreferenceSource.ExplicitUser
    )
    let capabilities = memoryRecoveryCapabilities(8192)
    let parentResolved = memoryResolvePolicy(AttemptPolicyInput(requested, capabilities))
    let parentCanonical = memoryRecoveryRequest(
        model, ThinkingLevel.Medium, parentResolved, "frozen message"
    )
    let parentDigest = modelPolicySha256Text(canonicalAgentValue(parentCanonical))
    let parentPolicyCanonical = canonicalResolvedModelRequestPolicy(parentResolved)
    let parentWireDigest = modelAttemptWirePolicyDigest(
        model, parentResolved.output.effectiveWireLimit, ModelToolChoice.Auto, 0,
        parentPolicyCanonical
    )
    let parentPolicy = AttemptPolicy(
        model,
        ThinkingLevel.Medium,
        ModelToolChoice.Auto,
        parentResolved.output.effectiveWireLimit,
        streamIdleMillis: 30000,
        resolvedPolicy: Some(parentResolved)
    )
    let parentCheckpoint = RunningModelCheckpoint(
        semanticId,
        parentCanonical,
        parentDigest,
        parentWireDigest,
        parentId,
        parentId,
        "memory-recovery-turn",
        stableRequestId,
        100,
        modelRequests: 1
    )
    let parentContinuation = memoryRecoveryContinuation(
        runId, sessionId, model, parentCheckpoint, requested, capabilities
    )
    let parent = DurableModelAttempt(
        parentId,
        semanticId,
        runId,
        1,
        ModelAttemptLifecycle.Created,
        attemptPolicyValue(parentPolicy),
        "initial",
        100,
        100,
        providerRequestId: stableRequestId,
        semanticRequestDigest: parentDigest,
        wirePolicyDigest: parentWireDigest
    )
    let parentEvent = memoryRecoveryEvent(runId, 1)
    let runs = MemoryRunRepository()
    expect(runs.save(RunSnapshot(runId, sessionId, RunState.Running)).isOk(),
        "recovery memory fixture stores its run")
    expect(runs.prepareModelAttempt(parent, parentEvent, parentContinuation).isOk(),
        "initial frozen model boundary is prepared")
    let claimed = runs.claimModelAttemptDispatch(
        parentId, memoryRecoveryEvent(runId, 2)
    )
    expect(match (claimed) {
        case Result.Ok(value) => value
        case Result.Err(_) => false
    }, "recovery parent is recorded as dispatched")

    let childCeiling = match (nextLowerThinkingCeiling(
        capabilities, parentResolved.thinking.effective
    )) {
        case Some(value) => value
        case None => throw IllegalStateException("fixture has no lower thinking ceiling")
    }
    let childResolved = memoryResolvePolicy(AttemptPolicyInput(
        requested, capabilities, recoveryCeiling: Some(childCeiling)
    ))
    let childThinking = childResolved.thinking.effective
    let wireOnly = mutation == "wire_only"
    let childMessage = if (mutation == "messages") {
        "mutated message"
    } else {
        "frozen message"
    }
    let recoveryCanonical = memoryRecoveryRequest(
        model, childThinking, childResolved, childMessage
    )
    let childCanonical = if (wireOnly) { parentCanonical } else { recoveryCanonical }
    let childDigest = if (wireOnly) {
        parentDigest
    } else {
        modelPolicySha256Text(canonicalAgentValue(childCanonical))
    }
    let childPolicyCanonical = if (wireOnly) {
        parentPolicyCanonical
    } else {
        canonicalResolvedModelRequestPolicy(childResolved)
    }
    let childWireDigest = if (wireOnly) {
        modelAttemptWirePolicyDigest(
            model, parentResolved.output.effectiveWireLimit, ModelToolChoice.Auto, 1,
            parentPolicyCanonical
        )
    } else {
        modelAttemptWirePolicyDigest(
            model, childResolved.output.effectiveWireLimit, ModelToolChoice.Auto, 0,
            childPolicyCanonical
        )
    }
    let childStreamIdleMillis = if (mutation == "policy_scalar") { 30001 } else { 30000 }
    let childPolicy = if (wireOnly) {
        AttemptPolicy(
            model,
            ThinkingLevel.Medium,
            ModelToolChoice.Auto,
            parentResolved.output.effectiveWireLimit,
            reason: AttemptPolicyReason.Retry,
            streamIdleMillis: childStreamIdleMillis,
            resolvedPolicy: Some(parentResolved)
        )
    } else {
        AttemptPolicy(
            model,
            childThinking,
            ModelToolChoice.Auto,
            childResolved.output.effectiveWireLimit,
            reason: AttemptPolicyReason.OutputLimitRecovery,
            streamIdleMillis: childStreamIdleMillis,
            resolvedPolicy: Some(childResolved)
        )
    }
    let childPolicyReason = if (wireOnly) { "retry" } else { "output_limit_recovery" }
    let childCheckpoint = RunningModelCheckpoint(
        semanticId,
        childCanonical,
        childDigest,
        childWireDigest,
        parentId,
        childId,
        "memory-recovery-turn",
        stableRequestId + "-retry-1",
        100,
        modelRequests: 2,
        inputTokens: 100
    )
    let nextCapabilities = if (mutation == "capabilities") {
        memoryRecoveryCapabilities(16384)
    } else {
        capabilities
    }
    let childImageInputs = if (mutation == "images") {
        [ModelImage(ModelImageSourceKind.Url, "https://example.test/image")]
    } else {
        Array<ModelImage>()
    }
    let childExecutionLane = if (mutation == "execution_lane") {
        LaneId("memory-recovery-other-lane")
    } else {
        LaneId("main")
    }
    let childContinuation = memoryRecoveryContinuation(
        runId,
        sessionId,
        model,
        childCheckpoint,
        requested,
        nextCapabilities,
        imageInputs: childImageInputs,
        executionLaneId: childExecutionLane
    )
    let child = DurableModelAttempt(
        childId,
        semanticId,
        runId,
        2,
        ModelAttemptLifecycle.Created,
        attemptPolicyValue(childPolicy),
        childPolicyReason,
        101,
        101,
        parentAttemptId: Some(parentId),
        providerRequestId: stableRequestId + "-retry-1",
        semanticRequestDigest: childDigest,
        wirePolicyDigest: childWireDigest
    )
    let childEvent = memoryRecoveryEvent(runId, 3)
    let beforeContinuation = memoryRecoveryReadContinuation(runs, runId)
    let beforeCheckpoint = memoryRecoveryReadCheckpoint(beforeContinuation)
    let beforeEventCount = memoryRecoveryEventCount(runs, runId)
    let result = runs.prepareModelAttempt(child, childEvent, childContinuation)
    if (shouldAccept) {
        expect(result.isOk(), "exact frozen output-limit child is accepted by the public memory port")
        let storedChild = match (runs.modelAttempt(childId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => throw IllegalStateException("accepted child Attempt is missing")
        }
        let afterCheckpoint = memoryRecoveryReadCheckpoint(
            memoryRecoveryReadContinuation(runs, runId)
        )
        let storedParent = match (runs.modelAttempt(parentId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => throw IllegalStateException("recovery parent Attempt is missing")
        }
        expect(storedChild.id.value == childId.value &&
            afterCheckpoint.activeAttemptId.value == childId.value &&
            afterCheckpoint.semanticRequestId.value == semanticId.value &&
            afterCheckpoint.semanticRequestDigest != beforeCheckpoint.semanticRequestDigest &&
            memoryRecoveryEventCount(runs, runId) == beforeEventCount + 1 &&
            storedParent.lifecycle == ModelAttemptLifecycle.Created &&
            storedParent.dispatchState == ModelAttemptDispatchState.DispatchClaimed,
            "memory accepts the proven child without synthesizing parent lifecycle state")
    } else {
        let afterContinuation = memoryRecoveryReadContinuation(runs, runId)
        let afterCheckpoint = memoryRecoveryReadCheckpoint(afterContinuation)
        let afterEventCount = memoryRecoveryEventCount(runs, runId)
        let storedParent = match (runs.modelAttempt(parentId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => throw IllegalStateException("rejected child lost its parent Attempt")
        }
        expect(result.isError() &&
            afterContinuation.model == beforeContinuation.model &&
            afterContinuation.prompt == beforeContinuation.prompt &&
            memoryRecoveryCapabilitiesMatch(afterContinuation, beforeContinuation) &&
            memoryRecoveryCheckpointMatches(beforeCheckpoint, afterCheckpoint) &&
            afterEventCount == beforeEventCount &&
            errorKind(runs.modelAttempt(childId)) == Some(AgentErrorKind.RecoveryRequired) &&
            storedParent.lifecycle == ModelAttemptLifecycle.Created &&
            storedParent.dispatchState == ModelAttemptDispatchState.DispatchClaimed &&
            runs.prepareModelAttempt(parent, parentEvent, parentContinuation).isOk(),
            "rejected " + mutation +
                " drift leaves the stored continuation, events, and attempts unchanged")
    }
}

func memoryRecoveryCapabilities(maxOutputTokens: Int64): ModelExecutionCapabilitiesSnapshot {
    ModelExecutionCapabilitiesSnapshot(
        "fixture-model",
        ThinkingCapabilities(
            ThinkingControlMode.Effort,
            supportedLevels: [
                ThinkingLevel.Low,
                ThinkingLevel.Medium,
                ThinkingLevel.High
            ]
        ),
        maxOutputTokens
    )
}

func memoryResolvePolicy(input: AttemptPolicyInput): ResolvedModelRequestPolicy {
    match (resolveModelAttemptPolicy(input)) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.message)
    }
}

func memoryRecoveryRequest(
    model: String,
    thinking: ThinkingLevel,
    policy: ResolvedModelRequestPolicy,
    message: String
): AgentValue {
    objectValue([
        ValueField("model", textValue(model)),
        ValueField("system", textValue("")),
        ValueField("messages", listValue([
            objectValue([
                ValueField("role", textValue("user")),
                ValueField("blocks", listValue([
                    objectValue([
                        ValueField("kind", textValue("text")),
                        ValueField("text", textValue(message)),
                        ValueField("call_id", textValue("")),
                        ValueField("name", textValue("")),
                        ValueField("arguments", objectValue([])),
                        ValueField("is_error", boolValue(false)),
                        ValueField("receipt_id", textValue("")),
                        ValueField("image", nullValue()),
                        ValueField("opaque_state", nullValue())
                    ])
                ]))
            ])
        ])),
        ValueField("tools", listValue([])),
        ValueField("thinking", textValue(memoryRecoveryThinkingName(thinking))),
        ValueField("wire_max_output_tokens", integerValue(policy.output.effectiveWireLimit)),
        ValueField("streaming", boolValue(true)),
        ValueField("parallel_tool_calls", boolValue(false)),
        ValueField("service_tier", textValue("")),
        ValueField("cache_policy", textValue("default")),
        ValueField("cache_key", textValue("")),
        ValueField("tool_choice", textValue("auto")),
        ValueField("structured_output", nullValue()),
        ValueField("resolved_policy", resolvedModelPolicyCheckpointValue(policy))
    ])
}

func memoryRecoveryThinkingName(value: ThinkingLevel): String {
    match (value) {
        case ThinkingLevel.Off => "off"
        case ThinkingLevel.Minimal => "minimal"
        case ThinkingLevel.Low => "low"
        case ThinkingLevel.Medium => "medium"
        case ThinkingLevel.High => "high"
        case ThinkingLevel.XHigh => "xhigh"
        case ThinkingLevel.Max => "max"
    }
}

func memoryRecoveryContinuation(
    runId: RunId,
    sessionId: SessionId,
    model: String,
    checkpoint: RunningModelCheckpoint,
    requested: RequestedModelPolicy,
    capabilities: ModelExecutionCapabilitiesSnapshot,
    imageInputs!: Array<ModelImage> = [],
    executionLaneId!: LaneId = LaneId("main")
): RunContinuation {
    RunContinuation(
        RunContinuationKind.RunningModel,
        runId,
        sessionId,
        model,
        "frozen prompt",
        checkpoint,
        requested,
        capabilities,
        thinking: ThinkingLevel.Medium,
        imageInputs: imageInputs,
        executionLaneId: executionLaneId
    )
}

func memoryRecoveryEvent(runId: RunId, sequence: Int64): AgentEvent {
    AgentEvent(
        EventMeta(sequence, TraceId("testkit-memory-recovery"), runId),
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([]))
    )
}

func memoryRecoveryReadContinuation(
    runs: MemoryRunRepository,
    runId: RunId
): RunContinuation {
    match (runs.continuation(runId)) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.message)
    }
}

func memoryRecoveryReadCheckpoint(value: RunContinuation): RunningModelCheckpoint {
    match (value.runningModel) {
        case Some(checkpoint) => checkpoint
        case None => throw IllegalStateException("memory recovery continuation has no checkpoint")
    }
}

func memoryRecoveryCapabilitiesMatch(
    left: RunContinuation,
    right: RunContinuation
): Bool {
    match ((left.modelCapabilitiesSnapshot, right.modelCapabilitiesSnapshot)) {
        case (Some(a), Some(b)) =>
            a.snapshotSchemaVersion == b.snapshotSchemaVersion &&
                a.modelId == b.modelId &&
                a.capabilityFingerprint == b.capabilityFingerprint
        case _ => false
    }
}

func memoryRecoveryEventCount(runs: MemoryRunRepository, runId: RunId): Int64 {
    match (runs.events(runId, 0)) {
        case Result.Ok(page) => page.events.size
        case Result.Err(error) => throw IllegalStateException(error.message)
    }
}

func memoryRecoveryCheckpointMatches(
    left: RunningModelCheckpoint,
    right: RunningModelCheckpoint
): Bool {
    let costsMatch = match ((left.costMicros, right.costMicros)) {
        case (None, None) => true
        case (Some(a), Some(b)) => a == b
        case _ => false
    }
    left.semanticRequestId.value == right.semanticRequestId.value &&
        canonicalAgentValue(left.canonicalRequest) == canonicalAgentValue(right.canonicalRequest) &&
        left.semanticRequestDigest == right.semanticRequestDigest &&
        left.wirePolicyDigest == right.wirePolicyDigest &&
        left.originalAttemptId.value == right.originalAttemptId.value &&
        left.activeAttemptId.value == right.activeAttemptId.value &&
        left.stableTurnId == right.stableTurnId &&
        left.stableRequestId == right.stableRequestId &&
        left.requestStartedAtMillis == right.requestStartedAtMillis &&
        left.modelRequests == right.modelRequests &&
        left.workModelRequests == right.workModelRequests &&
        left.drainModelRequests == right.drainModelRequests &&
        left.requestBudgetClass == right.requestBudgetClass &&
        left.inputTokens == right.inputTokens &&
        left.outputTokens == right.outputTokens &&
        left.reasoningTokens == right.reasoningTokens &&
        left.cacheReadTokens == right.cacheReadTokens &&
        left.cacheWriteTokens == right.cacheWriteTokens &&
        costsMatch &&
        left.lastInputTokens == right.lastInputTokens &&
        left.lastOutputTokens == right.lastOutputTokens &&
        left.lastRequestDurationMillis == right.lastRequestDurationMillis &&
        left.toolCalls == right.toolCalls &&
        left.turns == right.turns &&
        left.consecutiveCapabilityDenials == right.consecutiveCapabilityDenials &&
        left.lastCapabilityDeniedTool == right.lastCapabilityDeniedTool
}

func continuation(
    runId: RunId,
    sessionId: SessionId,
    operationId: OperationId,
    callId: String,
    argumentHash: String
): RunContinuation {
    RunContinuation(
        runId,
        sessionId,
        "fixture-model",
        "fixture prompt",
        ApprovalRequest(
            operationId,
            callId,
            "fixture-tool",
            Capability(CapabilityKind.WorkspaceRead),
            sessionId: sessionId.value,
            argumentHash: argumentHash
        )
    )
}

func deterministicControlContract(): Unit {
    let ids = DeterministicIds(prefix: "contract")
    expect(ids.nextRunId().value == "contract-run-1", "run IDs are deterministic")
    expect(ids.nextSessionId().value == "contract-session-1", "session IDs are deterministic")
    expect(ids.nextOperationId().value == "contract-operation-1", "operation IDs are deterministic")
    let clock = ManualClock(initialMillis: 10)
    expect(clock.advance(5) == 15 && clock.monotonicMillis() == 15, "manual time advances explicitly")
}

func benchmarkContract(): Unit {
    let series = AgentBenchmarkSeries("contract", warmupRuns: 2)
    for (value in [50, 10, 40, 20, 30]) {
        series.add(AgentBenchmarkSample(
            ttftMillis: Some(value),
            generationMillis: Some(100),
            outputTokens: Some(value),
            rssBytes: None
        ))
    }
    let summary = series.summary()
    expect(summary.totalSamples == 5 && summary.warmups == 2 && summary.samples == 3,
        "benchmark summary excludes the configured warmup observations")
    expect(summary.ttftMillis.minimum == Some(20), "measured benchmark values are sorted for minimum")
    expect(summary.ttftMillis.p50 == Some(30), "benchmark exposes p50")
    expect(summary.ttftMillis.p95 == Some(40) && summary.ttftMillis.p99 == Some(40),
        "benchmark exposes nearest-rank p95 and p99")
    expect(summary.tokensPerSecondMilli.count == 3, "throughput is derived without floating-point drift")
    expect(summary.rssBytes.count == 0 && summary.rssBytes.p50.isNone(),
        "unavailable memory remains unavailable")
}

func request(id: String): ModelRequest {
    ModelRequest("fixture", [], requestId: id, streaming: true)
}

func errorKind<T>(value: Result<T>): ?AgentErrorKind {
    match (value) {
        case Result.Ok(_) => None
        case Result.Err(error) => Some(error.kind)
    }
}

func waitForFuture<T>(future: Future<T>, message: String): Unit {
    var waited: Int64 = 0
    while (future.tryGet().isNone() && waited < 2000) {
        sleep(Duration.millisecond)
        waited += 1
    }
    if (future.tryGet().isNone()) { throw IllegalStateException(message) }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException("contract failed: " + message) }
}
