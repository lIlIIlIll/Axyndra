package agent_core_contract

import yjson_support.*
import yjson.*
import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
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

    public func transcriptSnapshot(request: ModelRequest): ?String {
        let _ = request.requestId
        Some("durable-model-transcript-v1")
    }

    public func validateTranscriptSnapshot(snapshot: String): Bool {
        snapshot == "durable-model-transcript-v1"
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

    public func transcriptSnapshot(request: ModelRequest): ?String {
        let _ = request.requestId
        Some("durable-model-transcript-v1")
    }

    public func validateTranscriptSnapshot(snapshot: String): Bool {
        snapshot == "durable-model-transcript-v1"
    }

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

func durableContextPayload(database: SqliteDatabase, runId: RunId): String {
    let rows = database.query("SELECT payload FROM run_continuations WHERE run_id=?", [SqlParameter.Text(runId.value)])
    expect(rows.size == 1, "context fault injection identifies exactly one persisted continuation")
    rows[0].required(0)
}

func durableReplaceContextPayload(database: SqliteDatabase, runId: RunId, previous: String, replacement: String): Unit {
    expect(durableContextPayload(database, runId) == previous, "context fixture CAS starts from the exact retained bytes")
    database.execute("UPDATE run_continuations SET payload=? WHERE run_id=? AND payload=?",
        [SqlParameter.Text(replacement), SqlParameter.Text(runId.value), SqlParameter.Text(previous)])
    expect(durableContextPayload(database, runId) == replacement, "context fixture CAS changes only the identified payload")
}

func durableInjectFutureContext(
    database: SqliteDatabase, runs: SqliteRunRepository, runId: RunId, schema: String
): (String, String) {
    let original = durableContextPayload(database, runId)
    let frozen = runs.continuation(runId).value().getOrThrow()
    frozen.contextSnapshotPayload.put("schema", textValue(schema))
    let refusedWrite = runs.saveContinuation(frozen)
    let actual = match (refusedWrite.error()) { case Some(error) => error.describe(); case None => "unexpected successful write" }
    expect(refusedWrite.isError() && refusedWrite.error().getOrThrow().code == "persistence.conflict",
        "ordinary persistence must reject changing a sealed context binding: " + actual)
    expect(durableContextPayload(database, runId) == original,
        "rejected ordinary context write preserves the original continuation bytes")

    // Historical corruption is injected through one exact SQL row, not an authorized repository transition.
    // Re-seal the public outer codec so recovery actually reaches the unsupported inner context schema.
    let durable = decodeDurableRunContinuation(original)
    let snapshot = optionalRunRequestSnapshotFromDurableContinuation(durable).getOrThrow()
    snapshot.field("skill_stack").getOrThrow().put("schema", textValue(schema))
    let changed = encodeDurableRunContinuation(withRunRequestSnapshotProjection(durable, snapshot))
    let checked = decodeDurableRunContinuation(changed)
    expect(changed != original && encodeDurableRunContinuation(checked) == changed &&
        optionalRunRequestSnapshotFromDurableContinuation(checked).getOrThrow()
            .field("skill_stack").getOrThrow().field("schema").getOrThrow().text == schema,
        "future context fixture remains a valid sealed outer continuation with the exact changed inner schema")
    durableReplaceContextPayload(database, runId, original, changed)
    println("Durable future context fixture: canonical write rejected persistence.conflict; exact sealed history injected")
    (original, changed)
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
        let (original, preserved) = durableInjectFutureContext(
            database, runs, callerRequest.runId, "axyndra.run-context/future")
        let attemptsBefore = database.scalarInt("SELECT COUNT(*) FROM model_attempts")
        let refused = core.resume(callerRequest)
        expect(refused.isError() && refused.error().getOrThrow().kind == AgentErrorKind.RecoveryRequired &&
            refused.error().getOrThrow().code == "context.snapshot_unsupported_or_invalid",
            "unsupported context returns typed model recovery error without throwing")
        expect(model.calls == 0 && database.scalarInt("SELECT COUNT(*) FROM model_attempts") == attemptsBefore &&
            database.query("SELECT payload FROM run_continuations WHERE run_id='durable-model-run'")[0].required(0) == preserved,
            "unsupported model context preserves historical continuation and creates no provider IO or Attempt")
        durableReplaceContextPayload(database, callerRequest.runId, preserved, original)
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
        let settledRows = database.query(
            "SELECT phase,active_attempt_id,payload,digest FROM run_continuations " +
                "WHERE run_id='durable-model-run'")
        expect(settledRows.size == 1 && settledRows[0].required(0) == "checkpoint" &&
            settledRows[0][1].isNone(), "durable restart retains one inactive checkpoint")
        let settled = decodeDurableRunContinuation(settledRows[0].required(2))
        expect(settled.isSealed() && settled.digest == settledRows[0].required(3) &&
            settled.runId.value == "durable-model-run" &&
            runExecutionPhaseName(settled.phase) == "checkpoint" &&
            settled.attemptId.isNone() && settled.pendingOperationId.isNone() &&
            settled.pendingApprovalId.isNone() && settled.waitingExternal.isNone() &&
            settled.toolBatch.isNone() && settled.workDebt.isEmpty(),
            "durable settled checkpoint has no executable attempt or foreground debt")
        let proof = database.query(
            "SELECT a.id,d.id FROM model_attempts a JOIN model_decisions d ON d.attempt_id=a.id " +
                "WHERE a.run_id='durable-model-run' AND a.lifecycle='completed' " +
                "AND a.completed_at_millis IS NOT NULL AND d.validation_status='validated' " +
                "AND d.canonical_committed_at_millis IS NOT NULL")
        expect(proof.size == 1 && proof[0].required(0) == attempts[1].required(0),
            "durable settled checkpoint refers to the actual completed retry and committed Decision")
        let phase = runExecutionPhasePayload(settled.phase)
        expect(phase.field("settled_model_attempt_id").getOrThrow().text == proof[0].required(0) &&
            phase.field("committed_decision_id").getOrThrow().text == proof[0].required(1),
            "durable checkpoint binds the exact completed Attempt and Decision")
        let audit = database.query("SELECT payload FROM audit_events " +
            "WHERE run_id='durable-model-run' AND kind='model_continuation_settled'")
        expect(audit.size == 1 && audit[0].required(0) == encodeStoredValue(objectValue([
            ValueField("attempt_id", textValue(proof[0].required(0))),
            ValueField("decision_id", textValue(proof[0].required(1)))])),
            "durable settlement audit agrees exactly with the checkpoint proof")
        let reopened = SqliteDatabase(durableDatabasePath(root))
        try {
            let pending = SqliteRunRepository(reopened).pendingRecoveryContinuation(SessionId("durable-model-session"))
            expect(pending.isOk() && pending.value().getOrThrow().isNone(),
                "reopened repository exposes no settled model execution for recovery")
        } finally { reopened.close() }
        let repeated = core.resume(callerRequest)
        expect(repeated.isError() && model.calls == 1 &&
            durableAttemptRows(database, RunId("durable-model-run")).size == 2 &&
            database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE attempt_id IN " +
                "(SELECT id FROM model_attempts WHERE run_id='durable-model-run')") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE run_id='durable-model-run' " +
                "AND kind='model_continuation_settled'") == 1 &&
            database.query("SELECT payload FROM run_continuations WHERE run_id='durable-model-run'")[0].required(0) ==
                settledRows[0].required(2),
            "resuming a settled checkpoint refuses replay without model, Decision or checkpoint mutation")
        println("Durable settled model checkpoint contract passed: sealed proof, reopened recovery and no replay")
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
    let (original, preserved) = durableInjectFutureContext(
        database, runs, durableToolRequest().runId, "legacy.nonempty.skill.snapshot")
    let approvalsBefore = database.scalarInt("SELECT COUNT(*) FROM approvals")
    let refused = core.decide(durableToolRequest(), approval, ApprovalDecision.Approve)
    expect(refused.isError() && refused.error().getOrThrow().code == "context.snapshot_unsupported_or_invalid",
        "unsupported context returns typed approval recovery error before consuming decision")
    expect(database.scalarInt("SELECT COUNT(*) FROM approvals") == approvalsBefore &&
        database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0 && !exists(Path(effectPath)) &&
        database.query("SELECT payload FROM run_continuations WHERE run_id='durable-tool-run'")[0].required(0) == preserved,
        "invalid context cannot consume actual pending approval, write effect, Receipt or historical bytes")
    durableReplaceContextPayload(database, durableToolRequest().runId, preserved, original)
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
        // The same genuinely killed, once-effectful operation must not become
        // resumable merely because a request/budget projection can be inspected.
        let boundaryRuns = SqliteRunRepository(database)
        let boundaryModel = DurableResumeAnswerModel()
        let boundaryCore = AgentCore(boundaryModel, boundaryRuns, pipeline, catalog,
            threadRuntimes: Some(registry), operationRuntime: Some(operations),
            modelDecisionRuntime: Some(SqliteModelDecisionStore(database)))
        expect(boundaryCore.resumeContextBoundary(durableToolRequest(), { _ => () }).isError() &&
            boundaryModel.calls == 0 && durableEffectCount(effectPath) == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0,
            "context-boundary recovery never replays actual unknown effect or fabricates Receipt107")
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

// ModelPort supplies deterministic failure/reply DATA; Core, Thread, Attempts,
// continuation commits and reopened consumer below are actual SQLite paths.
class DurableTerminalConsumerModel <: ModelPort {
    private let runs: SqliteRunRepository
    private let expected: AgentRunRequest
    private let failed: Bool
    var calls: Int64 = 0
    init(runs: SqliteRunRepository, expected: AgentRunRequest, failed!: Bool = true) {
        this.runs = runs; this.expected = expected; this.failed = failed
    }
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let _ = request; let _ = events
        calls++
        let pending = runs.pendingRecoveryContinuation(expected.sessionId).value().getOrThrow()
        expect(pending.isSome() && pending.getOrThrow().runId.value == expected.runId.value &&
            pending.getOrThrow().kind == RunContinuationKind.RunningModel,
            "actual nonterminal Model owner remains an eligible recovery continuation")
        if (failed) {
            return Result.Err(AgentError(AgentErrorKind.Transport, "fixture.terminal_model_failure",
                "deterministic provider failure data", retryable: false))
        }
        Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "durable recovery complete")],
            stopReason: "end_turn", providerId: "durable-recovery", responseId: "durable-recovery-response"))
    }
}

func durableTerminalFailedModelHistory(root: String): (String, String) {
    Directory.create(root, recursive: true)
    let database = SqliteDatabase(durableDatabasePath(root))
    let runs = SqliteRunRepository(database)
    let operations = DurableOperationStore(database)
    let catalog = ToolCatalog()
    let request = durableModelRequest(RunId("terminal-model-run"), SessionId("terminal-model-session"),
        "durable-model", "preserve the actual failed request", autoRetry: false)
    let model = DurableTerminalConsumerModel(runs, request)
    let core = AgentCore(model, runs, ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds()), catalog,
        threadRuntimes: Some(SqliteThreadRuntimeRegistry(database,
            ContextProjector("durable-e0-02", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })),
        operationRuntime: Some(operations), modelDecisionRuntime: Some(SqliteModelDecisionStore(database)))
    try {
        let outcome = core.start(request)
        expect(outcome.isError() && outcome.error().getOrThrow().code == "fixture.terminal_model_failure" &&
            model.calls == 1, "the real Core settles one failed Model Attempt without retry")
        expect(database.query("SELECT state FROM runs WHERE id='terminal-model-run'")[0].required(0) == "failed" &&
            database.query("SELECT active_turn_id FROM threads WHERE id='terminal-model-session'")[0][0].isNone(),
            "actual canonical terminal Run has no live Thread owner")
        let history = database.query("SELECT payload,digest FROM run_continuations WHERE run_id='terminal-model-run'")
        expect(history.size == 1 && database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE run_id='terminal-model-run' AND lifecycle='failed'") == 1,
            "failure keeps its original continuation and actual failed Attempt")
        (history[0].required(0), history[0].required(1))
    } finally { database.close() }
}

func durableTerminalModelContinuationContract(root: String): Unit {
    let (payload, digest) = durableTerminalFailedModelHistory(root)
    let database = SqliteDatabase(durableDatabasePath(root))
    let runs = SqliteRunRepository(database)
    let operations = DurableOperationStore(database)
    let catalog = ToolCatalog()
    let request = durableModelRequest(RunId("new-model-run"), SessionId("terminal-model-session"),
        "durable-model", "a new legitimate user intent", autoRetry: false)
    let model = DurableTerminalConsumerModel(runs, request, failed: false)
    let core = AgentCore(model, runs, ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds()), catalog,
        threadRuntimes: Some(SqliteThreadRuntimeRegistry(database,
            ContextProjector("durable-e0-02", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })),
        operationRuntime: Some(operations), modelDecisionRuntime: Some(SqliteModelDecisionStore(database)))
    try {
        let pending = runs.pendingRecoveryContinuation(SessionId("terminal-model-session"))
        expect(pending.isOk() && pending.value().getOrThrow().isNone() && model.calls == 0,
            "reopened SQLite consumer skips a terminal failed continuation without replay")
        let preserved = database.query("SELECT payload,digest FROM run_continuations WHERE run_id='terminal-model-run'")
        expect(preserved.size == 1 && preserved[0].required(0) == payload && preserved[0].required(1) == digest,
            "selection preserves byte-exact historical continuation data")
        let outcome = core.start(request).value().getOrThrow()
        expect(match (outcome) { case AgentRunOutcome.Completed(snapshot) => snapshot.runId.value == "new-model-run"
            case _ => false }, "the same canonical Thread admits and completes a distinct new Run")
        expect(model.calls == 1 && database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE run_id='terminal-model-run'") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE run_id='new-model-run' AND lifecycle='completed'") == 1,
            "new intent dispatches once; the original failed Attempt is never retried or replaced")
        let after = database.query("SELECT payload,digest FROM run_continuations WHERE run_id='terminal-model-run'")
        expect(after.size == 1 && after[0].required(0) == payload && after[0].required(1) == digest,
            "the new Run leaves original continuation bytes and version binding unchanged")
    } finally { database.close() }
}

func durableCoreTrajectoriesContract(): Unit {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    try {
        durableTerminalModelContinuationContract(root + "/terminal-model")
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
