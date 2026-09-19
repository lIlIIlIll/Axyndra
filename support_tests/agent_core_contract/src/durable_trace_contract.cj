package agent_core_contract

import yjson_support.*
import yjson.*
import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_skills.*
import agent_store.*
import persistence_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.process.*
import std.sync.*
import std.time.*
import tool_runtime.*

class DurableCrashDispatchModel <: ModelPort {
    private let marker: String
    var calls: Int64 = 0

    init(marker: String) {
        this.marker = marker
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request
        let _ = events
        calls += 1
        File.writeTo(marker, "ready".toArray())
        while (true) {
            sleep(Duration.second)
        }
        Result.Err(AgentError(
            AgentErrorKind.Internal,
            "fixture.unreachable",
            "durable crash worker was terminated before the model returned"
        ))
    }
}

class DurableResumeAnswerModel <: ModelPort {
    var calls: Int64 = 0
    var lastModel: String = ""

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls += 1
        lastModel = request.model
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply(
            [ModelBlock(ModelBlockKind.Text, text: "durable recovery complete")],
            stopReason: "end_turn",
            providerId: "durable-recovery",
            responseId: "durable-recovery-response"
        ))
    }
}

class DurableToolCallModel <: ModelPort {
    private let toolName: String

    init(toolName: String) {
        this.toolName = toolName
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply([
            ModelBlock(
                ModelBlockKind.ToolCall,
                callId: "durable-call",
                name: toolName,
                arguments: objectValue([])
            )
        ], stopReason: "tool_calls", responseId: "durable-tool-response"))
    }
}

class DurableReceiptCrashTool <: ToolExecutor {
    private let effectPath: String
    private let marker: String
    private let blockAfterPersisted: Bool

    init(effectPath: String, marker: String, blockAfterPersisted!: Bool = false) {
        this.effectPath = effectPath
        this.marker = marker
        this.blockAfterPersisted = blockAfterPersisted
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let _ = context
        let call = preparedToolCall(prepared)
        durableIncrementEffect(effectPath)
        Result.Ok(ToolResult(
            call.callId,
            objectValue([ValueField("effect", textValue("applied"))])
        ))
    }

    public func afterResultPersisted(
        context: ToolInvocationContext,
        result: ToolResult
    ): Result<Unit> {
        let _ = context
        let _ = result
        if (blockAfterPersisted) {
            File.writeTo(marker, "receipt-persisted".toArray())
            while (true) {
                sleep(Duration.second)
            }
        }
        Result.Ok(())
    }
}

class DurableUnknownEffectTool <: ToolExecutor {
    private let effectPath: String
    private let marker: String

    init(effectPath: String, marker: String) {
        this.effectPath = effectPath
        this.marker = marker
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let _ = context
        let call = preparedToolCall(prepared)
        durableIncrementEffect(effectPath)
        File.writeTo(marker, "effect-started".toArray())
        while (true) {
            sleep(Duration.second)
        }
        Result.Ok(ToolResult(
            call.callId,
            objectValue([ValueField("effect", textValue("unreachable"))])
        ))
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

func durableIncrementEffect(path: String): Unit {
    let current = if (exists(Path(path))) {
        try { Int64.parse(String.fromUtf8(File.readFrom(path)).trimAscii()) }
        catch (_: Exception) { 0 }
    } else {
        0
    }
    File.writeTo(path, (current + 1).toString().toArray())
}

func durableEffectCount(path: String): Int64 {
    if (!exists(Path(path))) { return 0 }
    try { Int64.parse(String.fromUtf8(File.readFrom(path)).trimAscii()) }
    catch (_: Exception) { 0 }
}

func durableDatabasePath(root: String): String {
    root + "/state.db"
}

func durableCapabilitySet(kind: CapabilityKind): CapabilitySet {
    CapabilitySet(values: [Capability(kind)])
}

func durableModelRequest(
    runId: RunId,
    sessionId: SessionId,
    model: String,
    prompt: String,
    capabilities!: CapabilitySet = CapabilitySet(),
    autoRetry!: Bool = true
): AgentRunRequest {
    AgentRunRequest(
        runId,
        sessionId,
        model,
        prompt,
        capabilities: capabilities,
        budget: ResourceBudget(maxWallMillis: 60000, maxIdleMillis: 60000),
        autoRetry: autoRetry
    )
}

func durableCatalog(
    toolName: String,
    executor: ToolExecutor,
    capability: CapabilityKind
): ToolCatalog {
    let catalog = ToolCatalog()
    expect(catalog.register(
        ToolDescriptor(
            ModelToolDefinition(toolName, "durable crash-window tool", objectValue([])),
            Capability(capability),
            sideEffecting: capability == CapabilityKind.WorkspaceWrite
        ),
        executor
    ).isOk(), "durable tool registration")
    catalog
}

func durableEvents(
    runs: SqliteRunRepository,
    runId: RunId
): ArrayList<AgentEvent> {
    let page = runs.events(runId, 0).value().getOrThrow()
    let events = ArrayList<AgentEvent>()
    for (event in page.events) { events.add(event) }
    events
}

func durableOperationId(database: SqliteDatabase, runId: RunId): OperationId {
    let rows = database.query(
        "SELECT id FROM operations WHERE run_id=" + sqliteText(runId.value) + " ORDER BY id"
    )
    expect(rows.size == 1, "durable trace has one Operation")
    OperationId(rows[0].required(0))
}

func durableRunContinuationCleared(database: SqliteDatabase, runId: RunId): Bool {
    database.scalarInt(
        "SELECT COUNT(*) FROM run_continuations WHERE run_id=" + sqliteText(runId.value)
    ) == 0
}

func durableAttemptRows(database: SqliteDatabase, runId: RunId): Array<SqliteRow> {
    database.query(
        "SELECT id,attempt_no,lifecycle,replay_barrier FROM model_attempts WHERE run_id=" +
            sqliteText(runId.value) + " ORDER BY attempt_no"
    )
}

func durableExpectRecovery(
    actions: Array<RecoveryAction>,
    kind: RecoveryActionKind,
    message: String
): Unit {
    expect(actions.size == 1 && actions[0].kind == kind, message)
}

func durableToolResultCount(database: SqliteDatabase, threadId: ThreadId): Int64 {
    database.scalarInt(
        "SELECT COUNT(*) FROM items WHERE thread_id=" + sqliteText(threadId.value) +
            " AND kind='tool_result'"
    )
}

func durableLaunchWorker(mode: String, root: String): Unit {
    Directory.create(root, recursive: true)
    let marker = root + "/ready"
    let executable = getCommandLine()[0]
    let process = launch(
        executable,
        ["--e0-02-crash-worker", mode, root],
        workingDirectory: Path("."),
        stdIn: ProcessRedirect.Discard,
        stdOut: ProcessRedirect.Discard,
        stdErr: ProcessRedirect.Discard
    )
    var attempts: Int64 = 0
    while (!exists(Path(marker)) && process.isAlive() && attempts < 3000) {
        sleep(Duration.millisecond * 10)
        attempts += 1
    }
    expect(exists(Path(marker)) && process.isAlive(),
        "durable " + mode + " worker reached its crash marker")
    process.terminate(force: true)
    let _ = process.wait()
    expect(!process.isAlive(), "durable " + mode + " worker terminated")
}

func durableModelDispatchWorker(root: String): Int64 {
    let database = SqliteDatabase(durableDatabasePath(root))
    let runs = SqliteRunRepository(database)
    let threadRuntimes = SqliteThreadRuntimeRegistry(
        database,
        ContextProjector("durable-e0-02", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let decisions = SqliteModelDecisionStore(database)
    let operations = DurableOperationStore(database)
    let catalog = ToolCatalog()
    let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds())
    let core = AgentCore(
        DurableCrashDispatchModel(root + "/ready"),
        runs,
        pipeline,
        catalog,
        threadRuntimes: Some(threadRuntimes),
        operationRuntime: Some(operations),
        modelDecisionRuntime: Some(decisions)
    )
    let request = durableModelRequest(
        RunId("durable-model-run"),
        SessionId("durable-model-session"),
        "durable-model",
        "durable semantic prompt"
    )
    let _ = core.start(request)
    while (true) {
        sleep(Duration.second)
    }
    0
}

func durableModelRestartTraceContract(root: String): Unit {
    durableLaunchWorker("model-dispatch", root)
    let database = SqliteDatabase(durableDatabasePath(root))
    let runs = SqliteRunRepository(database)
    let threadRuntimes = SqliteThreadRuntimeRegistry(
        database,
        ContextProjector("durable-e0-02", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let decisions = SqliteModelDecisionStore(database)
    let operations = DurableOperationStore(database)
    let catalog = ToolCatalog()
    let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds())
    let model = DurableResumeAnswerModel()
    let core = AgentCore(
        model,
        runs,
        pipeline,
        catalog,
        threadRuntimes: Some(threadRuntimes),
        operationRuntime: Some(operations),
        modelDecisionRuntime: Some(decisions)
    )
    try {
        let callerRequest = durableModelRequest(
            RunId("durable-model-run"),
            SessionId("durable-model-session"),
            "caller-drift-model",
            "caller drift must not replace the frozen request",
            autoRetry: false
        )
        let resumed = core.resume(callerRequest).value().getOrThrow()
        expect(match (resumed) {
            case AgentRunOutcome.Completed(snapshot) =>
                snapshot.status == RunState.Completed && snapshot.modelRequests == 1
            case _ => false
        }, "durable model restart reaches one completed Run")
        expect(model.calls == 1 && model.lastModel == "durable-model",
            "resume uses the frozen model request rather than caller drift")

        let events = durableEvents(runs, RunId("durable-model-run"))
        let attempts = durableAttemptRows(database, RunId("durable-model-run"))
        expect(attempts.size == 2 && attempts[0].required(2) == "abandoned" &&
            attempts[1].required(2) == "completed" && attempts[0].required(3) == "none" &&
            attempts[1].required(3) == "provider_terminal",
            "durable restart leaves one abandoned attempt and one completed retry")
        expect(eventCount(events, "model.attempt_started") == 2 &&
            eventCount(events, "model.restart_retry_possible_duplicate") == 1 &&
            eventCount(events, "model.request_attempt_completed") == 1 &&
            eventCount(events, "model.attempt_replay_barrier") == 1,
            "durable restart records one replay warning, one completion, and one barrier")

        let a1Policy = eventIndex(events, "model.attempt_policy_applied")
        let a1Dispatch = eventIndexAfter(events, "model.attempt_dispatch_claimed", a1Policy)
        let a1Started = eventIndexAfter(events, "model.attempt_started", a1Dispatch)
        let a2Policy = eventIndexAfter(events, "model.attempt_policy_applied", a1Started)
        let duplicate = eventIndexAfter(events, "model.restart_retry_possible_duplicate", a2Policy)
        let a2Dispatch = eventIndexAfter(events, "model.attempt_dispatch_claimed", duplicate)
        let a2Started = eventIndexAfter(events, "model.attempt_started", a2Dispatch)
        let completed = eventIndexAfter(events, "model.request_attempt_completed", a2Started)
        let barrier = eventIndexAfter(events, "model.attempt_replay_barrier", completed)
        let persisted = eventIndexAfter(events, "model.decision_persisted", barrier)
        let committed = eventIndexAfter(events, "model.decision_committed", persisted)
        let finished = eventIndex(events, "run.completed")
        expect(a1Policy < a1Dispatch && a1Dispatch < a1Started &&
            a2Policy < duplicate && duplicate < a2Dispatch && a2Dispatch < a2Started &&
            a2Started < completed && completed < barrier && barrier < persisted &&
            persisted < committed && committed < finished,
            "durable restart preserves policy, duplicate, dispatch, completion, barrier, and commit order")
        expect(database.scalarInt(
            "SELECT COUNT(*) FROM model_decisions WHERE attempt_id IN " +
                "(SELECT id FROM model_attempts WHERE run_id=" +
                sqliteText("durable-model-run") + ")"
            ) == 1 && database.scalarInt(
            "SELECT COUNT(*) FROM canonical_decision_items WHERE decision_id IN " +
                "(SELECT id FROM model_decisions WHERE attempt_id IN " +
                "(SELECT id FROM model_attempts WHERE run_id=" +
                sqliteText("durable-model-run") + "))"
            ) == 1,
            "durable restart stores one Decision and one canonical projection")
        expect(durableRunContinuationCleared(database, RunId("durable-model-run")),
            "durable restart clears the running-model continuation")
    } finally {
        database.close()
    }
}

func durableToolRequest(): AgentRunRequest {
    durableModelRequest(
        RunId("durable-tool-run"),
        SessionId("durable-tool-session"),
        "durable-tool-model",
        "durable tool result",
        capabilities: durableCapabilitySet(CapabilityKind.WorkspaceWrite)
    )
}

func durableToolPipeline(
    database: SqliteDatabase,
    executor: ToolExecutor
): (ToolCatalog, DurableOperationStore, ToolPipeline) {
    let operations = DurableOperationStore(database)
    let catalog = durableCatalog("durable_write", executor, CapabilityKind.WorkspaceWrite)
    let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds())
    (catalog, operations, pipeline)
}

func durableReceiptWorker(root: String): Int64 {
    let database = SqliteDatabase(durableDatabasePath(root))
    let runs = SqliteRunRepository(database)
    let threadRuntimes = SqliteThreadRuntimeRegistry(
        database,
        ContextProjector("durable-e0-02", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let decisions = SqliteModelDecisionStore(database)
    let effectPath = root + "/effect-count"
    let executor = DurableReceiptCrashTool(
        effectPath,
        root + "/ready",
        blockAfterPersisted: true
    )
    let (catalog, operations, pipeline) = durableToolPipeline(database, executor)
    let core = AgentCore(
        DurableToolCallModel("durable_write"),
        runs,
        pipeline,
        catalog,
        threadRuntimes: Some(threadRuntimes),
        operationRuntime: Some(operations),
        modelDecisionRuntime: Some(decisions)
    )
    let pending = core.start(durableToolRequest()).value().getOrThrow()
    let approval = match (pending) {
        case AgentRunOutcome.AwaitingApproval(_, value) => value
        case _ => throw IllegalStateException("durable receipt worker did not pause for approval")
    }
    let _ = core.decide(durableToolRequest(), approval, ApprovalDecision.Approve)
    while (true) {
        sleep(Duration.second)
    }
    0
}

func durableCommittedReceiptReplayTraceContract(root: String): Unit {
    durableLaunchWorker("tool-result", root)
    expect(durableEffectCount(root + "/effect-count") == 1,
        "durable receipt worker performs its side effect once")
    let database = SqliteDatabase(durableDatabasePath(root))
    let operations = DurableOperationStore(database)
    let effectPath = root + "/effect-count"
    let catalog = durableCatalog(
        "durable_write",
        DurableReceiptCrashTool(effectPath, root + "/unused"),
        CapabilityKind.WorkspaceWrite
    )
    let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds())
    let context = ToolInvocationContext(
        RunId("durable-tool-run"),
        SessionId("durable-tool-session"),
        durableCapabilitySet(CapabilityKind.WorkspaceWrite)
    )
    let operationId = durableOperationId(database, RunId("durable-tool-run"))
    try {
        let first = pipeline.decide(context, operationId, ApprovalDecision.Approve)
        let second = pipeline.decide(context, operationId, ApprovalDecision.Approve)
        expect(first.isOk() && second.isOk(),
            "durable committed receipt is replayable through the public pipeline")
        let firstResult = match (first.value().getOrThrow()) {
            case ToolInvocationResult.Completed(value) => value
            case _ => throw IllegalStateException("first durable receipt replay was not completed")
        }
        let secondResult = match (second.value().getOrThrow()) {
            case ToolInvocationResult.Completed(value) => value
            case _ => throw IllegalStateException("second durable receipt replay was not completed")
        }
        expect(firstResult.callId == secondResult.callId &&
            encodeStoredValue(firstResult.output) == encodeStoredValue(secondResult.output) &&
            firstResult.isError == secondResult.isError &&
            firstResult.receiptId == secondResult.receiptId &&
            durableEffectCount(effectPath) == 1,
            "replayed receipt returns identical canonical output without re-execution")
        expect(database.scalarInt(
            "SELECT COUNT(*) FROM operations WHERE id=" + sqliteText(operationId.value)
        ) == 1 && database.scalarInt(
            "SELECT COUNT(*) FROM approvals WHERE operation_id=" + sqliteText(operationId.value)
        ) == 1 && database.scalarInt(
            "SELECT COUNT(*) FROM operation_receipts WHERE operation_id=" +
                sqliteText(operationId.value)
        ) == 1 && database.scalarInt(
            "SELECT COUNT(*) FROM audit_events WHERE operation_id=" +
                sqliteText(operationId.value) + " AND kind='operation_execution_handoff'"
        ) == 1 && durableToolResultCount(database, ThreadId("durable-tool-session")) == 1,
            "durable receipt replay preserves one Operation, approval, handoff, receipt, and ToolResult")
    } finally {
        database.close()
    }
}

func durableEffectWorker(root: String): Int64 {
    let database = SqliteDatabase(durableDatabasePath(root))
    let runs = SqliteRunRepository(database)
    let threadRuntimes = SqliteThreadRuntimeRegistry(
        database,
        ContextProjector("durable-e0-02", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let decisions = SqliteModelDecisionStore(database)
    let operations = DurableOperationStore(database)
    let effectPath = root + "/effect-count"
    let catalog = durableCatalog(
        "durable_effect",
        DurableUnknownEffectTool(effectPath, root + "/ready"),
        CapabilityKind.WorkspaceWrite
    )
    let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds())
    let core = AgentCore(
        DurableToolCallModel("durable_effect"),
        runs,
        pipeline,
        catalog,
        threadRuntimes: Some(threadRuntimes),
        operationRuntime: Some(operations),
        modelDecisionRuntime: Some(decisions)
    )
    let pending = core.start(durableToolRequest()).value().getOrThrow()
    let approval = match (pending) {
        case AgentRunOutcome.AwaitingApproval(_, value) => value
        case _ => throw IllegalStateException("durable effect worker did not pause for approval")
    }
    let _ = core.decide(durableToolRequest(), approval, ApprovalDecision.Approve)
    while (true) {
        sleep(Duration.second)
    }
    0
}

func durableUnknownEffectTraceContract(root: String): Unit {
    durableLaunchWorker("tool-effect", root)
    expect(durableEffectCount(root + "/effect-count") == 1,
        "durable unknown-effect worker applies its side effect once")
    let database = SqliteDatabase(durableDatabasePath(root))
    let operations = DurableOperationStore(database)
    let effectPath = root + "/effect-count"
    let catalog = durableCatalog(
        "durable_effect",
        DurableUnknownEffectTool(effectPath, root + "/unused"),
        CapabilityKind.WorkspaceWrite
    )
    let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds())
    let context = ToolInvocationContext(
        RunId("durable-tool-run"),
        SessionId("durable-tool-session"),
        durableCapabilitySet(CapabilityKind.WorkspaceWrite)
    )
    let operationId = durableOperationId(database, RunId("durable-tool-run"))
    try {
        durableExpectRecovery(
            OperationRecoveryPlanner(database).inspect(ThreadId("durable-tool-session")),
            RecoveryActionKind.RequireUnknownOutcomeReconciliation,
            "durable unknown effect requires explicit reconciliation"
        )
        let registry = SqliteThreadRuntimeRegistry(
            database,
            ContextProjector("durable-e0-02", ConservativeThreadTokenEstimator()),
            { => agentUtcMillis() }
        )
        let recovered = registry.recover(
            ThreadId("durable-tool-session"), "durable-tool-workspace"
        )
        expect(recovered.isError() && recovered.error().getOrThrow().code ==
            "thread.recovery_actions_pending",
            "durable Thread recovery refuses an unknown-effect Operation")
        let replay = pipeline.decide(context, operationId, ApprovalDecision.Approve)
        expect(replay.isError() && replay.error().getOrThrow().code ==
            "operation.execution_prepare_failed",
            "unknown-effect Operation cannot be blindly retried")
        expect(durableEffectCount(effectPath) == 1 && database.scalarInt(
            "SELECT COUNT(*) FROM operation_receipts WHERE operation_id=" +
                sqliteText(operationId.value)
        ) == 0 && durableToolResultCount(database, ThreadId("durable-tool-session")) == 0,
            "unknown-effect recovery preserves one side effect and no fabricated receipt")
        durableExpectRecovery(
            OperationRecoveryPlanner(database).inspect(ThreadId("durable-tool-session")),
            RecoveryActionKind.RequireUnknownOutcomeReconciliation,
            "unknown-effect recovery action remains stable after rejected replay"
        )
    } finally {
        database.close()
    }
}

func durableCoreTrajectoriesContract(): Unit {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    try {
        durableModelRestartTraceContract(root + "/model")
        durableCommittedReceiptReplayTraceContract(root + "/receipt")
        durableUnknownEffectTraceContract(root + "/effect")
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func maybeRunDurableCoreTraceWorker(): ?Int64 {
    let args = getCommandLine()
    if (args.size != 4 || args[1] != "--e0-02-crash-worker") { return None }
    match (args[2]) {
        case "model-dispatch" => Some(durableModelDispatchWorker(args[3]))
        case "tool-result" => Some(durableReceiptWorker(args[3]))
        case "tool-effect" => Some(durableEffectWorker(args[3]))
        case _ => throw IllegalArgumentException("unknown durable crash worker mode")
    }
}
