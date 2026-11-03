package agent_core_contract

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

func selectedCutContext(text: String): InvocationContextProjection {
    InvocationContextProjection(contributions: [InvocationContextContribution("fixture/context", "guide", "fixture:guide", text,
        ContextContentTrust.UserSelected)], sourceDigest: modelPolicySha256Text(text))
}

class ContextCutManifest <: ModelContextManifestRuntimePort {
    let snapshots = ArrayList<InvocationContextProjection>()
    let manifests = ArrayList<ModelContextManifest>()
    let database: SqliteDatabase
    let databasePath: String
    var cutCheckpointIsInspectableWithoutReplay = false
    init(database: SqliteDatabase, databasePath: String) { this.database = database; this.databasePath = databasePath }
    public func recordBeforeModelEffect(request: AgentRunRequest, requestId: RequestId,
        turnId: SemanticTurnId, executionLaneId: LaneId, stepId: StepId, stepOrdinal: Int64,
        projection: ModelContextProjection, lane: ModelLane, renderedRequest: AgentValue,
        estimatedInputTokens: Int64, observedAtMillis: Int64): Result<Unit> {
        snapshots.add(request.contextSnapshot)
        if (snapshots.size == 2 && database.scalarInt(
            "SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == 1) {
            let durable = decodeDurableRunContinuation(database.query(
                "SELECT payload FROM run_continuations WHERE run_id=?",
                [SqlParameter.Text(request.runId.value)])[0].required(0))
            let reopened = SqliteDatabase(databasePath)
            try {
                let stored = contextSnapshotFromValue(decodeStoredValue(reopened.query(
                    "SELECT skill_snapshot FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])[0].required(0)))
                cutCheckpointIsInspectableWithoutReplay =
                    SqliteRunRepository(reopened).pendingRecoveryContinuation(request.sessionId).value().getOrThrow().isNone() &&
                    reopened.query("SELECT state FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])[0].required(0) == "running" &&
                    contextReadProjectionDigest(stored) == contextReadProjectionDigest(request.contextSnapshot) &&
                    durable.attemptId.isNone() && durable.pendingApprovalId.isNone() &&
                    durable.workDebt.activeAttempts.isEmpty() && durable.workDebt.pendingApprovals.isEmpty() &&
                    (match (durable.phase) { case RunExecutionPhase.ContextCompiling(_) => true; case _ => false }) &&
                    reopened.query("SELECT s.id FROM run_composition_bindings b JOIN composition_snapshots s ON s.id=b.snapshot_id " +
                        "WHERE b.run_id=? AND b.snapshot_id=?", [SqlParameter.Text(request.runId.value),
                            SqlParameter.Text(durable.compositionSnapshotId.value)]).size == 1
            } finally { reopened.close() }
        }
        let store = SqliteContextManifestStore(database)
        match (store.ensureModelStep(request.runId, ThreadId(request.sessionId.value), executionLaneId,
            turnId, stepId, stepOrdinal, None, None, observedAtMillis)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let manifest = match (ContextCompiler("context-cut-compiler").compile(ContextCompileInput(
            ContextManifestId("context-cut-" + requestId.value), ThreadId(request.sessionId.value),
            executionLaneId, turnId, stepId, projection, ItemId("user-" + request.runId.value),
            objectValue([ValueField("context_snapshot_digest", textValue(contextReadProjectionDigest(request.contextSnapshot)))]),
            [], [], [], [], lane, renderedRequest))) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        match (store.save(manifest, [], observedAtMillis)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        manifests.add(manifest)
        store.recordContextReady(request.runId, manifest, observedAtMillis)
    }
}

class ContextCutModel <: ModelPort {
    let requests = ArrayList<ModelRequest>()
    var update: ?RunContextUpdate = None
    let threads: SqliteThreadRuntimeRegistry
    let database: SqliteDatabase
    let manifests: ContextCutManifest
    let scenario: String
    let valid = AtomicBool(true)
    var rejectedFences: Int64 = 0
    var pendingDidNotChangeSnapshot = false
    var staleManifestDenied = false
    var currentRequestSnapshot = false
    let cancellationReady = AtomicBool(false)
    let cancellationObserved = AtomicBool(false)
    init(threads: SqliteThreadRuntimeRegistry, database: SqliteDatabase,
        manifests: ContextCutManifest, scenario: String) {
        this.threads = threads; this.database = database; this.manifests = manifests; this.scenario = scenario
    }
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        requests.add(request)
        let runtime = threads.acquire(ThreadId("context-cut-thread"), "").value().getOrThrow()
        let active = runtime.activeRun().getOrThrow()
        if (requests.size == 1) {
            let previous = contextReadProjectionDigest(active.contextSnapshot)
            let next = if (scenario == "empty") { InvocationContextProjection() } else { selectedCutContext("AFTER_CONTEXT") }
            for (mode in ["run", "epoch", "projection"]) {
                let rejected = runtime.queueContextSnapshot(
                    if (mode == "run") { RunId("foreign-run") } else { active.runId },
                    if (mode == "epoch") { active.epoch + 1 } else { active.epoch },
                    if (mode == "projection") { modelPolicySha256Text("wrong") } else { previous }, next)
                if (rejected.isError()) { rejectedFences += 1 }
            }
            let gate = valid
            update = Some(runtime.queueContextSnapshot(active.runId, active.epoch, previous, next,
                validity: { => if (gate.load()) { Result.Ok(()) } else { Result.Err(AgentError(
                    AgentErrorKind.Conflict, "context.update_source_stale", "source revoked")) } }).value().getOrThrow())
            if (runtime.queueContextSnapshot(active.runId, active.epoch, previous, next).isError()) { rejectedFences += 1 }
            pendingDidNotChangeSnapshot = contextReadProjectionDigest(runtime.activeRun().getOrThrow().contextSnapshot) == previous &&
                update.getOrThrow().state() == ContextUpdateState.Queued &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == 0
            if (scenario == "cancel") { update.getOrThrow().cancel() }
            if (scenario == "revoke") { valid.store(false) }
            if (scenario == "run-cancel") {
                // The model task must not synchronously cancel/join itself.
                // Signal only after the real queue and unchanged-snapshot facts
                // above exist, then observe the actual Run's child token.
                let token = runtime.childCancellationToken(expectedRunId: Some(active.runId), expectedEpoch: Some(active.epoch)).value().getOrThrow()
                cancellationReady.store(true)
                let deadline = MonoTime.now() + Duration.second * 10
                while (!token.isCancelled() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
                expect(token.isCancelled(), "external owner cancellation reaches this actual Model task")
                cancellationObserved.store(true)
                return Result.Err(AgentError(AgentErrorKind.Cancelled, "fixture.context_cancelled", "actual owner cancelled the Run"))
            }
            if (scenario == "rollback") {
                database.execute("CREATE TRIGGER context_cut_fault BEFORE INSERT ON audit_events " +
                    "WHEN NEW.kind='context_snapshot_safe_cut' BEGIN SELECT RAISE(ABORT,'context cut fault'); END")
            }
            if (scenario == "terminal") {
                return Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "done before a new cut")], stopReason: "end_turn"))
            }
        }
        if (requests.size == 2 && (scenario == "apply" || scenario == "empty" || (scenario == "approval" || scenario == "approval-batch"))) {
            let before = database.query("SELECT payload FROM run_continuations WHERE run_id='context-cut-run'")[0].required(0)
            staleManifestDenied = SqliteContextManifestStore(database).recordContextReady(active.runId,
                manifests.manifests[0], agentUtcMillis()).isError() &&
                database.query("SELECT payload FROM run_continuations WHERE run_id='context-cut-run'")[0].required(0) == before
            let durable = decodeDurableRunContinuation(before)
            let projected = optionalRunRequestSnapshotFromDurableContinuation(durable).getOrThrow().field("skill_stack").getOrThrow()
            currentRequestSnapshot = contextReadProjectionDigest(contextSnapshotFromValue(projected)) ==
                contextReadProjectionDigest(active.contextSnapshot)
        }
        if ((scenario == "approval" || scenario == "approval-batch") && requests.size == 2) {
            return Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "approved context complete")], stopReason: "end_turn"))
        }
        if (scenario == "approval-batch" && requests.size == 1) {
            return Result.Ok(contractModelReply([
                ModelBlock(ModelBlockKind.ToolCall, callId: "context-call-first", name: "context_probe", arguments: objectValue([])),
                ModelBlock(ModelBlockKind.ToolCall, callId: "context-call-second", name: "context_probe", arguments: objectValue([]))]))
        }
        if (requests.size <= 2) {
            return Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.ToolCall,
                callId: "context-call-" + requests.size.toString(), name: "context_probe", arguments: objectValue([]))]))
        }
        Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "context complete")], stopReason: "end_turn"))
    }
}

func coreContextSnapshotCutContracts(): Unit {
    for (scenario in ["apply", "empty", "approval", "approval-batch", "cancel", "revoke", "run-cancel", "rollback", "terminal"]) {
        let root = Directory.createTemp("/tmp").toString()
        let database = SqliteDatabase(root + "/cut.db")
        try {
            let catalog = ToolCatalog(); let probe = CutContextTool()
            catalog.register(ToolDescriptor(ModelToolDefinition("context_probe", "context probe", objectValue([])),
                Capability(CapabilityKind.WorkspaceRead), sideEffecting: (scenario == "approval" || scenario == "approval-batch"), implementationVersion: "context-probe-v1",
                implementationFingerprint: "context-probe-v1"), probe).value().getOrThrow()
            let operations = DurableOperationStore(database)
            let threads = SqliteThreadRuntimeRegistry(database,
                ContextProjector("context-cut", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
            let manifests = ContextCutManifest(database, root + "/cut.db")
            let model = ContextCutModel(threads, database, manifests, scenario)
            let core = AgentCore(model, SqliteRunRepository(database),
                ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds()), catalog,
                threadRuntimes: Some(threads), operationRuntime: Some(operations),
                modelDecisionRuntime: Some(SqliteModelDecisionStore(database)), contextManifestRuntime: Some(manifests))
            let before = selectedCutContext("BEFORE_CONTEXT")
            let request = AgentRunRequest(RunId("context-cut-run"), SessionId("context-cut-thread"),
                "fixture", "change context at a real model boundary", contextSnapshot: before,
                capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
                approvalModeOverride: if ((scenario == "approval" || scenario == "approval-batch")) { Some(ApprovalMode.AlwaysAsk) } else { None },
                budget: ResourceBudget(maxConcurrentTools: 1, maxToolCalls: 2))
            var outcome = if (scenario == "run-cancel") {
                contextCutCancelFromOwner(core, model, request)
            } else { core.start(request) }
            if ((scenario == "approval" || scenario == "approval-batch")) {
                let approval = match (outcome) { case Result.Ok(AgentRunOutcome.AwaitingApproval(_, value)) => value
                    case _ => throw IllegalStateException("actual first operation did not wait for approval") }
                expect(model.update.getOrThrow().state() == ContextUpdateState.Queued && probe.contexts.isEmpty() &&
                    database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == 0,
                    "queued data cannot cross a pending canonical operation or change its approved Prepared view")
                outcome = core.decide(request, approval, ApprovalDecision.Approve, { _ => () })
                if (scenario == "approval-batch") {
                    let second = match (outcome) { case Result.Ok(AgentRunOutcome.AwaitingApproval(_, value)) => value
                        case _ => throw IllegalStateException("actual second canonical operation did not wait for approval") }
                    expect(second.operationId.value != approval.operationId.value && probe.contexts.size == 1 &&
                        model.update.getOrThrow().state() == ContextUpdateState.Queued &&
                        database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") == 1 &&
                        database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == 0,
                        "settling the first approval cannot cross the second pending canonical call")
                    outcome = core.decide(request, second, ApprovalDecision.Approve, { _ => () })
                }
            }
            expect(model.rejectedFences == 4 && model.pendingDidNotChangeSnapshot,
                "wrong Run/epoch/projection and duplicate queue fail without altering the first frozen model request")
            let changed = scenario == "apply" || scenario == "empty" || (scenario == "approval" || scenario == "approval-batch")
            let cutCount = database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'")
            let actualOutcome = match (outcome) { case Result.Err(error) => error.describe(); case Result.Ok(_) => "Result.Ok" }
            println("context cut diagnostic scenario=" + scenario + " cuts=" + cutCount.toString() +
                " requests=" + model.requests.size.toString() + " tools=" + probe.contexts.size.toString() +
                " run_state=" + database.query("SELECT state FROM runs WHERE id='context-cut-run'")[0].required(0) +
                " outcome=" + actualOutcome)
            expect(cutCount == (if (changed) { 1 } else { 0 }),
                "exactly one actual cut or no cut is persisted; scenario=" + scenario + " outcome=" + actualOutcome)
            let actual = contextSnapshotFromValue(decodeStoredValue(database.query(
                "SELECT skill_snapshot FROM runs WHERE id='context-cut-run'")[0].required(0)))
            if (changed) {
                let expectedRequests = if ((scenario == "approval" || scenario == "approval-batch")) { 2 } else { 3 }
                let expectedTools = if (scenario == "approval") { 1 } else { 2 }
                expect(outcome.isOk() && model.requests.size == expectedRequests && probe.contexts.size == expectedTools &&
                    model.update.getOrThrow().state() == ContextUpdateState.Applied && model.staleManifestDenied && model.currentRequestSnapshot &&
                    manifests.cutCheckpointIsInspectableWithoutReplay,
                    "the same durable Run commits the context CAS and rejects a late old Manifest without losing the current continuation")
                expect(model.requests[0].system.contains("BEFORE_CONTEXT") && !model.requests[1].system.contains("BEFORE_CONTEXT") &&
                    (scenario == "empty" || model.requests[1].system.contains("AFTER_CONTEXT")),
                    "actual second model system uses the applied data, including empty replacement")
                let old = probe.contexts[0]
                expect(old.contextProjection.contributions()[0].content == "BEFORE_CONTEXT",
                    "already prepared or approved work keeps its exact previous context projection")
                if (scenario == "approval-batch") {
                    expect(probe.contexts[1].contextProjection.contributions()[0].content == "BEFORE_CONTEXT" &&
                        probe.contexts[1].budget.snapshot().toolCalls == 2 && probe.contexts[1].budget.snapshot().activeTools == 0,
                        "both original approved calls keep old context and charge exactly twice before one cut")
                }
                if (scenario != "approval" && scenario != "approval-batch") {
                let next = probe.contexts[1]
                expect(old.contextProjection.contributions()[0].content == "BEFORE_CONTEXT" &&
                    contextReadProjectionDigest(next.contextProjection) == contextReadProjectionDigest(actual) &&
                    !refEq(old, next) && refEq(old.budget, next.budget) && refEq(old.cancellation, next.cancellation) &&
                    old.runId.value == next.runId.value && old.epoch == next.epoch && probe.ownedTasks == 2 &&
                    old.budget.snapshot().toolCalls == 2 && old.budget.snapshot().activeTools == 0,
                    "old Prepared view stays immutable; new view retains the same actual Run, budget, token, task owner and slot")
                }
                expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") == expectedTools &&
                    database.scalarInt("SELECT COUNT(*) FROM composition_snapshots") == 2,
                    "the cut adds a ContextVersion, not a Run, Operation, Receipt or second snapshot registry")
            } else {
                expect(contextReadProjectionDigest(actual) == contextReadProjectionDigest(before) &&
                    model.update.getOrThrow().state() == ContextUpdateState.Discarded,
                    "cancel/revocation/rollback/terminal-before-cut never publishes the pending snapshot")
                if (scenario == "rollback") {
                    expect(database.scalarInt("SELECT COUNT(*) FROM composition_snapshots") == 1 && model.requests.size == 1,
                        "late Store transaction failure rolls back context, composition and next model admission")
                } else if (scenario == "run-cancel") {
                    expect(database.query("SELECT state FROM runs WHERE id='context-cut-run'")[0].required(0) == "cancelled" &&
                        model.requests.size == 1 && model.cancellationObserved.load() &&
                        database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0,
                        "actual Run cancellation discards the queued snapshot without a new model effect")
                } else { expect(outcome.isOk(), "withdrawing data does not invalidate the original unchanged model execution") }
            }
            let reopened = SqliteDatabase(root + "/cut.db")
            try {
                expect(reopened.query("SELECT skill_snapshot FROM runs WHERE id='context-cut-run'")[0].required(0) ==
                    database.query("SELECT skill_snapshot FROM runs WHERE id='context-cut-run'")[0].required(0),
                    "restart reads only the actual persistent version; volatile queued content is not reconstructed")
            } finally { reopened.close() }
        } finally { database.close(); remove(root, recursive: true) }
    }
    println("Core context snapshot safe-cut contract passed: 9 durable scenarios")
}

// Own the Core caller on another task, invoke cancellation from the fixture's
// controlling task, and join before the enclosing database cleanup can run.
func contextCutCancelFromOwner(core: AgentCore, model: ContextCutModel,
    request: AgentRunRequest): Result<AgentRunOutcome> {
    let pending = spawn { core.start(request) }
    try {
        let deadline = MonoTime.now() + Duration.second * 10
        while (!model.cancellationReady.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
        expect(model.cancellationReady.load(), "the actual Model task queued its context update before external cancellation")
        expect(core.cancel(request.runId).isOk(), "external caller cancels and joins the actual Run")
        pending.get()
    } finally {
        // Even a failed assertion cannot close SQLite beneath a live Core task.
        try { let _ = core.cancel(request.runId) } finally { let _ = pending.get() }
    }
}
