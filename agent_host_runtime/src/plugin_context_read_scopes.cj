package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import agent_domain.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import yjson.*
import yjson_support.*

// Classification inputs only. Capabilities, approval, exact read witnesses,
// canonical Operations and Receipts remain at their existing boundaries.
public class HostContextReadScopes {
    public let digest: String
    private let roots: Array<String>
    private let copiedData: ?HostContextReadScopeCopiedData104
    init(configuration: HostContextReadScopeConfiguration, componentDigest: String, roots: Array<String>,
        copiedData!: ?HostContextReadScopeCopiedData104 = None) {
        this.copiedData = copiedData
        this.roots = roots.clone()
        this.digest = modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("schema", textValue("axyndra.context-read-scopes/v1")),
            ValueField("configuration", textValue(configuration.encoded)),
            ValueField("configuration_witness", textValue(configuration.witness)),
            ValueField("components", textValue(componentDigest))])))
    }
    public func permission(host: HostJavaScriptPluginHost, source: String, ordinary: String): String {
        if (!host.readViewSensitive(source)) { return ordinary }
        // These exclusions precede every data-root match, even for an exact
        // installed package. A broad operator root cannot override them.
        if (host.contextReadHardSensitive(source)) { return "sensitive-path.read" }
        for (root in roots where hostPathComponentsContain(root, source)) { return "outside-workspace.read" }
        "sensitive-path.read"
    }
    public func validate(host: HostJavaScriptPluginHost): Result<Unit> {
        let current = match (host.captureContextReadScopes()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (current.digest != digest) { return hostPluginResourceError("context.read_scopes_changed", "read classification changed after preparation") }
        Result.Ok(())
    }
}

public func hostContextReadPermission(host: HostJavaScriptPluginHost, scopes: ?HostContextReadScopes,
    source: String, ordinary: String): String {
    match (scopes) { case Some(value) => value.permission(host, source, ordinary)
        case None => if (host.readViewSensitive(source)) { "sensitive-path.read" } else { ordinary } }
}

public class HostContextReadScopeConfiguration {
    public let encoded: String
    public let witness: String
    init(encoded: String, witness: String) { this.encoded = encoded; this.witness = witness }
}

// A missing file means no operator data roots. Read the bounded contents
// through the existing verified-handle copy rather than following a path
// after stat. The file witness also invalidates delete/recreate with same bytes.
public func hostContextReadScopeConfiguration(settingsRoot: String): Result<HostContextReadScopeConfiguration> {
    if (settingsRoot == "") { return Result.Ok(HostContextReadScopeConfiguration("", "")) }
    try {
        let directory = Path(settingsRoot).join("plugins")
        if (!exists(directory)) { return Result.Ok(HostContextReadScopeConfiguration("", "")) }
        let info = FileInfo(directory)
        if (info.isSymbolicLink() || !info.isDirectory()) {
            return hostPluginResourceError("context.read_scopes_invalid", "read scope configuration directory is unsafe") }
        let path = directory.join("read-scopes.json")
        var present = false
        for (entry in Directory.readFrom(directory) where entry.name == "read-scopes.json") {
            if (entry.isSymbolicLink() || !entry.isRegular()) {
                return hostPluginResourceError("context.read_scopes_invalid", "read scope configuration must be a regular file") }
            present = true
        }
        if (!present) { return Result.Ok(HostContextReadScopeConfiguration("", "")) }
        let witness = match (hostReadResourceWitness(path.toString())) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let size = try { Int64.parse(witness.split(":")[4]) } catch (_: Exception) { -1 }
        if (!witness.startsWith("f:") || size < 1 || size > 65536) {
            return hostPluginResourceError("context.read_scopes_invalid", "read scope configuration exceeds its regular-file bound") }
        let temporary = Directory.createTemp("/tmp")
        var result: Result<HostContextReadScopeConfiguration> = hostPluginResourceError("context.read_scopes_invalid", "read scope configuration is unavailable")
        try {
            let target = temporary.join("configuration")
            match (hostReadResourceCopy(path.toString(), witness, target.toString(), size)) {
                case Result.Err(error) => result = Result.Err(error)
                case Result.Ok(count) =>
                    if (count != size) { result = hostPluginResourceError("context.read_scopes_invalid", "read scope configuration changed while observed") }
                    else { result = Result.Ok(HostContextReadScopeConfiguration(String.fromUtf8(File.readFrom(target)), witness)) }
            }
        } finally { remove(temporary, recursive: true) }
        result
    } catch (_: Exception) { hostPluginResourceError("context.read_scopes_invalid", "read scope configuration could not be validated") }
}

public func hostLoadContextReadScopes(host: HostJavaScriptPluginHost, settingsRoot: String,
    components: ?RegistryContextComponentSnapshot): Result<HostContextReadScopes> {
    let configuration = match (hostContextReadScopeConfiguration(settingsRoot)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let encoded = configuration.encoded
    let roots = ArrayList<String>()
    try {
        if (encoded != "") {
            let config = parseUnifiedJson(encoded, maxBytes: 65536, maxDepth: 8)
            if (!httpIntentExactFields(config, ["version", "roots"]) ||
                config.field("version").getOrThrow().unifiedKind != ValueKind.Number ||
                config.field("version").getOrThrow().asNumberText() != "1" ||
                config.field("roots").getOrThrow().unifiedKind != ValueKind.List ||
                config.field("roots").getOrThrow().items.size > 64) {
                return hostPluginResourceError("context.read_scopes_invalid", "read scope configuration has an invalid shape") }
            let settings = Path(settingsRoot).normalize().toString()
            let control = Path(settings).join("plugins").toString()
            for (item in config.field("roots").getOrThrow().items) {
                if (item.unifiedKind != ValueKind.Text || item.text == "" || item.text.size > 4096 || item.text.contains("\u{0000}")) {
                    return hostPluginResourceError("context.read_scopes_invalid", "read scope root is invalid") }
                let root = if (item.text.startsWith("$" + "{settings_root}/")) { Path(settings).join(item.text[17..]).toString() } else { item.text }
                if (!Path(root).isAbsolute() || Path(root).normalize().toString() != root || root.contains("$") ||
                    root == settings || !hostPathComponentsContain(settings, root) ||
                    hostPathComponentsContain(control, root) || hostPathComponentsContain(root, control) ||
                    host.contextReadHardSensitive(root) || roots.contains(root)) {
                    return hostPluginResourceError("context.read_scopes_invalid", "operator data roots must be narrow ordinary settings data directories") }
                roots.add(root)
            }
        }
        // A projection from the existing locked registry, never roots supplied
        // by a native provider or copied into a second persistent registry.
        match (components) {
            case Some(value) => hostContextReadScopeOwned104(configuration, roots, value)
            case None => Result.Ok(HostContextReadScopes(configuration, "", roots.toArray()))
        }
    } catch (_: Exception) { hostPluginResourceError("context.read_scopes_invalid", "read scope roots could not be validated") }
}

// Scope data only. This independently paid copy grants no Source, permission,
// I/O or acknowledgement. The legacy scope can escape through callers with no
// retirement contract, so its actual copied data remains funded (OPEN).
class HostContextReadScopeCopiedData104 {
    let payment: LogicalJsonOwnerReservation
    var bytes: ?Array<UInt8> = None
    var componentDigest: ?String = None
    var roots: ?ArrayList<String> = None
    var next: ?HostContextReadScopeCopiedData104 = None
    var constructedScope = false
    init(payment: LogicalJsonOwnerReservation) { this.payment = payment }
}
private class HostContextReadScopeCopyDebt104 {
    private let lock = Mutex()
    private var head: ?HostContextReadScopeCopiedData104 = None
    func retain(actual: HostContextReadScopeCopiedData104): Unit {
        lock.lock(); try { actual.next = head; head = Some(actual) } finally { lock.unlock() }
    }
}
private let hostContextReadScopeCopyDebt104 = HostContextReadScopeCopyDebt104()

private func hostContextReadScopeAdd104(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || left > 134217728 - right) {
        throw LogicalJsonPayloadError("Host read scope copied data exceeds the original aggregate")
    }
    left + right
}
private func hostContextReadScopeTextInvoice104(total: Int64, bytes: Int64): Int64 {
    if (bytes < 0 || bytes > (134217728 - total) / 128) {
        throw LogicalJsonPayloadError("Host read scope copied text exceeds the original aggregate")
    }
    hostContextReadScopeAdd104(total, bytes * 128)
}
private func hostContextReadScopeRootExtent104(values: OwnedRegistryTextList, index: Int64): Int64 {
    let raw = match (values.copyAt(index)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) =>
            error.close()
            throw LogicalJsonPayloadError("Host read scope root byte owner cannot fit the original capacity")
    }
    // The already-paid scope wrapper/frame covers this numeric helper. No
    // String or DOM is produced while measuring; its frame returns first.
    try { hostContextReadScopeRootExtentFrame104(raw) } finally { raw.close() }
}
private func hostContextReadScopeRootExtentFrame104(raw: OwnedRegistryUtf8): Int64 { raw.byteCount }

private func hostContextReadScopeCopyDigestFrame104(actual: HostContextReadScopeCopiedData104,
    raw: OwnedRegistryUtf8): Unit {
    var copiedBytes = Array<UInt8>(raw.byteCount, repeat: 0u8)
    actual.bytes = Some(copiedBytes)
    for (index in 0..raw.byteCount) { copiedBytes[index] = raw.byteAt(index) }
    actual.bytes = Some(copiedBytes)
    actual.componentDigest = Some(String.fromUtf8(copiedBytes))
}
private func hostContextReadScopeCopyRootFrame104(actual: HostContextReadScopeCopiedData104,
    raw: OwnedRegistryUtf8): Unit {
    var copiedBytes = Array<UInt8>(raw.byteCount, repeat: 0u8)
    actual.bytes = Some(copiedBytes)
    for (index in 0..raw.byteCount) { copiedBytes[index] = raw.byteAt(index) }
    actual.bytes = Some(copiedBytes)
    let root = String.fromUtf8(copiedBytes)
    if (!actual.roots.getOrThrow().contains(root)) { actual.roots.getOrThrow().add(root) }
}
private func hostContextReadScopeCopyRoot104(actual: HostContextReadScopeCopiedData104,
    values: OwnedRegistryTextList, index: Int64): Unit {
    let raw = match (values.copyAt(index)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) =>
            error.close()
            throw LogicalJsonPayloadError("Host read scope root copy cannot fit the original capacity")
    }
    try { hostContextReadScopeCopyRootFrame104(actual, raw) }
    finally {
        // The copy helper's String/array locals have returned. The actual root
        // String stays in the separately prepaid scope, never the byte loan.
        actual.bytes = None
        raw.close()
    }
}
private func hostContextReadScopeBuildFrame104(actual: HostContextReadScopeCopiedData104,
    configuration: HostContextReadScopeConfiguration, operatorRoots: ArrayList<String>,
    componentRoots: OwnedRegistryTextList, componentDigest: OwnedRegistryUtf8): HostContextReadScopes {
    actual.roots = Some(ArrayList<String>())
    for (root in operatorRoots) { actual.roots.getOrThrow().add(root) }
    hostContextReadScopeCopyDigestFrame104(actual, componentDigest)
    actual.bytes = None
    for (index in 0..componentRoots.size) { hostContextReadScopeCopyRoot104(actual, componentRoots, index) }
    let result = HostContextReadScopes(configuration, actual.componentDigest.getOrThrow(),
        actual.roots.getOrThrow().toArray(), copiedData: Some(actual))
    actual.constructedScope = true
    result
}
private func hostContextReadScopeOwnedFrame104(actual: HostContextReadScopeCopiedData104,
    configuration: HostContextReadScopeConfiguration, operatorRoots: ArrayList<String>,
    components: RegistryContextComponentSnapshot, rawDigest: OwnedRegistryUtf8,
    initialInvoice: Int64): HostContextReadScopes {
    var invoice = initialInvoice
    let componentRoots = components.readRoots()
    try {
        for (index in 0..componentRoots.size) {
            invoice = hostContextReadScopeAdd104(invoice, 8192)
            invoice = hostContextReadScopeTextInvoice104(invoice,
                hostContextReadScopeRootExtent104(componentRoots, index))
        }
        // All occurrences, including duplicates removed by the original
        // projection, are summed BEFORE any copied String or array.
        actual.payment.ensureRetainedPeak(invoice)
        hostContextReadScopeBuildFrame104(actual, configuration, operatorRoots, componentRoots, rawDigest)
    } finally {
        // The build helper has returned. New Strings/Scope/canonical digest
        // remain covered by actual.payment, never this temporary root list.
        componentRoots.close()
    }
}
private func hostContextReadScopeOwned104(configuration: HostContextReadScopeConfiguration,
    operatorRoots: ArrayList<String>, components: RegistryContextComponentSnapshot): Result<HostContextReadScopes> {
    let rawDigest = match (components.copyDigest()) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) => return hostRegistryOwnedError81<HostContextReadScopes>(error)
    }
    var pending: ?HostContextReadScopeCopiedData104 = None
    try {
        // Complete retained configuration/witness, digest, original root
        // aliases, canonical framing Strings/DOM/hash bytes and both array
        // clones are covered. 128 per input UTF8 byte also covers simultaneous
        // conversion/path splitting and escaping copies; cells are SUM below.
        var invoice: Int64 = 65536
        invoice = hostContextReadScopeTextInvoice104(invoice, configuration.encoded.size)
        invoice = hostContextReadScopeTextInvoice104(invoice, configuration.witness.size)
        invoice = hostContextReadScopeTextInvoice104(invoice, rawDigest.byteCount)
        for (root in operatorRoots) {
            invoice = hostContextReadScopeAdd104(invoice, 8192)
            invoice = hostContextReadScopeTextInvoice104(invoice, root.size)
        }
        let actual = HostContextReadScopeCopiedData104(rawDigest.deriveCopiedDataPayment(invoice))
        pending = Some(actual)
        // The entire inner measurement/readRoots/build and all failure frames
        // return before the outer holder can retire any private partial data.
        let result = hostContextReadScopeOwnedFrame104(actual, configuration, operatorRoots,
            components, rawDigest, invoice)
        actual.bytes = None
        // Only an actually constructed Scope becomes conservative escaping
        // data debt. This is not a Source or physical acknowledgement.
        hostContextReadScopeCopyDebt104.retain(actual)
        Result.Ok(result)
    } catch (_: LogicalJsonPayloadError) {
        hostPluginResourceError("plugin.registry_metadata_capacity", "registry metadata cannot fit the original shared capacity")
    } finally {
        match (pending) {
            case Some(actual) => if (!actual.constructedScope) {
                // No Scope escaped from the complete returned inner frame.
                // Clear actual arrays/Strings first, then retire only this
                // copied-data child; original Registry/input owners remain.
                actual.bytes = None; actual.roots = None; actual.componentDigest = None
                pending = None
                actual.payment.close()
            }
            case None => ()
        }
        rawDigest.close()
    }
}
