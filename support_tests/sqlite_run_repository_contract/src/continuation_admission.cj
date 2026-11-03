package sqlite_run_repository_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

class ContinuationTestEstimator <: ThreadTokenEstimator {
    public func estimateSystemInstructions(_: String): Int64 { 1 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 1 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 1 }
    public func estimateItem(_: ThreadItem): Int64 { 1 }
    public func estimateDynamicState(_: AgentValue): Int64 { 1 }
}
func continuationTestLane(): ModelLane {
    ModelLane(ModelLaneRole.Main, "fixture", "fixture-model", "responses", ModelLaneCapabilitiesSnapshot(),
        100, 10, 5, "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system-v1")
}
// TEST authorizer only. These contracts prove Runtime/SQLite boundaries; they
// do not pretend to authenticate an Application Command or installed package.
class ContinuationTestAuthorizer <: ContinuationRunAuthorizer {
    let origin: ContinuationRunOrigin
    init(origin: ContinuationRunOrigin) { this.origin = origin }
    public func authorizeNextRun(): Result<ContinuationRunOrigin> { Result.Ok(origin) }
    public func validateCurrent(value: ContinuationRunOrigin): Result<Unit> {
        if (!sameContinuationRunOrigin(value, origin)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "test.changed", "test owner changed")) }
        Result.Ok(())
    }
}

func continuationRunAdmissionContract(root: String): Unit {
    for (scenario in ["completed", "default-deny", "revoked", "pause", "old-generation", "wrong-source", "wrong-control-payload",
        "wrong-thread", "wrong-previous", "wrong-revision", "wrong-epoch", "wrong-request", "wrong-launch", "rollback", "copied-proof", "missing-proof"]) {
        continuationRunAdmissionScenario(root, scenario)
    }
    println("Continuation Run admission contract passed: 16 real SQLite scenarios, one Runtime and same-transaction claim; test authorizer, no Application ingress claim")
}

func continuationRunAdmissionScenario(root: String, scenario: String): Unit {
    let db = SqliteDatabase(root + "/continuation-admission-" + scenario + ".db")
    try {
        let repository = SqliteRunRepository(db)
        let facts = ContinuationAllowanceRepository(repository)
        let verifier: ?ContinuationRunTransactionVerifier = if (scenario == "default-deny") { None }
            else { Some(SqliteContinuationRunVerifier(facts)) }
        let sink = SqliteThreadCommitSink(db, continuationVerifier: verifier)
        let thread = ThreadId("continuation-thread")
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        let runtime = AgentThreadRuntime(coordinator, ContextProjector("test", ContinuationTestEstimator()), { => 10 })
        let lane = continuationTestLane(); let context = InvocationContextProjection(); let budget = objectValue([])
        let started = runtime.startTurn(SemanticTurnId("previous-turn"), RunId("previous-run"), ItemId("actual-user"),
            ThreadItemContent.UserMessage([ThreadMessagePart.Text("actual user work")]), lane, context).value().getOrThrow()
        expect(runtime.finish(RunState.Completed, 100).isOk(), "original actual user Run completes before continuation")
        let address = ContinuationAllowanceAddress(thread, LaneId("main"), "workflow", "goal")
        let control = allowanceContractControl(db, facts, address, None,
            ContinuationAllowanceControl.Create("allowance", Some(10))).value().getOrThrow()
        let raw = db.query("SELECT payload FROM audit_events WHERE id=?", [SqlParameter.Int64Value(control.eventId)])[0].required(0)
        let snapshot = coordinator.snapshot()
        let request = objectValue([ValueField("prompt", textValue("frozen full host request"))])
        let origin = ContinuationRunOrigin(
            if (scenario == "wrong-thread") { "another-thread" } else { thread.value }, "main", "workflow", "goal", control.allowanceId,
            if (scenario == "wrong-control-payload") { modelPolicySha256Text("wrong") } else { modelPolicySha256Text(raw) },
            if (scenario == "wrong-source") { modelPolicySha256Text("another-control") } else { control.controlSourceDigest },
            if (scenario == "wrong-previous") { "another-run" } else { "previous-run" }, "continuation-run", "continuation-turn", "continuation-note", modelPolicySha256Text(canonicalAgentValue(request)),
            if (scenario == "wrong-launch") { modelPolicySha256Text("wrong-launch") }
            else { continuationRunLaunchDigest(modelLaneSnapshotValue(lane), contextSnapshotValue(context), budget) },
            control.generation + (if (scenario == "old-generation") { 1 } else { 0 }), control.eventId,
            snapshot.thread.revision + (if (scenario == "wrong-revision") { 1 } else { 0 }),
            started.epoch + (if (scenario == "wrong-epoch") { 2 } else { 1 }))
        let authority = ContinuationRunAuthority(ContinuationTestAuthorizer(origin))
        let admission = authority.reserve().value().getOrThrow()
        if (scenario == "revoked") { authority.revoke() }
        if (scenario == "pause") {
            expect(allowanceContractControl(db, facts, address, Some(control), ContinuationAllowanceControl.Pause).isOk(),
                "actual paused control facts deny a stale live reservation") }
        if (scenario == "rollback") {
            db.execute("CREATE TRIGGER deny_continuation BEFORE INSERT ON runs WHEN NEW.id='continuation-run' BEGIN SELECT RAISE(ABORT,'test run insert failure'); END") }
        let result = runtime.startContinuationTurn(admission,
            if (scenario == "wrong-request") { objectValue([ValueField("prompt", textValue("changed request"))]) } else { request }, lane, context, budget)
        let positive = ["completed", "copied-proof", "missing-proof"].contains(scenario)
        expect(result.isOk() == positive, "continuation startup actual outcome matches scenario " + scenario)
        if (!positive) {
            expect(db.scalarInt("SELECT COUNT(*) FROM runs WHERE id='continuation-run'") == 0 &&
                db.scalarInt("SELECT COUNT(*) FROM items WHERE id='continuation-note'") == 0 &&
                db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'") == 0,
                "failed admission leaves no Run, initiator or orphan claim: " + scenario)
            expect(coordinator.snapshot().thread.revision == snapshot.thread.revision && coordinator.snapshot().activeRunId.isNone(),
                "failed durable startup restores the one coordinator cursor")
            return
        }
        let active = result.value().getOrThrow()
        expect(db.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'") == 1 &&
            db.scalarInt("SELECT COUNT(*) FROM items WHERE kind='system_note'") == 1 &&
            db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'") == 1,
            "continuation creates one typed SystemNote plus one claim and never fabricates a user message")
        expect(db.scalarInt("SELECT COUNT(*) FROM operations") == 0 && db.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0,
            "Run admission does not create a Tool or second model Attempt")
        db.readTransaction<Unit>({ tx => requireConsumedContinuationRun(tx, thread, active.turnId, active.runId, active.epoch) })
        let stored = db.query("SELECT provenance FROM items WHERE id='continuation-note'")[0].required(0)
        expect(encodeStoredProvenance(decodeStoredProvenance(stored)) == stored,
            "typed continuation origin round trips in the actual length-framed Store codec")
        expect(runtime.startContinuationTurn(admission, request, lane, context, budget).isError(), "same live admission is single-use")
        authority.revoke()
        expect(runtime.currentRunCancellationToken(active.runId, active.epoch).value().getOrThrow().check().isOk(),
            "pause revokes the next admission without cancelling the already admitted Run")
        if (scenario == "missing-proof") {
            db.execute("DELETE FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'")
        } else if (scenario == "copied-proof") {
            db.execute("UPDATE audit_events SET run_id='another-run' WHERE kind='host_continuation_claim_consumed_v1'")
        }
        if (scenario != "completed") {
            var rejected = false
            try { db.readTransaction<Unit>({ tx => requireConsumedContinuationRun(tx, thread, active.turnId, active.runId, active.epoch) }) }
                catch (_: Exception) { rejected = true }
            expect(rejected, "missing or cross-Run copied claim cannot authorize context consumption")
        }
        expect(runtime.finish(RunState.Completed, 100).isOk(), "current Run still settles independently of next-Run control revocation")
        let loaded = sink.loadThread(thread)
        let history = ThreadCoordinator(loaded, sink)
        expect(history.snapshot().items.size == 2, "typed initiator remains inspectable after reopening canonical Thread history")
    } finally { db.close() }
}
