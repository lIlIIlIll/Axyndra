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
import yjson.*
import yjson_support.*

class CutContextTool <: ToolExecutor {
    let contexts = ArrayList<ToolInvocationContext>()
    let preparedCalls = ArrayList<PreparedToolInvocation>()
    var ownedTasks: Int64 = 0
    func returnContextsAfterAssertions159(): Unit {
        preparedCalls.clear()
        while (!contexts.isEmpty()) {
            let returned = detachContext159()
            returned.returnOwnedToolSetFrame159()
        }
    }
    private func detachContext159(): ToolInvocationContext {
        let value = contexts[contexts.size - 1]
        contexts.remove(at: contexts.size - 1)
        value
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        contexts.add(context.retainInvocationContext159())
        preparedCalls.add(prepared)
        expect(context.budget.snapshot().activeTools == 1, "each changed-view executor owns the same exclusive slot")
        // The replacement context must bind to the real existing Run owner,
        // not merely retain a budget/token while losing asynchronous ownership.
        // This probe performs no effect; the nested-ownership contract tests
        // live work and quarantine separately.
        let task = spawn { => () }
        match (context.ownTask("catalog-cut/" + prepared.operationId.value, task)) {
            case Result.Err(error) => task.get(); return Result.Err(error)
            case Result.Ok(_) => ownedTasks += 1
        }
        task.get()
        Result.Ok(ToolResult(prepared.call.callId, objectValue([])))
    }
}

class CutManifestCapture <: ModelContextManifestRuntimePort {
    let lanes = ArrayList<ModelLane>()
    let revisions = ArrayList<Int64>()
    public func recordBeforeModelEffect(request: AgentRunRequest, requestId: RequestId,
        turnId: SemanticTurnId, executionLaneId: LaneId, stepId: StepId, stepOrdinal: Int64,
        projection: ModelContextProjection, lane: ModelLane, renderedRequest: AgentValue,
        estimatedInputTokens: Int64, observedAtMillis: Int64): Result<Unit> {
        lanes.add(modelLaneFromSnapshotValue(parseUnifiedJson(stringifyUnifiedJson(modelLaneSnapshotValue(lane)))))
        revisions.add(projection.threadRevision)
        Result.Ok(())
    }
}

class CutDirectoryModel <: ModelPort {
    let requests = ArrayList<ModelRequest>()
    private let catalog: ToolCatalog
    private let owner: ToolCatalogOwner
    private let second: CutContextTool
    private let empty: Bool
    init(catalog: ToolCatalog, owner: ToolCatalogOwner, second: CutContextTool, empty: Bool) {
        this.catalog = catalog
        this.owner = owner
        this.second = second
        this.empty = empty
    }
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        requests.add(request)
        events(ModelEvent.Completed)
        if (requests.size == 1) {
            let next: Array<ToolCatalogRegistration> = if (empty) { [] } else { [cutRegistration(second, "second")] }
            expect(catalog.replaceOwnedBatch(owner, 1, cutBinding(2), next).isOk(),
                "real owner CAS publishes while the first model request is already frozen")
            return Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.ToolCall,
                callId: "cut-first-call", name: "plugin.cut.echo", arguments: objectValue([]))]))
        }
        if (requests.size == 2 && !empty) {
            return Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.ToolCall,
                callId: "cut-second-call", name: "plugin.cut.echo", arguments: objectValue([]))]))
        }
        Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "cut complete")], stopReason: "end_turn"))
    }
}

func cutBinding(revision: Int64): ToolContributionBinding {
    ToolContributionBinding("sha256:" + modelPolicySha256Text("cut-package"),
        modelPolicySha256Text("cut-configuration"), "actual-cut-endpoint-and-lease", revision)
}
func cutRegistration(tool: CutContextTool, version: String): ToolCatalogRegistration {
    ToolCatalogRegistration(ToolDescriptor(ModelToolDefinition("plugin.cut.echo", version, objectValue([])),
        Capability(CapabilityKind.WorkspaceRead), implementationVersion: version,
        implementationFingerprint: "cut-adapter-" + version), tool)
}

func coreCatalogSafeCutContracts(): Unit {
    for (empty in [false, true]) {
        let first = CutContextTool(); let second = CutContextTool()
        try { coreCatalogSafeCutFrame159(empty, first, second) }
        finally { first.returnContextsAfterAssertions159(); second.returnContextsAfterAssertions159() }
    }
    durableCoreCatalogSafeCutContract()
    println("Core catalog safe-cut contract passed (same Run replacement and empty directory)")
}
private func coreCatalogSafeCutFrame159(empty: Bool, first: CutContextTool, second: CutContextTool): Unit {
    let catalog = ToolCatalog()
    let owner = catalog.createContributionOwner("cut-owner", "plugin.cut.",
        threadId: Some(ThreadId("cut-thread"))).value().getOrThrow()
    catalog.replaceOwnedBatch(owner, 0, cutBinding(1), [cutRegistration(first, "first")]).value().getOrThrow()
    let model = CutDirectoryModel(catalog, owner, second, empty)
    let manifests = CutManifestCapture()
    let runs = MemoryRuns()
    let result = AgentCore(model, runs,
        ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()), catalog,
        contextManifestRuntime: Some(manifests)).start(AgentRunRequest(RunId("cut-run"),
            SessionId("cut-thread"), "fixture", "replace directory between model effects",
            capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
            budget: ResourceBudget(maxConcurrentTools: 1, maxToolCalls: 2)))
    expect(result.isOk() && first.contexts.size == 1 && first.contexts[0].toolEntryDescriptionEquals159(0, "first"),
        "the already-requested first tool keeps its original executor despite concurrent directory publication")
    expect(manifests.lanes.size == model.requests.size && manifests.lanes[0].toolSet.id != manifests.lanes[1].toolSet.id &&
        manifests.revisions[1] > manifests.revisions[0] && model.requests[0].tools[0].description == "first",
        "one same-Run canonical safe cut changes the next ModelContextManifest and model request")
    if (empty) {
        expect(model.requests.size == 2 && model.requests[1].tools.isEmpty() &&
            !manifests.lanes[1].capabilities.tools && second.contexts.isEmpty(),
            "an empty published directory takes effect at the next cut without inventing a Tool")
    } else {
        expect(model.requests.size == 3 && model.requests[1].tools[0].description == "second" &&
            second.contexts.size == 1 && second.contexts[0].toolEntryDescriptionEquals159(0, "second"),
            "the next same-Run model ToolCall executes exactly the new retained registration")
        let old = first.contexts[0]
        let current = second.contexts[0]
        expect(!refEq(old, current) && refEq(old.budget, current.budget) &&
            refEq(old.cancellation, current.cancellation) && old.runId.value == current.runId.value &&
            old.epoch == current.epoch && old.budget.snapshot().toolCalls == 2 &&
            old.budget.snapshot().activeTools == 0 &&
            !old.sameToolSetIdentity159(current),
            "new context view shares real Run budget/token/slot but never mutates an old Prepared view")
        expect(first.ownedTasks == 1 && second.ownedTasks == 1,
            "both original and safe-cut views retain the actual Run/epoch-bound asynchronous task owner")
        expect(current.currentSequence() == old.currentSequence() &&
            current.nextAuditSequence() == old.nextAuditSequence() - 1,
            "event and audit sequence allocation remains one stream across context views")
        expect(manifests.lanes[1].toolSet.id == manifests.lanes[2].toolSet.id,
            "an unchanged catalog does not create another context cut")
    }
}

class DurableCutManifest <: ModelContextManifestRuntimePort {
    let ids = ArrayList<ContextManifestId>()
    private let database: SqliteDatabase
    init(database: SqliteDatabase) { this.database = database }
    public func recordBeforeModelEffect(request: AgentRunRequest, requestId: RequestId,
        turnId: SemanticTurnId, executionLaneId: LaneId, stepId: StepId, stepOrdinal: Int64,
        projection: ModelContextProjection, lane: ModelLane, renderedRequest: AgentValue,
        estimatedInputTokens: Int64, observedAtMillis: Int64): Result<Unit> {
        let store = SqliteContextManifestStore(database)
        match (store.ensureModelStep(request.runId, ThreadId(request.sessionId.value), executionLaneId,
            turnId, stepId, stepOrdinal, None, None, observedAtMillis)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let manifest = match (ContextCompiler("durable-cut-compiler").compile(ContextCompileInput(
            ContextManifestId("cut-manifest-" + requestId.value), ThreadId(request.sessionId.value),
            executionLaneId, turnId, stepId, projection, ItemId("user-" + request.runId.value),
            objectValue([]), [], [], [], [], lane, renderedRequest))) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        match (store.save(manifest, [], observedAtMillis)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        ids.add(manifest.id)
        store.recordContextReady(request.runId, manifest, observedAtMillis)
    }
}

class DurableCutModel <: ModelPort {
    private let model: CutDirectoryModel
    private let database: SqliteDatabase
    private var firstAttempt = ""
    var calls: Int64 = 0
    var lateClearPreserved = false
    var uncommittedClearDenied = false
    init(model: CutDirectoryModel, database: SqliteDatabase) { this.model = model; this.database = database }
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls += 1
        let active = database.query("SELECT active_attempt_id,payload FROM run_continuations WHERE run_id='cut-run'")[0]
        if (calls == 1) { firstAttempt = active.required(0) }
        if (calls == 2) {
            let repository = SqliteRunRepository(database)
            lateClearPreserved = repository.clearModelExecutionContinuation(RunId("cut-run"), ModelAttemptId(firstAttempt)).isOk() &&
                database.query("SELECT payload FROM run_continuations WHERE run_id='cut-run'")[0].required(0) == active.required(1)
            uncommittedClearDenied = repository.clearModelExecutionContinuation(RunId("cut-run"), ModelAttemptId(active.required(0))).isError() &&
                database.query("SELECT payload FROM run_continuations WHERE run_id='cut-run'")[0].required(0) == active.required(1)
        }
        model.execute(request, events)
    }
}

func durableCoreCatalogSafeCutContract(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(root + "/core-cut.db")
    try {
        let first = CutContextTool(); let second = CutContextTool()
        try { durableCoreCatalogSafeCutFrame159(root, database, first, second) }
        finally { first.returnContextsAfterAssertions159(); second.returnContextsAfterAssertions159() }
    } finally { database.close(); remove(root, recursive: true) }
}
private func durableCoreCatalogSafeCutFrame159(root: String, database: SqliteDatabase,
    first: CutContextTool, second: CutContextTool): Unit {
    let catalog = ToolCatalog()
    let owner = catalog.createContributionOwner("cut-owner", "plugin.cut.", threadId: Some(ThreadId("cut-thread")))
        .value().getOrThrow()
    catalog.replaceOwnedBatch(owner, 0, cutBinding(1), [cutRegistration(first, "first")]).value().getOrThrow()
    let model = DurableCutModel(CutDirectoryModel(catalog, owner, second, false), database)
    let operations = DurableOperationStore(database)
    let contexts = DurableCutManifest(database)
    let threads = SqliteThreadRuntimeRegistry(database,
        ContextProjector("durable-cut", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
    let result = AgentCore(model, SqliteRunRepository(database),
        ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds()), catalog,
        threadRuntimes: Some(threads), operationRuntime: Some(operations),
        modelDecisionRuntime: Some(SqliteModelDecisionStore(database)), contextManifestRuntime: Some(contexts))
        .start(AgentRunRequest(RunId("cut-run"), SessionId("cut-thread"), "fixture", "refresh on one real durable Run",
            capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
            budget: ResourceBudget(maxConcurrentTools: 1, maxToolCalls: 2)))
    expect(result.isOk() && model.calls == 3 && first.contexts.size == 1 && second.contexts.size == 1 &&
        first.ownedTasks == 1 && second.ownedTasks == 1 &&
        model.lateClearPreserved && model.uncommittedClearDenied,
        "actual SQLite/Core model settlement, next safe cut and two tool calls retain exact identities without late-clear deletion")
    expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") == 2 &&
        database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='model_lane_safe_cut'") == 1 &&
        database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='model_continuation_settled'") == 3 &&
        database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE canonical_committed_at_millis IS NOT NULL") == 3,
        "real decisions, receipts, one directory cut and per-Attempt settlement remain distinct durable facts")
    let store = SqliteContextManifestStore(database)
    let firstManifest = store.load(contexts.ids[0]).value().getOrThrow()
    let nextManifest = store.load(contexts.ids[1]).value().getOrThrow()
    expect(firstManifest.digest != nextManifest.digest &&
        firstManifest.toolCatalogSnapshot.field("snapshot_id").getOrThrow().text !=
            nextManifest.toolCatalogSnapshot.field("snapshot_id").getOrThrow().text &&
        database.scalarInt("SELECT COUNT(*) FROM composition_snapshots") == 2,
        "the same ContextCompiler/store records old and new immutable ContextVersions, not a second snapshot registry")
    let reopened = SqliteDatabase(root + "/core-cut.db")
    try {
        expect(SqliteContextManifestStore(reopened).load(contexts.ids[0]).value().getOrThrow().digest == firstManifest.digest &&
            SqliteContextManifestStore(reopened).load(contexts.ids[1]).value().getOrThrow().digest == nextManifest.digest,
            "a separately opened Store observes exactly both historical manifests after the same-Run update")
    } finally { reopened.close() }
}
