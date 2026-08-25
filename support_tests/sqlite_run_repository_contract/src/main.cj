package sqlite_run_repository_contract

import agent_domain.*
import agent_store.*
import persistence_runtime.*
import std.fs.*

main(): Int64 {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    let database = SqliteDatabase(root + "/state.db")
    try {
        seedCanonicalRun(database)
        let repository = SqliteRunRepository(database, eventCapacity: 2)
        let runId = RunId("run-1")
        let sessionId = SessionId("thread-1")
        expect(repository.save(RunSnapshot(
            runId,
            sessionId,
            RunState.Running,
            summary: "running"
        )).isOk(), "canonical Run accepts its product snapshot")
        expect(repository.find(runId).value().getOrThrow().summary == "running",
            "product Run snapshot round-trips through SQLite")
        for (sequence in 1..4) {
            expect(repository.append(AgentEvent(
                EventMeta(sequence, TraceId("sqlite-run-contract"), runId),
                AgentEventPayload.Audit("sqlite-run-contract", objectValue([]))
            )).isOk(), "Run event appends monotonically")
        }
        let page = repository.events(runId, 0).value().getOrThrow()
        expect(page.events.size == 3 && !page.resyncRequired && page.nextSequence == 4,
            "low-frequency lifecycle events do not compete for telemetry retention")
        expect(repository.append(AgentEvent(
            EventMeta(5, TraceId("sqlite-run-contract"), runId),
            AgentEventPayload.Audit("sqlite-run-contract", objectValue([]))
        )).isError(), "SQLite Run journal rejects sequence gaps")
        attemptPolicyAtomicityContract(database, repository, runId)
        retryAttemptAtomicityContract(database)
        restartAttemptAtomicityContract(database)
        continuationCasIdempotencyContract(database)
        telemetryRetentionContract(database, repository, runId)
        expect(repository.save(RunSnapshot(
            RunId("ownerless"),
            sessionId,
            RunState.Running
        )).isError(), "repository cannot create an ownerless Run")
        metadataContract(database, root)
        println("SQLite Run repository contract passed")
        0
    } finally {
        database.close()
        let _ = removeIfExists(root, recursive: true)
    }
}

func retryAttemptAtomicityContract(database: SqliteDatabase): Unit {
    seedRetryRun(database)
    let repository = SqliteRunRepository(database)
    let decisions = SqliteModelDecisionStore(database)
    let runId = RunId("retry-run")
    let sessionId = SessionId("retry-thread")
    expect(repository.save(RunSnapshot(
        runId, sessionId, RunState.Running, summary: "retry"
    )).isOk(), "retry fixture stores its Run snapshot")
    let semanticId = SemanticModelRequestId("retry-semantic")
    let parentId = ModelAttemptId("retry-attempt-1")
    let childId = ModelAttemptId("retry-attempt-2")
    let canonical = objectValue([ValueField("model", textValue("fixture"))])
    let requested = RequestedModelPolicy(
        ThinkingLevel.High,
        RequestOutputBudget(4096, minVisibleResponseTokens: 1024)
    )
    let capabilities = ModelExecutionCapabilitiesSnapshot(
        "fixture",
        ThinkingCapabilities(
            ThinkingControlMode.Effort,
            supportedLevels: canonicalNonOffThinkingLevels()
        ),
        4096
    )
    let parentCheckpoint = RunningModelCheckpoint(
        semanticId, canonical, "retry-semantic-digest", "retry-wire-digest",
        parentId, parentId, "retry-turn", "retry-request-1", 0
    )
    let parentContinuation = RunContinuation(
        RunContinuationKind.RunningModel, runId, sessionId, "fixture", "retry",
        parentCheckpoint, requested, capabilities
    )
    let parent = DurableModelAttempt(
        parentId, semanticId, runId, 1, ModelAttemptLifecycle.Created,
        objectValue([]), "initial", 0, 0,
        providerRequestId: "retry-request-1",
        semanticRequestDigest: "retry-semantic-digest",
        wirePolicyDigest: "retry-wire-digest"
    )
    expect(repository.prepareModelAttempt(
        parent,
        scopedEvent(1, runId, semanticId, parentId,
            AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([]))),
        parentContinuation
    ).isOk(), "initial Attempt and continuation commit atomically")
    expect(decisions.terminalizeAttempt(
        parentId, ModelAttemptLifecycle.Abandoned, "model.rate_limited", 1
    ).isOk(), "retry parent is durably abandoned")
    let childCheckpoint = RunningModelCheckpoint(
        semanticId, canonical, "retry-semantic-digest", "retry-wire-digest",
        parentId, childId, "retry-turn", "retry-request-2", 0
    )
    let childContinuation = RunContinuation(
        RunContinuationKind.RunningModel, runId, sessionId, "fixture", "retry",
        childCheckpoint, requested, capabilities
    )
    let child = DurableModelAttempt(
        childId, semanticId, runId, 2, ModelAttemptLifecycle.Created,
        objectValue([]), "retry", 1, 1,
        parentAttemptId: Some(parentId),
        providerRequestId: "retry-request-2",
        semanticRequestDigest: "retry-semantic-digest",
        wirePolicyDigest: "retry-wire-digest"
    )
    expect(repository.prepareModelAttempt(
        child,
        scopedEvent(2, runId, semanticId, childId,
            AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([]))),
        childContinuation
    ).isOk() &&
        repository.modelAttempt(childId).value().getOrThrow().attemptNo == 2 &&
        repository.continuation(runId).value().getOrThrow()
            .runningModel.getOrThrow().activeAttemptId.value == childId.value,
        "a durably abandoned parent authorizes exactly one same-request retry transition")
}

func continuationCasIdempotencyContract(database: SqliteDatabase): Unit {
    seedMigrationRun(database)
    let repository = SqliteRunRepository(database)
    let runId = RunId("migration-run")
    let sessionId = SessionId("migration-thread")
    expect(repository.save(RunSnapshot(
        runId, sessionId, RunState.WaitingApproval, summary: "legacy migration"
    )).isOk(), "migration fixture stores its waiting Run snapshot")
    let approval = ApprovalRequest(
        OperationId("migration-operation"), "migration-call", "write",
        Capability(CapabilityKind.WorkspaceWrite),
        sessionId: sessionId.value, argumentHash: "migration-arguments"
    )
    let requested = RequestedModelPolicy(
        ThinkingLevel.High,
        RequestOutputBudget(8192, minVisibleResponseTokens: 1024)
    )
    let capabilities = ModelExecutionCapabilitiesSnapshot(
        "fixture",
        ThinkingCapabilities(
            ThinkingControlMode.Effort,
            supportedLevels: canonicalNonOffThinkingLevels()
        ),
        8192
    )
    let initial = RunContinuation(
        runId, sessionId, "fixture", "resume current continuation", approval,
        thinking: ThinkingLevel.High,
        budget: ResourceBudget(maxOutputTokens: 8192),
        requestedPolicy: requested,
        modelCapabilitiesSnapshot: capabilities,
        cacheKey: "initial",
        executionLaneId: LaneId("review")
    )
    expect(repository.saveContinuation(initial).isOk(),
        "current continuation is installed as the CAS source")
    let updated = RunContinuation(
        runId, sessionId, "fixture", "resume current continuation", approval,
        thinking: ThinkingLevel.High,
        budget: ResourceBudget(maxOutputTokens: 8192),
        requestedPolicy: requested,
        modelCapabilitiesSnapshot: capabilities,
        cacheKey: "updated",
        executionLaneId: LaneId("review")
    )
    let winner = repository.compareAndSwapContinuation(Some(initial), updated)
    let concurrentEquivalent = repository.compareAndSwapContinuation(Some(initial), updated)
    expect(winner.isOk() && concurrentEquivalent.isOk() &&
        concurrentEquivalent.value().getOrThrow().cacheKey == "updated" &&
        repository.continuation(runId).value().getOrThrow().executionLaneId.value == "review",
        "equivalent continuation CAS preserves its non-main execution Lane")
    let drifted = RunContinuation(
        runId, sessionId, "fixture", "resume current continuation", approval,
        thinking: ThinkingLevel.High,
        budget: ResourceBudget(maxOutputTokens: 8192),
        requestedPolicy: requested,
        modelCapabilitiesSnapshot: capabilities,
        cacheKey: "drifted",
        executionLaneId: LaneId("review")
    )
    expect(repository.compareAndSwapContinuation(Some(initial), drifted).isError(),
        "non-equivalent concurrent continuation remains a CAS conflict")

    let semanticId = SemanticModelRequestId("migration-semantic")
    let attemptId = ModelAttemptId("migration-attempt")
    let checkpoint = RunningModelCheckpoint(
        semanticId,
        objectValue([ValueField("model", textValue("fixture"))]),
        "migration-semantic-digest", "migration-wire-digest",
        attemptId, attemptId, "migration-turn", "migration-request", 0
    )
    let running = RunContinuation(
        RunContinuationKind.RunningModel,
        runId, sessionId, "fixture", "resume current continuation",
        checkpoint, requested, capabilities,
        thinking: ThinkingLevel.High,
        budget: ResourceBudget(maxOutputTokens: 8192),
        cacheKey: "updated",
        executionLaneId: LaneId("review")
    )
    let attempt = DurableModelAttempt(
        attemptId, semanticId, runId, 1, ModelAttemptLifecycle.Created,
        objectValue([]), "initial", 0, 0,
        providerRequestId: "migration-request",
        semanticRequestDigest: "migration-semantic-digest",
        wirePolicyDigest: "migration-wire-digest"
    )
    expect(repository.prepareModelAttempt(
        attempt,
        scopedEvent(1, runId, semanticId, attemptId,
            AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([]))),
        running
    ).isOk() && database.query(
        "SELECT active_attempt_id FROM run_continuations WHERE run_id='migration-run'"
    )[0].required(0) == attemptId.value,
        "approved continuation indexes its exact active model Attempt")
    expect(repository.clearModelExecutionContinuation(runId, attemptId).isOk() &&
        database.scalarInt(
            "SELECT COUNT(*) FROM run_continuations WHERE run_id='migration-run'"
        ) == 0,
        "completed model Attempt atomically clears the structured continuation")
}

func restartAttemptAtomicityContract(database: SqliteDatabase): Unit {
    seedRestartRun(database)
    let repository = SqliteRunRepository(database)
    let runId = RunId("restart-run")
    let sessionId = SessionId("restart-thread")
    expect(repository.save(RunSnapshot(
        runId, sessionId, RunState.Running, summary: "restart"
    )).isOk(), "restart fixture stores its Run snapshot")
    let semanticId = SemanticModelRequestId("restart-semantic")
    let parentId = ModelAttemptId("restart-attempt-1")
    let canonical = objectValue([ValueField("model", textValue("fixture"))])
    let checkpoint1 = RunningModelCheckpoint(
        semanticId, canonical, "restart-semantic-digest", "restart-wire-digest",
        parentId, parentId, "restart-turn", "restart-request", 0
    )
    let requested = RequestedModelPolicy(
        ThinkingLevel.Medium,
        RequestOutputBudget(4096, minVisibleResponseTokens: 1024)
    )
    let capabilities = ModelExecutionCapabilitiesSnapshot(
        "fixture",
        ThinkingCapabilities(
            ThinkingControlMode.Effort,
            supportedLevels: canonicalNonOffThinkingLevels()
        ),
        4096
    )
    let continuation1 = RunContinuation(
        RunContinuationKind.RunningModel, runId, sessionId, "fixture", "resume",
        checkpoint1, requested, capabilities
    )
    let parent = DurableModelAttempt(
        parentId, semanticId, runId, 1, ModelAttemptLifecycle.Created,
        objectValue([]), "initial", 0, 0,
        providerRequestId: "restart-request",
        semanticRequestDigest: "restart-semantic-digest",
        wirePolicyDigest: "restart-wire-digest"
    )
    let preparedParent = repository.prepareModelAttempt(
        parent,
        scopedEvent(1, runId, semanticId, parentId,
            AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
                ValueField("code", textValue("model.attempt_policy_applied"))
            ]))),
        continuation1
    )
    match (preparedParent) {
        case Result.Ok(_) => ()
        case Result.Err(error) => throw IllegalStateException(
            "restart parent prepare failed: " + error.code + ": " + error.message
        )
    }
    let claimedDispatch = repository.claimModelAttemptDispatch(
        parentId,
        scopedEvent(2, runId, semanticId, parentId,
            AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
                ValueField("code", textValue("model.attempt_dispatch_claimed"))
            ])))
    )
    match (claimedDispatch) {
        case Result.Ok(true) => ()
        case Result.Ok(false) => throw IllegalStateException("restart parent was already claimed")
        case Result.Err(error) => throw IllegalStateException(
            "restart parent claim failed: " + error.code + ": " + error.message
        )
    }
    let claimedParent = match (repository.modelAttempt(parentId)) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(
            "restart parent read failed: " + error.code + ": " + error.message
        )
    }
    let childId = ModelAttemptId("restart-attempt-2")
    let checkpoint2 = RunningModelCheckpoint(
        semanticId, canonical, "restart-semantic-digest", "restart-wire-digest",
        parentId, childId, "restart-turn", "restart-request-retry-1", 0
    )
    let continuation2 = RunContinuation(
        RunContinuationKind.RunningModel, runId, sessionId, "fixture", "resume",
        checkpoint2, requested, capabilities
    )
    let child = DurableModelAttempt(
        childId, semanticId, runId, 2, ModelAttemptLifecycle.Created,
        objectValue([]), "retry", 0, 0,
        parentAttemptId: Some(parentId),
        providerRequestId: "restart-request-retry-1",
        semanticRequestDigest: "restart-semantic-digest",
        wirePolicyDigest: "restart-wire-digest"
    )
    let policyEvent = scopedEvent(
        3, runId, semanticId, childId,
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
            ValueField("code", textValue("model.attempt_policy_applied"))
        ]))
    )
    let duplicateEvent = scopedEvent(
        4, runId, semanticId, childId,
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
            ValueField("code", textValue("model.restart_retry_possible_duplicate"))
        ]))
    )
    let invalidDuplicate = scopedEvent(
        5, runId, semanticId, childId,
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
            ValueField("code", textValue("model.restart_retry_possible_duplicate"))
        ]))
    )
    let tamperedIdentityChild = DurableModelAttempt(
        childId, SemanticModelRequestId("restart-semantic-tampered"), runId, 2,
        ModelAttemptLifecycle.Created, objectValue([]), "retry", 0, 0,
        parentAttemptId: Some(parentId),
        providerRequestId: "restart-request-retry-1",
        semanticRequestDigest: "restart-semantic-digest-tampered",
        wirePolicyDigest: "restart-wire-digest"
    )
    expect(repository.prepareRestartModelAttempt(
        claimedParent, tamperedIdentityChild, policyEvent, duplicateEvent, continuation2
    ).isError() && restartBoundaryIsUnchanged(repository, runId, parentId, childId),
        "restart rejects child semantic identity and digest tampering before durable mutation")
    let tamperedWireChild = DurableModelAttempt(
        childId, semanticId, runId, 2, ModelAttemptLifecycle.Created,
        objectValue([]), "retry", 0, 0,
        parentAttemptId: Some(parentId),
        providerRequestId: "restart-request-retry-1",
        semanticRequestDigest: "restart-semantic-digest",
        wirePolicyDigest: "restart-wire-digest-tampered"
    )
    expect(repository.prepareRestartModelAttempt(
        claimedParent, tamperedWireChild, policyEvent, duplicateEvent, continuation2
    ).isError() && restartBoundaryIsUnchanged(repository, runId, parentId, childId),
        "restart rejects child wire policy digest tampering before durable mutation")
    let tamperedCheckpoint = RunningModelCheckpoint(
        semanticId, canonical, "restart-semantic-digest", "restart-checkpoint-wire-tampered",
        parentId, childId, "restart-turn", "restart-request-retry-1", 0
    )
    let tamperedContinuation = RunContinuation(
        RunContinuationKind.RunningModel, runId, sessionId, "fixture", "resume",
        tamperedCheckpoint, requested, capabilities
    )
    expect(repository.prepareRestartModelAttempt(
        claimedParent, child, policyEvent, duplicateEvent, tamperedContinuation
    ).isError() && restartBoundaryIsUnchanged(repository, runId, parentId, childId),
        "restart rejects checkpoint wire policy digest tampering before durable mutation")
    let tamperedStateChild = DurableModelAttempt(
        childId, semanticId, runId, 3, ModelAttemptLifecycle.Streaming,
        objectValue([]), "retry", 0, 0,
        parentAttemptId: Some(parentId),
        providerRequestId: "restart-request-retry-1",
        semanticRequestDigest: "restart-semantic-digest",
        wirePolicyDigest: "restart-wire-digest",
        dispatchState: ModelAttemptDispatchState.DispatchClaimed
    )
    expect(repository.prepareRestartModelAttempt(
        claimedParent, tamperedStateChild, policyEvent, duplicateEvent, continuation2
    ).isError() && restartBoundaryIsUnchanged(repository, runId, parentId, childId),
        "restart rejects a child that is not Prepared attempt 2 before durable mutation")
    expect(repository.prepareRestartModelAttempt(
        claimedParent, child, policyEvent, invalidDuplicate, continuation2
    ).isError() &&
        repository.modelAttempt(parentId).value().getOrThrow().lifecycle ==
            ModelAttemptLifecycle.Streaming &&
        repository.modelAttempt(childId).isError() &&
        repository.continuation(runId).value().getOrThrow()
            .runningModel.getOrThrow().activeAttemptId.value == parentId.value,
        "restart boundary validation leaves no partial durable mutation")
    expect(repository.prepareRestartModelAttempt(
        claimedParent, child, policyEvent, duplicateEvent, continuation2
    ).isOk() &&
        repository.modelAttempt(parentId).value().getOrThrow().lifecycle ==
            ModelAttemptLifecycle.Abandoned &&
        repository.modelAttempt(childId).value().getOrThrow().attemptNo == 2 &&
        repository.continuation(runId).value().getOrThrow()
            .runningModel.getOrThrow().activeAttemptId.value == childId.value &&
        repository.events(runId, 0).value().getOrThrow().events.size == 4,
        "parent CAS, child, continuation, policy, and duplicate audit commit atomically")
    let barrierEvent = scopedEvent(
        5, runId, semanticId, childId,
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
            ValueField("code", textValue("model.attempt_replay_barrier")),
            ValueField("barrier", textValue("provider_terminal"))
        ]))
    )
    expect(repository.markModelAttemptReplayBarrier(
        childId, ModelAttemptReplayBarrier.ProviderTerminal, barrierEvent
    ).isOk() && repository.markModelAttemptReplayBarrier(
        childId, ModelAttemptReplayBarrier.ProviderTerminal, barrierEvent
    ).isOk(), "barrier row and exact event are atomically idempotent")
    let driftedBarrierEvent = scopedEvent(
        5, runId, semanticId, childId,
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
            ValueField("code", textValue("model.attempt_replay_barrier")),
            ValueField("barrier", textValue("tool_evidence"))
        ]))
    )
    expect(repository.markModelAttemptReplayBarrier(
        childId, ModelAttemptReplayBarrier.ProviderTerminal, driftedBarrierEvent
    ).isError(), "barrier idempotency rejects a drifted audit event")
}

func restartBoundaryIsUnchanged(
    repository: SqliteRunRepository,
    runId: RunId,
    parentId: ModelAttemptId,
    childId: ModelAttemptId
): Bool {
    repository.modelAttempt(parentId).value().getOrThrow().lifecycle ==
        ModelAttemptLifecycle.Streaming &&
        repository.modelAttempt(childId).isError() &&
        repository.continuation(runId).value().getOrThrow()
            .runningModel.getOrThrow().activeAttemptId.value == parentId.value &&
        repository.events(runId, 0).value().getOrThrow().events.size == 2
}

func attemptPolicyAtomicityContract(
    database: SqliteDatabase,
    repository: SqliteRunRepository,
    runId: RunId
): Unit {
    let semanticId = SemanticModelRequestId("semantic-policy")
    let attemptId = ModelAttemptId("attempt-policy")
    let attempt = DurableModelAttempt(
        attemptId, semanticId, runId, 1, ModelAttemptLifecycle.Created,
        objectValue([ValueField("policy_resolution_version", integerValue(1))]),
        "initial", 1, 1
    )
    let event = scopedEvent(
        4, runId, semanticId, attemptId,
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
            ValueField("code", textValue("model.attempt_policy_applied"))
        ]))
    )
    expect(repository.persistAttemptPolicy(attempt, event).isOk() &&
        repository.persistAttemptPolicy(attempt, event).isOk(),
        "attempt policy row and event commit idempotently as one boundary")
    expect(database.scalarInt(
        "SELECT COUNT(*) FROM model_attempts WHERE id='attempt-policy'"
    ) == 1 && database.scalarInt(
        "SELECT COUNT(*) FROM app_run_events WHERE run_id='run-1' AND sequence=4"
    ) == 1, "atomic policy boundary persists one exact row and one exact event")
    let rejectedAttempt = DurableModelAttempt(
        ModelAttemptId("attempt-gap"), SemanticModelRequestId("semantic-gap"),
        runId, 1, ModelAttemptLifecycle.Created, objectValue([]), "initial", 2, 2
    )
    let rejectedEvent = scopedEvent(
        6, runId, rejectedAttempt.semanticRequestId, rejectedAttempt.id,
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
            ValueField("code", textValue("model.attempt_policy_applied"))
        ]))
    )
    expect(repository.persistAttemptPolicy(rejectedAttempt, rejectedEvent).isError() &&
        database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE id='attempt-gap'") == 0,
        "event failure rolls back the model Attempt policy row before provider I/O")
}

func telemetryRetentionContract(
    database: SqliteDatabase,
    repository: SqliteRunRepository,
    runId: RunId
): Unit {
    let semanticId = SemanticModelRequestId("semantic-1")
    let attemptId = ModelAttemptId("attempt-1")
    expect(repository.append(scopedEvent(
        5, runId, semanticId, attemptId,
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
            ValueField("code", textValue("model.attempt_started"))
        ]))
    )).isOk(), "attempt lifecycle appends")
    var sequence: Int64 = 6
    var expectedReasoning = ""
    for (_ in 0..10000) {
        expect(repository.append(scopedEvent(
            sequence, runId, semanticId, attemptId,
            AgentEventPayload.ReasoningDelta("x")
        )).isOk(), "reasoning telemetry appends")
        expectedReasoning += "x"
        sequence++
    }
    expect(repository.append(scopedEvent(
        sequence, runId, semanticId, attemptId,
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
            ValueField("code", textValue("model.decision_committed"))
        ]))
    )).isOk(), "decision lifecycle appends")
    sequence++
    expect(database.scalarInt(
        "SELECT COUNT(*) FROM app_run_events WHERE run_id='run-1' AND event_class='telemetry'"
    ) == 2, "10000 tiny reasoning deltas aggregate into two bounded rows")
    expect(database.scalarInt(
        "SELECT COUNT(*) FROM app_run_events WHERE run_id='run-1' AND event_class='lifecycle'"
    ) == 6, "telemetry volume never evicts lifecycle rows")
    var replayedReasoning = ""
    for (event in repository.events(runId, 0).value().getOrThrow().events) {
        match (event.payload) {
            case AgentEventPayload.ReasoningDelta(text) => replayedReasoning += text
            case _ => ()
        }
    }
    expect(replayedReasoning == expectedReasoning,
        "reasoning aggregation preserves exact per-stream ordering and content")

    var expectedA = ""
    var expectedB = ""
    for (index in 0..10000) {
        let callId = if (index % 2 == 0) { "A" } else { "B" }
        let text = if (callId == "A") { "a" } else { "b" }
        expect(repository.append(scopedEvent(
            sequence, runId, semanticId, attemptId,
            AgentEventPayload.Extension(AgentEventKind.Model, objectValue([
                ValueField("code", textValue("model.tool_arguments")),
                ValueField("call_id", textValue(callId)),
                ValueField("text", textValue(text))
            ]))
        )).isOk(), "interleaved tool telemetry appends")
        if (callId == "A") { expectedA += text } else { expectedB += text }
        sequence++
    }
    let toolRows = database.query(
        "SELECT stream_key,delta_count,char_count FROM app_run_events " +
            "WHERE run_id='run-1' AND event_class='telemetry' ORDER BY stream_key"
    )
    expect(toolRows.size == 2,
        "interleaved tool arguments remain isolated and bounded by scoped stream key")
    for (row in toolRows) {
        expect(row.required(1) == "5000" && row.required(2) == "5000",
            "tool argument aggregation preserves per-call counts and character totals")
    }
    var replayedA = ""
    var replayedB = ""
    for (event in repository.events(runId, 0).value().getOrThrow().events) {
        match (event.payload) {
            case AgentEventPayload.Extension(_, detail) =>
                let callId = fieldText(detail, "call_id")
                if (callId == "A") { replayedA += fieldText(detail, "text") }
                else if (callId == "B") { replayedB += fieldText(detail, "text") }
            case _ => ()
        }
    }
    expect(replayedA == expectedA && replayedB == expectedB,
        "interleaved tool aggregation preserves exact per-call ordering and content")
    let gap = repository.events(runId, 100).value().getOrThrow()
    expect(gap.resyncRequired, "cursor inside a pruned/aggregated span requires resync")
}

func fieldText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.kind == ValueKind.Text) { item.text } else { "" }
        case None => ""
    }
}

func scopedEvent(
    sequence: Int64,
    runId: RunId,
    semanticId: SemanticModelRequestId,
    attemptId: ModelAttemptId,
    payload: AgentEventPayload
): AgentEvent {
    AgentEvent(EventMeta(
        sequence, TraceId("trace-1"), runId,
        semanticRequestId: Some(semanticId), attemptId: Some(attemptId)
    ), payload)
}

func metadataContract(database: SqliteDatabase, root: String): Unit {
    let repository = SqliteSessionMetadataRepository(database)
    let source = SessionId("metadata-source")
    let target = SessionId("metadata-target")
    expect(repository.name(source).value().getOrThrow() == "" &&
        repository.setName(source, "Primary").isOk() &&
        repository.setModel(source, "fixture").isOk() &&
        repository.setWorkspaceBinding(source, root, root).isOk() &&
        repository.setFastMode(source, true).isOk() &&
        repository.setWorkMode(source, "plan").isOk() &&
        repository.setDraft(source, "draft").isOk() &&
        repository.setTodoPhases(source, listValue([textValue("verify")])).isOk() &&
        repository.setGoalState(source, objectValue([
            ValueField("objective", textValue("finish"))
        ])).isOk(), "SQLite Thread metadata accepts public product fields")
    expect(repository.copy(source, target).isOk() &&
        repository.name(target).value().getOrThrow() == "Primary" &&
        repository.model(target).value().getOrThrow() == "fixture" &&
        repository.workspaceRoot(target).value().getOrThrow() == root &&
        repository.fastMode(target).value().getOrThrow() &&
        repository.workMode(target).value().getOrThrow() == "plan" &&
        repository.draft(target).value().getOrThrow() == "draft" &&
        repository.todoPhases(target).value().getOrThrow().items.size == 1 &&
        repository.goalState(target).value().getOrThrow().kind == ValueKind.Object,
        "SQLite Thread metadata copies atomically without file sidecars")
    expect(repository.setWorkMode(source, "unsafe").isError() &&
        repository.setWorkspaceBinding(source, root, "/").isError(),
        "SQLite Thread metadata preserves mode and workspace validation")
}

func seedCanonicalRun(database: SqliteDatabase): Unit {
    database.transaction<Unit>({ transaction =>
        transaction.execute(
            "INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal,active_turn_id) " +
                "VALUES('thread-1',1,'workspace','open',2,'turn-1')"
        )
        transaction.execute(
            "INSERT INTO turns(id,thread_id,ordinal,state,user_item_id,active_run_id) " +
                "VALUES('turn-1','thread-1',1,'active','user-1','run-1')"
        )
        transaction.execute(
            "INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) " +
                "VALUES('user-1','thread-1','turn-1',1,'user_message','{}','user',1)"
        )
        transaction.execute(
            "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage,started_at_millis) " +
                "VALUES('run-1','thread-1','turn-1',1,'running','{}','{}','{}','{}',1)"
        )
    })
}

func seedRestartRun(database: SqliteDatabase): Unit {
    database.transaction<Unit>({ transaction =>
        transaction.execute(
            "INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal,active_turn_id) " +
                "VALUES('restart-thread',1,'workspace','open',2,'restart-turn')"
        )
        transaction.execute(
            "INSERT INTO turns(id,thread_id,ordinal,state,user_item_id,active_run_id) " +
                "VALUES('restart-turn','restart-thread',1,'active','restart-user','restart-run')"
        )
        transaction.execute(
            "INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) " +
                "VALUES('restart-user','restart-thread','restart-turn',1,'user_message','{}','user',1)"
        )
        transaction.execute(
            "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage,started_at_millis) " +
                "VALUES('restart-run','restart-thread','restart-turn',1,'running','{}','{}','{}','{}',1)"
        )
    })
}

func seedRetryRun(database: SqliteDatabase): Unit {
    database.transaction<Unit>({ transaction =>
        transaction.execute(
            "INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal,active_turn_id) " +
                "VALUES('retry-thread',1,'workspace','open',2,'retry-turn')"
        )
        transaction.execute(
            "INSERT INTO turns(id,thread_id,ordinal,state,user_item_id,active_run_id) " +
                "VALUES('retry-turn','retry-thread',1,'active','retry-user','retry-run')"
        )
        transaction.execute(
            "INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) " +
                "VALUES('retry-user','retry-thread','retry-turn',1,'user_message','{}','user',1)"
        )
        transaction.execute(
            "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage,started_at_millis) " +
                "VALUES('retry-run','retry-thread','retry-turn',1,'running','{}','{}','{}','{}',1)"
        )
    })
}

func seedMigrationRun(database: SqliteDatabase): Unit {
    database.transaction<Unit>({ transaction =>
        transaction.execute(
            "INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal,active_turn_id) " +
                "VALUES('migration-thread',1,'workspace','open',2,'migration-turn')"
        )
        transaction.execute(
            "INSERT INTO turns(id,thread_id,ordinal,state,user_item_id,active_run_id) " +
                "VALUES('migration-turn','migration-thread',1,'active','migration-user','migration-run')"
        )
        transaction.execute(
            "INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) " +
                "VALUES('migration-user','migration-thread','migration-turn',1,'user_message','{}','user',1)"
        )
        transaction.execute(
            "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage,started_at_millis) " +
                "VALUES('migration-run','migration-thread','migration-turn',1,'waiting_approval','{}','{}','{}','{}',1)"
        )
    })
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
