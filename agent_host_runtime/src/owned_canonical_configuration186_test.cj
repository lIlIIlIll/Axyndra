package agent_host_runtime

import agent_domain.*
import agent_plugin_registry.{PluginRegistry, ProductPluginRecord, PluginRegistryResult, PluginDescriptorText, OwnedRegistryUtf8}
import agent_extension_runtime.{JavaScriptToolDescriptor, reserveNativeControlMetadata, nativeControlMetadataUsage113, nativeControlMetadataCapacity113}
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// The fixture exercises only private configuration DATA. It never invokes
// Native, creates a tool invocation, grants permission or supplies a Receipt.
private class CanonicalConfigurationNoEffect186 <: ToolExecutor {
    public func execute(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> {
        Result<ToolResult>.Err(AgentError(AgentErrorKind.PermissionDenied,
            "test.configuration_data_only186", "configuration control has no execution effect"))
    }
}
private func canonicalConfigurationRecord186(value: PluginRegistryResult<ProductPluginRecord>): ProductPluginRecord {
    match (value) {
        case PluginRegistryResult.Ok(record) => record
        case PluginRegistryResult.Err(error) =>
            try { throw IllegalStateException("actual configuration Registry fixture import failed") }
            finally { error.close() }
    }
}
// The existing configuration or fixture payer owns the returned independent
// UTF8 copy. Temporary Registry bytes close only after the whole copy helper
// returns; no public raw descriptor or new authority is introduced.
private func canonicalConfigurationCopyTextFrame199(bytes: OwnedRegistryUtf8,
    payment: LogicalJsonOwnerReservation): String {
    let count = bytes.byteCount
    if (count < 0 || count > (nativeControlMetadataCapacity113() - 1048576 - 65536) / 32) {
        throw IllegalStateException("actual Registry text copy exceeds the original aggregate")
    }
    payment.ensureRetainedPeak(1048576 + count * 32 + 65536)
    let copied = Array<UInt8>(count, repeat: 0)
    for (index in 0..count) { copied[index] = bytes.byteAt(index) }
    String.fromUtf8(copied)
}
private func canonicalConfigurationDescriptorText199(record: ProductPluginRecord,
    field: PluginDescriptorText, payment: LogicalJsonOwnerReservation): String {
    let bytes = match (record.descriptor.copyText(field)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) =>
            try { throw IllegalStateException("actual Registry descriptor copy refused") }
            finally { error.close() }
    }
    try { canonicalConfigurationCopyTextFrame199(bytes, payment) }
    finally { bytes.close() }
}
private func canonicalConfigurationProducerFrame186(cache: HostCanonicalProjectionConfigurationCache173,
    record: ProductPluginRecord): HostOwnedCanonicalProjectionSelection186 {
    // The actual original Registry child pays before all configuration DOM,
    // copies, owner links or view metadata. Registration is the production
    // load's same private pending-payment construction helper.
    let payment = record.descriptor.deriveCopiedDataPayment(1048576)
    let owner = cache.registerOwnedData186(payment)
    let namespace199 = canonicalConfigurationDescriptorText199(record, PluginDescriptorText.Namespace, payment)
    let digest199 = canonicalConfigurationDescriptorText199(record, PluginDescriptorText.ContentDigest, payment)
    let tool = match (decodeAgentValue("{\"name\":\"inspect186\",\"provider\":\"provider186\",\"action\":\"canonical.context.project\",\"capability\":\"workspace.read\",\"effect\":\"read_only\"}")) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw IllegalStateException("configuration DATA fixture did not decode")
    }
    // No method validates or uses these DATA-only path/witness fields.
    let snapshot = HostCanonicalProjectionSelection173("", "{}", "", namespace199,
        digest199, UInt64(1), tool, payment)
    owner.publish186(snapshot)
    owner.retain186()
}
private func canonicalConfigurationViewsFrame186(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation): Unit {
    let cache = HostCanonicalProjectionConfigurationCache173()
    // Same production parser, a known malformed operator file remains a
    // closed DATA error; it cannot publish a configuration or new Source.
    @Expect(match (hostParseCanonicalConfigurationData186("{")) { case Result.Err(_) => true; case Result.Ok(_) => false })
    @Expect(cache.ownedDataCount186(), 0)
    for (_ in 0..32) {
        let before = probe.retainedCustodyUsage113()
        let first = canonicalConfigurationProducerFrame186(cache, record)
        // The entire producer has returned: no local raw snapshot remains.
        let second = first.retainOwnedConfiguration186()
        @Expect(cache.ownedDataCount186(), 1)
        let held = probe.retainedCustodyUsage113()
        @Expect(held[0] > before[0])
        @Expect(first.withOwnedConfigurationFrame186({ =>
            first.returnOwnedConfiguration186()
            let during = probe.retainedCustodyUsage113()
            during[0] == held[0] && during[1] == held[1] && during[2] == held[2]
        }))
        // The callback and complete private action frame are gone before the
        // first exact header can return. The second real share keeps backing.
        @Expect(!first.canReturnOwnedConfiguration186())
        @Expect(second.textEquals186(3, "provider186"))
        @Expect(cache.ownedDataCount186(), 1)
        @Expect(probe.retainedCustodyUsage113()[0] > before[0])
        second.returnOwnedConfiguration186()
        @Expect(cache.ownedDataCount186(), 0)
        let after = probe.retainedCustodyUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1]); @Expect(after[2], before[2])
    }
}
private func canonicalConfigurationCatalogProducerFrame186(record: ProductPluginRecord,
    catalog: ToolCatalog, configuration: HostOwnedCanonicalProjectionSelection186): Unit {
    let mount = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw IllegalStateException("actual configuration mount copy refused")
    }
    let identity = hostRegistryCatalogIdentity159(mount, mount.mountDescriptor159())
    identity.beginCatalogConstruction159()
    canonicalConfigurationCatalogPublicationFrame186(identity, catalog, configuration)
    // The publication helper has fully returned before these original gates.
    identity.returnedCatalogConstruction159()
    mount.returnedMountFrame159()
}
private func canonicalConfigurationCatalogPublicationFrame186(identity: HostRegistryCatalogIdentity159,
    catalog: ToolCatalog, configuration: HostOwnedCanonicalProjectionSelection186): Unit {
    identity.ownCanonicalConfiguration186(configuration)
    let declared = JavaScriptToolDescriptor("inspect186", description: "configuration DATA retirement",
        inputSchemaJson: "{\"type\":\"object\"}")
    identity.reserveTool159(declared, "configuration186")
    let schema = match (decodeAgentValue(declared.inputSchemaJson)) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw IllegalStateException("actual configuration catalog schema did not decode")
    }
    let descriptor = ToolDescriptor(ModelToolDefinition("plugin." + identity.namespace + ".inspect186",
        declared.description, schema), Capability(CapabilityKind.WorkspaceRead),
        implementationVersion: "configuration186", implementationFingerprint: "configuration186")
    @Expect(catalog.registerBatch([ToolCatalogRegistration(descriptor, CanonicalConfigurationNoEffect186())],
        dataPayment: Some(identity)).isOk())
}
private func canonicalConfigurationCatalogFrame186(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation, fixture: LogicalJsonOwnerReservation): Unit {
    let namespace199 = canonicalConfigurationDescriptorText199(record, PluginDescriptorText.Namespace, fixture)
    let cache = HostCanonicalProjectionConfigurationCache173()
    let catalog = ToolCatalog()
    let configuration = canonicalConfigurationProducerFrame186(cache, record)
    let beforeCatalog = probe.retainedCustodyUsage113()
    canonicalConfigurationCatalogProducerFrame186(record, catalog, configuration)
    @Expect(catalog.definitionNamesEqual159(["plugin." + namespace199 + ".inspect186"]))
    let held = probe.retainedCustodyUsage113()
    @Expect(held[0] > beforeCatalog[0])
    @Expect(configuration.withOwnedConfigurationFrame186({ =>
        let refused = !catalog.retireCatalogData159()
        let during = probe.retainedCustodyUsage113()
        refused && during[0] == held[0] && during[1] == held[1] && during[2] == held[2]
    }))
    // A refused close leaves the original Catalog retryable. The actual
    // Catalog drops descriptor/executor backing before returning its share.
    @Expect(catalog.retireCatalogData159())
    @Expect(cache.ownedDataCount186(), 0)
    @Expect(!configuration.canReturnOwnedConfiguration186())
    @Expect(!catalog.definitionNamesEqual159(["plugin." + namespace199 + ".inspect186"]))
}
private func canonicalConfigurationUnpublishedFrame186(record: ProductPluginRecord,
    cache: HostCanonicalProjectionConfigurationCache173,
    configuration: HostOwnedCanonicalProjectionSelection186): Unit {
    let mount = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw IllegalStateException("unpublished configuration mount copy refused")
    }
    let identity = hostRegistryCatalogIdentity159(mount, mount.mountDescriptor159())
    identity.beginCatalogConstruction159()
    canonicalConfigurationUnpublishedProducer186(identity, configuration)
    // No catalog publication exists. Only this full producer return can
    // release both the exact linked view and the original metadata owner.
    identity.returnedCatalogConstruction159()
    mount.returnedMountFrame159()
    @Expect(cache.ownedDataCount186(), 0)
    @Expect(!configuration.canReturnOwnedConfiguration186())
}
private func canonicalConfigurationUnpublishedProducer186(identity: HostRegistryCatalogIdentity159,
    configuration: HostOwnedCanonicalProjectionSelection186): Unit {
    identity.ownCanonicalConfiguration186(configuration)
}
private func canonicalConfigurationExportFrame186(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation): Unit {
    let cache = HostCanonicalProjectionConfigurationCache173()
    let before = probe.retainedCustodyUsage113()
    let configuration = canonicalConfigurationProducerFrame186(cache, record)
    let privateHeld = probe.retainedCustodyUsage113()
    // These are the public interface's exact eight exports. A third-party
    // route may save them after its entire callback has returned.
    let namespace = configuration.namespace
    let digest = configuration.packageDigest
    let localTool = configuration.localTool
    let provider = configuration.provider
    let action = configuration.action
    let capability = configuration.capability
    let effect = configuration.effect
    let configurationDigest = configuration.configurationDigest
    let exportsHeld = probe.retainedCustodyUsage113()
    @Expect(cache.publicTextDebtCount186(), 8)
    @Expect(exportsHeld[0] > privateHeld[0])
    configuration.returnOwnedConfiguration186()
    @Expect(cache.ownedDataCount186(), 0)
    @Expect(!configuration.canReturnOwnedConfiguration186())
    @Expect(record.descriptor.textEquals(PluginDescriptorText.Namespace, namespace))
    @Expect(record.descriptor.textEquals(PluginDescriptorText.ContentDigest, digest))
    @Expect(localTool, "inspect186"); @Expect(provider, "provider186")
    @Expect(action, "canonical.context.project"); @Expect(capability, "workspace.read")
    @Expect(effect, "read_only"); @Expect(configurationDigest.size > 0)
    let after = probe.retainedCustodyUsage113()
    // The original DATA/view invoice returned, while all eight independently
    // copied exports remain actually paid. No unknown export ACK is fabricated.
    @Expect(after[0] < exportsHeld[0]); @Expect(after[0] > before[0])
    @Expect(after[1] >= before[1]); @Expect(after[2], before[2] + 8)
    @Expect(cache.publicTextDebtCount186(), 8)
}
private func canonicalConfigurationRegistryFrame186(catalogControl: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    var registry: ?PluginRegistry = Option<PluginRegistry>.None
    try {
        Directory.create(root + "/source186/extensions", recursive: true)
        File.writeTo(root + "/source186/package.json",
            "{\"name\":\"configuration186\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source186/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let actual = PluginRegistry(root + "/settings", root)
        registry = Some(actual)
        let record = canonicalConfigurationRecord186(actual.importLocal(root + "/source186"))
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease()
                try { fixture.ensureRetainedPeak(4194304) }
                catch (error: Exception) { fixture.close(); throw error }
                var returned = false
                try {
                    let before = probe.retainedCustodyUsage113()
                    if (catalogControl) {
                        canonicalConfigurationCatalogFrame186(record, probe, fixture)
                        let cache = HostCanonicalProjectionConfigurationCache173()
                        let configuration = canonicalConfigurationProducerFrame186(cache, record)
                        canonicalConfigurationUnpublishedFrame186(record, cache, configuration)
                    }
                    else { canonicalConfigurationViewsFrame186(record, probe) }
                    // Both entire consumer helpers have returned before
                    // measuring the true original shared ledger baseline.
                    let after = probe.retainedCustodyUsage113()
                    @Expect(after[0], before[0]); @Expect(after[1], before[1]); @Expect(after[2], before[2])
                    returned = true
                } finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally {
        try { match (registry) {
            case Some(value) => value.close(); registry = Option<PluginRegistry>.None
            case None => () }
        } finally { remove(root, recursive: true) }
    }
}
private func canonicalConfigurationExportRegistryFrame186(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    var registry: ?PluginRegistry = Option<PluginRegistry>.None
    try {
        Directory.create(root + "/source186/extensions", recursive: true)
        File.writeTo(root + "/source186/package.json",
            "{\"name\":\"configuration186\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source186/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let actual = PluginRegistry(root + "/settings", root)
        registry = Some(actual)
        let record = canonicalConfigurationRecord186(actual.importLocal(root + "/source186"))
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease()
                try { fixture.ensureRetainedPeak(4194304) }
                catch (error: Exception) { fixture.close(); throw error }
                var returned = false
                try {
                    let before = probe.retainedCustodyUsage113()
                    canonicalConfigurationExportFrame186(record, probe)
                    let after = probe.retainedCustodyUsage113()
                    @Expect(after[0] > before[0]); @Expect(after[1] >= before[1]); @Expect(after[2], before[2] + 8)
                    returned = true
                } finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally {
        try { match (registry) {
            case Some(value) => value.close(); registry = Option<PluginRegistry>.None
            case None => () }
        } finally { remove(root, recursive: true) }
    }
}
@Test
class HostOwnedCanonicalConfiguration186Tests {
    @TestCase
    func actualRegistryIndependentSharesReturnOnlyAfterWholeAction186(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { canonicalConfigurationRegistryFrame186(false) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func actualCatalogBlocksEarlyConfigurationReturnAndRetiresSameBank186(): Unit {
        let before = nativeControlMetadataUsage113()
        let fixture = reserveNativeControlMetadata(65536)
        try { canonicalConfigurationRegistryFrame186(true) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func publicTextExportsKeepIndependentInvoicesAfterPrivateViewReturns186(): Unit {
        let fixture = reserveNativeControlMetadata(65536)
        try { canonicalConfigurationExportRegistryFrame186() } finally { fixture.close() }
    }

}
