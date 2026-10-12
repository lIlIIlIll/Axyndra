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
import std.convert.*
import yjson.*
import yjson_support.*

class ContinuationCoreModel <: ModelPort {
    let requests = ArrayList<ModelRequest>()
    let threads: SqliteThreadRuntimeRegistry
    let scenario: String
    init(threads: SqliteThreadRuntimeRegistry, scenario: String) { this.threads = threads; this.scenario = scenario }
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        requests.add(request)
        if (scenario == "context-cut" && requests.size == 2) {
            let runtime = threads.acquire(ThreadId("continuation-core"), "").value().getOrThrow()
            let active = runtime.activeRun().getOrThrow()
            runtime.queueContextSnapshot(active.runId, active.epoch, contextReadProjectionDigest(active.contextSnapshot),
                selectedCutContext("CONTINUATION_AFTER_CUT")).value().getOrThrow()
            events(ModelEvent.Completed)
            return Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.ToolCall, callId: "continuation-read",
                name: "continuation_probe", arguments: objectValue([]))], inputTokens: 7, outputTokens: 3))
        }
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "continuation complete")],
            stopReason: "end_turn", inputTokens: 7, outputTokens: 3))
    }
}

class ContinuationCoreManifest <: ModelContextManifestRuntimePort {
    let database: SqliteDatabase
    init(database: SqliteDatabase) { this.database = database }
    public func recordBeforeModelEffect(request: AgentRunRequest, requestId: RequestId,
        turnId: SemanticTurnId, executionLaneId: LaneId, stepId: StepId, stepOrdinal: Int64,
        projection: ModelContextProjection, lane: ModelLane, rendered: AgentValue,
        estimated: Int64, observed: Int64): Result<Unit> {
        var intent: ?ItemId = None
        for (item in projection.recentItems where item.turnId.value == turnId.value) {
            if (item.kind == ItemKind.UserMessage) { intent = Some(item.id) }
            if (isContinuationInitiatorDescription(item)) {
                database.readTransaction<Unit>({ tx => let _ = consumedContinuationRequest(tx, item) })
                intent = Some(item.id)
            }
        }
        let store = SqliteContextManifestStore(database)
        match (store.ensureModelStep(request.runId, ThreadId(request.sessionId.value), executionLaneId,
            turnId, stepId, stepOrdinal, None, None, observed)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let manifest = match (ContextCompiler("continuation-core-contract").compile(ContextCompileInput(
            ContextManifestId("manifest-" + requestId.value), ThreadId(request.sessionId.value), executionLaneId,
            turnId, stepId, ModelContextProjection(projection.threadRevision, projection.checkpoint,
                projection.recentItems, projection.dynamicState, estimated, false), intent.getOrThrow(),
            objectValue([ValueField("context_snapshot_digest", textValue(contextReadProjectionDigest(request.contextSnapshot)))]),
            [], [], [], [], lane, rendered))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (store.save(manifest, [], observed)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        store.recordContextReady(request.runId, manifest, observed)
    }
}

// Explicit trusted test owner. These tests exercise Core's real single start
// and model/SQLite accounting; Product tests cover actual user-command capture.
class ContinuationCoreAuthorizer <: ContinuationRunAuthorizer {
    let origin: ContinuationRunOrigin
    init(origin: ContinuationRunOrigin) { this.origin = origin }
    public func authorizeNextRun(): Result<ContinuationRunOrigin> { Result.Ok(origin) }
    public func validateCurrent(value: ContinuationRunOrigin): Result<Unit> {
        if (!sameContinuationRunOrigin(value, origin)) { return Result.Err(AgentError(
            AgentErrorKind.PermissionDenied, "test.origin_changed", "test continuation origin changed")) }
        Result.Ok(())
    }
}

func continuationCoreContracts(): Unit {
    for (scenario in ["complete", "paused", "rollback", "wrong-request", "token-exhausted", "reopen", "fork", "fork-again", "context-cut"]) {
        let root = Directory.createTemp("/tmp").toString()
        let database = SqliteDatabase(root + "/continuation.db")
        try {
            let runs = SqliteRunRepository(database)
            let facts = ContinuationAllowanceRepository(runs)
            let catalog = ToolCatalog()
            let operations = DurableOperationStore(database)
            let threads = SqliteThreadRuntimeRegistry(database,
                ContextProjector("continuation-core", ConservativeThreadTokenEstimator()), { => agentUtcMillis() },
                continuationVerifier: Some(SqliteContinuationRunVerifier(facts)))
            let model = ContinuationCoreModel(threads, scenario)
            if (scenario == "context-cut") {
                catalog.register(ToolDescriptor(ModelToolDefinition("continuation_probe", "continuation context probe", objectValue([])),
                    Capability(CapabilityKind.WorkspaceRead), implementationVersion: "continuation-probe-v1",
                    implementationFingerprint: "continuation-probe-v1"), CutContextTool()).value().getOrThrow()
            }
            let core = AgentCore(model, runs, ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds()), catalog,
                threadRuntimes: Some(threads), operationRuntime: Some(operations),
                modelDecisionRuntime: Some(SqliteModelDecisionStore(database)),
                contextManifestRuntime: Some(ContinuationCoreManifest(database)))
            let session = SessionId("continuation-core")
            expect(core.start(AgentRunRequest(RunId("first"), session, "fixture", "real user request")).isOk(),
                "continuation has a genuinely completed first canonical Run")
            let address = ContinuationAllowanceAddress(ThreadId(session.value), LaneId("main"), "workflow", "goal")
            let control = database.transaction<ContinuationAllowanceFacts>({ tx =>
                facts.appendControlFacts(tx, address, None, ContinuationAllowanceControl.Create("allowance", Some(1)),
                    modelPolicySha256Text("actual-test-user-control"), agentUtcMillis()).value().getOrThrow()
            })
            let raw = database.query("SELECT payload FROM audit_events WHERE id=?", [SqlParameter.Int64Value(control.eventId)])[0].required(0)
            let runtime = threads.acquire(ThreadId(session.value), "").value().getOrThrow()
            let thread = runtime.threadSnapshot()
            let previousEpoch = Int64.parse(database.query("SELECT epoch FROM runs WHERE id='first'")[0].required(0))
            let request = AgentRunRequest(RunId("next"), session, "fixture", "frozen continuation prompt",
                capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]))
            let frozen = core.prepareContinuation(request).value().getOrThrow()
            // Neither the caller's mutable array nor an exported copy can alter
            // the request captured in the transient admission or persisted claim.
            request.capabilities.values[0] = Capability(CapabilityKind.WorkspaceWrite)
            let exported = frozen.requestCopy()
            exported.capabilities.values[0] = Capability(CapabilityKind.ProcessSpawn)
            let origin = ContinuationRunOrigin(session.value, "main", "workflow", "goal", control.allowanceId,
                modelPolicySha256Text(raw), control.controlSourceDigest, "first", "next", "turn-next", "continuation-next",
                if (scenario == "wrong-request") { modelPolicySha256Text("wrong") } else { frozen.requestDigest }, frozen.launchDigest,
                control.generation, control.eventId, thread.thread.revision, previousEpoch + 1)
            let authority = ContinuationRunAuthority(ContinuationCoreAuthorizer(origin))
            let admission = authority.reserve().value().getOrThrow()
            if (scenario == "paused") {
                authority.revoke()
                database.transaction<Unit>({ tx => let _ = facts.appendControlFacts(tx, address, Some(control),
                    ContinuationAllowanceControl.Pause, modelPolicySha256Text("actual-test-pause"), agentUtcMillis()).value().getOrThrow() })
            }
            if (scenario == "rollback") { database.execute("CREATE TRIGGER deny_next BEFORE INSERT ON runs WHEN NEW.id='next' BEGIN SELECT RAISE(ABORT,'test next Run insert failure'); END") }
            var rejected = false
            try {
                rejected = core.startContinuation(AgentContinuationStart(frozen, admission), { _ => () }).isError()
            } catch (_: IllegalArgumentException) { rejected = true }
            let positive = ["complete", "token-exhausted", "reopen", "fork", "fork-again", "context-cut"].contains(scenario)
            let attempts: Int64 = if (scenario == "context-cut") { 3 } else if (positive) { 2 } else { 1 }
            expect(rejected != positive, "real Core continuation result matches " + scenario)
            expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts") == attempts &&
                database.scalarInt("SELECT COUNT(*) FROM model_decisions") == attempts &&
                database.scalarInt("SELECT COUNT(*) FROM operations") == (if (scenario == "context-cut") { 1 } else { 0 }),
                "one actual Attempt per admitted Run, no substitute Tool or hidden model retry")
            expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'") == 1 &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'") == (if (positive) { 1 } else { 0 }),
                "failed admission rolls back the claim; successful continuation never invents user input")
            if (!positive) { continue }
            let last = model.requests[1]
            var promptCount: Int64 = 0
            for (message in last.messages) { for (block in message.blocks where block.kind == ModelBlockKind.Text) {
                if (block.text == "frozen continuation prompt") { promptCount += 1 }
                expect(block.text != "Host continuation", "provenance marker is never model prompt data")
            } }
            expect(promptCount == 1, "actual Model request consumes the one frozen claim prompt")
            let loaded = SqliteThreadCommitSink(database).loadThread(ThreadId(session.value))
            var note: ?ThreadItem = None
            for (item in loaded.items where item.id.value == "continuation-next") { note = Some(item) }
            let historical = runs.continuationModelInput(note.getOrThrow()).value().getOrThrow()
            expect(historical.blocks[0].text == "frozen continuation prompt", "history resolves data only through the exact consumed claim")
            let generic = modelMessagesFromProjection(ModelContextProjection(loaded.thread.revision, None,
                [note.getOrThrow()], objectValue([]), 0, false))
            expect(generic.isEmpty(), "generic SystemNote projection remains inert")
            expect(core.startContinuation(AgentContinuationStart(frozen, admission), { _ => () }).isError() && model.requests.size == attempts,
                "consumed transient admission cannot dispatch a second Attempt")
            let remaining = database.readTransaction<ContinuationAllowanceFacts>({ tx => facts.readFacts(tx, address).value().getOrThrow().getOrThrow() })
            expect(remaining.tokensUsed == (if (scenario == "context-cut") { 20 } else { 10 }) && !remaining.hasRemainingTokens(),
                "original completed Run statistics gate the next Run only")
            if (scenario == "context-cut") {
                expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == 1 &&
                    runs.continuationModelInput(note.getOrThrow()).isOk(),
                    "legitimate context CAS keeps the original launch composition and historical prompt proof valid")
            }
            if (scenario == "token-exhausted") {
                let third = core.prepareContinuation(AgentRunRequest(RunId("third"), session, "fixture", "third request")).value().getOrThrow()
                let nextOrigin = ContinuationRunOrigin(session.value, "main", "workflow", "goal", control.allowanceId,
                    modelPolicySha256Text(raw), control.controlSourceDigest, "next", "third", "turn-third", "continuation-third",
                    third.requestDigest, third.launchDigest, control.generation, control.eventId,
                    runtime.threadSnapshot().thread.revision, previousEpoch + 2)
                let nextOwner = ContinuationRunAuthority(ContinuationCoreAuthorizer(nextOrigin))
                expect(core.startContinuation(AgentContinuationStart(third, nextOwner.reserve().value().getOrThrow()), { _ => () }).isError() &&
                    model.requests.size == 2 && database.scalarInt("SELECT COUNT(*) FROM runs WHERE id='third'") == 0,
                    "a new actual Run admission rechecks canonical cumulative statistics before any Attempt")
            }
            if (scenario == "reopen") {
                let reopened = SqliteDatabase(root + "/continuation.db")
                try {
                    let reopenedRuns = SqliteRunRepository(reopened)
                    expect(reopenedRuns.continuationModelInput(note.getOrThrow()).isOk() &&
                        reopenedRuns.pendingRecoveryContinuation(session).value().getOrThrow().isNone(),
                        "reopened consumed data does not mint a live owner or pending continuation")
                } finally { reopened.close() }
            }
            if (scenario == "fork" || scenario == "fork-again") {
                let fork = completedThreadCloneSnapshot(ThreadId("fork"), loaded.thread.workspaceId, loaded)
                expect(SqliteThreadSeedStore(database).createCompleted(fork).isOk(), "completed continuation forks as typed data-only history")
                var target = ThreadId("fork")
                if (scenario == "fork-again") {
                    let forked = SqliteThreadCommitSink(database).loadThread(target)
                    expect(SqliteThreadSeedStore(database).createCompleted(completedThreadCloneSnapshot(ThreadId("fork-again"), forked.thread.workspaceId, forked)).isOk(),
                        "second fork verifies the first copied history in the same seed transaction")
                    target = ThreadId("fork-again")
                }
                expect(database.query("SELECT id FROM audit_events WHERE thread_id=? AND kind='host_continuation_claim_consumed_v1'",
                    [SqlParameter.Text(target.value)]).isEmpty(), "fork never copies an admission claim")
                let copied = SqliteThreadCommitSink(database).loadThread(target)
                var historicalItem: ?ThreadItem = None
                for (item in copied.items where isContinuationHistoryDescription(item)) { historicalItem = Some(item) }
                let actualHistory = historicalItem.getOrThrow()
                let forged = ThreadItem(actualHistory.id, ThreadId("different-thread"), actualHistory.turnId, actualHistory.ordinal,
                    actualHistory.content, actualHistory.provenance, createdAtMillis: actualHistory.createdAtMillis)
                expect(runs.continuationModelInput(forged).isError(), "copied Item identity cannot borrow another Thread's history proof")
                database.execute("INSERT INTO audit_events(thread_id,run_id,kind,payload,created_at_millis,commit_sequence) " +
                    "SELECT thread_id,run_id,kind,payload,created_at_millis,commit_sequence FROM audit_events " +
                    "WHERE thread_id=? AND kind='host_continuation_history_v1'", [SqlParameter.Text(target.value)])
                expect(runs.continuationModelInput(actualHistory).isError(), "duplicate history proofs fail closed")
                database.execute("DELETE FROM audit_events WHERE id=(SELECT MAX(id) FROM audit_events WHERE thread_id=? AND kind='host_continuation_history_v1')",
                    [SqlParameter.Text(target.value)])
                let originalClaim = database.query("SELECT payload FROM audit_events WHERE run_id='next' AND kind='host_continuation_claim_consumed_v1'")[0].required(0)
                let changed = decodeStoredValue(originalClaim)
                changed.put("request", objectValue([ValueField("model_input", textValue("changed source"))]))
                database.execute("UPDATE audit_events SET payload=? WHERE run_id='next' AND kind='host_continuation_claim_consumed_v1'",
                    [SqlParameter.Text(encodeStoredValue(changed))])
                expect(SqliteThreadSeedStore(database).createCompleted(completedThreadCloneSnapshot(ThreadId("bad-fork"), loaded.thread.workspaceId, loaded)).isError() &&
                    database.scalarInt("SELECT COUNT(*) FROM threads WHERE id='bad-fork'") == 0,
                    "source request tampering rejects and rolls back the entire history seed transaction")
                database.execute("UPDATE audit_events SET payload=? WHERE run_id='next' AND kind='host_continuation_claim_consumed_v1'",
                    [SqlParameter.Text(originalClaim)])
                // Original mutable source removal cannot invalidate a committed
                // history copy; its own exact request digest remains checked.
                database.execute("DELETE FROM audit_events WHERE thread_id='continuation-core' AND kind='host_continuation_claim_consumed_v1'")
                let sourceFree = core.start(AgentRunRequest(RunId("fork-user-run"), SessionId(target.value), "fixture", "new actual user input"))
                expect(sourceFree.isOk() && model.requests.size == 3, "a fork can run only through its new ordinary user admission")
                var copiedPrompt: Int64 = 0
                for (message in model.requests[2].messages) { for (block in message.blocks where block.kind == ModelBlockKind.Text) {
                    if (block.text == "frozen continuation prompt") { copiedPrompt += 1 }
                } }
                expect(copiedPrompt == 1 && database.query("SELECT i.id FROM items i JOIN turns t ON t.id=i.turn_id " +
                    "JOIN runs r ON r.turn_id=t.id WHERE r.id='fork-user-run' AND i.id=t.user_item_id AND i.kind='user_message'").size == 1,
                    "copied model data stays once in history while the new canonical initiator is actual user input")
            }
        } finally { database.close() }
    }
    println("Core continuation start contract passed: 9 real SQLite scenarios, exact frozen model input, context CAS, verified fork history and no fabricated UserMessage")
}
