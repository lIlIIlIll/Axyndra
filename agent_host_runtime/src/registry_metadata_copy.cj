package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_plugin_registry.*
import agent_sdk.*
import tool_runtime.*
import process4cj as process
import std.collection.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

private let hostRegistryMountDescriptors159 = HostRegistryMountDescriptors159()
private let hostRegistryCatalogIdentityDebt159 = HostRegistryCatalogIdentityDebt159()
private let hostRegistryUnknownBackings159 = HostRegistryUnknownBackingDebt159()

// This graph is Host-private. Legacy Host callbacks and grants still contain
// raw String aliases; neither unmount nor a returned helper proves those
// callers retired. Their exact copied-data child therefore remains funded.
// Registry scope/pin closure may retire its own graph, never this allocation.
class HostRegistryCopiedGraph81 {
    let payment: LogicalJsonOwnerReservation
    var bytes: ?Array<UInt8> = None
    var source: ?String = None
    var document: ?AgentValue = None
    var descriptor: ?PluginPackageDescriptor = None
    var escapedText: ?String = None
    var fenceCode90: ?String = None
    var originalFenceError90: ?PluginImportError = None
    init(payment: LogicalJsonOwnerReservation) { this.payment = payment }
    func clearReturnedScratch(): Unit { bytes = None; source = None; document = None }
}

private class HostRegistryCopiedGraphDebt81 {
    private let lock = Mutex()
    private let graphs = ArrayList<HostRegistryCopiedGraph81>()
    func retain(actual: HostRegistryCopiedGraph81): Unit {
        lock.lock(); try { graphs.add(actual) } finally { lock.unlock() }
    }
    // Actual object identity selects only its original copied-data reservation.
    // This is never Source, a pin check, permission or an execution admission.
    func deriveFenceErrorData90(descriptor: PluginPackageDescriptor, invoice: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            for (actual in graphs) {
                match (actual.descriptor) {
                    case Some(value) => if (refEq(value, descriptor)) {
                        let payment = actual.payment.deriveRetainedLease()
                        try { payment.ensureRetainedPeak(invoice); return payment }
                        catch (error: Exception) { payment.close(); throw error }
                    }
                    case None => ()
                }
            }
            return hostRegistryMountDescriptors159.derive159(descriptor, invoice)
        } finally { lock.unlock() }
    }
}
private let hostRegistryCopiedGraphDebt81 = HostRegistryCopiedGraphDebt81()

func hostRegistryAdd81(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || left > 134217728 - right) {
        throw LogicalJsonPayloadError("Host registry copied data exceeds its original aggregate")
    }
    left + right
}
// No String/Array/DOM is created while measuring. Wire bytes upper-bound every
// decoded text occurrence. SUM covers the byte copy, source, parser/scanner
// text/scratch, DTO trim/namespace copies and constructor string clones.
// Each structural occurrence includes JSON cells, lists, DTO objects and both
// constructor/getter array clones. The 64 KiB pays the fixed helper/debt cells.
private func hostRegistryCopyInvoice81(raw: OwnedRegistryUtf8): Int64 {
    let count = raw.byteCount
    var total: Int64 = 65536
    var quoted = false; var escaped = false
    for (index in 0..count) {
        let byte = raw.byteAt(index)
        total = hostRegistryAdd81(total, 16)
        if (quoted) {
            if (escaped) { escaped = false }
            else if (byte == b'\\') { escaped = true }
            else if (byte == b'"') { quoted = false }
        } else if (byte == b'"') {
            quoted = true; total = hostRegistryAdd81(total, 2048)
        } else if (byte == b'{' || byte == b'[' || byte == b':' || byte == b',') {
            total = hostRegistryAdd81(total, 2048)
        }
    }
    if (quoted || escaped) { throw LogicalJsonPayloadError("Host registry copied metadata framing is incomplete") }
    total
}

private func hostRegistryCopyFrame81(actual: HostRegistryCopiedGraph81, raw: OwnedRegistryUtf8): Unit {
    var copiedBytes = Array<UInt8>(raw.byteCount, repeat: 0u8)
    actual.bytes = Some(copiedBytes)
    for (index in 0..raw.byteCount) { copiedBytes[index] = raw.byteAt(index) }
    actual.bytes = Some(copiedBytes)
    actual.source = Some(String.fromUtf8(copiedBytes))
    actual.document = Some(parseUnifiedJson(actual.source.getOrThrow(), maxBytes: LOGICAL_JSON_HARD_BYTES))
    actual.descriptor = Some(hostRegistryDecodeDescriptor81(actual.document.getOrThrow()))
}

// Package-only migration seam, never a public raw getter. The exact graph and
// its same-bank payment are registered before any private allocation/capture.
// Successful helper RETURN clears only temporary fields; external legacy
// aliases keep the independent copied-data debt. Opaque failures retain it too.
func hostRegistryDescriptorCopy81(owned: OwnedPluginPackageDescriptor): Result<PluginPackageDescriptor> {
    let raw = match (owned.copyCompleteJson()) {
        case PluginRegistryResult.Err(error) => return hostRegistryOwnedError81<PluginPackageDescriptor>(error)
        case PluginRegistryResult.Ok(value) => value
    }
    try {
        let payment = raw.deriveCopiedDataPayment(hostRegistryCopyInvoice81(raw))
        let actual = HostRegistryCopiedGraph81(payment)
        hostRegistryCopiedGraphDebt81.retain(actual)
        hostRegistryCopyFrame81(actual, raw)
        actual.clearReturnedScratch()
        Result.Ok(actual.descriptor.getOrThrow())
    } catch (_: LogicalJsonPayloadError) {
        hostPluginResourceError("plugin.registry_metadata_capacity", "registry metadata cannot fit the original shared capacity")
    } finally { raw.close() }
}

private func hostRegistryCopyTextFrame81(actual: HostRegistryCopiedGraph81, raw: OwnedRegistryUtf8): Unit {
    var copiedBytes = Array<UInt8>(raw.byteCount, repeat: 0u8)
    actual.bytes = Some(copiedBytes)
    for (index in 0..raw.byteCount) { copiedBytes[index] = raw.byteAt(index) }
    actual.bytes = Some(copiedBytes)
    actual.escapedText = Some(String.fromUtf8(copiedBytes))
}
private func hostRegistryOwnedMessage81(error: PluginRegistryOwnedError): String {
    match (error.staticReason) {
        case PluginRegistryStaticReason.MetadataCapacity => return "registry metadata cannot fit the original shared capacity"
        case PluginRegistryStaticReason.ExecutionNotCurrent => return "installed execution pin is not current"
        case PluginRegistryStaticReason.InstalledRecordAbsent => return "installed record is absent"
        case PluginRegistryStaticReason.ComponentAliasInvalid => return "initial context configuration or its exact installed binding is unavailable"
        case PluginRegistryStaticReason.None => ()
    }
    let raw = match (error.copyText(PluginRegistryErrorText.Message)) {
        case PluginRegistryResult.Err(_) => throw LogicalJsonPayloadError("Host registry error copy cannot fit the original capacity")
        case PluginRegistryResult.Ok(value) => value
    }
    try {
        var invoice: Int64 = 8192
        for (_ in 0..raw.byteCount) { invoice = hostRegistryAdd81(invoice, 8) }
        let actual = HostRegistryCopiedGraph81(raw.deriveCopiedDataPayment(invoice))
        hostRegistryCopiedGraphDebt81.retain(actual)
        hostRegistryCopyTextFrame81(actual, raw)
        actual.clearReturnedScratch()
        actual.escapedText.getOrThrow()
    } finally { raw.close() }
}
func hostRegistryOwnedError81<T>(error: PluginRegistryOwnedError): Result<T> {
    // Fixed category codes remain control data. A complete dynamic message is
    // copied and independently paid before it enters the legacy AgentError.
    try { hostPluginResourceError(error.code, hostRegistryOwnedMessage81(error)) }
    catch (_: LogicalJsonPayloadError) {
        hostPluginResourceError("plugin.registry_metadata_capacity", "registry metadata cannot fit the original shared capacity")
    } finally { error.close() }
}
// Legacy pin.enter/current return their original two-field control result.
// Pay all original code/message references, UTF8 array copies, String copies,
// AgentError trim copies and mapping/wrapper cells before capture/allocation.
// The real mapped error may escape through worker/Core/caller APIs; no guessed
// consumer ACK is available. Its independent same-bank data child stays paid.
private func hostRegistryFenceCopy90(descriptor: PluginPackageDescriptor, error: PluginImportError): HostRegistryCopiedGraph81 {
    var invoice: Int64 = 65536
    for (_ in 0..error.code.size) { invoice = hostRegistryAdd81(invoice, 8) }
    for (_ in 0..error.message.size) { invoice = hostRegistryAdd81(invoice, 8) }
    let payment = hostRegistryCopiedGraphDebt81.deriveFenceErrorData90(descriptor, invoice)
    let actual = HostRegistryCopiedGraph81(payment)
    hostRegistryCopiedGraphDebt81.retain(actual)
    actual.originalFenceError90 = Some(error)
    hostRegistryFenceCopyFrame90(actual, error)
    return actual
}
private func hostRegistryFenceCopyFrame90(actual: HostRegistryCopiedGraph81, error: PluginImportError): Unit {
    actual.fenceCode90 = Some(String.fromUtf8(error.code.toArray()))
    actual.escapedText = Some(String.fromUtf8(error.message.toArray()))
}
func hostRegistryFenceError90<T>(descriptor: PluginPackageDescriptor, error: PluginImportError): Result<T> {
    let actual = hostRegistryFenceCopy90(descriptor, error)
    hostPluginResourceError(actual.fenceCode90.getOrThrow(), actual.escapedText.getOrThrow())
}
func hostRegistryFenceJavaScriptError90(descriptor: PluginPackageDescriptor, error: PluginImportError): JavaScriptHostError {
    let actual = hostRegistryFenceCopy90(descriptor, error)
    JavaScriptHostError(actual.fenceCode90.getOrThrow(), actual.escapedText.getOrThrow())
}

func hostRegistryJavaScriptError81(error: PluginRegistryOwnedError): JavaScriptHostError {
    try { JavaScriptHostError(error.code, hostRegistryOwnedMessage81(error)) }
    catch (_: LogicalJsonPayloadError) {
        JavaScriptHostError("plugin.registry_metadata_capacity", "registry metadata cannot fit the original shared capacity")
    } finally { error.close() }
}

// Full actual Registry inspection remains mandatory. These are comparisons of
// data only; all original Source/approval/effect fences stay in their callers.
func hostRegistryPackageMatches81(registry: PluginRegistry, root: String,
    namespace!: ?String = None, version!: ?String = None, digest!: ?String = None,
    entrypoint!: ?String = None): Result<Bool> {
    let actual = match (registry.inspect(root)) {
        case PluginRegistryResult.Err(error) =>
            // These callers previously ignored the inspection error graph.
            // Preserve its fixed category without exporting its dynamic data.
            let code = error.code; error.close()
            return hostPluginResourceError(code, "registry package inspection failed")
        case PluginRegistryResult.Ok(value) => value
    }
    try {
        let wrapper = actual.deriveCopiedDataPayment(4096)
        try { Result.Ok(hostRegistryPackageMatchesFrame81(actual, root, namespace, version, digest, entrypoint)) }
        finally { wrapper.close() }
    } finally { actual.close() }
}
private func hostRegistryPackageMatchesFrame81(actual: OwnedPluginPackageDescriptor, root: String,
    namespace: ?String, version: ?String, digest: ?String, entrypoint: ?String): Bool {
    if (!actual.textEquals(PluginDescriptorText.Root, root)) { return false }
    match (namespace) { case Some(value) => if (!actual.textEquals(PluginDescriptorText.Namespace, value)) { return false }; case None => () }
    match (version) { case Some(value) => if (!actual.textEquals(PluginDescriptorText.Version, value)) { return false }; case None => () }
    match (digest) { case Some(value) => if (!actual.textEquals(PluginDescriptorText.ContentDigest, value)) { return false }; case None => () }
    match (entrypoint) { case Some(value) => if (!actual.textEquals(PluginDescriptorText.Entrypoint, value)) { return false }; case None => () }
    true
}

private func hostRegistryText81(value: AgentValue, field: String): String {
    let actual = value.field(field).getOrThrow()
    if (actual.kind() != JsonKind.String) { throw LogicalJsonPayloadError("Host registry descriptor text schema changed") }
    actual.text
}
private func hostRegistryBool81(value: AgentValue, field: String): Bool {
    let actual = value.field(field).getOrThrow()
    if (actual.kind() != JsonKind.Boolean) { throw LogicalJsonPayloadError("Host registry descriptor boolean schema changed") }
    actual.asBool()
}
private func hostRegistryStrings81(value: AgentValue): Array<String> {
    let values = ArrayList<String>()
    for (item in value.items) {
        if (item.kind() != JsonKind.String) { throw LogicalJsonPayloadError("Host registry descriptor array schema changed") }
        values.add(item.text)
    }
    values.toArray()
}
private func hostRegistryContributionKind81(value: String): PluginContributionKind {
    match (value) {
        case "tool" => PluginContributionKind.Tool; case "command" => PluginContributionKind.Command
        case "skill" => PluginContributionKind.Skill; case "provider" => PluginContributionKind.Provider
        case "model_provider" => PluginContributionKind.ModelProvider; case "context_provider" => PluginContributionKind.ContextProvider
        case "resource_provider" => PluginContributionKind.ResourceProvider; case "event" => PluginContributionKind.Event
        case "service" => PluginContributionKind.Service
        case _ => throw LogicalJsonPayloadError("Host registry contribution kind changed")
    }
}
private func hostRegistryComponentKind81(value: String): PluginComponentKind {
    match (value) {
        case "skill" => PluginComponentKind.Skill; case "mcp" => PluginComponentKind.Mcp
        case "prompt" => PluginComponentKind.Prompt; case "extension" => PluginComponentKind.Extension
        case "hook" => PluginComponentKind.Hook; case "command" => PluginComponentKind.Command
        case "theme" => PluginComponentKind.Theme; case "hosted" => PluginComponentKind.HostedOnly
        case _ => throw LogicalJsonPayloadError("Host registry component kind changed")
    }
}
private func hostRegistryDecodeDescriptor81(value: AgentValue): PluginPackageDescriptor {
    let ecosystem = match (hostRegistryText81(value, "ecosystem")) {
        case "pi" => PluginEcosystem.Pi; case "codex" => PluginEcosystem.Codex; case "axyndra" => PluginEcosystem.Axyndra
        case _ => throw LogicalJsonPayloadError("Host registry ecosystem changed") }
    let family = match (hostRegistryText81(value, "family")) {
        case "pi" => PluginManifestFamily.Pi; case "codex" => PluginManifestFamily.Codex; case "axyndra" => PluginManifestFamily.Axyndra
        case _ => throw LogicalJsonPayloadError("Host registry manifest family changed") }
    let entry = match (hostRegistryText81(value, "entry_kind")) {
        case "javascript" => PluginEntryKind.JavaScript; case "native-executable" => PluginEntryKind.NativeExecutable
        case "legacy-process" => PluginEntryKind.LegacyProcess
        case _ => throw LogicalJsonPayloadError("Host registry entry kind changed") }
    let components = ArrayList<PluginComponent>()
    for (item in value.field("components").getOrThrow().items) {
        let status = match (hostRegistryText81(item, "status")) {
            case "supported" => PluginComponentStatus.Supported; case "blocked" => PluginComponentStatus.Blocked
            case "unsupported" => PluginComponentStatus.Unsupported; case "unverified" => PluginComponentStatus.Unverified
            case _ => throw LogicalJsonPayloadError("Host registry component status changed") }
        components.add(PluginComponent(hostRegistryComponentKind81(hostRegistryText81(item, "kind")), hostRegistryText81(item, "relative_path"),
            status: status, name: hostRegistryText81(item, "name"), identity: hostRegistryText81(item, "identity"),
            dependencies: hostRegistryStrings81(item.field("dependencies").getOrThrow())))
    }
    let dependencies = ArrayList<PluginPackageDependency>()
    for (item in value.field("dependencies").getOrThrow().items) {
        dependencies.add(PluginPackageDependency(hostRegistryText81(item, "name"), hostRegistryText81(item, "version_range"),
            optional: hostRegistryBool81(item, "optional"), development: hostRegistryBool81(item, "development"))) }
    let hooks = ArrayList<PluginHookDeclaration>()
    for (item in value.field("hook_declarations").getOrThrow().items) {
        hooks.add(PluginHookDeclaration(hostRegistryText81(item, "event"), hostRegistryText81(item, "matcher"),
            hostRegistryText81(item, "command"), Int64.parse(item.field("timeout_millis").getOrThrow().asNumberText()))) }
    let componentDependencies = ArrayList<PluginContributionDependency>()
    for (item in value.field("component_dependencies").getOrThrow().items) {
        componentDependencies.add(PluginContributionDependency(hostRegistryText81(item, "namespace"), hostRegistryText81(item, "version_range"),
            hostRegistryContributionKind81(hostRegistryText81(item, "kind")), hostRegistryText81(item, "name"))) }
    let contributions = ArrayList<PluginContributionDefinition>()
    for (item in value.field("contributions").getOrThrow().items) {
        let profile = match (hostRegistryText81(item, "execution_profile")) {
            case "brokered" => PluginToolExecutionProfile.Brokered; case "data_only" => PluginToolExecutionProfile.DataOnly
            case _ => throw LogicalJsonPayloadError("Host registry execution profile changed") }
        contributions.add(PluginContributionDefinition(hostRegistryText81(item, "name"), hostRegistryContributionKind81(hostRegistryText81(item, "kind")),
            supportsPreparationReference: hostRegistryBool81(item, "supports_preparation_reference"),
            allowedUserControls: hostRegistryStrings81(item.field("allowed_user_controls").getOrThrow()), executionProfile: profile,
            inputAttachmentField: hostRegistryText81(item, "input_attachment_field"),
            inputAttachmentMaxBytes: Int64.parse(item.field("input_attachment_max_bytes").getOrThrow().asNumberText()))) }
    let actual = PluginPackageDescriptor(hostRegistryText81(value, "id"), hostRegistryText81(value, "version"), ecosystem, family,
        hostRegistryText81(value, "source"), root: hostRegistryText81(value, "root"), manifestPath: hostRegistryText81(value, "manifest_path"),
        overlayPath: hostRegistryText81(value, "overlay_path"), compatibilityProfile: hostRegistryText81(value, "compatibility_profile"),
        components: components.toArray(), dependencies: dependencies.toArray(), hookDeclarations: hooks.toArray(),
        componentDependencies: componentDependencies.toArray(), missingDependencies: hostRegistryStrings81(value.field("missing_dependencies").getOrThrow()),
        entrypoint: hostRegistryText81(value, "entrypoint"), entryKind: entry, contributions: contributions.toArray(),
        requestedCapabilities: hostRegistryStrings81(value.field("requested_capabilities").getOrThrow()), sdkRange: hostRegistryText81(value, "sdk_range"),
        protocolRange: hostRegistryText81(value, "protocol_range"), contentDigest: hostRegistryText81(value, "content_digest"),
        declaredContentDigest: hostRegistryText81(value, "declared_content_digest"), signature: hostRegistryText81(value, "signature"))
    if (actual.namespace != hostRegistryText81(value, "namespace")) { throw LogicalJsonPayloadError("Host registry namespace reconstruction changed") }
    actual
}

// Public consumers retain closed Registry handles. Only Host creates the
// independently paid private graph used by its existing configuration/launch
// implementations. No decoded descriptor crosses back through these APIs.
public func loadHostPluginHttpConfiguration(settingsRoot: String,
    descriptor: OwnedPluginPackageDescriptor): Result<HostPluginHttpConfiguration> {
    let actual = match (hostRegistryDescriptorCopy81(descriptor)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    loadHostPluginHttpConfiguration(settingsRoot, actual.namespace, actual.contentDigest)
}
public func hostLoadPluginLifecycleConfiguration(settingsRoot: String,
    descriptor: OwnedPluginPackageDescriptor): Result<HostPluginLifecycleConfiguration> {
    let actual = match (hostRegistryDescriptorCopy81(descriptor)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    hostLoadPluginLifecycleConfiguration(settingsRoot, actual.namespace, actual.contentDigest, actual.root)
}
public func hostOrdinaryToolPayloadSelection(settingsRoot: String, descriptor: OwnedPluginPackageDescriptor,
    availableTools: Array<String>, kind: String, tool: String, limits: ?OrdinaryToolPayloadLimits,
    document!: Bool = false): Result<String> {
    let actual = match (hostRegistryDescriptorCopy81(descriptor)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    hostOrdinaryToolPayloadSelection(settingsRoot, actual, availableTools, kind, tool, limits, document: document)
}
public func hostStartJavaScriptHost(descriptor: OwnedPluginPackageDescriptor, generation: UInt64,
    launcher: JavaScriptHostProcessLauncher, timeoutMillis!: Int64 = 30000,
    cancellation!: ?process.CancellationToken = None, serviceLimits!: ?ServiceProtocolLimits = None,
    payloadLimits!: ?ServicePayloadLimits = None, ordinaryToolPayload!: Bool = false,
    providerSequence!: Bool = false, contextSequence!: Bool = false,
    dispatchFence!: ?JavaScriptHostDispatchFence = None): JavaScriptHostResult<JavaScriptExtensionHost> {
    let actual = match (hostRegistryDescriptorCopy81(descriptor)) {
        case Result.Err(error) => return JavaScriptHostResult.Err(JavaScriptHostError(error.code, error.message))
        case Result.Ok(value) => value }
    hostStartJavaScriptHost(actual, generation, launcher, timeoutMillis: timeoutMillis, cancellation: cancellation,
        serviceLimits: serviceLimits, payloadLimits: payloadLimits, ordinaryToolPayload: ordinaryToolPayload,
        providerSequence: providerSequence, contextSequence: contextSequence, dispatchFence: dispatchFence)
}

// DATA only: preserve the original descriptor identity lookup and bank. No
// registry pin or effect permission is created by this reservation.
func hostRegistryDeriveCopiedData159(descriptor: PluginPackageDescriptor, invoice: Int64): LogicalJsonOwnerReservation {
    hostRegistryCopiedGraphDebt81.deriveFenceErrorData90(descriptor, invoice)
}
func hostRegistryFenceJavaScriptError159(data: HostRegistryMountData159, error: PluginImportError): JavaScriptHostError {
    var invoice: Int64 = 65536
    for (_ in 0..error.code.size) { invoice = hostRegistryAdd81(invoice, 8) }
    for (_ in 0..error.message.size) { invoice = hostRegistryAdd81(invoice, 8) }
    let actual = HostRegistryCopiedGraph81(data.deriveError159(invoice))
    hostRegistryCopiedGraphDebt81.retain(actual)
    actual.originalFenceError90 = Some(error)
    hostRegistryFenceCopyFrame90(actual, error)
    JavaScriptHostError(actual.fenceCode90.getOrThrow(), actual.escapedText.getOrThrow())
}

// Private copied descriptor custody. The frame owner is registered before the
// first byte/DOM/DTO copy. Only the known mount frame may borrow this graph;
// legacy publication or an opaque escape keeps its original payment retained.
class HostRegistryMountDescriptor159 {
    private let lock = Mutex()
    private var graph: ?HostRegistryCopiedGraph81
    private var escaped = false
    private var frameReturned = false
    private var borrowed = false
    var nextRetained159: ?HostRegistryMountDescriptor159 = None
    init(graph: HostRegistryCopiedGraph81) { this.graph = Some(graph) }

    func mountDescriptor159(): PluginPackageDescriptor {
        lock.lock()
        try {
            if (frameReturned || borrowed) { throw LogicalJsonPayloadError("mount descriptor frame is unavailable") }
            borrowed = true
            graph.getOrThrow().descriptor.getOrThrow()
        } finally { lock.unlock() }
    }
    func retainLegacy159(): Unit {
        lock.lock(); try { escaped = true } finally { lock.unlock() }
    }
    func matches159(descriptor: PluginPackageDescriptor): Bool {
        lock.lock()
        try {
            match (graph) {
                case None => false
                case Some(value) => match (value.descriptor) {
                    case None => false
                    case Some(current) => refEq(current, descriptor)
                }
            }
        } finally { lock.unlock() }
    }
    func derive159(invoice: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            let child = graph.getOrThrow().payment.deriveRetainedLease()
            try { child.ensureRetainedPeak(invoice); child }
            catch (error: Exception) { child.close(); throw error }
        } finally { lock.unlock() }
    }
    private func clearReturned159(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            borrowed = false
            frameReturned = true
            if (escaped) { return None }
            let actual = match (graph) { case None => return None; case Some(value) => value }
            actual.clearReturnedScratch()
            actual.descriptor = None
            actual.escapedText = None
            actual.fenceCode90 = None
            actual.originalFenceError90 = None
            graph = None
            Some(actual.payment)
        } finally { lock.unlock() }
    }
    func returnedMountFrame159(): Unit {
        // This method is called outside the helper containing the raw DTO.
        match (clearReturned159()) {
            case None => ()
            case Some(payment) =>
                hostRegistryMountDescriptors159.remove159(this)
                payment.close()
        }
    }
}

private class HostRegistryMountDescriptors159 {
    private let lock = Mutex()
    private var head: ?HostRegistryMountDescriptor159 = None
    func retain159(value: HostRegistryMountDescriptor159): Unit {
        lock.lock(); try { value.nextRetained159 = head; head = Some(value) }
        finally { lock.unlock() }
    }
    func derive159(descriptor: PluginPackageDescriptor, invoice: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            var current = head
            while (current.isSome()) {
                let value = current.getOrThrow()
                if (value.matches159(descriptor)) { return value.derive159(invoice) }
                current = value.nextRetained159
            }
            throw LogicalJsonPayloadError("descriptor has no original mount DATA owner")
        } finally { lock.unlock() }
    }
    func remove159(value: HostRegistryMountDescriptor159): Unit {
        lock.lock()
        try {
            var current = head
            var previous: ?HostRegistryMountDescriptor159 = None
            while (current.isSome()) {
                let selected = current.getOrThrow()
                if (refEq(selected, value)) {
                    match (previous) {
                        case None => head = selected.nextRetained159
                        case Some(parent) => parent.nextRetained159 = selected.nextRetained159
                    }
                    selected.nextRetained159 = None
                    return
                }
                previous = current; current = selected.nextRetained159
            }
        } finally { lock.unlock() }
    }
}

func hostRegistryMountDescriptorCopy159(owned: OwnedPluginPackageDescriptor): Result<HostRegistryMountDescriptor159> {
    let raw = match (owned.copyCompleteJson()) {
        case PluginRegistryResult.Err(error) => return hostRegistryOwnedError81<HostRegistryMountDescriptor159>(error)
        case PluginRegistryResult.Ok(value) => value
    }
    try {
        // The existing full invoice covers the same copying pipeline and its
        // fixed carrier/node; no new bank, floor, cap or descriptor authority.
        let payment = raw.deriveCopiedDataPayment(hostRegistryCopyInvoice81(raw))
        let graph = HostRegistryCopiedGraph81(payment)
        let owner = HostRegistryMountDescriptor159(graph)
        hostRegistryMountDescriptors159.retain159(owner)
        try {
            hostRegistryCopyFrame81(graph, raw)
            graph.clearReturnedScratch()
            Result.Ok(owner)
        } catch (error: Exception) {
            // Unknown construction failures retain all partial aliases.
            owner.retainLegacy159()
            throw error
        }
    } catch (_: LogicalJsonPayloadError) {
        hostPluginResourceError("plugin.registry_metadata_capacity", "registry metadata cannot fit the original shared capacity")
    } finally { raw.close() }
}

// Private copied catalog DATA, including recursive declarations and callback
// captures. Existing raw ToolCatalog/snapshot APIs can outlive unmount, so this
// holder stays paid until an explicit private-reference retirement protocol.
// No Source, capability, instance-generation or executor identity is created.
class HostRegistryCatalogIdentity159 <: ToolCatalogDataPayment159 & ToolCatalogSnapshotPayment159 & ToolCatalogRetirableData159 {
    private let paymentLock159 = Mutex()
    private var namespaceValue: String = ""
    private var contentDigestValue: String = ""
    private var versionValue: String = ""
    private var rootValue: String = ""
    private var payment: ?LogicalJsonOwnerReservation
    private var retainedInvoice159: Int64
    private var constructionFrames159: Int64 = 0
    private var constructionReturned159 = false
    private let producerReturned159 = HostRegistryCatalogProducer159()
    private var catalogAliases159 = false
    private var catalogShares159: Int64 = 0
    private var canonical186: ?HostOwnedCanonicalProjectionSelection186 = None<HostOwnedCanonicalProjectionSelection186>
    private var primitive191: ?HostOwnedPrimitiveConfiguration191 = None<HostOwnedPrimitiveConfiguration191>
    private var tools159: ?HostRegistryCatalogToolData159 = None
    private var temporary159: ?HostRegistryCatalogTemporary159 = Option<HostRegistryCatalogTemporary159>.None
    var nextRetained159: ?HostRegistryCatalogIdentity159 = None
    prop namespace: String { get() { namespaceValue } }
    prop contentDigest: String { get() { contentDigestValue } }
    prop version: String { get() { versionValue } }
    prop root: String { get() { rootValue } }
    init(payment: LogicalJsonOwnerReservation, invoice: Int64) {
        this.payment = Some(payment); this.retainedInvoice159 = invoice
    }
    public func retainCatalogData159(): ToolCatalogDataLease159 {
        paymentLock159.lock()
        try {
            if (payment.isNone() || constructionFrames159 != 1 || constructionReturned159 || catalogShares159 == Int64.Max) {
                throw LogicalJsonPayloadError("catalog owner has no live construction frame")
            }
            let phase = payment.getOrThrow().deriveRetainedLease()
            try { phase.ensureRetainedPeak(8192) }
            catch (error: Exception) { phase.close(); throw error }
            let result = HostRegistryCatalogDataLease159(this, phase)
            catalogShares159++
            result
        } finally { paymentLock159.unlock() }
    }
    func ownPrimitiveConfiguration191(value: HostOwnedPrimitiveConfiguration191): Unit {
        paymentLock159.lock(); try {
            if (constructionFrames159 != 1 || constructionReturned159 || payment.isNone()) {
                value.holdUnknown191(); throw IllegalStateException("primitive configuration has no actual Catalog construction frame") }
            value.nextCatalog191 = primitive191; primitive191 = Some(value)
        } finally { paymentLock159.unlock() }
    }
    private func primitiveFramesReturned191(): Bool {
        var current = primitive191
        while (current.isSome()) {
            let value = current.getOrThrow()
            if (!value.canReturnOwnedPrimitive191()) { return false }
            current = value.nextCatalog191
        }
        true
    }
    private func returnPrimitiveConfigurations191(): Unit {
        // All actual Catalog descriptor/executor/backing and producer frames
        // have already returned. A separate actual share may still hold data.
        while (primitive191.isSome()) {
            let value = takePrimitiveConfigurationFrame191()
            value.returnOwnedPrimitive191()
        }
    }
    private func takePrimitiveConfigurationFrame191(): HostOwnedPrimitiveConfiguration191 {
        paymentLock159.lock(); try {
            let value = primitive191.getOrThrow()
            primitive191 = value.nextCatalog191; value.nextCatalog191 = None<HostOwnedPrimitiveConfiguration191>
            value
        } finally { paymentLock159.unlock() }
    }
    func ownCanonicalConfiguration186(value: HostOwnedCanonicalProjectionSelection186): Unit {
        paymentLock159.lock(); try {
            if (constructionFrames159 != 1 || constructionReturned159 || payment.isNone()) {
                value.holdUnknown186(); throw IllegalStateException("canonical configuration has no actual catalog construction frame") }
            value.nextCatalog186 = canonical186; canonical186 = Some(value)
        } finally { paymentLock159.unlock() }
    }
    private func canonicalFramesReturned186(): Bool {
        var current = canonical186
        while (current.isSome()) {
            let value = current.getOrThrow()
            if (!value.canReturnOwnedConfiguration186()) { return false }
            current = value.nextCatalog186
        }
        true
    }
    private func returnCanonicalConfigurations186(): Unit {
        // Called only after the actual Catalog dropped all descriptor and
        // executor/canonicalizer backing and complete producer frames returned.
        while (canonical186.isSome()) {
            let value = takeCanonicalConfigurationFrame186()
            value.returnOwnedConfiguration186()
        }
    }
    private func takeCanonicalConfigurationFrame186(): HostOwnedCanonicalProjectionSelection186 {
        paymentLock159.lock(); try {
            let value = canonical186.getOrThrow()
            canonical186 = value.nextCatalog186; value.nextCatalog186 = None<HostOwnedCanonicalProjectionSelection186>
            value
        } finally { paymentLock159.unlock() }
    }
    func canReturnCatalogShare159(): Bool {
        paymentLock159.lock()
        try { constructionReturned159 && constructionFrames159 == 0 &&
            catalogShares159 > 0 && !catalogAliases159 && !hasUnknownTemporary159() && payment.isSome() && canonicalFramesReturned186() && primitiveFramesReturned191() }
        finally { paymentLock159.unlock() }
    }
    func returnedCatalogShare159(): ?LogicalJsonOwnerReservation {
        paymentLock159.lock()
        try {
            if (catalogShares159 <= 0) { throw LogicalJsonPayloadError("catalog share underflow") }
            catalogShares159--
        } finally { paymentLock159.unlock() }
        retireLastCatalogShare159()
    }
    private func takeReturnedCatalogIdentity159(): ?LogicalJsonOwnerReservation {
        paymentLock159.lock()
        try {
            if (!constructionReturned159 || constructionFrames159 != 0 || catalogShares159 != 0 ||
                catalogAliases159 || hasUnknownTemporary159() || payment.isNone() || !canonicalFramesReturned186() || !primitiveFramesReturned191()) { return None<LogicalJsonOwnerReservation> }
            namespaceValue = ""; contentDigestValue = ""; versionValue = ""; rootValue = ""
            let actual = payment
            payment = None<LogicalJsonOwnerReservation>
            retainedInvoice159 = 0
            actual
        } finally { paymentLock159.unlock() }
    }
    private func retireLastCatalogShare159(): ?LogicalJsonOwnerReservation {
        let actual = takeReturnedCatalogIdentity159()
        match (actual) {
            case None => None<LogicalJsonOwnerReservation>
            case Some(value) =>
                returnCanonicalConfigurations186()
                returnPrimitiveConfigurations191()
                retireReturnedTemporaries159()
                retireUnpublishedTools159()
                hostRegistryCatalogIdentityDebt159.remove159(this)
                Some(value)
        }
    }
    public func reserveCatalogData159(bytes: Int64): Unit {
        paymentLock159.lock()
        try {
            let next = hostRegistryAdd81(retainedInvoice159, bytes)
            payment.getOrThrow().ensureRetainedPeak(next)
            retainedInvoice159 = next
        } finally { paymentLock159.unlock() }
    }
    public func reserveSnapshotCatalogData159(bytes: Int64): LogicalJsonOwnerReservation {
        paymentLock159.lock()
        try {
            if ((!catalogAliases159 && catalogShares159 == 0) || payment.isNone()) {
                throw LogicalJsonPayloadError("catalog snapshot requires its actual retained Registry data")
            }
            let child = payment.getOrThrow().deriveRetainedLease()
            try { child.ensureRetainedPeak(bytes) }
            catch (error: Exception) { child.close(); throw error }
            child
        } finally { paymentLock159.unlock() }
    }
    public func reserveTemporaryCatalogData159(bytes: Int64): ToolCatalogTemporaryData159 {
        paymentLock159.lock()
        try {
            if (constructionFrames159 != 1 || constructionReturned159 || payment.isNone()) {
                throw LogicalJsonPayloadError("catalog staging requires the actual construction borrow")
            }
            // This child pays its own carrier/link and array growth slots.
            // No cumulative parent metadata charge survives a returned phase.
            let child = payment.getOrThrow().deriveRetainedLease()
            try { child.ensureRetainedPeak(hostRegistryAdd81(bytes, 4096)) }
            catch (error: Exception) { child.close(); throw error }
            let phase = HostRegistryCatalogTemporary159(child, this)
            phase.next159 = temporary159
            temporary159 = Some(phase)
            phase
        } finally { paymentLock159.unlock() }
    }
    func reserveBacking159(bytes: Int64): HostRegistryCatalogBacking159 {
        paymentLock159.lock()
        try {
            if (constructionFrames159 != 1 || constructionReturned159 || payment.isNone()) {
                throw LogicalJsonPayloadError("catalog backing requires the actual construction borrow")
            }
            let child = payment.getOrThrow().deriveRetainedLease()
            try { child.ensureRetainedPeak(hostRegistryAdd81(bytes, 4096)) }
            catch (error: Exception) { child.close(); throw error }
            HostRegistryCatalogBacking159(child, producerReturned159)
        } finally { paymentLock159.unlock() }
    }
    private func takeReturnedTemporary159(): ?LogicalJsonOwnerReservation {
        paymentLock159.lock()
        try {
            if (!constructionReturned159 || constructionFrames159 != 0) {
                throw LogicalJsonPayloadError("catalog construction frame is still active")
            }
            var previous: ?HostRegistryCatalogTemporary159 = Option<HostRegistryCatalogTemporary159>.None
            var current = temporary159
            while (current.isSome()) {
                let phase = current.getOrThrow()
                match (phase.takeReturnedPayment159()) {
                    case Some(actual) =>
                        match (previous) {
                            case Some(value) => value.next159 = phase.next159
                            case None => temporary159 = phase.next159
                        }
                        phase.next159 = Option<HostRegistryCatalogTemporary159>.None
                        return Some(actual)
                    case None => ()
                }
                previous = current; current = phase.next159
            }
            Option<LogicalJsonOwnerReservation>.None
        } finally { paymentLock159.unlock() }
    }

    // Select only parents whose published raw aliases still require their
    // full payment. This collector never retires the parent/header, tools,
    // callbacks, descriptors or historical snapshots.
    func hasCollectibleRetainedTemporary159(): Bool {
        paymentLock159.lock()
        try {
            if ((!catalogAliases159 && catalogShares159 == 0) || !constructionReturned159 ||
                constructionFrames159 != 0 || payment.isNone()) { return false }
            var current = temporary159
            while (current.isSome()) {
                let phase = current.getOrThrow()
                if (phase.helperReturned159()) { return true }
                current = phase.next159
            }
            false
        } finally { paymentLock159.unlock() }
    }
    func collectRetainedTemporaries159(): Unit {
        // The intrusive registry selected a permanently retained parent.
        // Concurrent producers may only make additional phases ready; they
        // cannot retire this parent's raw-payload/header payment.
        if (hasCollectibleRetainedTemporary159()) { retireReturnedTemporaries159() }
    }

    private func retireReturnedTemporaries159(): Unit {
        while (true) {
            // Only the original reservation exits the removal helper. The
            // phase carrier, list link, staging list and ToolCatalog frame
            // have all ceased to reference the temporary container.
            match (takeReturnedTemporary159()) {
                case Some(value) => value.close()
                case None => return
            }
        }
    }
    func beginCatalogConstruction159(): Unit {
        paymentLock159.lock()
        try {
            if (constructionReturned159 || constructionFrames159 != 0 || payment.isNone()) {
                throw LogicalJsonPayloadError("catalog construction data has no unused borrow")
            }
            constructionFrames159 = 1
        } finally { paymentLock159.unlock() }
    }
    func retainCatalogAliases159(): Unit {
        paymentLock159.lock()
        try { catalogAliases159 = true } finally { paymentLock159.unlock() }
    }
    // Called only under paymentLock159, preserving lock order parent->phase.
    private func hasUnknownTemporary159(): Bool {
        var current = temporary159
        while (current.isSome()) {
            let phase = current.getOrThrow()
            if (!phase.helperReturned159()) { return true }
            current = phase.next159
        }
        false
    }
    private func clearReturnedConstruction159(): ?LogicalJsonOwnerReservation {
        paymentLock159.lock()
        try {
            if (constructionReturned159) { return None }
            if (constructionFrames159 != 1) {
                throw LogicalJsonPayloadError("catalog construction borrow did not return")
            }
            constructionFrames159 = 0
            constructionReturned159 = true
            if (catalogAliases159 || catalogShares159 != 0 || hasUnknownTemporary159() || !canonicalFramesReturned186() || !primitiveFramesReturned191()) { return None }
            // The helper that observed these private raw fields has returned.
            // No descriptor/callback was published, and no dynamic error can
            // reference these copies. Clear actual fields before releasing.
            namespaceValue = ""; contentDigestValue = ""; versionValue = ""; rootValue = ""
            let result = payment
            payment = None
            retainedInvoice159 = 0
            result
        } finally { paymentLock159.unlock() }
    }
    func returnedCatalogConstruction159(): Unit {
        // Called only after the actual Host construction helper returned.
        producerReturned159.returned159.store(true)
        let retired = clearReturnedConstruction159()
        retireReturnedTemporaries159()
        match (retired) {
            case None => ()
            case Some(value) =>
                returnCanonicalConfigurations186()
                returnPrimitiveConfigurations191()
                retireUnpublishedTools159()
                hostRegistryCatalogIdentityDebt159.remove159(this)
                value.close()
        }
        // A later constructor may already have replaced this producer's
        // backing while this original frame was active. Its retained owner
        // can now collect that exact old backing and staging phase.
        hostRegistryCatalogIdentityDebt159.collectReturnedTemporaries159()
    }
    func copy159(descriptor: PluginPackageDescriptor): Unit {
        namespaceValue = String.fromUtf8(descriptor.namespace.toArray())
        contentDigestValue = String.fromUtf8(descriptor.contentDigest.toArray())
        versionValue = String.fromUtf8(descriptor.version.toArray())
        rootValue = String.fromUtf8(descriptor.root.toArray())
    }
    func reserveTool159(tool: JavaScriptToolDescriptor, executorVersion: String): HostRegistryCatalogToolData159 {
        // Fixed registration/descriptor/executor/callback/candidate slots.
        // Text factors cover all simultaneous concatenations, trims, UTF8
        // copies, hashes and error-name references created by this mount.
        var invoice: Int64 = 65536
        invoice = hostRegistryCatalogTextInvoice159(invoice, namespaceValue)
        invoice = hostRegistryCatalogTextInvoice159(invoice, contentDigestValue)
        invoice = hostRegistryCatalogTextInvoice159(invoice, versionValue)
        invoice = hostRegistryCatalogTextInvoice159(invoice, rootValue)
        invoice = hostRegistryCatalogTextInvoice159(invoice, executorVersion)
        invoice = hostRegistryCatalogTextInvoice159(invoice, tool.name)
        invoice = hostRegistryCatalogTextInvoice159(invoice, tool.description)
        invoice = hostRegistryCatalogTextInvoice159(invoice, tool.inputAttachmentField)
        invoice = hostRegistryAdd81(invoice, hostRegistryCatalogSchemaInvoice159(tool.inputSchemaJson))
        paymentLock159.lock()
        try {
            if (constructionFrames159 != 1 || constructionReturned159 || payment.isNone()) {
                throw LogicalJsonPayloadError("catalog tool data requires the current private construction borrow")
            }
            // Parent owns the linked carrier metadata; the independent child
            // owns this declaration's schema/text/callback graph only.
            let metadata = hostRegistryAdd81(retainedInvoice159, 4096)
            payment.getOrThrow().ensureRetainedPeak(metadata)
            retainedInvoice159 = metadata
            let child = payment.getOrThrow().deriveRetainedLease()
            try { child.ensureRetainedPeak(invoice) }
            catch (error: Exception) { child.close(); throw error }
            let value = HostRegistryCatalogToolData159(tool, child)
            value.next159 = tools159
            tools159 = Some(value)
            value
        } finally { paymentLock159.unlock() }
    }
    private func takeUnpublishedTool159(): ?HostRegistryCatalogToolData159 {
        paymentLock159.lock()
        try {
            if (!constructionReturned159 || constructionFrames159 != 0 || catalogAliases159 || catalogShares159 != 0) {
                throw LogicalJsonPayloadError("catalog tool aliases have not retired")
            }
            let value = tools159
            match (value) {
                case Some(current) => tools159 = current.next159; current.next159 = None
                case None => ()
            }
            value
        } finally { paymentLock159.unlock() }
    }
    private func retireUnpublishedTools159(): Unit {
        while (true) {
            match (takeUnpublishedTool159()) {
                case None => return
                case Some(value) => value.retireReturnedTool159()
            }
        }
    }
    func reserveHook159(extensionId: String, event: String): Unit {
        var invoice: Int64 = 32768
        invoice = hostRegistryCatalogTextInvoice159(invoice, extensionId)
        invoice = hostRegistryCatalogTextInvoice159(invoice, event)
        invoice = hostRegistryCatalogTextInvoice159(invoice, namespaceValue)
        invoice = hostRegistryCatalogTextInvoice159(invoice, contentDigestValue)
        invoice = hostRegistryCatalogTextInvoice159(invoice, versionValue)
        invoice = hostRegistryCatalogTextInvoice159(invoice, rootValue)
        reserveCatalogData159(invoice)
    }
}
private func hostRegistryCatalogTextInvoice159(current: Int64, text: String): Int64 {
    var invoice = current
    for (_ in 0..text.size) { invoice = hostRegistryAdd81(invoice, 64) }
    invoice
}
private func hostRegistryCatalogSchemaInvoice159(text: String): Int64 {
    var invoice: Int64 = 8192
    var quoted = false; var escaped = false
    var depth: Int64 = 0
    // Measure the original immutable String without Array/DOM construction.
    // Each nesting level pays the overlapping recursive canonical framing;
    // structural/string occurrences pay JSON nodes, list snapshots/sorting,
    // scalar formatting and the caller's two independent digest operations.
    // This is a retained-memory upper invoice, never an exact encoded size.
    unsafe {
        let raw = text.rawData()
        for (index in 0..raw.size) {
            let byte = raw[index]
            for (_ in 0..(depth + 1)) { invoice = hostRegistryAdd81(invoice, 64) }
            if (quoted) {
                if (escaped) { escaped = false }
                else if (byte == b'\\') { escaped = true }
                else if (byte == b'"') { quoted = false }
            } else if (byte == b'"') {
                quoted = true
                for (_ in 0..(depth + 1)) { invoice = hostRegistryAdd81(invoice, 2048) }
            } else if (byte == b'{' || byte == b'[') {
                for (_ in 0..(depth + 1)) { invoice = hostRegistryAdd81(invoice, 2048) }
                depth++
            } else if (byte == b'}' || byte == b']') {
                if (depth > 0) { depth-- }
            } else if (byte == b':' || byte == b',') {
                for (_ in 0..(depth + 1)) { invoice = hostRegistryAdd81(invoice, 2048) }
            }
        }
    }
    // Original decoder alone validates malformed framing and its old limits.
    invoice
}
private class HostRegistryCatalogIdentityDebt159 {
    private let lock = Mutex()
    private var head: ?HostRegistryCatalogIdentity159 = None

    private let collectorLock159 = Mutex()
    private func selectCollectible159(): ?HostRegistryCatalogIdentity159 {
        lock.lock()
        try {
            var current = head
            while (current.isSome()) {
                let value = current.getOrThrow()
                if (value.hasCollectibleRetainedTemporary159()) { return Some(value) }
                current = value.nextRetained159
            }
            Option<HostRegistryCatalogIdentity159>.None
        } finally { lock.unlock() }
    }
    func collectReturnedTemporaries159(): Unit {
        // No snapshot/list/closure is allocated. The static collector mutex
        // serializes the scan; the debt-list mutex is released before the
        // selected parent's phase removal/close helper is entered.
        collectorLock159.lock()
        try {
            while (true) {
                match (selectCollectible159()) {
                    case Some(value) => value.collectRetainedTemporaries159()
                    case None => return
                }
            }
        } finally { collectorLock159.unlock() }
    }

    func remove159(value: HostRegistryCatalogIdentity159): Unit {
        lock.lock()
        try {
            var previous: ?HostRegistryCatalogIdentity159 = None
            var current = head
            while (current.isSome()) {
                let selected = current.getOrThrow()
                if (refEq(selected, value)) {
                    match (previous) {
                        case Some(prior) => prior.nextRetained159 = selected.nextRetained159
                        case None => head = selected.nextRetained159
                    }
                    selected.nextRetained159 = None
                    return
                }
                previous = current
                current = selected.nextRetained159
            }
        } finally { lock.unlock() }
    }
    func retain159(value: HostRegistryCatalogIdentity159): Unit {
        lock.lock(); try { value.nextRetained159 = head; head = Some(value) }
        finally { lock.unlock() }
    }
}

func hostRegistryCatalogIdentity159(owner: HostRegistryMountDescriptor159,
    descriptor: PluginPackageDescriptor): HostRegistryCatalogIdentity159 {
    var invoice: Int64 = 65536
    invoice = hostRegistryCatalogTextInvoice159(invoice, descriptor.namespace)
    invoice = hostRegistryCatalogTextInvoice159(invoice, descriptor.contentDigest)
    invoice = hostRegistryCatalogTextInvoice159(invoice, descriptor.version)
    invoice = hostRegistryCatalogTextInvoice159(invoice, descriptor.root)
    let payment = owner.derive159(invoice)
    let value = HostRegistryCatalogIdentity159(payment, invoice)
    hostRegistryCatalogIdentityDebt159.retain159(value)
    try { value.copy159(descriptor) }
    catch (error: Exception) { owner.retainLegacy159(); throw error }
    value
}

// Internal typed declaration reference captured by the actual executor policy
// closures. It keeps the entire ready declaration and schema allocation under
// its original child; no raw complete package descriptor is captured.
class HostRegistryCatalogToolData159 {
    private let lock159 = Mutex()
    private var declaration159: ?JavaScriptToolDescriptor
    private var payment159: ?LogicalJsonOwnerReservation
    var next159: ?HostRegistryCatalogToolData159 = None
    init(value: JavaScriptToolDescriptor, payment: LogicalJsonOwnerReservation) {
        declaration159 = Some(value); payment159 = Some(payment)
    }
    prop name: String { get() { lock159.lock(); try { declaration159.getOrThrow().name } finally { lock159.unlock() } } }
    prop description: String { get() { lock159.lock(); try { declaration159.getOrThrow().description } finally { lock159.unlock() } } }
    prop inputSchemaJson: String { get() { lock159.lock(); try { declaration159.getOrThrow().inputSchemaJson } finally { lock159.unlock() } } }
    prop executionProfile: PluginToolExecutionProfile { get() { lock159.lock(); try { declaration159.getOrThrow().executionProfile } finally { lock159.unlock() } } }
    private func clearReturnedTool159(): ?LogicalJsonOwnerReservation {
        lock159.lock()
        try {
            declaration159 = None
            let actual = payment159
            payment159 = None
            actual
        } finally { lock159.unlock() }
    }
    func retireReturnedTool159(): Unit {
        // Only the parent whose private construction helper returned may
        // reach this method. Published/historical aliases keep that parent.
        match (clearReturnedTool159()) {
            case Some(value) => value.close()
            case None => ()
        }
    }
}

// Private phase carrier: the ToolCatalog's marker alone never releases its
// child. Only the enclosing returned Host construction removes this carrier.
private class HostRegistryCatalogTemporary159 <: ToolCatalogTemporaryData159 {
    private let lock159 = Mutex()
    private var payment159: ?LogicalJsonOwnerReservation
    private var returned159 = false
    private var backingStarted159 = false
    private var backingPreparing159 = false
    private let producer159: HostRegistryCatalogIdentity159
    private var candidate159: ?HostRegistryCatalogBacking159 = Option<HostRegistryCatalogBacking159>.None
    private var prior159: ?ToolCatalogBackingData159 = Option<ToolCatalogBackingData159>.None
    var next159: ?HostRegistryCatalogTemporary159 = Option<HostRegistryCatalogTemporary159>.None
    init(payment: LogicalJsonOwnerReservation, producer: HostRegistryCatalogIdentity159) { payment159 = Some(payment); producer159 = producer }
    public func newBacking159(bytes: Int64): ToolCatalogBackingData159 {
        lock159.lock()
        try {
            if (returned159 || backingStarted159) {
                throw LogicalJsonPayloadError("catalog backing phase was already used")
            }
            backingStarted159 = true
            backingPreparing159 = true
        } finally { lock159.unlock() }
        // Never acquire producer.paymentLock while holding the phase mutex:
        // returned construction collection takes producer -> phase locks.
        // Failure deliberately leaves preparing true and the phase retained.
        let value = producer159.reserveBacking159(bytes)
        lock159.lock()
        try {
            candidate159 = Some(value)
            backingPreparing159 = false
            value
        } finally { lock159.unlock() }
    }
    public func prepareBackingPublication159(previous: ?ToolCatalogBackingData159): Unit {
        lock159.lock()
        try {
            if (returned159 || candidate159.isNone()) {
                throw LogicalJsonPayloadError("catalog backing publication is missing")
            }
            // Under the actual Catalog lock, DATA preparation precedes
            // its field-only commit. The returned helper is the later witness;
            // retain the exact prior payment until that full helper returns.
            prior159 = previous
            candidate159 = Option<HostRegistryCatalogBacking159>.None
        } finally { lock159.unlock() }
    }
    private func takeBackingPayment159(): ?LogicalJsonOwnerReservation {
        lock159.lock()
        try {
            if (!returned159 || backingPreparing159) { return Option<LogicalJsonOwnerReservation>.None }
            match (prior159) {
                case Some(value) => match (value as HostRegistryCatalogBacking159) {
                    case Some(actual) => match (actual.takeRetiredBackingPayment159()) {
                        case Some(payment) => prior159 = Option<ToolCatalogBackingData159>.None; return Some(payment)
                        case None => return Option<LogicalJsonOwnerReservation>.None
                    }
                    // An unrelated DATA implementation has no local proof.
                    case None => return Option<LogicalJsonOwnerReservation>.None
                }
                case None => ()
            }
            match (candidate159) {
                case Some(value) => match (value.takeRetiredBackingPayment159()) {
                    case Some(payment) => candidate159 = Option<HostRegistryCatalogBacking159>.None; Some(payment)
                    case None => Option<LogicalJsonOwnerReservation>.None
                }
                case None => Option<LogicalJsonOwnerReservation>.None
            }
        } finally { lock159.unlock() }
    }
    public func returnedTemporaryHelper159(): Unit {
        lock159.lock(); try { returned159 = true } finally { lock159.unlock() }
    }
    func helperReturned159(): Bool {
        lock159.lock()
        try {
            if (!returned159 || backingPreparing159) { return false }
            match (prior159) {
                case Some(value) => match (value as HostRegistryCatalogBacking159) {
                    case Some(actual) => if (!actual.canRetireBacking159()) { return false }
                    case None => return false
                }
                case None => ()
            }
            match (candidate159) {
                case Some(value) => if (!value.canRetireBacking159()) { return false }
                case None => ()
            }
            true
        } finally { lock159.unlock() }
    }
    func takeReturnedPayment159(): ?LogicalJsonOwnerReservation {
        // The removal helper returns only an original reservation, after
        // clearing the old carrier field. No old ArrayList/carrier escapes it.
        match (takeBackingPayment159()) { case Some(value) => value.close(); case None => () }
        lock159.lock()
        try {
            if (!returned159 || backingPreparing159 || candidate159.isSome() || prior159.isSome()) { return Option<LogicalJsonOwnerReservation>.None }
            let actual = payment159
            payment159 = Option<LogicalJsonOwnerReservation>.None
            actual
        } finally { lock159.unlock() }
    }
}

// Only the private ToolCatalog backing ArrayList is covered by this child.
// Descriptors/executors and public snapshots have distinct retained owners.
class HostRegistryCatalogProducer159 { let returned159 = AtomicBool(false) }
// Independently funded share. Catalog clears all of its actual containers and
// its link helper returns before calling this private producer-owned receipt.
class HostRegistryCatalogDataLease159 <: ToolCatalogDataLease159 {
    private let lock = Mutex()
    private var owner: ?HostRegistryCatalogIdentity159
    private var payment: ?LogicalJsonOwnerReservation
    init(owner: HostRegistryCatalogIdentity159, payment: LogicalJsonOwnerReservation) {
        this.owner = Some(owner); this.payment = Some(payment)
    }
    public func catalogProducerReturned159(): Bool {
        lock.lock()
        try { match (owner) { case Some(value) => value.canReturnCatalogShare159(); case None => false } }
        finally { lock.unlock() }
    }
    public func catalogReferencesReturned159(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        lock.lock()
        try {
            match (owner) {
                case None => (None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>)
                case Some(value) =>
                    let parent = value.returnedCatalogShare159()
                    owner = None<HostRegistryCatalogIdentity159>
                    let own = payment
                    payment = None<LogicalJsonOwnerReservation>
                    (parent, own)
            }
        } finally { lock.unlock() }
    }
}
class HostRegistryCatalogBacking159 <: ToolCatalogBackingData159 & ToolCatalogRetirableBacking159 {
    private let lock159 = Mutex()
    private var payment159: ?LogicalJsonOwnerReservation
    private var producerReturned159: ?HostRegistryCatalogProducer159
    private var unknown159 = false
    private var listed159 = false
    var next159: ?HostRegistryCatalogBacking159 = Option<HostRegistryCatalogBacking159>.None
    init(payment: LogicalJsonOwnerReservation, producerReturned: HostRegistryCatalogProducer159) {
        payment159 = Some(payment); producerReturned159 = Some(producerReturned)
    }
    public func growBacking159(bytes: Int64): Unit {
        lock159.lock()
        try { payment159.getOrThrow().ensureRetainedPeak(hostRegistryAdd81(bytes, 4096)) }
        finally { lock159.unlock() }
    }
    public func retainUnknownBacking159(): Unit {
        lock159.lock()
        try {
            unknown159 = true
            if (!listed159) {
                listed159 = true
                hostRegistryUnknownBackings159.retain159(this)
            }
        } finally { lock159.unlock() }
    }
    public func backingProducerReturned159(): Bool { canRetireBacking159() }
    public func backingReferencesReturned159(): ?LogicalJsonOwnerReservation {
        // ToolCatalog has cleared the actual private ArrayList and its whole
        // clearing helper returned. Producer return remains independently required.
        takeRetiredBackingPayment159()
    }
    func canRetireBacking159(): Bool {
        lock159.lock()
        try { !unknown159 && payment159.isSome() && match (producerReturned159) {
            case Some(value) => value.returned159.load(); case None => false
        } }
        finally { lock159.unlock() }
    }
    func takeRetiredBackingPayment159(): ?LogicalJsonOwnerReservation {
        lock159.lock()
        try {
            // The old producer may still have the committed array on its
            // construction stack even after a concurrent later replacement.
            if (unknown159 || producerReturned159.isNone() || !producerReturned159.getOrThrow().returned159.load()) {
                return Option<LogicalJsonOwnerReservation>.None
            }
            // Drop the producer carrier before returning the backing's
            // reservation. The caller closes it after this helper returns.
            producerReturned159 = None<HostRegistryCatalogProducer159>
            let actual = payment159
            payment159 = Option<LogicalJsonOwnerReservation>.None
            actual
        } finally { lock159.unlock() }
    }
}
private class HostRegistryUnknownBackingDebt159 {
    private let lock159 = Mutex()
    private var first159: ?HostRegistryCatalogBacking159 = Option<HostRegistryCatalogBacking159>.None
    func retain159(value: HostRegistryCatalogBacking159): Unit {
        lock159.lock()
        try { value.next159 = first159; first159 = Some(value) }
        finally { lock159.unlock() }
    }
}
