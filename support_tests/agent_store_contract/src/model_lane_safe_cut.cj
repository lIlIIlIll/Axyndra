package agent_store_contract

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import std.fs.*
import yjson.*
import yjson_support.*

func modelLaneCutSnapshot(thread: ThreadId, version: String): ToolSetSnapshot {
    let schema = objectValue([])
    ToolSetSnapshot("cut-" + version, [ToolSnapshotEntry("plugin.cut.echo", version, schema,
        version, [Capability(CapabilityKind.WorkspaceRead)],
        implementationFingerprint: "fingerprint-" + version,
        schemaDigest: modelPolicySha256Text(canonicalAgentValue(schema)))], threadId: Some(thread))
}

class ModelLaneCutFixture {
    let root: String
    let database: SqliteDatabase
    let sink: SqliteThreadCommitSink
    var runtime: AgentThreadRuntime
    let thread = ThreadId("cut-thread")
    let run = RunId("cut-run")
    let turn = SemanticTurnId("cut-turn")
    let original: ModelLane
    init() {
        root = Directory.createTemp("/tmp").toString()
        database = SqliteDatabase(root + "/cut.db")
        sink = SqliteThreadCommitSink(database)
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        runtime = AgentThreadRuntime(coordinator, ContextProjector("cut-store", StoreEstimator()), { => 20 })
        original = modelLaneReplacingToolSet(recoveryLane(), modelLaneCutSnapshot(thread, "first"))
        runtime.startTurn(turn, run, ItemId("cut-user"),
            ThreadItemContent.UserMessage(textMessageParts("refresh catalog")), original,
            InvocationContextProjection(), createdAtMillis: 1).value().getOrThrow()
    }
    func snapshot(version: String): ToolSetSnapshot { modelLaneCutSnapshot(thread, version) }
    func cut(): Result<ActiveRunSnapshot> {
        let active = runtime.activeRun().getOrThrow()
        runtime.replaceToolSetAtSafeCut(run, active.epoch, original, snapshot("second"))
    }
    func continuation(): DurableRunContinuationV1 {
        SqliteSemanticStore(database).continuation(run).value().getOrThrow()
    }
    func setDebt(debt: WorkDebtSnapshot): Unit {
        let current = continuation()
        let next = sealDurableRunContinuation(DurableRunContinuationV1(current.runId, current.laneId,
            current.turnId, current.stepOrdinal, current.phase, current.compositionSnapshotId,
            current.modelLaneSnapshotId, workDebt: debt))
        SqliteSemanticStore(database).transact(TransactionPreconditions(thread,
            runtime.threadSnapshot().thread.revision, run,
            database.scalarInt("SELECT revision FROM run_continuations WHERE run_id='cut-run'")),
            DurableWriteSet(continuation: Some(next))).value().getOrThrow()
        reload()
    }
    func reload(): Unit {
        let active = runtime.activeRun().getOrThrow()
        let lane = modelLaneFromSnapshotValue(decodeStoredValue(database.query(
            "SELECT lane_snapshot FROM runs WHERE id='cut-run'")[0].required(0)))
        runtime = AgentThreadRuntime(ThreadCoordinator(sink.loadThread(thread), sink),
            ContextProjector("cut-store", StoreEstimator()),
            RecoveredRunSpec(turn, run, active.epoch, active.state, active.transitionSequence,
                lane, InvocationContextProjection()), { => 25 })
    }
    func saveManifest(lane: ModelLane, name: String, ordinal: Int64): ModelContextManifest {
        let store = SqliteContextManifestStore(database)
        let step = StepId(name + "-step")
        store.ensureModelStep(run, thread, LaneId("main"), turn, step, ordinal, None, None, 30).value().getOrThrow()
        let manifest = ContextCompiler("cut-compiler").compile(ContextCompileInput(
            ContextManifestId(name), thread, LaneId("main"), turn, step,
            runtime.projectContext().value().getOrThrow(), ItemId("cut-user"),
            objectValue([]), [], [], [], [], lane,
            objectValue([ValueField("tools", listValue([]))]))).value().getOrThrow()
        store.save(manifest, [], 30).value().getOrThrow()
        manifest
    }
    func close(): Unit { database.close(); remove(root, recursive: true) }
}

func modelLaneSafeCutContracts(): Unit {
    modelLaneSafeCutPersistenceContract()
    modelLaneSafeCutRollbackContract()
    modelLaneSafeCutDebtContract()
    modelLaneSafeCutManifestRaceContract()
    for (scenario in ["run", "epoch", "thread", "lane", "pending-call", "waiting-run"]) {
        modelLaneSafeCutFenceContract(scenario)
    }
    println("Store model-lane safe-cut contract passed (persistence, rollback, debts, stale manifest, 6 fences)")
}

func modelLaneSafeCutPersistenceContract(): Unit {
    let fixture = ModelLaneCutFixture()
    try {
        let before = fixture.runtime.threadSnapshot()
        let old = fixture.continuation()
        let changed = fixture.cut().value().getOrThrow()
        let current = fixture.continuation()
        expect(changed.lane.toolSet.id == "cut-second" &&
            fixture.runtime.threadSnapshot().thread.revision == before.thread.revision + 1 &&
            fixture.runtime.threadSnapshot().items.size == before.items.size &&
            fixture.runtime.threadSnapshot().nextResultSequence == before.nextResultSequence &&
            current.modelLaneSnapshotId.value != old.modelLaneSnapshotId.value &&
            current.compositionSnapshotId.value != old.compositionSnapshotId.value &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM composition_snapshots") == 2 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='model_lane_safe_cut'") == 1,
            "one real transaction replaces lane/composition/continuation without inventing a canonical Item or resetting cursors")
        expect(fixture.runtime.replaceToolSetAtSafeCut(fixture.run, changed.epoch,
            fixture.original, fixture.snapshot("third")).isError(), "old lane is a strict CAS conflict")
        fixture.reload()
        expect(fixture.runtime.activeRun().getOrThrow().lane.toolSet.id == "cut-second" &&
            fixture.continuation().modelLaneSnapshotId.value == current.modelLaneSnapshotId.value,
            "reopened Runtime recovers the precise new lane instead of resolving the latest catalog")
        let store = SqliteContextManifestStore(fixture.database)
        let projection = fixture.runtime.projectContext().value().getOrThrow()
        let step = StepId("cut-next-model")
        store.ensureModelStep(fixture.run, fixture.thread, LaneId("main"), fixture.turn, step, 1,
            None, None, 30).value().getOrThrow()
        let manifest = ContextCompiler("cut-compiler").compile(ContextCompileInput(
            ContextManifestId("cut-manifest"), fixture.thread, LaneId("main"), fixture.turn, step,
            projection, ItemId("cut-user"), objectValue([]), [], [], [], [], changed.lane,
            objectValue([ValueField("tools", listValue([]))]))).value().getOrThrow()
        store.save(manifest, [], 30).value().getOrThrow()
        store.recordContextReady(fixture.run, manifest, 30).value().getOrThrow()
        expect(fixture.continuation().modelLaneSnapshotId.value == current.modelLaneSnapshotId.value &&
            fixture.continuation().compositionSnapshotId.value == current.compositionSnapshotId.value &&
            store.load(manifest.id).value().getOrThrow().toolCatalogSnapshot.field("snapshot_id").getOrThrow().text == "cut-second",
            "next actual Context Manifest preserves the changed durable lane/composition identities")
    } finally { fixture.close() }
}

func modelLaneSafeCutRollbackContract(): Unit {
    let fixture = ModelLaneCutFixture()
    try {
        let before = fixture.runtime.threadSnapshot()
        let old = fixture.continuation()
        fixture.database.execute("CREATE TRIGGER reject_lane_audit BEFORE INSERT ON audit_events " +
            "WHEN NEW.kind='model_lane_safe_cut' BEGIN SELECT RAISE(ABORT,'cut fault'); END")
        expect(fixture.cut().isError() && fixture.runtime.activeRun().getOrThrow().lane.toolSet.id == "cut-first" &&
            fixture.runtime.threadSnapshot().thread.revision == before.thread.revision &&
            fixture.continuation().digest == old.digest &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM composition_snapshots") == 1,
            "late transaction failure rolls back composition, lane, continuation, audit and in-memory revision together")
        fixture.database.execute("DROP TRIGGER reject_lane_audit")
        expect(fixture.cut().isOk(), "the same expected lane succeeds after a rolled-back attempt")
    } finally { fixture.close() }
}

func modelLaneSafeCutDebtContract(): Unit {
    let fixture = ModelLaneCutFixture()
    try {
        let debt = WorkDebtSnapshot(unclaimedInputs: [InboxEntryId("queued")],
            activeChildRuns: [RunId("child")], ownedTasks: [OwnedTaskId("task")],
            deferredContexts: [DeferredContextId("context")])
        fixture.setDebt(debt)
        expect(fixture.cut().isOk(), "independent owned work does not force all catalog updates to the next Run")
        let after = fixture.continuation().workDebt
        expect(after.unclaimedInputs.size == 1 && after.activeChildRuns.size == 1 &&
            after.ownedTasks.size == 1 && after.deferredContexts.size == 1,
            "safe cut preserves all non-table work debt instead of manufacturing an empty continuation")
        let manifest = fixture.saveManifest(fixture.runtime.activeRun().getOrThrow().lane, "debt-manifest", 1)
        SqliteContextManifestStore(fixture.database).recordContextReady(fixture.run, manifest, 31).value().getOrThrow()
        let contextDebt = fixture.continuation().workDebt
        expect(contextDebt.unclaimedInputs.size == 1 && contextDebt.activeChildRuns.size == 1 &&
            contextDebt.ownedTasks.size == 1 && contextDebt.deferredContexts.size == 1,
            "actual next ContextReady also retains every outstanding non-table obligation")
        expect(fixture.runtime.finish(RunState.Completed, 0).isError(),
            "the retained debt still prevents a false Completed Run after the cut")
    } finally { fixture.close() }
    let blocked = ModelLaneCutFixture()
    try {
        blocked.setDebt(WorkDebtSnapshot(activeAttempts: [ModelAttemptId("not-yet-settled")]))
        let before = blocked.continuation().digest
        expect(blocked.cut().isError() && blocked.continuation().digest == before,
            "active model debt is a fence even without a matching table row; it cannot be silently erased")
    } finally { blocked.close() }
}

func modelLaneSafeCutManifestRaceContract(): Unit {
    let fixture = ModelLaneCutFixture()
    try {
        let old = fixture.saveManifest(fixture.original, "before-cut-manifest", 1)
        fixture.cut().value().getOrThrow()
        let current = fixture.continuation().digest
        let store = SqliteContextManifestStore(fixture.database)
        expect(store.recordContextReady(fixture.run, old, 32).isError() && fixture.continuation().digest == current,
            "a compiled and saved old manifest cannot be re-labelled with the new lane after a concurrent cut")
        let newLane = fixture.runtime.activeRun().getOrThrow().lane
        // Same snapshot id with different content must fail too; an id-only
        // check would allow stale or forged entries to enter the new context.
        let tampered = modelLaneReplacingToolSet(newLane, ToolSetSnapshot(newLane.toolSet.id,
            fixture.snapshot("different-content").entries, threadId: Some(fixture.thread)))
        let wrong = fixture.saveManifest(tampered, "same-id-wrong-content", 2)
        expect(store.recordContextReady(fixture.run, wrong, 33).isError() && fixture.continuation().digest == current,
            "the manifest fence compares complete immutable content, not merely snapshot_id")
        let valid = fixture.saveManifest(newLane, "after-cut-manifest", 3)
        expect(store.recordContextReady(fixture.run, valid, 34).isOk() && store.load(old.id).isOk(),
            "new context is admitted while the old immutable manifest remains readable history")
    } finally { fixture.close() }
}

func modelLaneSafeCutFenceContract(scenario: String): Unit {
    let fixture = ModelLaneCutFixture()
    try {
        let active = fixture.runtime.activeRun().getOrThrow()
        if (scenario == "pending-call") {
            fixture.runtime.commitResult(ResultEnvelope(fixture.thread, fixture.turn, fixture.run,
                active.epoch, 1, ThreadItemDraft(ItemId("cut-call"),
                    ThreadItemContent.ToolCall(CanonicalToolCallId("cut-call"), "plugin.cut.echo", objectValue([])),
                    ItemProvenance("model", runId: Some(fixture.run)))))
        }
        if (scenario == "waiting-run") {
            fixture.database.execute("UPDATE runs SET state='waiting_approval' WHERE id='cut-run'")
        }
        if (scenario == "lane") {
            fixture.database.execute("UPDATE runs SET lane_snapshot=? WHERE id='cut-run'",
                [SqlParameter.Text(encodeStoredValue(modelLaneSnapshotValue(
                    modelLaneReplacingToolSet(fixture.original, fixture.snapshot("other")))))])
        }
        let before = fixture.runtime.threadSnapshot().thread.revision
        let snapshot = if (scenario == "thread") { ToolSetSnapshot("foreign", [], threadId: Some(ThreadId("foreign"))) }
            else { fixture.snapshot("second") }
        let result = fixture.runtime.replaceToolSetAtSafeCut(
            if (scenario == "run") { RunId("wrong") } else { fixture.run },
            active.epoch + if (scenario == "epoch") { 1 } else { 0 }, fixture.original, snapshot)
        expect(result.isError() && fixture.runtime.threadSnapshot().thread.revision == before &&
            fixture.runtime.activeRun().getOrThrow().lane.toolSet.id == "cut-first" &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='model_lane_safe_cut'") == 0,
            "safe cut rejects wrong Run, epoch, scope, durable lane, unfinished call or non-running state: " + scenario)
    } finally { fixture.close() }
}
