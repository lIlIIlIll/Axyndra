package agent_host_runtime

import agent_domain.*
import agent_plugin_registry.*
import agent_extension_runtime.{JavaScriptToolDescriptor, reserveNativeControlMetadata, nativeControlMetadataUsage113}
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

private class RegistryCatalogBackingExecutor159 <: ToolExecutor {
    let calls = AtomicInt64(0)
    public func execute(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> {
        calls.fetchAdd(1)
        Result<ToolResult>.Err(AgentError(AgentErrorKind.PermissionDenied,
            "test.catalog_backing_no_effect", "catalog backing control never invokes a tool"))
    }
}

// Created only after the actual Registry bank has paid the two-MiB fixture
// reservation. This carrier owns the actual worker action and catalog refs.
private class RegistryCatalogBackingControl159 {
    let entered = AtomicBool(false)
    let released = AtomicBool(false)
    var catalog: ?ToolCatalog = Some(ToolCatalog())
    var first: ?HostRegistryCatalogIdentity159
    var worker: ?Future<Bool> = Option<Future<Bool>>.None
    var executor: ?RegistryCatalogBackingExecutor159 = Some(RegistryCatalogBackingExecutor159())
    init(first: HostRegistryCatalogIdentity159) { this.first = Some(first) }

    func publish159(data: HostRegistryCatalogIdentity159, name: String): Bool {
        let declared = JavaScriptToolDescriptor(name, description: "actual concurrent backing 借用",
            inputSchemaJson: "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}")
        data.reserveTool159(declared, "backing-fixture159")
        let schema = match (decodeAgentValue(declared.inputSchemaJson)) {
            case Result.Ok(value) => value
            case Result.Err(_) => throw IllegalStateException("actual catalog backing schema did not decode")
        }
        let descriptor = ToolDescriptor(ModelToolDefinition("plugin." + data.namespace + "." + name,
            declared.description, schema), Capability(CapabilityKind.ExtensionInvoke, resource: data.namespace),
            implementationVersion: "backing-fixture159", implementationFingerprint: "backing159:" + name)
        // The actual Catalog receives an independently paid share. Its
        // complete private teardown is the eventual DATA return witness.
        catalog.getOrThrow().registerBatch(
            [ToolCatalogRegistration(descriptor, executor.getOrThrow())], dataPayment: Some(data)).isOk()
    }
    func firstConstruction159(): Bool {
        let accepted = publish159(first.getOrThrow(), "first159")
        entered.store(true)
        let deadline = MonoTime.now() + Duration.second * 5
        while (!released.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
        if (!released.load()) { throw IllegalStateException("catalog backing construction control timed out") }
        accepted
    }
    func namesAndNoExecution159(): Bool {
        // The closed Catalog consumer returns only Bool; it does not export
        // a definition, schema, callback or name alias to this fixture.
        catalog.getOrThrow().definitionNamesEqual159([
            "plugin.pi:generation159.first159", "plugin.pi:generation159.second159"])
            && executor.getOrThrow().calls.load() == 0
    }
    func clearAfterWorker159(): Unit {
        match (worker) { case Some(value) => let _ = value.get(); case None => () }
        worker = Option<Future<Bool>>.None
        first = Option<HostRegistryCatalogIdentity159>.None
        if (!catalog.getOrThrow().retireCatalogData159()) {
            throw IllegalStateException("actual catalog still has a live DATA borrower")
        }
        catalog = Option<ToolCatalog>.None
        executor = Option<RegistryCatalogBackingExecutor159>.None
    }
}

private func registryCatalogBackingRecord159(value: PluginRegistryResult<ProductPluginRecord>): ProductPluginRecord {
    match (value) {
        case PluginRegistryResult.Ok(record) => record
        case PluginRegistryResult.Err(error) =>
            try { throw IllegalStateException("actual catalog backing Registry import failed") }
            finally { error.close() }
    }
}
private func registryCatalogBackingIdentity159(owner: HostRegistryMountDescriptor159): HostRegistryCatalogIdentity159 {
    hostRegistryCatalogIdentity159(owner, owner.mountDescriptor159())
}
private func registryCatalogBackingOwner159(record: ProductPluginRecord): HostRegistryMountDescriptor159 {
    match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw IllegalStateException("actual catalog backing descriptor copy refused")
    }
}
private func registryCatalogBackingConcurrentFrame159(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation): Unit {
    let firstOwner = registryCatalogBackingOwner159(record)
    let secondOwner = registryCatalogBackingOwner159(record)
    let first = registryCatalogBackingIdentity159(firstOwner)
    let second = registryCatalogBackingIdentity159(secondOwner)
    first.beginCatalogConstruction159(); second.beginCatalogConstruction159()
    let state = RegistryCatalogBackingControl159(first)
    try {
        state.worker = Some(spawn { state.firstConstruction159() })
        let deadline = MonoTime.now() + Duration.second * 5
        while (!state.entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
        @Expect(state.entered.load())
        @Expect(state.worker.getOrThrow().tryGet().isNone())
        @Expect(state.publish159(second, "second159"))
        // The second producer's real publication helper has returned. Its
        // previous private backing still belongs to the blocked first frame.
        second.returnedCatalogConstruction159(); secondOwner.returnedMountFrame159()
        let held = probe.retainedCustodyUsage113()
        second.collectRetainedTemporaries159()
        let custodyActual159b1 = probe.retainedCustodyUsage113()
        let custodyExpected159b1 = held
        @Expect(custodyActual159b1[0], custodyExpected159b1[0])
        @Expect(custodyActual159b1[1], custodyExpected159b1[1])
        @Expect(custodyActual159b1[2], custodyExpected159b1[2])
        @Expect(state.worker.getOrThrow().tryGet().isNone())
        @Expect(state.namesAndNoExecution159())
        state.released.store(true)
        @Expect(state.worker.getOrThrow().get())
        // Physical Future return alone is not a DATA return marker.
        let custodyActual159b2 = probe.retainedCustodyUsage113()
        let custodyExpected159b2 = held
        @Expect(custodyActual159b2[0], custodyExpected159b2[0])
        @Expect(custodyActual159b2[1], custodyExpected159b2[1])
        @Expect(custodyActual159b2[2], custodyExpected159b2[2])
        first.returnedCatalogConstruction159()
        let returned = probe.retainedCustodyUsage113()
        // Each one-entry staging and the old one-entry backing actually paid
        // 8192 + 128 + 4096, plus the original 1024 ledger bytes per child. The two staging children and exact old backing
        // have now cleared their carrier fields after both helpers returned.
        @Expect(returned[0], held[0] - 3 * (8192 + 128 + 4096 + 1024))
        @Expect(returned[2], held[2] - 3)
        @Expect(returned[1], held[1])
        @Expect(state.namesAndNoExecution159())
        second.collectRetainedTemporaries159()
        let custodyActual159b3 = probe.retainedCustodyUsage113()
        let custodyExpected159b3 = returned
        @Expect(custodyActual159b3[0], custodyExpected159b3[0])
        @Expect(custodyActual159b3[1], custodyExpected159b3[1])
        @Expect(custodyActual159b3[2], custodyExpected159b3[2])
        firstOwner.returnedMountFrame159()
        // The real published payload owners and current backing deliberately
        // remain paid. This is not a catalog teardown or unmount-as-ACK test.
        @Expect(probe.retainedCustodyUsage113()[0] > 4096)
    } finally {
        state.released.store(true)
        state.clearAfterWorker159()
    }
}

private func registryCatalogBackingActualFrame159(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    var registry: ?PluginRegistry = Option<PluginRegistry>.None
    try {
        Directory.create(root + "/source-债/extensions", recursive: true)
        File.writeTo(root + "/source-债/package.json",
            "{\"name\":\"generation159\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source-债/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let actual = PluginRegistry(root + "/settings", root)
        registry = Some(actual)
        let record = registryCatalogBackingRecord159(actual.importLocal(root + "/source-债"))
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                // Actual same Registry root: pay before carrier, closures,
                // Future, catalog and any fixture schema/snapshot creation.
                let fixture = probe.deriveRetainedLease()
                try { fixture.ensureRetainedPeak(2097152) }
                catch (error: Exception) { fixture.close(); throw error }
                var fixtureReturned = false
                try {
                    let nativeBefore = nativeControlMetadataUsage113()
                    let bankBefore = probe.retainedCustodyUsage113()
                    registryCatalogBackingConcurrentFrame159(record, probe)
                    let bankAfter = probe.retainedCustodyUsage113()
                    @Expect(bankAfter[0], bankBefore[0])
                    @Expect(bankAfter[1], bankBefore[1])
                    @Expect(bankAfter[2], bankBefore[2])
                    let custodyActual159b4 = nativeControlMetadataUsage113()
                    let custodyExpected159b4 = nativeBefore
                    @Expect(custodyActual159b4[0], custodyExpected159b4[0])
                    @Expect(custodyActual159b4[1], custodyExpected159b4[1])
                    fixtureReturned = true
                } finally {
                    // An unknown worker/helper failure keeps this original
                    // reservation charged; it is never a cleanup receipt.
                    if (fixtureReturned) { fixture.close() }
                }
            } finally { probe.close() }
        } finally { record.close() }
    } finally {
        try { match (registry) { case Some(value) => value.close(); registry = Option<PluginRegistry>.None; case None => () } }
        finally { remove(root, recursive: true) }
    }
}

@Test
class HostRegistryCatalogBacking159Tests {
    @TestCase
    func actualTwoNonemptyCatalogProducersRetainOldBackingUntilTheirPhysicalFramesReturn159(): Unit {
        // Measure the real common Native bank before even the fixture root.
        // Both producer helpers/Future and the complete private Registry frame
        // must return before this final equality can hold. Registry.close by
        // itself cannot retire an escaped Catalog child.
        let bankBefore159 = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { registryCatalogBackingActualFrame159() }
        finally { fixture.close() }
        let bankAfter159 = nativeControlMetadataUsage113()
        @Expect(bankAfter159[0], bankBefore159[0])
        @Expect(bankAfter159[1], bankBefore159[1])
    }
}
