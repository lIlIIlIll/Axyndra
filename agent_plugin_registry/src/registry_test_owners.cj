package agent_plugin_registry

import std.collection.*
import std.fs.*
import agent_domain.*
import agent_extension_runtime.*

// Test cleanup only. Every constructor, parser and allocation is production;
// no mock budget, source or metadata result is injected here.
class RegistryTestOwners {
    private let values = ArrayList<PluginRegistry>()
    func openRegistry(settings: String, workspace: String): PluginRegistry {
        let result = PluginRegistry(settings,workspace); values.add(result); result
    }
    func close(): Unit {
        var index = values.size - 1
        while (index >= 0) { values[index].close(); index-- }
        values.clear()
    }
}


// Private test consumers exercise numeric paid copies. The callback is package
// test code returning Unit; none stores or exports the borrowed text. The
// actual frame returns before holder fields clear and its child payment closes.
private class RegistryTestTextHolder78 {
    var text: ?String = None
    let payment: LogicalJsonOwnerReservation
    init(bytes: OwnedRegistryUtf8) {
        payment = bytes.deriveCopiedDataPayment(bytes.byteCount * 32 + 65536)
        let copied = Array<UInt8>(bytes.byteCount, repeat: 0)
        for (index in 0..copied.size) { copied[index] = bytes.byteAt(index) }
        text = Some(String.fromUtf8(copied))
    }
    func close(): Unit { text = None; payment.close() }
}
private class RegistryTestBool78 { var value = false }
private class RegistryTestInspection78 { var value: ?PluginRegistryResult<OwnedPluginPackageDescriptor> = None }
private func registryTestTextFrame78(holder: RegistryTestTextHolder78, action: (String) -> Unit): Unit {
    action(holder.text.getOrThrow())
}
func registryTestWithRoot78(record: ProductPluginRecord, action: (String) -> Unit): Unit {
    let bytes = match (record.descriptor.copyText(PluginDescriptorText.Root)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) => throw registryTestOwnedFailure78(error)
    }
    try {
        let holder = RegistryTestTextHolder78(bytes)
        try { registryTestTextFrame78(holder, action) } finally { holder.close() }
    } finally { bytes.close() }
}
func registryTestRootExists78(record: ProductPluginRecord): Bool {
    let result = RegistryTestBool78()
    registryTestWithRoot78(record, { path => result.value = exists(Path(path)) }); result.value
}
func registryTestInspectInstalled78(registry: PluginRegistry, record: ProductPluginRecord): PluginRegistryResult<OwnedPluginPackageDescriptor> {
    let result = RegistryTestInspection78()
    registryTestWithRoot78(record, { path => result.value = Some(registry.inspect(path)) }); result.value.getOrThrow()
}
func registryTestOwnedCode78(error: PluginRegistryOwnedError): String {
    // Only fixed production category literals cross this diagnostic boundary.
    try { error.code } finally { error.close() }
}
func registryTestOwnedFailure78(error: PluginRegistryOwnedError): IllegalStateException {
    IllegalStateException(registryTestOwnedCode78(error))
}

// The existing 50,000-entry control remains caller-owned SDK data. The actual
// source fields are borrowed only within a private test helper and remain
// backed by original until this incoming packet is explicitly cleared.
class RegistryCallerInputFixture78 {
    private var selected: ?PluginRegistryCallerRecordInput = None
    init(original: ProductPluginRecord) {
        original.withRecord({ raw =>
            let source = raw.descriptor
            let callerDescriptor = PluginPackageDescriptor(source.id, source.version, source.ecosystem,
                source.family, source.source, root: source.root, manifestPath: source.manifestPath,
                components: source.components, contentDigest: source.contentDigest,
                requestedCapabilities: Array<String>(50000, repeat: "caller-retained-metadata"))
            selected = Some(PluginRegistryCallerRecordInput(callerDescriptor, raw.sourceKind, raw.locator,
                raw.versionLock, raw.revisionLock, raw.integrityLock, raw.contentLock,
                raw.enabled, raw.importedAt, scope: raw.scope, explicitlyDisabled: raw.explicitlyDisabled))
        })
    }
    prop input: PluginRegistryCallerRecordInput { get() { selected.getOrThrow() } }
    func close(): Unit { match (selected) { case Some(value) => selected = None; value.close(); case None => () } }
}
