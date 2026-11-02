package agent_core_contract

import yjson.*
import yjson_support.*
import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import std.time.*
import tool_runtime.*

class OutputLimitTraceModel <: ModelPort {
    private let mode: String
    private let runId: RunId
    private let runs: ?SqliteRunRepository
    private let idleCancelled = AtomicBool(false)
    var calls: Int64 = 0
    let requests = ArrayList<ModelRequest>()
    let checkpoints = ArrayList<RunningModelCheckpoint>()

    init(mode: String, runId: RunId, runs!: ?SqliteRunRepository = None) {
        this.mode = mode
        this.runId = runId
        this.runs = runs
    }

    private func capture(request: ModelRequest): Unit {
        requests.add(request)
        match (runs) {
            case Some(repository) =>
                let continuation = repository.continuation(runId).value().getOrThrow()
                match (continuation.runningModel) {
                    case Some(checkpoint) => checkpoints.add(checkpoint)
                    case None => throw IllegalStateException(
                        "durable output-limit model call has no RunningModel checkpoint"
                    )
                }
            case None => ()
        }
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls += 1
        capture(request)
        match (mode) {
            case "limited_then_answer" => if (calls == 1) {
                outputTraceLimitedReply(
                    events, "trace-limited-" + calls.toString(), partialTool: false
                )
            } else {
                outputTraceAnswer(events, calls, withUsage: true)
            }
            case "always_limited" =>
                outputTraceLimitedReply(
                    events, "trace-limited-" + calls.toString(), partialTool: false
                )
            case "idle_then_answer" => if (calls == 1) {
                while (!idleCancelled.load()) { sleep(Duration.millisecond * 5) }
                Result.Err(AgentError(
                    AgentErrorKind.Cancelled, "fixture.idle_cancelled",
                    "idle fixture stopped after Core cancelled its stalled request"
                ))
            } else if (calls == 2) {
                outputTraceAnswer(events, calls, withUsage: true)
            } else {
                Result.Err(AgentError(
                    AgentErrorKind.Internal, "fixture.unexpected_attempt",
                    "same-policy retry fixture received an unexpected third call"
                ))
            }
            case "tool_recovery" => if (calls == 1) {
                outputTraceLimitedReply(events, "trace-partial-tool", partialTool: true)
            } else if (calls == 2) {
                events(ModelEvent.ToolCallStarted("trace-echo-call", "echo"))
                events(ModelEvent.ToolArgumentsDelta(
                    "trace-echo-call", "{\"text\":\"durable echo\"}"
                ))
                events(ModelEvent.ToolCallCompleted("trace-echo-call"))
                events(ModelEvent.Completed)
                Result.Ok(contractModelReply(
                    [ModelBlock(
                        ModelBlockKind.ToolCall,
                        callId: "trace-echo-call",
                        name: "echo",
                        arguments: objectValue([
                            ValueField("text", textValue("durable echo"))
                        ])
                    )],
                    stopReason: "tool_calls",
                    providerId: "output-limit-trace",
                    responseId: "trace-tool-answer-2"
                ))
            } else if (calls == 3) {
                outputTraceAnswer(events, calls, withUsage: false)
            } else {
                Result.Err(AgentError(
                    AgentErrorKind.Internal, "fixture.unexpected_attempt",
                    "tool recovery fixture received an unexpected fourth call"
                ))
            }
            case "answer" => outputTraceAnswer(events, calls, withUsage: true)
            case "no_usage_answer" => outputTraceAnswer(events, calls, withUsage: false)
            case "forbidden" => Result.Err(AgentError(
                AgentErrorKind.Internal, "fixture.provider_must_not_run",
                "provider was invoked while a durable Decision awaited projection"
            ))
            case _ => throw IllegalArgumentException("unknown output-limit trace model mode")
        }
    }

    public func cancel(requestId: String): Result<Unit> {
        let _ = requestId
        idleCancelled.store(true)
        Result.Ok(())
    }
}

func outputTraceUsage(
    responseId: String,
    rejected!: Bool = false
): ModelUsage {
    if (rejected) {
        ModelUsage(
            inputTokens: 100,
            outputTokens: 20,
            reasoningTokens: 5,
            cacheReadTokens: 30,
            cacheWriteTokens: 10,
            source: ModelUsageSource.ProviderFinal,
            evidence: Some(ModelUsageEvidence(
                "output-limit-trace", "message_stop", providerResponseId: responseId
            ))
        )
    } else {
        ModelUsage(
            inputTokens: 20,
            outputTokens: 4,
            source: ModelUsageSource.ProviderFinal,
            evidence: Some(ModelUsageEvidence(
                "output-limit-trace", "message_stop", providerResponseId: responseId
            ))
        )
    }
}

func outputTraceLimitedReply(
    events: ModelEventSink,
    responseId: String,
    partialTool!: Bool = false
): Result<ModelReply> {
    let terminal = TerminalEvidence(
        "output-limit-trace", "message_stop", rawStopReason: "max_tokens",
        messageTerminalObserved: true, streamEofObserved: true,
        adapterVersion: "output-limit-trace-v1"
    )
    if (partialTool) {
        events(ModelEvent.ToolCallStarted("trace-partial-call", "echo"))
        events(ModelEvent.ToolArgumentsDelta("trace-partial-call", "{\"text\":"))
    }
    events(ModelEvent.ReasoningDelta("provisional output-limited reasoning"))
    events(ModelEvent.ProviderProgress(
        ProviderStreamEvent.MessageTerminalObserved(terminal)
    ))
    Result.Ok(ModelReply(
        [ModelBlock(ModelBlockKind.Reasoning, text: "provisional reasoning")],
        stopReason: "max_tokens",
        acceptedOutput: false,
        providerId: "output-limit-trace",
        responseId: responseId,
        usage: Some(outputTraceUsage(responseId, rejected: true)),
        terminalEvidence: Some(terminal),
        completionDisposition: CompletionDisposition.OutputLimited,
        decisionOutcome: DecisionOutcome.Unknown,
        validationVersion: 1
    ))
}

func outputTraceAnswer(
    events: ModelEventSink,
    attempt: Int64,
    withUsage!: Bool
): Result<ModelReply> {
    events(ModelEvent.Completed)
    let responseId = "trace-answer-" + attempt.toString()
    let reply = if (withUsage) {
        contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "durable recovery answer")],
            stopReason: "end_turn",
            providerId: "output-limit-trace",
            responseId: responseId,
            usage: Some(outputTraceUsage(responseId))
        )
    } else {
        contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "durable recovery answer")],
            stopReason: "end_turn",
            providerId: "output-limit-trace",
            responseId: responseId
        )
    }
    Result.Ok(reply)
}

func outputTraceRequest(
    runId: RunId,
    sessionId: SessionId,
    modelName!: String = "usage-fixture",
    prompt!: String = "complete the durable request",
    thinking!: ThinkingLevel = ThinkingLevel.Medium,
    capabilities!: CapabilitySet = CapabilitySet(),
    pricing!: ?ModelPricing = Some(rejectedUsagePricing()),
    autoRetry!: Bool = true
): AgentRunRequest {
    let thinkingCapabilities = if (thinking == ThinkingLevel.Off) {
        ThinkingCapabilities(ThinkingControlMode.NoThinking)
    } else {
        ThinkingCapabilities(
            ThinkingControlMode.Effort,
            supportedLevels: [ThinkingLevel.Low, ThinkingLevel.Medium]
        )
    }
    AgentRunRequest(
        runId,
        sessionId,
        modelName,
        prompt,
        system: "preserve this immutable system prefix",
        thinking: thinking,
        userRequestedThinking: Some(thinking),
        thinkingSource: ThinkingPreferenceSource.ExplicitUser,
        modelCapabilitiesSnapshot: Some(ModelExecutionCapabilitiesSnapshot(
            modelName, thinkingCapabilities, 100000
        )),
        capabilities: capabilities,
        budget: ResourceBudget(
            maxOutputTokens: 20,
            maxWallMillis: 60000,
            maxIdleMillis: 60000
        ),
        autoRetry: autoRetry,
        serviceTier: "priority",
        pricing: pricing,
        cachePolicy: ModelCachePolicy.StablePrefix,
        cacheKey: "output-limit-trace-cache",
        parallelToolCalls: true
    )
}

func outputTraceThreadRuntimes(
    database: SqliteDatabase,
    runId: RunId
): SqliteThreadRuntimeRegistry {
    SqliteThreadRuntimeRegistry(
        database,
        ContextProjector(
            "durable-output-limit-" + runId.value,
            ConservativeThreadTokenEstimator()
        ),
        { => agentUtcMillis() }
    )
}

func outputTraceCore(
    model: ModelPort,
    runs: SqliteRunRepository,
    catalog: ToolCatalog,
    operations: DurableOperationStore,
    threadRuntimes: SqliteThreadRuntimeRegistry,
    decisions: SqliteModelDecisionStore,
    recovery!: ModelAttemptRecoveryPolicy = ModelAttemptRecoveryPolicy()
): AgentCore {
    AgentCore(
        model,
        runs,
        ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds()),
        catalog,
        threadRuntimes: Some(threadRuntimes),
        operationRuntime: Some(operations),
        modelDecisionRuntime: Some(decisions),
        modelAttemptRecovery: recovery
    )
}

func outputTraceEvents(
    runs: SqliteRunRepository,
    runId: RunId
): ArrayList<AgentEvent> {
    let events = ArrayList<AgentEvent>()
    for (event in runs.events(runId, 0).value().getOrThrow().events) {
        events.add(event)
    }
    events
}

func outputTraceAttemptIds(
    database: SqliteDatabase,
    runId: RunId
): ArrayList<ModelAttemptId> {
    let ids = ArrayList<ModelAttemptId>()
    let rows = database.query(
        "SELECT id FROM model_attempts WHERE run_id=" + sqliteText(runId.value) +
            " ORDER BY rowid"
    )
    for (row in rows) { ids.add(ModelAttemptId(row.required(0))) }
    ids
}

func outputTraceFilteredRequest(value: AgentValue): String {
    let fields = ArrayList<ValueField>()
    for (field in value.fields) {
        if (field.name != "thinking" && field.name != "resolved_policy") {
            fields.add(field)
        }
    }
    canonicalAgentValue(objectValue(fields.toArray()))
}

func outputTraceAssertSelfConsistent(
    request: ModelRequest,
    checkpoint: RunningModelCheckpoint,
    attempt: DurableModelAttempt,
    message: String
): Unit {
    let semanticDigest = modelPolicySha256Text(
        canonicalAgentValue(checkpoint.canonicalRequest)
    )
    let policyCanonical = match (request.resolvedPolicy) {
        case Some(value) => canonicalResolvedModelRequestPolicy(value)
        case None => modelPolicyThinkingLevelName(request.thinking)
    }
    let wireDigest = modelAttemptWirePolicyDigest(
        request.model,
        request.wireMaxOutputTokens,
        request.toolChoice,
        request.transportHardTimeoutMillis,
        policyCanonical
    )
    expect(semanticDigest == checkpoint.semanticRequestDigest &&
        semanticDigest == attempt.semanticRequestDigest &&
        wireDigest == checkpoint.wirePolicyDigest &&
        wireDigest == attempt.wirePolicyDigest,
        message + " has self-consistent semantic and wire-policy digests")
}

func outputTraceEventPolicyReason(
    events: ArrayList<AgentEvent>,
    code: String
): String {
    for (event in events where eventCode(event) == code) {
        match (eventProtocolDetail(event).field("policy_reason")) {
            case Some(value) => if (value.unifiedKind == ValueKind.Text) { return value.text }
            case None => ()
        }
    }
    ""
}

func outputTraceCount(database: SqliteDatabase, sql: String): Int64 {
    database.scalarInt(sql)
}

func durableOutputLimitRecoveryWorker(root: String): Int64 {
    let runId = RunId("output-limit-restart-run")
    let sessionId = SessionId("output-limit-restart-session")
    let database = SqliteDatabase(durableDatabasePath(root))
    let runs = SqliteRunRepository(database)
    let threadRuntimes = outputTraceThreadRuntimes(database, runId)
    let decisions = SqliteModelDecisionStore(database)
    let operations = DurableOperationStore(database)
    let catalog = ToolCatalog()
    let model = OutputLimitTraceModel("limited_then_answer", runId, runs: Some(runs))
    let core = outputTraceCore(
        model, runs, catalog, operations, threadRuntimes, decisions,
        recovery: ModelAttemptRecoveryPolicy(maxRecoveryRetries: 1)
    )
    let _ = core.start(outputTraceRequest(runId, sessionId), { event =>
        if (eventCode(event) == "model.attempt_policy_applied" &&
            match (eventProtocolDetail(event).field("policy_reason")) {
                case Some(value) => value.unifiedKind == ValueKind.Text &&
                    value.text == "output_limit_recovery"
                case None => false
            }) {
            File.writeTo((root + "/ready"), "ready".toArray())
            while (true) { sleep(Duration.second) }
        }
    })
    while (true) { sleep(Duration.second) }
    0
}

func durableOutputDecisionWorker(root: String): Int64 {
    let runId = RunId("output-decision-restart-run")
    let sessionId = SessionId("output-decision-restart-session")
    let database = SqliteDatabase(durableDatabasePath(root))
    let runs = SqliteRunRepository(database)
    let threadRuntimes = outputTraceThreadRuntimes(database, runId)
    let decisions = SqliteModelDecisionStore(database)
    let operations = DurableOperationStore(database)
    let catalog = ToolCatalog()
    let model = OutputLimitTraceModel("no_usage_answer", runId, runs: Some(runs))
    let core = outputTraceCore(
        model, runs, catalog, operations, threadRuntimes, decisions
    )
    let _ = core.start(outputTraceRequest(
        runId, sessionId, pricing: None
    ), { event =>
        if (eventCode(event) == "model.decision_persisted") {
            File.writeTo((root + "/ready"), "ready".toArray())
            while (true) { sleep(Duration.second) }
        }
    })
    while (true) { sleep(Duration.second) }
    0
}

func outputTraceSuccessfulSnapshot(
    result: Result<AgentRunOutcome>,
    message: String
): RunSnapshot {
    expect(result.isOk(), message + " succeeds")
    match (result.value().getOrThrow()) {
        case AgentRunOutcome.Completed(snapshot) => snapshot
        case _ => throw IllegalStateException(message + " unexpectedly awaits approval")
    }
}

func durableOutputLimitRecoveryExactContract(root: String): Unit {
    let runId = RunId("output-limit-exact-run")
    let sessionId = SessionId("output-limit-exact-session")
    Directory.create(root, recursive: true)
    let database = SqliteDatabase(durableDatabasePath(root))
    let runs = SqliteRunRepository(database)
    let threadRuntimes = outputTraceThreadRuntimes(database, runId)
    let decisions = SqliteModelDecisionStore(database)
    let operations = DurableOperationStore(database)
    let catalog = ToolCatalog()
    let model = OutputLimitTraceModel("limited_then_answer", runId, runs: Some(runs))
    let core = outputTraceCore(
        model, runs, catalog, operations, threadRuntimes, decisions,
        recovery: ModelAttemptRecoveryPolicy(maxRecoveryRetries: 1)
    )
    try {
        let result = core.start(outputTraceRequest(runId, sessionId))
        let snapshot = outputTraceSuccessfulSnapshot(result, "T001 SQLite output-limit recovery")
        let attemptIds = outputTraceAttemptIds(database, runId)
        expect(model.calls == 2 && model.requests.size == 2 &&
            model.checkpoints.size == 2 && attemptIds.size == 2,
            "T001 sends exactly the limited parent and recovered child model calls")
        let parent = runs.modelAttempt(attemptIds[0]).value().getOrThrow()
        let child = runs.modelAttempt(attemptIds[1]).value().getOrThrow()
        let parentCheckpoint = model.checkpoints[0]
        let childCheckpoint = model.checkpoints[1]
        outputTraceAssertSelfConsistent(
            model.requests[0], parentCheckpoint, parent, "T001 parent"
        )
        outputTraceAssertSelfConsistent(
            model.requests[1], childCheckpoint, child, "T001 child"
        )
        expect(parent.semanticRequestId.value == child.semanticRequestId.value &&
            parentCheckpoint.semanticRequestId.value == childCheckpoint.semanticRequestId.value &&
            parent.semanticRequestDigest != child.semanticRequestDigest &&
            parent.wirePolicyDigest != child.wirePolicyDigest &&
            parent.lifecycle == ModelAttemptLifecycle.Abandoned &&
            child.lifecycle == ModelAttemptLifecycle.Completed &&
            child.parentAttemptId.isSome() &&
            child.parentAttemptId.getOrThrow().value == parent.id.value,
            "T001 keeps one semantic request while persisting a bounded policy-derived child")
        expect(model.requests[0].thinking == ThinkingLevel.Medium &&
            model.requests[1].thinking == ThinkingLevel.Low &&
            outputTraceFilteredRequest(parentCheckpoint.canonicalRequest) ==
                outputTraceFilteredRequest(childCheckpoint.canonicalRequest) &&
            canonicalAgentValue(parentCheckpoint.canonicalRequest.field("resolved_policy").getOrThrow()) !=
                canonicalAgentValue(childCheckpoint.canonicalRequest.field("resolved_policy").getOrThrow()),
            "T001 changes only thinking and resolved policy; immutable request content is preserved")
        expect(parent.policyReason == "initial" &&
            child.policyReason == "output_limit_recovery" &&
            outputTraceEventPolicyReason(
                outputTraceEvents(runs, runId), "model.auto_retry_start"
            ) == "output_limit_recovery",
            "T001 durable attempt and retry diagnostic identify output-limit recovery")
        let decisionRows = database.query(
            "SELECT d.attempt_id FROM model_decisions d JOIN model_attempts a " +
                "ON a.id=d.attempt_id WHERE a.run_id=" + sqliteText(runId.value)
        )
        expect(decisionRows.size == 1 && decisionRows[0].required(0) == child.id.value &&
            outputTraceCount(database,
                "SELECT COUNT(*) FROM canonical_decision_items WHERE decision_id IN " +
                    "(SELECT id FROM model_decisions WHERE attempt_id=" +
                    sqliteText(child.id.value) + ")") == 1 &&
            outputTraceCount(database,
                "SELECT COUNT(*) FROM operations WHERE run_id=" + sqliteText(runId.value)) == 0,
            "T001 stores only the child canonical Decision and creates no parent Operation")
        expect(snapshot.status == RunState.Completed && snapshot.modelRequests == 2 &&
            snapshot.inputTokens == 120 && snapshot.outputTokens == 24 &&
            snapshot.reasoningTokens == 5 && snapshot.cacheReadTokens == 30 &&
            snapshot.cacheWriteTokens == 10 && snapshot.costMicros == Some(158),
            "T001 bills the rejected and accepted replies once with exact per-request pricing")
    } finally {
        database.close()
    }
}

func durableOutputLimitRecoveryFailureCase(
    root: String,
    suffix: String,
    thinking: ThinkingLevel,
    mode: String,
    expectedCalls: Int64,
    expectedInput: Int64,
    expectedOutput: Int64,
    expectedCost: Int64,
    recovery: ModelAttemptRecoveryPolicy
): Unit {
    let runId = RunId("output-limit-failure-" + suffix)
    let sessionId = SessionId("output-limit-failure-session-" + suffix)
    Directory.create(root, recursive: true)
    let database = SqliteDatabase(durableDatabasePath(root))
    let runs = SqliteRunRepository(database)
    let threadRuntimes = outputTraceThreadRuntimes(database, runId)
    let decisions = SqliteModelDecisionStore(database)
    let operations = DurableOperationStore(database)
    let catalog = ToolCatalog()
    let model = OutputLimitTraceModel(mode, runId, runs: Some(runs))
    let core = outputTraceCore(
        model, runs, catalog, operations, threadRuntimes, decisions, recovery: recovery
    )
    try {
        let result = core.start(outputTraceRequest(
            runId, sessionId, thinking: thinking
        ))
        expect(result.isError() && model.calls == expectedCalls &&
            result.error().getOrThrow().code == "model.output_limited_before_decision",
            "T002 " + suffix + " keeps the output-limit root cause with bounded provider calls")
        let snapshot = runs.find(runId).value().getOrThrow()
        let attemptIds = outputTraceAttemptIds(database, runId)
        expect(attemptIds.size == expectedCalls && snapshot.status == RunState.Failed &&
            outputTraceCount(database,
                "SELECT COUNT(*) FROM model_decisions d JOIN model_attempts a " +
                    "ON a.id=d.attempt_id WHERE a.run_id=" + sqliteText(runId.value)) == 0 &&
            outputTraceCount(database,
                "SELECT COUNT(*) FROM operations WHERE run_id=" + sqliteText(runId.value)) == 0 &&
            outputTraceCount(database,
                "SELECT COUNT(*) FROM canonical_decision_items WHERE item_id IN " +
                    "(SELECT id FROM items WHERE thread_id=" + sqliteText(sessionId.value) + ")") == 0,
            "T002 " + suffix + " persists no partial canonical Decision or Operation")
        expect(snapshot.modelRequests == expectedCalls &&
            snapshot.inputTokens == expectedInput && snapshot.outputTokens == expectedOutput &&
            snapshot.reasoningTokens == expectedCalls * 5 &&
            snapshot.cacheReadTokens == expectedCalls * 30 &&
            snapshot.cacheWriteTokens == expectedCalls * 10 &&
            snapshot.costMicros == Some(expectedCost),
            "T002 " + suffix + " preserves the reported usage of every rejected reply")
    } finally {
        database.close()
    }
}

func durableOutputLimitRecoveryFailureContract(root: String): Unit {
    durableOutputLimitRecoveryFailureCase(
        root + "/disabled", "disabled", ThinkingLevel.Medium, "limited_then_answer",
        1, 100, 20, 130,
        ModelAttemptRecoveryPolicy(
            mode: ModelAttemptRecoveryMode.Disabled, maxRecoveryRetries: 0
        )
    )
    durableOutputLimitRecoveryFailureCase(
        root + "/off", "off", ThinkingLevel.Off, "limited_then_answer",
        1, 100, 20, 130, ModelAttemptRecoveryPolicy(maxRecoveryRetries: 1)
    )
    durableOutputLimitRecoveryFailureCase(
        root + "/exhausted", "exhausted", ThinkingLevel.Medium, "always_limited",
        2, 200, 40, 260, ModelAttemptRecoveryPolicy(maxRecoveryRetries: 1)
    )
}

func durableOutputLimitSamePolicyRetryContract(root: String): Unit {
    let runId = RunId("output-limit-idle-retry-run")
    let sessionId = SessionId("output-limit-idle-retry-session")
    Directory.create(root, recursive: true)
    let database = SqliteDatabase(durableDatabasePath(root))
    let runs = SqliteRunRepository(database)
    let threadRuntimes = outputTraceThreadRuntimes(database, runId)
    let decisions = SqliteModelDecisionStore(database)
    let operations = DurableOperationStore(database)
    let catalog = ToolCatalog()
    let model = OutputLimitTraceModel("idle_then_answer", runId, runs: Some(runs))
    let core = outputTraceCore(
        model, runs, catalog, operations, threadRuntimes, decisions,
        recovery: ModelAttemptRecoveryPolicy(maxRecoveryRetries: 1, streamIdleMillis: 250)
    )
    try {
        let result = core.start(outputTraceRequest(runId, sessionId))
        let snapshot = outputTraceSuccessfulSnapshot(result, "T003 durable stream-idle retry")
        let attemptIds = outputTraceAttemptIds(database, runId)
        expect(model.calls == 2 && model.requests.size == 2 &&
            model.checkpoints.size == 2 && attemptIds.size == 2 &&
            snapshot.status == RunState.Completed,
            "T003 retries a stream-idle failure exactly once through SQLite")
        let parent = runs.modelAttempt(attemptIds[0]).value().getOrThrow()
        let child = runs.modelAttempt(attemptIds[1]).value().getOrThrow()
        outputTraceAssertSelfConsistent(
            model.requests[0], model.checkpoints[0], parent, "T003 parent"
        )
        outputTraceAssertSelfConsistent(
            model.requests[1], model.checkpoints[1], child, "T003 child"
        )
        expect(parent.semanticRequestId.value == child.semanticRequestId.value &&
            parent.semanticRequestDigest == child.semanticRequestDigest &&
            parent.wirePolicyDigest == child.wirePolicyDigest &&
            canonicalAgentValue(model.checkpoints[0].canonicalRequest) ==
                canonicalAgentValue(model.checkpoints[1].canonicalRequest) &&
            model.requests[0].thinking == ThinkingLevel.Medium &&
            model.requests[1].thinking == ThinkingLevel.Medium &&
            parent.failureKind == "stream_idle_timeout" &&
            parent.lifecycle == ModelAttemptLifecycle.Abandoned &&
            child.lifecycle == ModelAttemptLifecycle.Completed &&
            child.policyReason == "retry" &&
            outputTraceEventPolicyReason(
                outputTraceEvents(runs, runId), "model.auto_retry_start"
            ) == "retry",
            "T003 keeps identical request and wire digests and reports an ordinary retry")
    } finally {
        database.close()
    }
}

func durableOutputLimitRecoveryRestartContract(root: String): Unit {
    let workerRoot = root + "/recovery"
    durableLaunchWorker("output-recovery", workerRoot)
    let runId = RunId("output-limit-restart-run")
    let sessionId = SessionId("output-limit-restart-session")
    let beforeResume = SqliteDatabase(durableDatabasePath(workerRoot))
    let beforeRuns = SqliteRunRepository(beforeResume)
    try {
        let ids = outputTraceAttemptIds(beforeResume, runId)
        expect(ids.size == 2, "T007 worker leaves the parent and prepared child in SQLite")
        let parent = beforeRuns.modelAttempt(ids[0]).value().getOrThrow()
        let child = beforeRuns.modelAttempt(ids[1]).value().getOrThrow()
        let continuation = beforeRuns.continuation(runId).value().getOrThrow()
        let checkpoint = continuation.runningModel.getOrThrow()
        expect(continuation.kind == RunContinuationKind.RunningModel &&
            parent.lifecycle == ModelAttemptLifecycle.Abandoned &&
            child.lifecycle == ModelAttemptLifecycle.Created &&
            child.attemptNo == 2 && child.parentAttemptId.isSome() &&
            child.parentAttemptId.getOrThrow().value == parent.id.value &&
            child.dispatchState == ModelAttemptDispatchState.Prepared &&
            child.dispatchStartedAtMillis.isNone() &&
            checkpoint.activeAttemptId.value == child.id.value &&
            checkpoint.modelRequests == 1 && checkpoint.inputTokens == 100 &&
            checkpoint.outputTokens == 20 && checkpoint.reasoningTokens == 5 &&
            checkpoint.cacheReadTokens == 30 && checkpoint.cacheWriteTokens == 10 &&
            checkpoint.costMicros == Some(130),
            "T007 kill boundary is after Prepared A2 checkpoint saves exactly A1 usage and before dispatch")
        expect(checkpoint.semanticRequestDigest == child.semanticRequestDigest &&
            modelPolicySha256Text(canonicalAgentValue(checkpoint.canonicalRequest)) ==
                checkpoint.semanticRequestDigest &&
            checkpoint.wirePolicyDigest == child.wirePolicyDigest &&
            checkpoint.canonicalRequest.field("model").getOrThrow().text == "usage-fixture" &&
            checkpoint.canonicalRequest.field("thinking").getOrThrow().text == "low" &&
            child.policyReason == "output_limit_recovery",
            "T007 prepared child remains bound to its frozen low-policy request")
    } finally {
        beforeResume.close()
    }

    let database = SqliteDatabase(durableDatabasePath(workerRoot))
    let runs = SqliteRunRepository(database)
    let threadRuntimes = outputTraceThreadRuntimes(database, runId)
    let decisions = SqliteModelDecisionStore(database)
    let operations = DurableOperationStore(database)
    let catalog = ToolCatalog()
    let model = OutputLimitTraceModel("answer", runId, runs: Some(runs))
    let core = outputTraceCore(
        model, runs, catalog, operations, threadRuntimes, decisions,
        recovery: ModelAttemptRecoveryPolicy(maxRecoveryRetries: 1)
    )
    try {
        let callerDrift = outputTraceRequest(
            runId,
            sessionId,
            modelName: "caller-drift-model",
            prompt: "caller drift cannot replace the frozen child",
            thinking: ThinkingLevel.High,
            pricing: None,
            autoRetry: false
        )
        let resumed = core.resume(callerDrift)
        let snapshot = outputTraceSuccessfulSnapshot(resumed, "T007 frozen child resume")
        let ids = outputTraceAttemptIds(database, runId)
        expect(model.calls == 1 && model.requests.size == 1 &&
            model.checkpoints.size == 1 && ids.size == 2 &&
            model.requests[0].model == "usage-fixture" &&
            model.requests[0].thinking == ThinkingLevel.Low &&
            model.checkpoints[0].semanticRequestDigest ==
                modelPolicySha256Text(canonicalAgentValue(
                    model.checkpoints[0].canonicalRequest
                )),
            "T007 resume dispatches the frozen low child once despite caller model, prompt, and policy drift")
        let child = runs.modelAttempt(ids[1]).value().getOrThrow()
        outputTraceAssertSelfConsistent(
            model.requests[0], model.checkpoints[0], child, "T007 resumed child"
        )
        expect(snapshot.status == RunState.Completed && snapshot.modelRequests == 2 &&
            snapshot.inputTokens == 120 && snapshot.outputTokens == 24 &&
            snapshot.reasoningTokens == 5 && snapshot.cacheReadTokens == 30 &&
            snapshot.cacheWriteTokens == 10 && snapshot.costMicros == Some(158),
            "T007 resume retains A1 usage and charges the accepted A2 reply exactly once")
        expect(ids.size == 2 && child.lifecycle == ModelAttemptLifecycle.Completed,
            "T007 recovery completes the prepared child without creating A3")
    } finally {
        database.close()
    }
}

func durableOutputDecisionResumeContract(root: String): Unit {
    let workerRoot = root + "/decision"
    durableLaunchWorker("output-decision", workerRoot)
    let runId = RunId("output-decision-restart-run")
    let sessionId = SessionId("output-decision-restart-session")
    let database = SqliteDatabase(durableDatabasePath(workerRoot))
    let runs = SqliteRunRepository(database)
    let threadRuntimes = outputTraceThreadRuntimes(database, runId)
    let decisions = SqliteModelDecisionStore(database)
    let operations = DurableOperationStore(database)
    let catalog = ToolCatalog()
    let model = OutputLimitTraceModel("forbidden", runId, runs: Some(runs))
    let core = outputTraceCore(
        model, runs, catalog, operations, threadRuntimes, decisions
    )
    try {
        let resumed = core.resume(outputTraceRequest(
            runId, sessionId, pricing: None
        ))
        let snapshot = outputTraceSuccessfulSnapshot(
            resumed, "T007 persisted Decision direct resume"
        )
        let ids = outputTraceAttemptIds(database, runId)
        expect(model.calls == 0 && ids.size == 1 && snapshot.status == RunState.Completed &&
            snapshot.modelRequests == 1 && snapshot.inputTokens == 0 &&
            snapshot.outputTokens == 0 && snapshot.costMicros.isNone() &&
            outputTraceCount(database,
                "SELECT COUNT(*) FROM model_decisions d JOIN model_attempts a " +
                    "ON a.id=d.attempt_id WHERE a.run_id=" + sqliteText(runId.value)) == 1 &&
            outputTraceCount(database,
                "SELECT COUNT(*) FROM canonical_decision_items WHERE decision_id IN " +
                    "(SELECT d.id FROM model_decisions d JOIN model_attempts a " +
                    "ON a.id=d.attempt_id WHERE a.run_id=" + sqliteText(runId.value) + ")") == 1,
            "T007 projects the persisted zero-usage Decision without a provider resend or synthetic usage")
    } finally {
        database.close()
    }
}

func outputTraceHasAssistantText(items: Array<ThreadItem>, expected: String): Bool {
    for (item in items) {
        match (item.content) {
            case ThreadItemContent.AssistantMessage(parts) =>
                for (part in parts) {
                    match (part) {
                        case ThreadMessagePart.Text(value) =>
                            if (value == expected) { return true }
                        case _ => ()
                    }
                }
            case _ => ()
        }
    }
    false
}

func durableOutputLimitToolRecoveryContract(root: String): Unit {
    let runId = RunId("output-limit-tool-run")
    let sessionId = SessionId("output-limit-tool-session")
    Directory.create(root, recursive: true)
    let database = SqliteDatabase(durableDatabasePath(root))
    let runs = SqliteRunRepository(database)
    let threadRuntimes = outputTraceThreadRuntimes(database, runId)
    let decisions = SqliteModelDecisionStore(database)
    let operations = DurableOperationStore(database)
    let echo = EchoTool()
    let catalog = durableCatalog("echo", echo, CapabilityKind.WorkspaceRead)
    let model = OutputLimitTraceModel("tool_recovery", runId, runs: Some(runs))
    let core = outputTraceCore(
        model, runs, catalog, operations, threadRuntimes, decisions,
        recovery: ModelAttemptRecoveryPolicy(maxRecoveryRetries: 1)
    )
    try {
        let result = core.start(outputTraceRequest(
            runId,
            sessionId,
            capabilities: durableCapabilitySet(CapabilityKind.WorkspaceRead)
        ))
        let snapshot = outputTraceSuccessfulSnapshot(result, "T009 durable partial-tool recovery")
        let ids = outputTraceAttemptIds(database, runId)
        expect(model.calls == 3 && model.requests.size == 3 &&
            model.checkpoints.size == 3 && ids.size == 3 &&
            model.requests[0].thinking == ThinkingLevel.Medium &&
            model.requests[1].thinking == ThinkingLevel.Low &&
            model.requests[2].thinking == ThinkingLevel.Medium &&
            model.checkpoints[0].semanticRequestId.value ==
                model.checkpoints[1].semanticRequestId.value &&
            model.checkpoints[2].semanticRequestId.value !=
                model.checkpoints[1].semanticRequestId.value &&
            snapshot.status == RunState.Completed,
            "T009 recovers the partial tool at low effort and restores requested effort for the next request")
        let thread = threadRuntimes.acquire(
            ThreadId(sessionId.value), "agent-core"
        ).value().getOrThrow().threadSnapshot()
        let finalAttempt = runs.modelAttempt(ids[2]).value().getOrThrow()
        expect(outputTraceHasAssistantText(
                thread.items, "durable recovery answer"
            ) && outputTraceCount(database,
                "SELECT COUNT(*) FROM model_decisions WHERE attempt_id=" +
                    sqliteText(finalAttempt.id.value)) == 1,
            "T009 the next semantic request stores the actual final answer Decision")
        let parent = runs.modelAttempt(ids[0]).value().getOrThrow()
        let child = runs.modelAttempt(ids[1]).value().getOrThrow()
        outputTraceAssertSelfConsistent(
            model.requests[0], model.checkpoints[0], parent, "T009 parent"
        )
        outputTraceAssertSelfConsistent(
            model.requests[1], model.checkpoints[1], child, "T009 child"
        )
        expect(parent.lifecycle == ModelAttemptLifecycle.Abandoned &&
            child.lifecycle == ModelAttemptLifecycle.Completed &&
            outputTraceCount(database,
                "SELECT COUNT(*) FROM model_decisions WHERE attempt_id=" +
                    sqliteText(parent.id.value)) == 0 &&
            outputTraceCount(database,
                "SELECT COUNT(*) FROM decision_operations d JOIN model_decisions m " +
                    "ON m.id=d.decision_id WHERE m.attempt_id=" +
                    sqliteText(parent.id.value)) == 0 &&
            echo.executions == 1 && echo.persistedResults == 1,
            "T009 provisional A1 tool arguments never create a Decision or execute")
        expect(outputTraceCount(database,
                "SELECT COUNT(*) FROM operations WHERE run_id=" + sqliteText(runId.value) +
                    " AND state='committed'") == 1 &&
            outputTraceCount(database,
                "SELECT COUNT(*) FROM operation_receipts r JOIN operations o " +
                    "ON o.id=r.operation_id WHERE o.run_id=" + sqliteText(runId.value) +
                    " AND r.outcome='completed'") == 1 &&
            outputTraceCount(database,
                "SELECT COUNT(*) FROM items WHERE thread_id=" + sqliteText(sessionId.value) +
                    " AND kind='tool_call'") == 1 &&
            durableToolResultCount(database, ThreadId(sessionId.value)) == 1,
            "T009 actual ToolPipeline commits one Echo Operation, receipt, ToolCall, and ToolResult")
        let operationAttemptRows = database.query(
            "SELECT m.attempt_id FROM decision_operations d JOIN model_decisions m " +
                "ON m.id=d.decision_id JOIN operations o ON o.id=d.operation_id " +
                "WHERE o.run_id=" + sqliteText(runId.value)
        )
        expect(operationAttemptRows.size == 1 &&
            operationAttemptRows[0].required(0) == child.id.value,
            "T009 the sole durable Operation belongs to accepted A2, never partial A1")
    } finally {
        database.close()
    }
}

func durableOutputLimitRecoveryContract(): Unit {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    try {
        durableOutputLimitRecoveryExactContract(root + "/exact")
        durableOutputLimitRecoveryFailureContract(root + "/failures")
        durableOutputLimitSamePolicyRetryContract(root + "/idle")
        durableOutputLimitRecoveryRestartContract(root + "/restart")
        durableOutputDecisionResumeContract(root + "/restart")
        durableOutputLimitToolRecoveryContract(root + "/tool")
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}
