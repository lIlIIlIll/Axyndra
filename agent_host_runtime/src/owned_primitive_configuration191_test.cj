package agent_host_runtime

import agent_domain.*
import agent_plugin_registry.{PluginRegistry, ProductPluginRecord, PluginRegistryResult, PluginDescriptorText, OwnedRegistryUtf8}
import agent_extension_runtime.{JavaScriptToolDescriptor, reserveNativeControlMetadata, nativeControlMetadataUsage113, nativeControlMetadataCapacity113}
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// Actual Registry payments, private production owner registration and concrete
// Catalog backing only. No tool/Native effect or fabricated Source/receipt.
private class PrimitiveConfigurationNoEffect191 <: ToolExecutor {
    public func execute(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> {
        Result<ToolResult>.Err(AgentError(AgentErrorKind.PermissionDenied,
            "test.primitive_data_only191", "configuration control has no execution effect"))
    }
}
private func primitiveConfigurationRecord191(value: PluginRegistryResult<ProductPluginRecord>): ProductPluginRecord {
    match (value) {
        case PluginRegistryResult.Ok(record) => record
        case PluginRegistryResult.Err(error) =>
            try { throw IllegalStateException("actual Primitive Registry fixture import failed") }
            finally { error.close() }
    }
}
// The existing configuration or fixture payer owns the returned independent
// UTF8 copy. Temporary Registry bytes close only after the whole copy helper
// returns; no public raw descriptor or new authority is introduced.
private func primitiveConfigurationCopyTextFrame199(bytes: OwnedRegistryUtf8,
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
private func primitiveConfigurationDescriptorText199(record: ProductPluginRecord,
    field: PluginDescriptorText, payment: LogicalJsonOwnerReservation): String {
    let bytes = match (record.descriptor.copyText(field)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) =>
            try { throw IllegalStateException("actual Registry descriptor copy refused") }
            finally { error.close() }
    }
    try { primitiveConfigurationCopyTextFrame199(bytes, payment) }
    finally { bytes.close() }
}
private func primitiveConfigurationProducerFrame191(cache: HostPrimitiveConfigurationCache111,
    record: ProductPluginRecord): HostOwnedPrimitiveConfiguration191 {
    let payment = record.descriptor.deriveCopiedDataPayment(1048576)
    let owner = cache.registerOwnedData191(payment)
    let namespace199 = primitiveConfigurationDescriptorText199(record, PluginDescriptorText.Namespace, payment)
    let digest199 = primitiveConfigurationDescriptorText199(record, PluginDescriptorText.ContentDigest, payment)
    let document = objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([
        objectValue([ValueField("namespace", textValue(namespace199)),
            ValueField("package_digest", textValue(digest199)),
            ValueField("tools", listValue([objectValue([
                ValueField("name", textValue("inspect191")), ValueField("profile", textValue("frozen-primitives-v1")),
                ValueField("services", listValue([textValue("child.start")])),
                ValueField("preparation_provider", textValue("provider191"))])]))])]))])
    let selected = match (hostPrimitiveSelections111(document, namespace199, digest199)) {
        case Result.Err(_) => throw IllegalStateException("actual Primitive exact operator selection refused")
        case Result.Ok(value) => value.getOrThrow()
    }
    // Closed predicate controls do not validate or use these DATA-only FD
    // fields. Production parsing/schema and owner construction are real.
    let value = HostPrimitiveConfiguration111("", encodeAgentValue(document), "", namespace199,
        digest199, selected, payment)
    owner.publish191(value)
    owner.retain191()
}
private func primitiveConfigurationSharesFrame191(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation): Unit {
    let cache = HostPrimitiveConfigurationCache111()
    @Expect(match (hostParsePrimitiveConfiguration191("{")) { case Result.Err(_) => true; case Result.Ok(_) => false })
    @Expect(cache.ownedDataCount191(), 0)
    for (_ in 0..32) {
        let before = probe.retainedCustodyUsage113()
        let first = primitiveConfigurationProducerFrame191(cache, record)
        let second = first.retainOwnedPrimitive191()
        @Expect(cache.ownedDataCount191(), 1)
        @Expect(first.permits("inspect191")); @Expect(!first.permits("absent191"))
        @Expect(first.permitsService("inspect191", "child.start"))
        @Expect(!first.permitsService("inspect191", "child.wait"))
        @Expect(!first.mappedInvocation("inspect191"))
        let held = probe.retainedCustodyUsage113()
        @Expect(first.withOwnedPrimitiveFrame191({ =>
            first.returnOwnedPrimitive191()
            let during = probe.retainedCustodyUsage113()
            during[0] == held[0] && during[1] == held[1] && during[2] == held[2]
        }))
        @Expect(!first.canReturnOwnedPrimitive191())
        @Expect(second.permitsService("inspect191", "child.start"))
        @Expect(cache.ownedDataCount191(), 1)
        second.returnOwnedPrimitive191()
        @Expect(cache.ownedDataCount191(), 0)
        let after = probe.retainedCustodyUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1]); @Expect(after[2], before[2])
    }
}
private func primitiveConfigurationCatalogPublicationFrame191(identity: HostRegistryCatalogIdentity159,
    catalog: ToolCatalog, configuration: HostOwnedPrimitiveConfiguration191): Unit {
    identity.ownPrimitiveConfiguration191(configuration)
    let declared = JavaScriptToolDescriptor("inspect191", description: "Primitive DATA retirement", inputSchemaJson: "{\"type\":\"object\"}")
    identity.reserveTool159(declared, "primitive191")
    let schema = match (decodeAgentValue(declared.inputSchemaJson)) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw IllegalStateException("actual Primitive Catalog schema failed")
    }
    let descriptor = ToolDescriptor(ModelToolDefinition("plugin." + identity.namespace + ".inspect191",
        declared.description, schema), configuration.invocationCapability("inspect191"),
        additionalCapabilities: configuration.additionalCapabilities("inspect191"),
        implementationVersion: "primitive191", implementationFingerprint: "primitive191")
    let service = JavaScriptToolDescriptor("backend191", description: "closed backend DATA predicate", inputSchemaJson: "{\"type\":\"object\"}")
    identity.reserveTool159(service, "backend191")
    let backend = ToolDescriptor(ModelToolDefinition("host.backend191", service.description, schema),
        Capability(CapabilityKind.ProcessSpawn), hostServiceOnly: true,
        implementationVersion: "backend191", implementationFingerprint: "backend191")
    @Expect(catalog.registerBatch([ToolCatalogRegistration(descriptor, PrimitiveConfigurationNoEffect191()),
        ToolCatalogRegistration(backend, PrimitiveConfigurationNoEffect191())], dataPayment: Some(identity)).isOk())
}
private func primitiveConfigurationCatalogProducerFrame191(record: ProductPluginRecord,
    catalog: ToolCatalog, configuration: HostOwnedPrimitiveConfiguration191): Unit {
    let mount = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw IllegalStateException("actual Primitive mount copy refused")
    }
    let identity = hostRegistryCatalogIdentity159(mount, mount.mountDescriptor159())
    identity.beginCatalogConstruction159()
    primitiveConfigurationCatalogPublicationFrame191(identity, catalog, configuration)
    identity.returnedCatalogConstruction159()
    mount.returnedMountFrame159()
}
private func primitiveConfigurationCatalogFrame191(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation, fixture: LogicalJsonOwnerReservation): Unit {
    let namespace199 = primitiveConfigurationDescriptorText199(record, PluginDescriptorText.Namespace, fixture)
    let cache = HostPrimitiveConfigurationCache111()
    let catalog = ToolCatalog()
    let before = probe.retainedCustodyUsage113()
    let configuration = primitiveConfigurationProducerFrame191(cache, record)
    primitiveConfigurationCatalogProducerFrame191(record, catalog, configuration)
    @Expect(catalog.publishedHostServiceMatches191("host.backend191", "backend191"))
    @Expect(!catalog.publishedHostServiceMatches191("host.backend191", "different191"))
    @Expect(!catalog.publishedHostServiceMatches191("absent191", "backend191"))
    @Expect(!catalog.publishedHostServiceMatches191("plugin." + namespace199 + ".inspect191", "primitive191"))
    let held = probe.retainedCustodyUsage113()
    @Expect(configuration.withOwnedPrimitiveFrame191({ =>
        let refused = !catalog.retireCatalogData159()
        let during = probe.retainedCustodyUsage113()
        refused && during[0] == held[0] && during[1] == held[1] && during[2] == held[2]
    }))
    // The closed backend comparison did not export the original descriptor.
    // All private action, producer and backing helpers have actually returned.
    @Expect(catalog.retireCatalogData159())
    @Expect(cache.ownedDataCount191(), 0)
    @Expect(!configuration.canReturnOwnedPrimitive191())
    @Expect(!catalog.publishedHostServiceMatches191("host.backend191", "backend191"))
    let after = probe.retainedCustodyUsage113()
    @Expect(after[0], before[0]); @Expect(after[1], before[1]); @Expect(after[2], before[2])
}
private func primitiveConfigurationRawExportFrame191(configuration: HostOwnedPrimitiveConfiguration191): HostPrimitiveConfiguration111 {
    configuration.exportCompatibilityHeld191()
}
private func primitiveConfigurationRawExportControl191(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation): Unit {
    let cache = HostPrimitiveConfigurationCache111()
    let before = probe.retainedCustodyUsage113()
    let configuration = primitiveConfigurationProducerFrame191(cache, record)
    let held = probe.retainedCustodyUsage113()
    for (_ in 0..32) {
        let temporary = configuration.retainOwnedPrimitive191()
        let raw = primitiveConfigurationRawExportFrame191(temporary)
        temporary.returnOwnedPrimitive191()
        // Real Raw export stays funded independently of this returned opaque
        // view. Repeated complete exports must not accumulate view invoices.
        @Expect(raw.permitsService("inspect191", "child.start"))
        @Expect(!temporary.canReturnOwnedPrimitive191())
        @Expect(cache.ownedDataCount191(), 1)
        let after = probe.retainedCustodyUsage113()
        @Expect(after[0], held[0]); @Expect(after[1], held[1]); @Expect(after[2], held[2])
    }
    configuration.returnOwnedPrimitive191()
    @Expect(!configuration.canReturnOwnedPrimitive191())
    @Expect(cache.ownedDataCount191(), 1)
    let after = probe.retainedCustodyUsage113()
    @Expect(after[0] > before[0]); @Expect(after[1] >= before[1]); @Expect(after[2], before[2] + 1)
    // No Root completion or test callback declares these actual Raw aliases
    // retired. Exactly the original DATA backing remains registered PaidHeld.
}
private func primitiveConfigurationFailureCaptureFrame191(configuration: HostOwnedPrimitiveConfiguration191): AgentError {
    configuration.retainFailure172(AgentError(AgentErrorKind.PermissionDenied, "test.full_primitive_error191",
        "full independent Primitive error body", retryable: true, fallbackAllowed: true,
        fields: [ErrorField("first191", "value-one191"), ErrorField("second191", "value-two191")]))
}
private func primitiveConfigurationFailureFrame191(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation): Unit {
    let cache = HostPrimitiveConfigurationCache111()
    let before = probe.retainedCustodyUsage113()
    let configuration = primitiveConfigurationProducerFrame191(cache, record)
    let error = primitiveConfigurationFailureCaptureFrame191(configuration)
    @Expect(cache.heldIndependentFailureCount191(), 1)
    configuration.returnOwnedPrimitive191()
    @Expect(cache.ownedDataCount191(), 0)
    @Expect(!configuration.canReturnOwnedPrimitive191())
    @Expect(error.kind, AgentErrorKind.PermissionDenied)
    @Expect(error.code, "test.full_primitive_error191"); @Expect(error.message, "full independent Primitive error body")
    @Expect(error.retryable); @Expect(error.fallbackAllowed)
    @Expect(error.fields.size, 2); @Expect(error.field("first191").getOrThrow(), "value-one191")
    @Expect(error.field("second191").getOrThrow(), "value-two191")
    @Expect(error.attemptFailure.isNone()); @Expect(error.observation.isNone())
    let after = probe.retainedCustodyUsage113()
    @Expect(after[0] > before[0]); @Expect(after[1] >= before[1]); @Expect(after[2] > before[2])
    @Expect(cache.heldIndependentFailureCount191(), 1)
    // The raw escaped full error and its allocator retain their independent
    // payment. Its lifetime does not retain operator DATA, Source or Root.
}
private func primitiveConfigurationRegistryFrame191(kind: Int64): Unit {
    let root = Directory.createTemp("/tmp").toString()
    var registry: ?PluginRegistry = Option<PluginRegistry>.None
    try {
        Directory.create(root + "/source191/bin", recursive: true)
        File.writeTo(root + "/source191/axyndra.plugin.json", "{\"id\":\"primitive191\",\"version\":\"1.0.0\",\"entry_kind\":\"native-executable\",\"entrypoint\":\"bin/noeffect191\",\"sdk_range\":\"[2.1.0,3.0.0)\",\"protocol_range\":\"axyndra-js-host-v2\",\"capabilities\":[],\"contributions\":[{\"kind\":\"provider\",\"name\":\"provider191\"},{\"kind\":\"tool\",\"name\":\"inspect191\"}]}".toArray())
        File.writeTo(root + "/source191/bin/noeffect191", "#!/bin/sh\nexit 99 # MUST_NOT_EXECUTE\n".toArray())
        let actual = PluginRegistry(root + "/settings", root); registry = Some(actual)
        let record = primitiveConfigurationRecord191(actual.importLocal(root + "/source191"))
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease()
                try { fixture.ensureRetainedPeak(4194304) }
                catch (error: Exception) { fixture.close(); throw error }
                var returned = false
                try {
                    let before = probe.retainedCustodyUsage113()
                    if (kind == 0) { primitiveConfigurationSharesFrame191(record, probe) }
                    else if (kind == 1) { primitiveConfigurationCatalogFrame191(record, probe, fixture) }
                    else if (kind == 2) { primitiveConfigurationFailureFrame191(record, probe) }
                    else { primitiveConfigurationRawExportControl191(record, probe) }
                    if (kind < 2) {
                        let after = probe.retainedCustodyUsage113()
                        @Expect(after[0], before[0]); @Expect(after[1], before[1]); @Expect(after[2], before[2]) }
                    returned = true
                } finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally {
        try { match (registry) { case Some(value) => value.close(); registry = Option<PluginRegistry>.None; case None => () } }
        finally { remove(root, recursive: true) }
    }
}
@Test
class HostOwnedPrimitiveConfiguration191Tests {
    @TestCase
    func actualRegistryPrimitiveSharesReturnAfterWholeAction191(): Unit {
        let before = nativeControlMetadataUsage113(); let fixture = reserveNativeControlMetadata(65536)
        try { primitiveConfigurationRegistryFrame191(0) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113(); @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func actualCatalogPrimitiveBackingAndClosedBackendGate191(): Unit {
        let before = nativeControlMetadataUsage113(); let fixture = reserveNativeControlMetadata(65536)
        try { primitiveConfigurationRegistryFrame191(1) } finally { fixture.close() }
        let after = nativeControlMetadataUsage113(); @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func actualRepeatedRawExportRetainsBackingButReturnsViewHeaders191(): Unit {
        let fixture = reserveNativeControlMetadata(65536)
        try { primitiveConfigurationRegistryFrame191(3) } finally { fixture.close() }
    }
    @TestCase
    func independentFullFailureDoesNotRetainPrimitiveData191(): Unit {
        let fixture = reserveNativeControlMetadata(65536)
        try { primitiveConfigurationRegistryFrame191(2) } finally { fixture.close() }
    }
}
