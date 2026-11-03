package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import agent_extension_runtime.{JavaScriptToolDescriptor, reserveNativeControlMetadata, nativeControlMetadataUsage113}
import agent_plugin_registry.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func registryDescriptorRecord159(value: PluginRegistryResult<ProductPluginRecord>): ProductPluginRecord {
    match (value) {
        case PluginRegistryResult.Ok(record) => record
        case PluginRegistryResult.Err(error) =>
            try { throw IllegalStateException("actual registry descriptor fixture failed") }
            finally { error.close() }
    }
}
private func registryDescriptorBorrowFrame159(owner: HostRegistryMountDescriptor159,
    original: OwnedPluginPackageDescriptor): Bool {
    let actual = owner.mountDescriptor159()
    actual.namespace == "pi:generation159" &&
        original.textEquals(PluginDescriptorText.Id, actual.id) &&
        original.textEquals(PluginDescriptorText.Version, actual.version) &&
        original.textEquals(PluginDescriptorText.Root, actual.root) &&
        original.textEquals(PluginDescriptorText.Entrypoint, actual.entrypoint) &&
        original.textEquals(PluginDescriptorText.ContentDigest, actual.contentDigest)
}
private func registryDescriptorActualFrame159(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    var registry: ?PluginRegistry = None
    try {
        Directory.create(root + "/source-债/extensions", recursive: true)
        File.writeTo(root + "/source-债/package.json",
            "{\"name\":\"generation159\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source-债/extensions/index.js",
            "throw new Error('MUST_NOT_EXECUTE_DURING_DATA_COPY');".toArray())
        let actual = PluginRegistry(root + "/settings", root)
        registry = Some(actual)
        let record = registryDescriptorRecord159(actual.importLocal(root + "/source-债"))
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let before = probe.retainedCustodyUsage113()
                let bank = nativeControlMetadataUsage113()
                for (_ in 0..32) {
                    let owner = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
                        case Result.Ok(value) => value
                        case Result.Err(_) => throw IllegalStateException("actual descriptor copy was refused")
                    }
                    @Expect(probe.retainedCustodyUsage113()[0] > before[0])
                    @Expect(probe.retainedCustodyUsage113()[2], before[2] + 1)
                    @Expect(registryDescriptorBorrowFrame159(owner, record.descriptor))
                    // The exact raw-descriptor helper has physically returned.
                    owner.returnedMountFrame159()
                    let returned = probe.retainedCustodyUsage113()
                    @Expect(returned[0], before[0])
                    @Expect(returned[2], before[2])
                    @Expect(returned[1] >= before[1])
                    let custodyActual159b1 = nativeControlMetadataUsage113()
                    let custodyExpected159b1 = bank
                    @Expect(custodyActual159b1[0], custodyExpected159b1[0])
                    @Expect(custodyActual159b1[1], custodyExpected159b1[1])
                    var refused = false
                    try { let _ = owner.mountDescriptor159() }
                    catch (_: LogicalJsonPayloadError) { refused = true }
                    @Expect(refused)
                    owner.returnedMountFrame159()
                    let custodyActual159b2 = probe.retainedCustodyUsage113()
                    let custodyExpected159b2 = returned
                    @Expect(custodyActual159b2[0], custodyExpected159b2[0])
                    @Expect(custodyActual159b2[1], custodyExpected159b2[1])
                    @Expect(custodyActual159b2[2], custodyExpected159b2[2])
                }
            } finally { probe.close() }
        } finally { record.close() }
    } finally {
        try { match (registry) { case Some(value) => value.close(); registry = None; case None => () } }
        finally { remove(root, recursive: true) }
    }
}

// Actual Registry parser/owned record + original Native bank, with no native
// worker, Tool, SQL receipt, mock owner, or Source factory in this DATA test.
@Test
class HostRegistryMountDescriptor159Tests {
    @TestCase
    func actualRegistryCopiesReturnTheirCompleteGraphAfterThePrivateBorrowFrame159(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { registryDescriptorActualFrame159() }
        finally { fixture.close() }
        let custodyActual159b3 = nativeControlMetadataUsage113()
        let custodyExpected159b3 = before
        @Expect(custodyActual159b3[0], custodyExpected159b3[0])
        @Expect(custodyActual159b3[1], custodyExpected159b3[1])
    }
}

private func registryCatalogIdentityCopyFrame159(owner: HostRegistryMountDescriptor159): HostRegistryCatalogIdentity159 {
    hostRegistryCatalogIdentity159(owner, owner.mountDescriptor159())
}
private func registryCatalogDeclarationFrame159(data: HostRegistryCatalogIdentity159): Bool {
    let input = JavaScriptToolDescriptor("catalog159", description: "private schema 借用",
        inputSchemaJson: "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}")
    data.reserveTool159(input, "fixture-executor-159")
    let schema = match (decodeAgentValue(input.inputSchemaJson)) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw IllegalStateException("catalog fixture schema did not decode")
    }
    let actual = ToolDescriptor(ModelToolDefinition("plugin." + data.namespace + "." + input.name,
        input.description, schema), Capability(CapabilityKind.ExtensionInvoke, resource: data.namespace),
        implementationVersion: "fixture-executor-159", implementationFingerprint: "fixture159:retained",
        capabilityResolver: Some({ _ => Capability(CapabilityKind.ExtensionInvoke, resource: data.namespace) }))
    // The independent existing streaming implementation must preserve the
    // constructor's original full recursive canonical schema identity.
    let catalog = ToolCatalog()
    let empty = catalog.registerBatch([], dataPayment: Some(data))
    empty.isOk() && actual.schemaDigest == canonicalAgentValueSha256(schema) &&
        actual.implementationFingerprint == "fixture159:retained"
}
private func registryCatalogActualUnpublishedFrame159(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    var registry: ?PluginRegistry = None
    try {
        Directory.create(root + "/source-债/extensions", recursive: true)
        File.writeTo(root + "/source-债/package.json",
            "{\"name\":\"generation159\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source-债/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let actual = PluginRegistry(root + "/settings", root)
        registry = Some(actual)
        let record = registryDescriptorRecord159(actual.importLocal(root + "/source-债"))
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let before = probe.retainedCustodyUsage113()
                let bank = nativeControlMetadataUsage113()
                for (_ in 0..16) {
                    let owner = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
                        case Result.Ok(value) => value
                        case Result.Err(_) => throw IllegalStateException("catalog fixture owner was refused")
                    }
                    let data = registryCatalogIdentityCopyFrame159(owner)
                    let copied = probe.retainedCustodyUsage113()
                    @Expect(copied[2], before[2] + 2)
                    data.beginCatalogConstruction159()
                    var duplicate = false
                    try { data.beginCatalogConstruction159() }
                    catch (_: LogicalJsonPayloadError) { duplicate = true }
                    @Expect(duplicate)
                    @Expect(registryCatalogDeclarationFrame159(data))
                    @Expect(probe.retainedCustodyUsage113()[0] > copied[0])
                    // Actual schema/descriptor/callback helper returned Bool;
                    // no borrowed schema or identity was returned/published.
                    data.returnedCatalogConstruction159()
                    owner.returnedMountFrame159()
                    let returned = probe.retainedCustodyUsage113()
                    @Expect(returned[0], before[0])
                    @Expect(returned[2], before[2])
                    @Expect(returned[1] >= before[1])
                    let custodyActual159b4 = nativeControlMetadataUsage113()
                    let custodyExpected159b4 = bank
                    @Expect(custodyActual159b4[0], custodyExpected159b4[0])
                    @Expect(custodyActual159b4[1], custodyExpected159b4[1])
                    var closed = false
                    try { data.beginCatalogConstruction159() }
                    catch (_: LogicalJsonPayloadError) { closed = true }
                    @Expect(closed)
                    data.returnedCatalogConstruction159()
                    let custodyActual159b5 = probe.retainedCustodyUsage113()
                    let custodyExpected159b5 = returned
                    @Expect(custodyActual159b5[0], custodyExpected159b5[0])
                    @Expect(custodyActual159b5[1], custodyExpected159b5[1])
                    @Expect(custodyActual159b5[2], custodyExpected159b5[2])
                }
            } finally { probe.close() }
        } finally { record.close() }
    } finally {
        try { match (registry) { case Some(value) => value.close(); registry = None; case None => () } }
        finally { remove(root, recursive: true) }
    }
}

@Test
class HostRegistryCatalogUnpublished159Tests {
    @TestCase
    func unpublishedRecursiveSchemaAndCallbackCopiesRetireAfterTheirActualHelper159(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(1048576)
        try { registryCatalogActualUnpublishedFrame159() }
        finally { fixture.close() }
        let custodyActual159b6 = nativeControlMetadataUsage113()
        let custodyExpected159b6 = before
        @Expect(custodyActual159b6[0], custodyExpected159b6[0])
        @Expect(custodyActual159b6[1], custodyExpected159b6[1])
    }
}

private func registryCatalogStagingCallFrame159(data: HostRegistryCatalogIdentity159,
    probe: LogicalJsonOwnerReservation): Bool {
    let before = probe.retainedCustodyUsage113()
    let catalog = ToolCatalog()
    let answer = catalog.registerBatch([], dataPayment: Some(data))
    let marked = probe.retainedCustodyUsage113()
    // Real ToolCatalog helper returned, but this outer private construction
    // frame has not returned. A marker must not release its real child early.
    answer.isOk() && marked[2] == before[2] + 1 && marked[0] > before[0]
}
private func registryCatalogStagingActualFrame159(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    var registry: ?PluginRegistry = None
    try {
        Directory.create(root + "/source-债/extensions", recursive: true)
        File.writeTo(root + "/source-债/package.json",
            "{\"name\":\"generation159\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source-债/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let actual = PluginRegistry(root + "/settings", root)
        registry = Some(actual)
        let record = registryDescriptorRecord159(actual.importLocal(root + "/source-债"))
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let before = probe.retainedCustodyUsage113()
                let bank = nativeControlMetadataUsage113()
                for (_ in 0..32) {
                    let owner = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
                        case Result.Ok(value) => value
                        case Result.Err(_) => throw IllegalStateException("catalog staging fixture owner was refused")
                    }
                    let data = registryCatalogIdentityCopyFrame159(owner)
                    data.beginCatalogConstruction159()
                    @Expect(registryCatalogStagingCallFrame159(data, probe))
                    data.returnedCatalogConstruction159()
                    owner.returnedMountFrame159()
                    let after = probe.retainedCustodyUsage113()
                    @Expect(after[0], before[0])
                    @Expect(after[2], before[2])
                    @Expect(after[1] >= before[1])
                    let custodyActual159b7 = nativeControlMetadataUsage113()
                    let custodyExpected159b7 = bank
                    @Expect(custodyActual159b7[0], custodyExpected159b7[0])
                    @Expect(custodyActual159b7[1], custodyExpected159b7[1])
                }
            } finally { probe.close() }
        } finally { record.close() }
    } finally {
        try { match (registry) { case Some(value) => value.close(); registry = None; case None => () } }
        finally { remove(root, recursive: true) }
    }
}
@Test
class HostRegistryCatalogTemporary159Tests {
    @TestCase
    func actualCatalogStagingReturnsOnlyAfterBothPrivateFrames159(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(1048576)
        try { registryCatalogStagingActualFrame159() }
        finally { fixture.close() }
        let custodyActual159b8 = nativeControlMetadataUsage113()
        let custodyExpected159b8 = before
        @Expect(custodyActual159b8[0], custodyExpected159b8[0])
        @Expect(custodyActual159b8[1], custodyExpected159b8[1])
    }
}
