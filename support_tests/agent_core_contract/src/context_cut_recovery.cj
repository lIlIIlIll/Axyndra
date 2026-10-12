package agent_core_contract

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*
import std.time.*
import yjson.*
import yjson_support.*

// Test-only barrier after a genuine commit. The external controller SIGKILLs
// this process and opens this same WAL in a new process; no catch simulates it.
class CutRecoveryBarrier {
    let phase: String
    let marker: String
    init(phase: String, marker: String) { this.phase = phase; this.marker = marker }
    func reached(name: String): Unit {
        if (phase != name) { return }
        File.writeTo(marker, name.toArray())
        while (true) { sleep(Duration.millisecond * 10) }
    }
}

class CutRecoveryCommitSink <: ThreadCommitSink {
    let actual: SqliteThreadCommitSink
    let barrier: CutRecoveryBarrier
    init(actual: SqliteThreadCommitSink, barrier: CutRecoveryBarrier) { this.actual = actual; this.barrier = barrier }
    public func commit(transition: ThreadTransition): Result<Unit> {
        match (actual.commit(transition)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (transition.modelLaneChange.isSome()) { barrier.reached("after_safe_cut") }
        Result.Ok(())
    }
    public func recordOperationReceipt(run: RunId, receipt: VNextOperationReceipt): Result<Unit> { actual.recordOperationReceipt(run, receipt) }
    public func recordRunTransition(thread: ThreadId, turn: SemanticTurnId, run: RunId, epoch: Int64,
        transition: RunTransition, observedAt: Int64): Result<Unit> {
        actual.recordRunTransition(thread, turn, run, epoch, transition, observedAt)
    }
    public func recordModelUsage(sample: RunModelUsageSample): Result<Unit> { actual.recordModelUsage(sample) }
}

// Only the initial process wraps the actual commit sink to expose a barrier.
// Restart recovery delegates to the unmodified real SQLite Runtime registry.
class CutRecoveryThreadRegistry <: ThreadRuntimeRegistry {
    let database: SqliteDatabase
    let barrier: CutRecoveryBarrier
    let projector = ContextProjector("context-cut-recovery", ConservativeThreadTokenEstimator())
    let restored: SqliteThreadRuntimeRegistry
    var initial: ?AgentThreadRuntime = None
    init(database: SqliteDatabase, barrier: CutRecoveryBarrier) {
        this.database = database; this.barrier = barrier
        this.restored = SqliteThreadRuntimeRegistry(database, projector, { => agentUtcMillis() })
    }
    public func acquire(thread: ThreadId, workspace: String): Result<AgentThreadRuntime> {
        match (initial) { case Some(value) => return Result.Ok(value); case None => () }
        if (database.scalarInt("SELECT COUNT(*) FROM threads") != 0) { return restored.acquire(thread, workspace) }
        let actual = SqliteThreadCommitSink(database)
        let snapshot = actual.createThread(thread, workspace)
        let runtime = AgentThreadRuntime(ThreadCoordinator(snapshot, CutRecoveryCommitSink(actual, barrier)), projector,
            { => agentUtcMillis() }, checkpointRepository: Some(SqliteContextCheckpointStore(database)))
        initial = Some(runtime); Result.Ok(runtime)
    }
    public func recover(thread: ThreadId, workspace: String): Result<AgentThreadRuntime> { restored.recover(thread, workspace) }
    public func releaseInactive(thread: ThreadId): Result<Bool> { restored.releaseInactive(thread) }
    public func discardInactive(thread: ThreadId): Result<Bool> { restored.discardInactive(thread) }
}

class CutRecoveryInteractions <: AgentInteractionSource {
    var pending = false
    public func takeSteering(): Array<AgentQueuedInput> {
        if (!pending) { return [] }; pending = false
        [AgentQueuedInput("ACCEPTED_BEFORE_CRASH", correlationId: "recovery-canonical-input", kind: "steer")]
    }
    public func hasSteering(): Bool { pending }
    public func takeFollowUps(): Array<AgentQueuedInput> { [] }
    public func interruptMode(): RunInterruptMode { RunInterruptMode.Wait }
}

class CutRecoveryModel <: ModelPort {
    let database: SqliteDatabase
    let threads: ThreadRuntimeRegistry
    let interactions: CutRecoveryInteractions
    var calls: Int64 = 0
    init(database: SqliteDatabase, threads: ThreadRuntimeRegistry, interactions: CutRecoveryInteractions) {
        this.database = database; this.threads = threads; this.interactions = interactions
    }
    public func transcriptSnapshot(request: ModelRequest): ?String { Some("context-cut-recovery-adapter-v1") }
    public func validateTranscriptSnapshot(value: String): Bool { value == "context-cut-recovery-adapter-v1" }
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls += 1
        if (database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0) {
            let runtime = threads.acquire(ThreadId("cut-recovery-thread"), "").value().getOrThrow()
            let active = runtime.activeRun().getOrThrow()
            runtime.queueContextSnapshot(active.runId, active.epoch, contextReadProjectionDigest(active.contextSnapshot),
                selectedCutContext("RECOVERED_CONTEXT")).value().getOrThrow()
            interactions.pending = true
            return Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.ToolCall, callId: "cut-recovery-call",
                name: "context_probe", arguments: objectValue([]))]))
        }
        expect(request.system.contains("RECOVERED_CONTEXT") && !request.system.contains("ORIGINAL_CONTEXT"),
            "new model request uses the current actual applied context")
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "context boundary resumed")], stopReason: "end_turn"))
    }
}

class CutRecoveryManifest <: ModelContextManifestRuntimePort {
    let actual: ContextCutManifest
    let database: SqliteDatabase
    let barrier: CutRecoveryBarrier
    init(database: SqliteDatabase, path: String, barrier: CutRecoveryBarrier) {
        this.actual = ContextCutManifest(database, path); this.database = database; this.barrier = barrier
    }
    public func recordBeforeModelEffect(request: AgentRunRequest, requestId: RequestId,
        turnId: SemanticTurnId, laneId: LaneId, stepId: StepId, ordinal: Int64, projection: ModelContextProjection,
        lane: ModelLane, rendered: AgentValue, estimated: Int64, observed: Int64): Result<Unit> {
        match (actual.recordBeforeModelEffect(request, requestId, turnId, laneId, stepId, ordinal,
            projection, lane, rendered, estimated, observed)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == 1) {
            barrier.reached("after_context_ready") }
        Result.Ok(())
    }
}

func maybeRunContextCutRecoveryWorker(): ?Int64 {
    let args = getCommandLine()
    if (args.size != 6 || args[1] != "--context-cut-recovery-worker") { return None }
    let mode = args[2]; let phase = args[3]; let path = args[4]; let marker = args[5]
    let database = SqliteDatabase(path)
    try {
        let barrier = CutRecoveryBarrier(if (mode == "start") { phase } else { "" }, marker)
        let threads = CutRecoveryThreadRegistry(database, barrier)
        let interactions = CutRecoveryInteractions()
        let model = CutRecoveryModel(database, threads, interactions)
        let catalog = ToolCatalog(); let probe = CutContextTool()
        catalog.register(ToolDescriptor(ModelToolDefinition("context_probe", "real context probe", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead), implementationVersion: "cut-recovery-v1",
            implementationFingerprint: "cut-recovery-v1"), probe).value().getOrThrow()
        let runs = SqliteRunRepository(database); let operations = DurableOperationStore(database)
        let core = AgentCore(model, runs, ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds()), catalog,
            threadRuntimes: Some(threads), operationRuntime: Some(operations), modelDecisionRuntime: Some(SqliteModelDecisionStore(database)),
            contextManifestRuntime: Some(CutRecoveryManifest(database, path, barrier)))
        let request = AgentRunRequest(RunId("cut-recovery-run"), SessionId("cut-recovery-thread"), "fixture", "recover at applied context cut",
            contextSnapshot: selectedCutContext("ORIGINAL_CONTEXT"), capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
            interactions: if (mode == "start") { Some(interactions) } else { None },
            budget: ResourceBudget(maxTurns: 4, maxConcurrentTools: 1, maxToolCalls: 2))
        let sink: AgentEventSink = { event =>
            match (event.payload) {
                case AgentEventPayload.BudgetUpdated(usage) => if (usage.turns == 2) { barrier.reached("after_turn_reserved") }
                case AgentEventPayload.Extension(_, detail) => match (detail.field("code")) {
                    case Some(value) => if (value.unifiedKind == ValueKind.Text && value.text == "interaction.injected") {
                        barrier.reached("after_canonical_input") }
                    case None => () }
                case _ => () }
        }
        if (mode == "start") {
            let value = core.start(request, sink)
            throw IllegalStateException("crash barrier was not reached: " + match (value) {
                case Result.Err(error) => error.describe(); case Result.Ok(_) => "completed" })
        }
        if (mode == "cancel") {
            let runtime = threads.recover(ThreadId(request.sessionId.value), "").value().getOrThrow()
            let active = runtime.activeRun().getOrThrow()
            runtime.cancel(1000, expectedRunId: Some(active.runId), expectedEpoch: Some(active.epoch)).value().getOrThrow()
        }
        let pending = runs.pendingContextBoundary(request.sessionId)
        if (mode == "cancel" || mode == "tampered") {
            expect(pending.isError() || pending.value().getOrThrow().isNone(), "cancelled/tampered boundary fails closed")
            expect(core.resumeContextBoundary(request, sink).isError() && model.calls == 0 && probe.contexts.isEmpty(),
                "data cannot recreate cancelled or tampered authority")
            println("Context boundary negative reopen passed"); return Some(0)
        }
        let boundary = pending.value().getOrThrow().getOrThrow()
        if (mode == "concurrent") {
            File.writeTo(marker, "ready-after-actual-boundary-read".toArray())
            let gate = path + ".race-go"
            let deadline = MonoTime.now() + Duration.second * 55
            while (!exists(Path(gate)) && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
            expect(exists(Path(gate)), "two actual reopen processes meet before resume within original sixty seconds")
        }
        let restored = coreContextBoundaryRequestFromValue(contextBoundaryField(boundary.data(), "request"))
        expect(runs.pendingRecoveryContinuation(request.sessionId).value().getOrThrow().isNone(),
            "a settled context marker never pretends to be old RunningModel")
        match (core.resumeContextBoundary(restored, sink)) {
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                expect(snapshot.turns == 2 && snapshot.modelRequests == 2 && snapshot.toolCalls == 1,
                    "turn/model/tool accounting is exact across a physically killed process")
            case Result.Err(error) =>
                if (mode == "concurrent") {
                    expect(model.calls == 0 && probe.contexts.isEmpty(), "losing current/CAS claimant performs zero provider or tool effects")
                    println("Context boundary concurrent loser: " + error.code)
                    return Some(0)
                }
                throw IllegalStateException(error.describe())
            case _ => throw IllegalStateException("resume did not complete the same actual Run") }
        expect(model.calls == 1 && probe.contexts.isEmpty() && database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 1,
            "no old tool, old Attempt, or second Receipt was replayed")
        expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 2 && database.scalarInt(
            "SELECT COUNT(*) FROM model_attempts WHERE semantic_request_id='semantic-cut-recovery-run-model-2' AND attempt_no=1") == 1,
            "exactly one new semantic Attempt used the original unique prepare/claim path")
        expect(runs.pendingContextBoundary(request.sessionId).value().getOrThrow().isNone(), "terminal same Run retains no resumable context marker")
        println("Context boundary physical reopen passed: " + phase)
        Some(0)
    } finally { database.close() }
}


// Original typed event decoder and Store JSON verifier inspect the actual
// BudgetUpdated written by Core/SqliteRunRepository, not a test-made payload.
class CutRecoveryBudgetRoundTripManifest107 <: ModelContextManifestRuntimePort {
    let actual: ContextCutManifest
    let database: SqliteDatabase
    let path: String
    var checked = false
    init(database: SqliteDatabase, path: String) {
        this.actual = ContextCutManifest(database, path); this.database = database; this.path = path
    }
    public func recordBeforeModelEffect(request: AgentRunRequest, requestId: RequestId,
        turnId: SemanticTurnId, laneId: LaneId, stepId: StepId, ordinal: Int64, projection: ModelContextProjection,
        lane: ModelLane, rendered: AgentValue, estimated: Int64, observed: Int64): Result<Unit> {
        match (actual.recordBeforeModelEffect(request, requestId, turnId, laneId, stepId, ordinal,
            projection, lane, rendered, estimated, observed)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == 1 && !checked) {
            let reopened = SqliteDatabase(path)
            try {
                let repository = SqliteRunRepository(reopened)
                let boundary = repository.contextBoundary(request.runId).value().getOrThrow().getOrThrow()
                let expected = contextBoundaryUsage(contextBoundaryField(boundary.data(), "usage"))
                let decoded = repository.events(request.runId, 0).value().getOrThrow()
                var typedBudgetCount: Int64 = 0
                var matchingBudget = false
                for (event in decoded.events) {
                    match (event.payload) { case AgentEventPayload.BudgetUpdated(usage) =>
                        typedBudgetCount += 1
                        matchingBudget = canonicalAgentValue(executionUsageValue(usage)) == canonicalAgentValue(executionUsageValue(expected))
                        case _ => () }
                }
                expect(typedBudgetCount > 0 && matchingBudget,
                    "original app event decoder reads the exact genuine current BudgetUpdated after cut/reopen")
                reopened.transaction { tx => requireContextBoundaryBudget(tx, request.runId, executionUsageValue(expected)) }
                expect(boundary.continuation.runId.value == request.runId.value &&
                    contextBoundaryText(boundary.data(), "point") == "turn_reserved" &&
                    repository.pendingRecoveryContinuation(request.sessionId).value().getOrThrow().isNone(),
                    "budget data never supplies old RunningModel execution authority")
                checked = true
            } finally { reopened.close() }
        }
        Result.Ok(())
    }
}

func coreContextBoundaryBudgetJsonReopenContract107(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let path = root + "/cut.db"
    let database = SqliteDatabase(path)
    try {
        let threads = SqliteThreadRuntimeRegistry(database,
            ContextProjector("context-cut-recovery-json107", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
        let interactions = CutRecoveryInteractions()
        let model = CutRecoveryModel(database, threads, interactions)
        let catalog = ToolCatalog(); let probe = CutContextTool()
        catalog.register(ToolDescriptor(ModelToolDefinition("context_probe", "real context probe", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead), implementationVersion: "cut-recovery-v1",
            implementationFingerprint: "cut-recovery-v1"), probe).value().getOrThrow()
        let runs = SqliteRunRepository(database); let operations = DurableOperationStore(database)
        let manifests = CutRecoveryBudgetRoundTripManifest107(database, path)
        let core = AgentCore(model, runs, ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds()), catalog,
            threadRuntimes: Some(threads), operationRuntime: Some(operations),
            modelDecisionRuntime: Some(SqliteModelDecisionStore(database)), contextManifestRuntime: Some(manifests))
        let request = AgentRunRequest(RunId("cut-recovery-run"), SessionId("cut-recovery-thread"), "fixture", "original event codec after actual cut",
            contextSnapshot: selectedCutContext("ORIGINAL_CONTEXT"), capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
            interactions: Some(interactions), budget: ResourceBudget(maxTurns: 4, maxConcurrentTools: 1, maxToolCalls: 2))
        expect(core.start(request).isOk() && manifests.checked && model.calls == 2,
            "actual BudgetUpdated write, legal cut and closed/reopened SQLite are a runnable positive")
        expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 2 &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 1 && probe.contexts.size == 1,
            "event codec repair never replays old Attempt/Tool/Receipt or creates a replacement Run")
    } finally { database.close(); remove(root, recursive: true) }
    println("Core context boundary original BudgetUpdated JSON reopen contract passed107")
}
