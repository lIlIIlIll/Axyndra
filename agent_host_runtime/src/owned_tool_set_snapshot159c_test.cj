package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_plugin_registry.{PluginRegistry, ProductPluginRecord, PluginRegistryResult, copyVerifiedPluginSnapshot}
import agent_extension_runtime.{JavaScriptToolDescriptor, reserveNativeControlMetadata}
import tool_runtime.*
import std.env.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

private class CatalogSnapshotExecutor159c <: ToolExecutor {
    let calls = AtomicInt64(0)
    public func execute(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> {
        calls.fetchAdd(1)
        Result<ToolResult>.Err(AgentError(AgentErrorKind.PermissionDenied,
            "test.snapshot_has_no_execution", "snapshot observation never dispatches a tool"))
    }
}
// The actual spawn captures only this prepaid cell. Clear its target after
// the complete Future.get helper returns; the scheduler never keeps the fixture.
private class CatalogSnapshotWorker159c {
    var target: ?CatalogSnapshotFixture159c
    init(value: CatalogSnapshotFixture159c) { target = Some(value) }
    func run159c(): Bool { target.getOrThrow().compareThenHoldCaller159c() }
}
private class CatalogSnapshotFixture159c {
    var catalog: ?ToolCatalog = Some(ToolCatalog())
    var executor: ?CatalogSnapshotExecutor159c = Some(CatalogSnapshotExecutor159c())
    let capabilities = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: "pi:snapshot159c")])
    var expected: ?ToolSetSnapshot = Option<ToolSetSnapshot>.None
    var owned: ?OwnedToolSetSnapshot159 = Option<OwnedToolSetSnapshot159>.None
    var action: ?CatalogSnapshotWorker159c = Option<CatalogSnapshotWorker159c>.None
    var worker: ?Future<Bool> = Option<Future<Bool>>.None
    let entered = AtomicBool(false)
    let release = AtomicBool(false)
    init(record: ProductPluginRecord) {
        let mount = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
            case Result.Ok(value) => value
            case Result.Err(_) => throw IllegalStateException("real Registry snapshot descriptor was refused")
        }
        let identity = hostRegistryCatalogIdentity159(mount, mount.mountDescriptor159())
        identity.beginCatalogConstruction159()
        let declared = JavaScriptToolDescriptor("snapshot159c", description: "完整 snapshot 雪",
            inputSchemaJson: "{\"type\":\"object\",\"properties\":{\"雪\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}")
        identity.reserveTool159(declared, "snapshot159c")
        let definition = ModelToolDefinition("plugin.pi:snapshot159c.snapshot159c", declared.description,
            decodeAgentValue(declared.inputSchemaJson).value().getOrThrow())
        let descriptor = ToolDescriptor(definition,
            Capability(CapabilityKind.ExtensionInvoke, resource: "pi:snapshot159c"),
            implementationVersion: "snapshot159c", implementationFingerprint: "snapshot159c:frozen")
        identity.retainCatalogAliases159()
        @Expect(catalog.getOrThrow().registerBatch([ToolCatalogRegistration(descriptor, executor.getOrThrow())], dataPayment: Some(identity)).isOk())
        identity.returnedCatalogConstruction159(); mount.returnedMountFrame159()
        // This original public export is intentionally Held and part of the
        // baseline, never a proof of whole catalog/model retirement.
        expected = Some(catalog.getOrThrow().toolSetSnapshot("actual-original159c", capabilities))
        @Expect(expected.getOrThrow().entries.size, 1)
        @Expect(expected.getOrThrow().entries[0].name, "plugin.pi:snapshot159c.snapshot159c")
    }
    func compareThenHoldCaller159c(): Bool {
        let equal = owned.getOrThrow().matchesContent159(expected.getOrThrow())
        entered.store(true)
        let deadline = MonoTime.now() + Duration.second * 5
        while (!release.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
        if (!release.load()) { throw IllegalStateException("actual snapshot caller did not release") }
        equal
    }
    func detachAfterActualWorker159c(): ?LogicalJsonOwnerReservation {
        @Expect(worker.getOrThrow().get())
        worker = Option<Future<Bool>>.None
        action.getOrThrow().target = Option<CatalogSnapshotFixture159c>.None
        action = Option<CatalogSnapshotWorker159c>.None
        // Actual Future return still does not manufacture the marker.
        @Expect(owned.getOrThrow().detachReturnedSnapshot159().isNone())
        owned.getOrThrow().returnedComparisonHelper159()
        let payment = owned.getOrThrow().detachReturnedSnapshot159()
        owned = Option<OwnedToolSetSnapshot159>.None
        payment
    }
}
private func catalogSnapshotUsage159c(actual: (Int64, Int64, Int64), expected: (Int64, Int64, Int64)): Unit {
    @Expect(actual[0], expected[0]); @Expect(actual[1], expected[1]); @Expect(actual[2], expected[2])
}
private func catalogSnapshotProductionFrame159c(record: ProductPluginRecord, probe: LogicalJsonOwnerReservation): Unit {
    let state = CatalogSnapshotFixture159c(record)
    // Warm up only the original physical high-water. Every subsequent real
    // nonempty observation must return exactly to the same SUM/lease count.
    @Expect(state.catalog.getOrThrow().toolSetSnapshotMatches159(state.expected.getOrThrow(), "observed159c", state.capabilities))
    @Expect(state.catalog.getOrThrow().changedToolSetSnapshot159(state.expected.getOrThrow(), "observed159c", state.capabilities).isNone())
    let before = probe.retainedCustodyUsage113()
    for (_ in 0..32) {
        @Expect(state.catalog.getOrThrow().toolSetSnapshotMatches159(state.expected.getOrThrow(), "observed159c", state.capabilities))
        @Expect(state.catalog.getOrThrow().changedToolSetSnapshot159(state.expected.getOrThrow(), "observed159c", state.capabilities).isNone())
        catalogSnapshotUsage159c(probe.retainedCustodyUsage113(), before)
    }
    @Expect(state.executor.getOrThrow().calls.load(), 0)
    state.owned = state.catalog.getOrThrow().ownedToolSetSnapshot159("blocked159c", state.capabilities)
    state.action = Some(CatalogSnapshotWorker159c(state))
    let action = state.action.getOrThrow()
    state.worker = Some(spawn { action.run159c() })
    let deadline = MonoTime.now() + Duration.second * 5
    while (!state.entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
    try {
        @Expect(state.entered.load()); @Expect(state.worker.getOrThrow().tryGet().isNone())
        let held = probe.retainedCustodyUsage113()
        @Expect(held[0] > before[0]); @Expect(held[2], before[2] + 1)
        @Expect(state.owned.getOrThrow().detachReturnedSnapshot159().isNone())
        catalogSnapshotUsage159c(probe.retainedCustodyUsage113(), held)
        state.release.store(true)
        let returned = state.detachAfterActualWorker159c()
        @Expect(returned.isSome())
        // The whole caller/worker/holder helper returned before this close.
        returned.getOrThrow().close()
        let after = probe.retainedCustodyUsage113()
        @Expect(after[0], before[0]); @Expect(after[2], before[2]); @Expect(after[1] >= before[1])
    } finally {
        state.release.store(true)
        match (state.worker) { case Some(value) => let _ = value.get(); case None => () }
        state.worker = Option<Future<Bool>>.None
        match (state.action) { case Some(value) => value.target = Option<CatalogSnapshotFixture159c>.None; case None => () }
        state.action = Option<CatalogSnapshotWorker159c>.None
        state.expected = Option<ToolSetSnapshot>.None
        state.catalog = Option<ToolCatalog>.None
        state.executor = Option<CatalogSnapshotExecutor159c>.None
    }
}
private func catalogSnapshotHistoricalFrame159c(record: ProductPluginRecord, probe: LogicalJsonOwnerReservation): Unit {
    let state = CatalogSnapshotFixture159c(record)
    let before = probe.retainedCustodyUsage113()
    let owned = state.catalog.getOrThrow().ownedToolSetSnapshot159("historical159c", state.capabilities).getOrThrow()
    let raw = owned.exportHistoricalSnapshot159()
    let held = probe.retainedCustodyUsage113()
    @Expect(held[0] > before[0]); @Expect(held[2], before[2] + 1)
    @Expect(raw.entries.size, 1)
    @Expect(state.catalog.getOrThrow().unregister("plugin.pi:snapshot159c.snapshot159c"))
    @Expect(owned.detachReturnedSnapshot159().isNone())
    catalogSnapshotUsage159c(probe.retainedCustodyUsage113(), held)
    @Expect(raw.entries[0].implementationFingerprint, "snapshot159c:frozen")
    @Expect(raw.entries[0].schemaDigest, modelPolicySha256Text(canonicalAgentValue(raw.entries[0].inputSchema)))
    @Expect(state.executor.getOrThrow().calls.load(), 0)
}
private func catalogSnapshotActual159c(historical: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"snapshot159c\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let record = match (registry.importLocal(root + "/source")) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException("real snapshot fixture import failed") } finally { error.close() }
        }
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease()
                fixture.ensureRetainedPeak(4194304)
                var returned = false
                try {
                    if (historical) { catalogSnapshotHistoricalFrame159c(record, probe) }
                    else { catalogSnapshotProductionFrame159c(record, probe) }
                    returned = true
                } finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}
@Test
class ActualOwnedCatalogSnapshot159cTests {
    @TestCase
    func nonemptyOriginalRegistrySnapshotsRetireOnlyAfterCompleteComparisonAndActualFuture159c(): Unit {
        let setup = reserveNativeControlMetadata(65536)
        try { catalogSnapshotActual159c(false) } finally { setup.close() }
    }
    @TestCase
    func publicHistoricalSnapshotRemainsPaidAcrossActualCatalogUnregister159c(): Unit {
        let setup = reserveNativeControlMetadata(65536)
        try { catalogSnapshotActual159c(true) } finally { setup.close() }
    }
}

private func ordinaryCatalogRecord221(value: PluginRegistryResult<ProductPluginRecord>): ProductPluginRecord {
    match (value) {
        case PluginRegistryResult.Ok(record) => record
        case PluginRegistryResult.Err(error) =>
            try { throw IllegalStateException(error.code) } finally { error.close() }
    }
}

@Test
class OrdinaryCatalogLifetimeSmoke221 {
    @TestCase
    func actualPlainNativeCatalogRetiresAfterItsWholePublicationReturns(): Unit {
        let parent = match (getVariable("TMPDIR")) {
            case Some(value) => value
            case None => "/tmp"
        }
        let fixture = match (getVariable("AXYNDRA_NATIVE_TOOL_PLUGIN_FIXTURE")) {
            case Some(value) => value
            case None => throw IllegalStateException("original Native tool fixture is required")
        }
        let root = Directory.createTemp(parent).toString()
        let source = root + "/source"
        Directory.create(source, recursive: true)
        copyVerifiedPluginSnapshot(fixture[..fixture.lastIndexOf("/").getOrThrow()], source)
        File.writeTo(source + "/axyndra.plugin.json", (
            "{\"id\":\"ordinary-catalog\",\"version\":\"1.0.0\"," +
            "\"entry_kind\":\"native-executable\",\"entrypoint\":\"native-plugin-tool\"," +
            "\"sdk_range\":\"[2.0.0,3.0.0)\",\"protocol_range\":\"axyndra-js-host-v2\"," +
            "\"contributions\":[{\"kind\":\"tool\",\"name\":\"echo\"}]}"
        ).toArray())
        let registry = PluginRegistry(root + "/settings", root)
        let host = HostJavaScriptPluginHost({ path => HostLocalReadTargetInspector(path) }, settingsRoot: root + "/settings")
        let catalog = ToolCatalog()
        try {
            ordinaryCatalogRecord221(registry.importLocal(source)).close()
            let record = ordinaryCatalogRecord221(registry.setEnabled("axyndra:ordinary-catalog", true))
            try {
                @Expect(host.ownRegistry(registry).isOk())
                @Expect(hostMountAndRegisterPluginTools(record, host, catalog).isOk())
                @Expect(catalog.definitionNamesEqual159(["plugin.axyndra:ordinary-catalog.echo"]))
                // No public Raw descriptor or snapshot escaped this Catalog.
                // The distinct Host generation still owns its legacy graph.
                @Expect(catalog.retireCatalogData159())
            } finally { record.close() }
        } finally {
            let _ = host.close()
            registry.close()
            remove(root, recursive: true)
        }
    }
}

