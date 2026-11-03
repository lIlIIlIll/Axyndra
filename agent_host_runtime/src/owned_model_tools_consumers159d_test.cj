package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_plugin_registry.{PluginRegistry, ProductPluginRecord, PluginRegistryResult}
import agent_extension_runtime.{JavaScriptToolDescriptor, reserveNativeControlMetadata, nativeControlMetadataUsage113}
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

private class ModelToolsFixtureExecutor159d <: ToolExecutor {
    let calls = AtomicInt64(0)
    public func execute(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> {
        calls.fetchAdd(1)
        Result<ToolResult>.Err(AgentError(AgentErrorKind.PermissionDenied,
            "test.model_tools_must_not_execute", "DATA model tools do not execute effects"))
    }
}

// The fixture pays before this cell, its closures, arrays, schema, or Future.
// A scheduler may retain the cell after get; it retains no target after clear.
private class ModelToolsWorker159d {
    var target: ?ModelToolsFixture159d
    init(target: ModelToolsFixture159d) { this.target = Some(target) }
    func run159d(): Bool { target.getOrThrow().waitThenRead159d() }
}
private class ModelToolsFixture159d {
    var catalog: ?ToolCatalog = Some(ToolCatalog())
    var executor: ?ModelToolsFixtureExecutor159d = Some(ModelToolsFixtureExecutor159d())
    var copied: ?OwnedModelTools159 = None<OwnedModelTools159>
    var originalDescriptor159: ?ToolDescriptor = None<ToolDescriptor>
    var tools: ?Array<ModelToolDefinition> = None<Array<ModelToolDefinition>>
    var first: ?ModelInputToolsBorrow159 = None<ModelInputToolsBorrow159>
    var second: ?ModelInputToolsBorrow159 = None<ModelInputToolsBorrow159>
    var worker: ?Future<Bool> = None<Future<Bool>>
    var action: ?ModelToolsWorker159d = None<ModelToolsWorker159d>
    let entered = AtomicBool(false)
    let released = AtomicBool(false)
    init(record: ProductPluginRecord, resolver!: ?ToolCanonicalArgumentsResolver = None<ToolCanonicalArgumentsResolver>) {
        let mount = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
            case Result.Ok(value) => value
            case Result.Err(_) => throw IllegalStateException("model tools fixture mount was refused")
        }
        let identity = hostRegistryCatalogIdentity159(mount, mount.mountDescriptor159())
        identity.beginCatalogConstruction159()
        let declared = JavaScriptToolDescriptor("inspect", description: "original schema 雪",
            inputSchemaJson: "{\"type\":\"object\",\"properties\":{\"雪\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}")
        identity.reserveTool159(declared, "model-tools159d")
        let definition = ModelToolDefinition("plugin.pi:modeltools159d.inspect", declared.description,
            decodeAgentValue(declared.inputSchemaJson).value().getOrThrow())
        let descriptor = ToolDescriptor(definition,
            Capability(CapabilityKind.ExtensionInvoke, resource: "pi:modeltools159d"),
            implementationVersion: "model-tools159d", implementationFingerprint: "model-tools159d:frozen",
            canonicalArgumentsResolver: resolver)
        if (resolver.isSome()) { originalDescriptor159 = Some(descriptor) }
        @Expect(catalog.getOrThrow().registerBatch(
            [ToolCatalogRegistration(descriptor, executor.getOrThrow())], dataPayment: Some(identity)).isOk())
        identity.returnedCatalogConstruction159(); mount.returnedMountFrame159()
    }
    func copyThenReturnSource159d(): Unit {
        var source = catalog.getOrThrow().sharedToolSetSnapshot159("model-tools159d",
            CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: "pi:modeltools159d")]))
        copied = Some(source.getOrThrow().copyOwnedModelTools159())
        source.getOrThrow().close159(); source = None<SharedToolSetSnapshot159>
        // The actual copy helper has returned. Its graph is independent of
        // the nonempty Catalog and its real backing/producer holders.
        @Expect(catalog.getOrThrow().retireCatalogData159())
        catalog = None<ToolCatalog>
        @Expect(executor.getOrThrow().calls.load(), 0)
        executor = None<ModelToolsFixtureExecutor159d>
        first = Some(copied.getOrThrow().borrowModelTools159())
        second = Some(copied.getOrThrow().borrowModelTools159())
        tools = Some(copied.getOrThrow().definitionsForPreparedRequest159())
    }
    func expectedTools159d(): Bool {
        let values = tools.getOrThrow()
        values.size == 1 && values[0].name == "plugin.pi:modeltools159d.inspect" &&
            values[0].description == "original schema 雪" &&
            canonicalAgentValue(values[0].inputSchema) == canonicalAgentValue(
                decodeAgentValue("{\"type\":\"object\",\"properties\":{\"雪\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}").value().getOrThrow())
    }
    func waitThenRead159d(): Bool {
        entered.store(true)
        let deadline = MonoTime.now() + Duration.second * 5
        while (!released.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
        if (!released.load()) { throw IllegalStateException("model input fixture wait timed out") }
        expectedTools159d()
    }
    func start159d(): Unit {
        action = Some(ModelToolsWorker159d(this))
        let paidCell = action.getOrThrow()
        worker = Some(spawn { paidCell.run159d() })
    }
    func returnPrepared159d(): Unit {
        copied.getOrThrow().closeAfterPreparedFrame159()
        copied = None<OwnedModelTools159>
    }
    func joinedFirst159d(): Unit {
        @Expect(worker.getOrThrow().get())
        worker = None<Future<Bool>>
        action.getOrThrow().target = None<ModelToolsFixture159d>
        action = None<ModelToolsWorker159d>
    }
    func returnFirst159d(): Unit {
        first.getOrThrow().returnModelToolsFrame159(); first = None<ModelInputToolsBorrow159>
    }
    func detachLast159d(): ModelInputToolsBorrow159 {
        // The caller closes only after this whole final raw-consumer helper
        // returned and the actual schema/array references were cleared.
        @Expect(expectedTools159d())
        tools = None<Array<ModelToolDefinition>>
        let result = second.getOrThrow(); second = None<ModelInputToolsBorrow159>
        result
    }
}

private func modelToolsConsumersFrame159d(record: ProductPluginRecord, probe: LogicalJsonOwnerReservation,
    threaded: Bool): Unit {
    let state = ModelToolsFixture159d(record)
    state.copyThenReturnSource159d()
    let admitted = probe.retainedCustodyUsage113()
    if (threaded) {
        state.start159d()
        let deadline = MonoTime.now() + Duration.second * 5
        while (!state.entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
        @Expect(state.entered.load()); @Expect(state.worker.getOrThrow().tryGet().isNone())
    }
    state.returnPrepared159d()
    let waiting = probe.retainedCustodyUsage113()
    @Expect(waiting[0], admitted[0]); @Expect(waiting[1], admitted[1]); @Expect(waiting[2], admitted[2])
    @Expect(state.expectedTools159d())
    if (threaded) {
        state.released.store(true)
        state.joinedFirst159d()
        // A completed Future and cleared scheduler target alone do not ACK.
        let afterJoin = probe.retainedCustodyUsage113()
        @Expect(afterJoin[0], waiting[0]); @Expect(afterJoin[2], waiting[2])
    }
    state.returnFirst159d()
    let one = probe.retainedCustodyUsage113()
    @Expect(one[0], waiting[0] - 4096 - 1024); @Expect(one[2], waiting[2] - 1)
    @Expect(state.expectedTools159d())
    let last = state.detachLast159d()
    last.returnModelToolsFrame159()
}

private func modelToolsActualRegistry159d(threaded: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"modeltools159d\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let record = match (registry.importLocal(root + "/source")) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException("model tools fixture import failed") } finally { error.close() }
        }
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease(); fixture.ensureRetainedPeak(4194304)
                var returned = false
                try {
                    let before = probe.retainedCustodyUsage113()
                    modelToolsConsumersFrame159d(record, probe, threaded)
                    let after = probe.retainedCustodyUsage113()
                    @Expect(after[0], before[0]); @Expect(after[2], before[2]); @Expect(after[1] >= before[1])
                    returned = true
                } finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}
@Test
class ActualModelToolsConsumers159dTests {
    @TestCase
    func nonemptyCopiesKeepBothConsumersPaidAfterPreparedAndCatalogReturn159d(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { modelToolsActualRegistry159d(false) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func actualFutureReturnCannotAcknowledgeSecondModelInputConsumer159d(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { modelToolsActualRegistry159d(true) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}

private func modelToolsDerivedContext159d(parent: ToolInvocationContext,
    shared: SharedToolSetSnapshot159): ToolInvocationContext {
    ToolInvocationContext(parent.runId, parent.sessionId, parent.capabilities,
        epoch: parent.epoch,
        toolContext: ToolContextDescriptor(workspaceRoot: parent.workspaceRoot, cwd: parent.cwd,
            environment: parent.environment, services: parent.services),
        cancellation: parent.cancellation, approvalModeOverride: parent.approvalModeOverride,
        outputSink: parent.outputSink, budget: parent.budget, budgetModeFn: parent.budgetModeFn,
        contextProjection: parent.contextProjection, ownedToolSetSnapshot159: Some(shared))
}
private func modelToolsContextIdentityFrame159d(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation): Unit {
    let fixture = ModelToolsFixture159d(record)
    let caps = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: "pi:modeltools159d")])
    var source = fixture.catalog.getOrThrow().sharedToolSetSnapshot159("model-tools159d", caps,
        threadId: Some(ThreadId("context159d")))
    var independent = fixture.catalog.getOrThrow().sharedToolSetSnapshot159("model-tools159d", caps,
        threadId: Some(ThreadId("context159d")))
    @Expect(source.getOrThrow().hasBoundThread159())
    @Expect(source.getOrThrow().requiredThreadMatches159(ThreadId("context159d")))
    @Expect(!source.getOrThrow().requiredThreadMatches159(ThreadId("other-context159d")))
    @Expect(source.getOrThrow().hasExportName159("plugin.pi:modeltools159d.inspect"))
    @Expect(source.getOrThrow().availableCompleteExport159("plugin.pi:modeltools159d.inspect"))
    @Expect(!source.getOrThrow().sameBacking159(independent.getOrThrow()))
    var parent = Some(ToolInvocationContext(RunId("context-run159d"), SessionId("context159d"), caps,
        epoch: 1, ownedToolSetSnapshot159: Some(source.getOrThrow().fork159())))
    var child = Some(modelToolsDerivedContext159d(parent.getOrThrow(), parent.getOrThrow().forkOwnedToolSetSnapshot159().getOrThrow()))
    var mismatched = Some(modelToolsDerivedContext159d(parent.getOrThrow(), independent.getOrThrow().fork159()))
    @Expect(child.getOrThrow().inheritExecutionControlFrom(parent.getOrThrow()).isOk())
    match (mismatched.getOrThrow().inheritExecutionControlFrom(parent.getOrThrow())) {
        case Result.Ok(_) => @Expect(false)
        case Result.Err(error) => @Expect(error.code, "tool.derived_snapshot_mismatch")
    }
    @Expect(child.getOrThrow().sameToolSetSnapshot159(parent.getOrThrow()))
    @Expect(child.getOrThrow().legacyToolSetSnapshot159.isNone())
    source.getOrThrow().close159(); source = None<SharedToolSetSnapshot159>
    independent.getOrThrow().close159(); independent = None<SharedToolSetSnapshot159>
    @Expect(fixture.catalog.getOrThrow().retireCatalogData159())
    fixture.catalog = None<ToolCatalog>
    @Expect(fixture.executor.getOrThrow().calls.load(), 0)
    fixture.executor = None<ModelToolsFixtureExecutor159d>
    mismatched.getOrThrow().returnOwnedToolSetFrame159(); mismatched = None<ToolInvocationContext>
    let withParent = probe.retainedCustodyUsage113()
    parent.getOrThrow().returnOwnedToolSetFrame159(); parent = None<ToolInvocationContext>
    let withChild = probe.retainedCustodyUsage113()
    // Only the parent's real independent handle retired. Its shared graph and
    // the child's handle must remain live and readable after that helper.
    @Expect(withChild[0], withParent[0] - 4096 - 1024)
    @Expect(withChild[2], withParent[2] - 1)
    @Expect(child.getOrThrow().hasOwnedToolSetSnapshot159())
    @Expect(child.getOrThrow().permitsToolSnapshotThread159(ThreadId("context159d")))
    child.getOrThrow().returnOwnedToolSetFrame159(); child = None<ToolInvocationContext>
}
private func modelToolsContextRegistryFrame159d(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"modeltools159d\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let record = match (registry.importLocal(root + "/source")) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException("context share fixture import failed") } finally { error.close() }
        }
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease(); fixture.ensureRetainedPeak(4194304)
                var returned = false
                try {
                    let before = probe.retainedCustodyUsage113()
                    modelToolsContextIdentityFrame159d(record, probe)
                    let after = probe.retainedCustodyUsage113()
                    @Expect(after[0], before[0]); @Expect(after[2], before[2]); @Expect(after[1] >= before[1])
                    returned = true
                } finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}
@Test
class ActualToolContextShares159dTests {
    @TestCase
    func realFrozenBackingIdentityAndChildShareSurviveParentReturn159d(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { modelToolsContextRegistryFrame159d() } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}

private func modelToolsRuntimeRequire159d<T>(value: Result<T>): T {
    match (value) { case Result.Ok(actual) => actual
        case Result.Err(error) => throw IllegalStateException("real lane fixture failed: " + error.code) }
}
private func modelToolsRuntimeLane159d(catalog: ToolCatalog): ModelLane {
    var source = catalog.sharedToolSetSnapshot159("runtime-model-tools159d",
        CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: "pi:modeltools159d")]),
        threadId: Some(ThreadId("runtime-tools159d")))
    let lane = modelLaneWithSharedToolSet159(ModelLaneRole.Main, "provider", "model", "responses",
        ModelLaneCapabilitiesSnapshot(), 10000, 100, 5, "estimator", "retry", "cache",
        source.getOrThrow(), "system-v1")
    source.getOrThrow().close159(); source = None<SharedToolSetSnapshot159>
    lane
}
private func modelToolsRuntimeFrame159d(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation, database: SqliteDatabase, cancelled: Bool): Unit {
    let fixture = ModelToolsFixture159d(record)
    let sink = SqliteThreadCommitSink(database)
    let coordinator = ThreadCoordinator(sink.createThread(ThreadId("runtime-tools159d"), "workspace"), sink)
    let runtime = AgentThreadRuntime(coordinator,
        ContextProjector("lane-view159d", ConservativeThreadTokenEstimator()), { => 10 })
    var lane = Some(modelToolsRuntimeLane159d(fixture.catalog.getOrThrow()))
    var started = Some(modelToolsRuntimeRequire159d(runtime.startTurn(
        SemanticTurnId("runtime-turn159d"), RunId("runtime-run159d"), ItemId("runtime-user159d"),
        ThreadItemContent.UserMessage(textMessageParts("actual SQLite lane views")),
        lane.getOrThrow(), InvocationContextProjection())))
    // The real TurnStarted SQL helper has returned; the producer's own lane
    // is independent of both the live Runtime and its returned SDK frame.
    lane.getOrThrow().returnOwnedLaneFrame159(); lane = None<ModelLane>
    @Expect(fixture.catalog.getOrThrow().retireCatalogData159())
    fixture.catalog = None<ToolCatalog>
    @Expect(fixture.executor.getOrThrow().calls.load(), 0)
    fixture.executor = None<ModelToolsFixtureExecutor159d>
    var first = runtime.activeRunOwned159()
    var second = runtime.activeRunOwned159()
    @Expect(first.isSome()); @Expect(second.isSome())
    @Expect(first.getOrThrow().snapshot159().lane.hasAvailableTools159())
    var terminal = Some(modelToolsRuntimeRequire159d(if (cancelled) {
        runtime.cancel(1000, expectedRunId: Some(started.getOrThrow().runId),
            expectedEpoch: Some(started.getOrThrow().epoch))
    } else {
        runtime.finish(RunState.Completed, 1000, expectedRunId: Some(started.getOrThrow().runId),
            expectedEpoch: Some(started.getOrThrow().epoch))
    }))
    @Expect(!runtime.hasActiveRun159())
    @Expect(terminal.getOrThrow().run.state == if (cancelled) { RunState.Cancelled } else { RunState.Completed })
    @Expect(terminal.getOrThrow().run.lane.hasAvailableTools159())
    @Expect(second.getOrThrow().snapshot159().lane.hasCompleteToolIdentities159())
    let two = probe.retainedCustodyUsage113()
    first.getOrThrow().returnActiveRunFrame159(); first = None<OwnedActiveRunFrame159>
    let one = probe.retainedCustodyUsage113()
    @Expect(one[0] < two[0]); @Expect(one[2], two[2] - 2)
    @Expect(second.getOrThrow().snapshot159().lane.permitsToolThread159(ThreadId("runtime-tools159d")))
    @Expect(second.getOrThrow().snapshot159().lane.hasAvailableTools159())
    started.getOrThrow().returnOwnedLaneView159(); started = None<ActiveRunSnapshot>
    terminal.getOrThrow().run.returnOwnedLaneView159(); terminal = None<RuntimeSettlement>
    // Neither durable completion/cancellation nor returning the initial and
    // terminal frames can acknowledge the remaining independent consumer.
    @Expect(second.getOrThrow().snapshot159().lane.hasAvailableTools159())
    second.getOrThrow().returnActiveRunFrame159(); second = None<OwnedActiveRunFrame159>
}
private func modelToolsRuntimeRegistry159d(cancelled: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"modeltools159d\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let record = match (registry.importLocal(root + "/source")) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException("runtime share import failed") } finally { error.close() }
        }
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease(); fixture.ensureRetainedPeak(4194304)
                var returned = false
                try {
                    let before = probe.retainedCustodyUsage113()
                    let database = SqliteDatabase(root + "/lane.sqlite")
                    try { modelToolsRuntimeFrame159d(record, probe, database, cancelled) }
                    finally { database.close() }
                    let after = probe.retainedCustodyUsage113()
                    @Expect(after[0], before[0]); @Expect(after[2], before[2]); @Expect(after[1] >= before[1])
                    returned = true
                } finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}
@Test
class ActualRuntimeLaneViews159dTests {
    @TestCase
    func actualSqliteCompletionDoesNotRetireIndependentSdkLaneViews159d(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { modelToolsRuntimeRegistry159d(false) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func actualSqliteCancellationKeepsViewsUntilTheirOwnConsumersReturn159d(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { modelToolsRuntimeRegistry159d(true) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}

// The actual registered canonicalizer deliberately keeps its Context object.
// This is not permission to keep its private catalog loan after that call.
private class SavedCanonicalContext159d {
    var saved: ?ToolInvocationContext = None<ToolInvocationContext>
    var retained: ?SharedToolSetSnapshot159 = None<SharedToolSetSnapshot159>
    let keepShare: Bool
    let entered = AtomicBool(false)
    let released = AtomicBool(false)
    init(keepShare: Bool) { this.keepShare = keepShare }
    func capture159d(context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
        @Expect(context.hasOwnedToolSetSnapshot159())
        @Expect(context.runId.value, "scoped-run159d")
        saved = Some(context)
        if (keepShare) { retained = context.forkOwnedToolSetSnapshot159() }
        Result.Ok(call.arguments)
    }
    func checkSavedRevoked159d(): Bool {
        var rejected = false
        try { let _ = saved.getOrThrow().forkOwnedToolSetSnapshot159() }
        catch (_: IllegalStateException) { rejected = true }
        if (!rejected) { return false }
        rejected = false
        try { let _ = saved.getOrThrow().nextSequence() }
        catch (_: IllegalStateException) { rejected = true }
        if (!rejected) { return false }
        rejected = false
        try { let _ = saved.getOrThrow().runId }
        catch (_: IllegalStateException) { rejected = true }
        rejected
    }
    func delayed159d(): Bool {
        entered.store(true)
        let deadline = MonoTime.now() + Duration.second * 5
        while (!released.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
        if (!released.load()) { throw IllegalStateException("scoped context fixture wait timed out") }
        checkSavedRevoked159d()
    }
}
private class SavedCanonicalWorker159d {
    var target: ?SavedCanonicalContext159d
    init(target: SavedCanonicalContext159d) { this.target = Some(target) }
    func run159d(): Bool { target.getOrThrow().delayed159d() }
}
private func scopedContextConsumersFrame159d(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation, keepShare: Bool): Unit {
    let before = probe.retainedCustodyUsage113()
    let state = SavedCanonicalContext159d(keepShare)
    let fixture = ModelToolsFixture159d(record,
        resolver: Some({ context, call => state.capture159d(context, call) }))
    let caps = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: "pi:modeltools159d")])
    var snapshot = fixture.catalog.getOrThrow().sharedToolSetSnapshot159("scoped159d", caps,
        threadId: Some(ThreadId("scoped-thread159d")))
    var parent = Some(ToolInvocationContext(RunId("scoped-run159d"), SessionId("scoped-thread159d"), caps,
        ownedToolSetSnapshot159: Some(snapshot.getOrThrow().fork159())))
    snapshot.getOrThrow().close159(); snapshot = None<SharedToolSetSnapshot159>
    let workerCell = SavedCanonicalWorker159d(state)
    var worker = Some(spawn { workerCell.run159d() })
    let deadline = MonoTime.now() + Duration.second * 5
    while (!state.entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
    @Expect(state.entered.load()); @Expect(worker.getOrThrow().tryGet().isNone())
    // This is the same real descriptor/resolver that registerBatch froze.
    // No public Catalog getter creates an unrelated historical raw export.
    let call = ToolCall("scoped-call159d", "plugin.pi:modeltools159d.inspect", objectValue([]))
    match (fixture.originalDescriptor159.getOrThrow().canonicalizedCall(parent.getOrThrow(), call)) {
        case Result.Err(_) => @Expect(false)
        case Result.Ok(value) => @Expect(canonicalAgentValue(value.arguments), canonicalAgentValue(call.arguments))
    }
    @Expect(state.checkSavedRevoked159d())
    @Expect(parent.getOrThrow().runId.value, "scoped-run159d")
    @Expect(parent.getOrThrow().hasOwnedToolSetSnapshot159())
    state.released.store(true)
    @Expect(worker.getOrThrow().get())
    worker = None<Future<Bool>>; workerCell.target = None<SavedCanonicalContext159d>
    fixture.originalDescriptor159 = None<ToolDescriptor>
    @Expect(fixture.catalog.getOrThrow().retireCatalogData159())
    fixture.catalog = None<ToolCatalog>
    @Expect(fixture.executor.getOrThrow().calls.load(), 0)
    fixture.executor = None<ModelToolsFixtureExecutor159d>
    parent.getOrThrow().returnOwnedToolSetFrame159(); parent = None<ToolInvocationContext>
    if (keepShare) {
        let held = probe.retainedCustodyUsage113()
        @Expect(held[0] > before[0]); @Expect(held[2] > before[2])
        @Expect(state.retained.getOrThrow().availableCompleteExport159("plugin.pi:modeltools159d.inspect"))
        state.retained.getOrThrow().close159(); state.retained = None<SharedToolSetSnapshot159>
    }
    let returned = probe.retainedCustodyUsage113()
    @Expect(returned[0], before[0]); @Expect(returned[2], before[2])
    // Still retaining the rejected Context shell cannot hold the original
    // Catalog or create a fresh authority. This check occurs before clearing it.
    @Expect(state.saved.isSome()); @Expect(state.checkSavedRevoked159d())
    state.saved = None<ToolInvocationContext>
}
private func scopedContextActualRegistry159d(keepShare: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"modeltools159d\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let record = match (registry.importLocal(root + "/source")) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException("scoped context fixture import failed") } finally { error.close() }
        }
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease(); fixture.ensureRetainedPeak(4194304)
                var returned = false
                try { scopedContextConsumersFrame159d(record, probe, keepShare); returned = true }
                finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}
@Test
class ActualScopedCanonicalContext159dTests {
    @TestCase
    func retainedCanonicalizerContextAndRealDelayedFutureCannotReuseReturnedView159d(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { scopedContextActualRegistry159d(false) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func explicitIndependentShareStaysPaidAfterCanonicalizerViewRevocation159d(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { scopedContextActualRegistry159d(true) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}

// These controls use the same imported Registry/Catalog and original bank.
// A retained Context outlives its producer's public view. A concurrent action
// keeps its actual handler frame, rather than an enum or close return, paid.
private class ScopedActionState159d {
    var context: ?ToolInvocationContext = None<ToolInvocationContext>
    var worker: ?Future<Bool> = None<Future<Bool>>
    let entered = AtomicBool(false)
    let release = AtomicBool(false)
    func handler159d(id: OperationId, action: () -> Result<Unit>): Result<Unit> {
        @Expect(id.value, "scoped-action159d")
        entered.store(true)
        let deadline = MonoTime.now() + Duration.second * 5
        while (!release.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
        if (!release.load()) { throw IllegalStateException("actual action frame did not return") }
        action()
    }
    func execute159d(): Bool {
        context.getOrThrow().withNestedToolSlot(OperationId("scoped-action159d"),
            { => Result<Unit>.Ok(()) }).isOk()
    }
    func capture159d(actual: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
        context = Some(actual)
        worker = Some(spawn { execute159d() })
        let deadline = MonoTime.now() + Duration.second * 5
        while (!entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
        @Expect(entered.load()); @Expect(worker.getOrThrow().tryGet().isNone())
        Result.Ok(call.arguments)
    }
    func savedRevoked159d(): Bool {
        var refused = false
        try { let _ = context.getOrThrow().nextSequence() }
        catch (_: IllegalStateException) { refused = true }
        refused
    }
}
private func retainedContextActionFrame159d(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation, concurrent: Bool): Unit {
    let before = probe.retainedCustodyUsage113()
    let state = ScopedActionState159d()
    let resolver: ?ToolCanonicalArgumentsResolver = if (concurrent) {
        Some({ actual, call => state.capture159d(actual, call) })
    } else { None<ToolCanonicalArgumentsResolver> }
    let fixture = ModelToolsFixture159d(record, resolver: resolver)
    let caps = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: "pi:modeltools159d")])
    var snapshot = fixture.catalog.getOrThrow().sharedToolSetSnapshot159("retained-context159d", caps,
        threadId: Some(ThreadId("retained-thread159d")))
    var parent = Some(ToolInvocationContext(RunId("retained-run159d"), SessionId("retained-thread159d"), caps,
        ownedToolSetSnapshot159: Some(snapshot.getOrThrow().fork159())))
    snapshot.getOrThrow().close159(); snapshot = None<SharedToolSetSnapshot159>
    var retained = None<ToolInvocationContext>
    var successor = None<ToolInvocationContext>
    if (concurrent) {
        parent.getOrThrow().setNestedToolScheduler({ id, action => state.handler159d(id, action) })
        let call = ToolCall("scoped-action-call159d", "plugin.pi:modeltools159d.inspect", objectValue([]))
        match (fixture.originalDescriptor159.getOrThrow().canonicalizedCall(parent.getOrThrow(), call)) {
            case Result.Ok(_) => ()
            case Result.Err(_) => @Expect(false)
        }
        // The canonicalizer has returned and its scope is revoked. The real
        // concurrent handler has entered and is still blocked inside its body.
        @Expect(state.savedRevoked159d()); @Expect(state.entered.load())
        @Expect(state.worker.getOrThrow().tryGet().isNone())
    } else {
        retained = Some(parent.getOrThrow().retainInvocationContext159())
        @Expect(retained.getOrThrow().nextSequence(), 1)
    }
    fixture.originalDescriptor159 = None<ToolDescriptor>
    @Expect(fixture.catalog.getOrThrow().retireCatalogData159())
    fixture.catalog = None<ToolCatalog>; fixture.executor = None<ModelToolsFixtureExecutor159d>
    parent.getOrThrow().returnOwnedToolSetFrame159()
    var rejected = false
    try { let _ = parent.getOrThrow().runId } catch (_: IllegalStateException) { rejected = true }
    @Expect(rejected)
    parent = None<ToolInvocationContext>
    let held = probe.retainedCustodyUsage113()
    @Expect(held[0] > before[0]); @Expect(held[2] > before[2])
    if (concurrent) {
        // Revocation must retain the exact data debt while the captured
        // handler is live, including after the producer owner has returned.
        @Expect(state.worker.getOrThrow().tryGet().isNone())
        state.release.store(true)
        @Expect(state.worker.getOrThrow().get())
        state.worker = None<Future<Bool>>
        @Expect(state.savedRevoked159d())
        state.context = None<ToolInvocationContext>
    } else {
        @Expect(retained.getOrThrow().runId.value, "retained-run159d")
        @Expect(retained.getOrThrow().nextSequence(), 2)
        @Expect(retained.getOrThrow().hasOwnedToolSetSnapshot159())
        // A real live retained child may transfer a further independent share
        // after the original public parent has already been revoked.
        successor = Some(retained.getOrThrow().retainInvocationContext159())
        retained.getOrThrow().returnOwnedToolSetFrame159()
        retained = None<ToolInvocationContext>
        @Expect(successor.getOrThrow().nextSequence(), 3)
        @Expect(successor.getOrThrow().runId.value, "retained-run159d")
        @Expect(successor.getOrThrow().permitsToolSnapshotThread159(ThreadId("retained-thread159d")))
        successor.getOrThrow().returnOwnedToolSetFrame159()
        successor = None<ToolInvocationContext>
    }
    let returned = probe.retainedCustodyUsage113()
    @Expect(returned[0], before[0]); @Expect(returned[2], before[2])
}
private func retainedContextActionRegistry159d(concurrent: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"modeltools159d\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let record = match (registry.importLocal(root + "/source")) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException("retained context fixture import failed") } finally { error.close() }
        }
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease(); fixture.ensureRetainedPeak(4194304)
                var returned = false
                try { retainedContextActionFrame159d(record, probe, concurrent); returned = true }
                finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}
@Test
class ActualRetainedContextActions159dTests {
    @TestCase
    func retainedChildMetadataAndSequenceSurviveRevokedProducerUntilLastRealReturn159d(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { retainedContextActionRegistry159d(false) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func revocationWaitsForActualConcurrentHandlerFrameBeforeBankRetirement159d(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { retainedContextActionRegistry159d(true) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}

private func modelToolsAddActualRegistration159d(record: ProductPluginRecord, catalog: ToolCatalog,
    executor: ModelToolsFixtureExecutor159d): Unit {
    let mount = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw IllegalStateException("second actual mount was refused")
    }
    let identity = hostRegistryCatalogIdentity159(mount, mount.mountDescriptor159())
    identity.beginCatalogConstruction159()
    let declared = JavaScriptToolDescriptor("second", description: "second actual schema 雪",
        inputSchemaJson: "{\"type\":\"object\",\"properties\":{\"second\":{\"type\":\"boolean\"}}}")
    identity.reserveTool159(declared, "model-tools159d-second")
    let descriptor = ToolDescriptor(ModelToolDefinition("plugin.pi:modeltools159d.second", declared.description,
        decodeAgentValue(declared.inputSchemaJson).value().getOrThrow()),
        Capability(CapabilityKind.ExtensionInvoke, resource: "pi:modeltools159d"),
        implementationVersion: "model-tools159d-second", implementationFingerprint: "model-tools159d:second:frozen")
    @Expect(catalog.registerBatch([ToolCatalogRegistration(descriptor, executor)], dataPayment: Some(identity)).isOk())
    identity.returnedCatalogConstruction159(); mount.returnedMountFrame159()
}
private func modelToolsSafeCutFrame159d(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation, database: SqliteDatabase): Unit {
    let baseline = probe.retainedCustodyUsage113()
    let fixture = ModelToolsFixture159d(record)
    let sink = SqliteThreadCommitSink(database)
    let coordinator = ThreadCoordinator(sink.createThread(ThreadId("runtime-tools159d"), "workspace"), sink)
    let runtime = AgentThreadRuntime(coordinator,
        ContextProjector("lane-cut159d", ConservativeThreadTokenEstimator()), { => 10 })
    var lane = Some(modelToolsRuntimeLane159d(fixture.catalog.getOrThrow()))
    var started = Some(modelToolsRuntimeRequire159d(runtime.startTurn(
        SemanticTurnId("runtime-turn159d"), RunId("runtime-run159d"), ItemId("runtime-user159d"),
        ThreadItemContent.UserMessage(textMessageParts("actual paid SQLite safe cut")),
        lane.getOrThrow(), InvocationContextProjection())))
    lane.getOrThrow().returnOwnedLaneFrame159(); lane = None<ModelLane>
    let caps = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: "pi:modeltools159d")])
    var expected = started.getOrThrow().lane.forkOwnedToolSetSnapshot159()
    var original = Some(ToolInvocationContext(started.getOrThrow().runId, SessionId("runtime-tools159d"), caps,
        epoch: started.getOrThrow().epoch, ownedToolSetSnapshot159: Some(expected.getOrThrow().fork159())))
    var retained = Some(original.getOrThrow().retainInvocationContext159())
    original.getOrThrow().returnOwnedToolSetFrame159(); original = None<ToolInvocationContext>
    modelToolsAddActualRegistration159d(record, fixture.catalog.getOrThrow(), fixture.executor.getOrThrow())
    var replacement = fixture.catalog.getOrThrow().changedSharedToolSetSnapshot159(expected.getOrThrow(),
        RunId("runtime-run159d"), caps, threadId: Some(ThreadId("runtime-tools159d")))
    @Expect(replacement.isSome())
    @Expect(replacement.getOrThrow().availableCompleteExport159("plugin.pi:modeltools159d.second"))
    @Expect(!expected.getOrThrow().hasExportName159("plugin.pi:modeltools159d.second"))
    @Expect(retained.getOrThrow().toolEntryDescriptionEquals159(0, "original schema 雪"))
    var updated = Some(modelToolsRuntimeRequire159d(runtime.replaceOwnedToolSetAtSafeCut159(
        RunId("runtime-run159d"), started.getOrThrow().epoch, started.getOrThrow().lane, replacement.getOrThrow())))
    @Expect(updated.getOrThrow().runId.value, started.getOrThrow().runId.value)
    @Expect(updated.getOrThrow().epoch, started.getOrThrow().epoch)
    @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='model_lane_safe_cut'"), 1)
    @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
    @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
    // Reusing the actual old full lane loses the original durable CAS. It
    // cannot manufacture a second Run, receipt or successful cut.
    match (runtime.replaceOwnedToolSetAtSafeCut159(RunId("runtime-run159d"), started.getOrThrow().epoch,
        started.getOrThrow().lane, replacement.getOrThrow())) {
        case Result.Ok(_) => @Expect(false)
        case Result.Err(error) => @Expect(error.code, "run.model_lane_cut_conflict")
    }
    @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='model_lane_safe_cut'"), 1)
    expected.getOrThrow().close159(); expected = None<SharedToolSetSnapshot159>
    replacement.getOrThrow().close159(); replacement = None<SharedToolSetSnapshot159>
    @Expect(fixture.catalog.getOrThrow().retireCatalogData159())
    fixture.catalog = None<ToolCatalog>
    @Expect(fixture.executor.getOrThrow().calls.load(), 0)
    fixture.executor = None<ModelToolsFixtureExecutor159d>
    var terminal = Some(modelToolsRuntimeRequire159d(runtime.finish(RunState.Completed, 1000,
        expectedRunId: Some(started.getOrThrow().runId), expectedEpoch: Some(started.getOrThrow().epoch))))
    @Expect(!runtime.hasActiveRun159())
    updated.getOrThrow().returnOwnedLaneView159(); updated = None<ActiveRunSnapshot>
    started.getOrThrow().returnOwnedLaneView159(); started = None<ActiveRunSnapshot>
    terminal.getOrThrow().run.returnOwnedLaneView159(); terminal = None<RuntimeSettlement>
    let held = probe.retainedCustodyUsage113()
    @Expect(held[0] > baseline[0]); @Expect(held[2] > baseline[2])
    @Expect(retained.getOrThrow().toolEntryDescriptionEquals159(0, "original schema 雪"))
    @Expect(retained.getOrThrow().epoch, 1)
    @Expect(retained.getOrThrow().runId.value, "runtime-run159d")
    retained.getOrThrow().returnOwnedToolSetFrame159(); retained = None<ToolInvocationContext>
    let returned = probe.retainedCustodyUsage113()
    @Expect(returned[0], baseline[0]); @Expect(returned[2], baseline[2])
}

private func modelToolsSafeCutRegistry159d(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"modeltools159d\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let record = match (registry.importLocal(root + "/source")) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException("runtime share import failed") } finally { error.close() }
        }
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease(); fixture.ensureRetainedPeak(4194304)
                var returned = false
                try {
                    let before = probe.retainedCustodyUsage113()
                    let database = SqliteDatabase(root + "/lane.sqlite")
                    try { modelToolsSafeCutFrame159d(record, probe, database) }
                    finally { database.close() }
                    let after = probe.retainedCustodyUsage113()
                    @Expect(after[0], before[0]); @Expect(after[2], before[2]); @Expect(after[1] >= before[1])
                    returned = true
                } finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}

@Test
class ActualPaidCatalogSafeCut159dTests {
    @TestCase
    func realRegistryAndSqliteCutKeepsOldConsumerUntilItsOwnFinalReturn159d(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { modelToolsSafeCutRegistry159d() } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}
