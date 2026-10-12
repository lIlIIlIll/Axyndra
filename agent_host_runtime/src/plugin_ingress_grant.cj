package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import yjson.*
import yjson_support.*

// Explicit operator file, loaded only by the local stdio composition root.
// A peer cannot choose a principal, package, export list or target Thread.
func hostIngressReadConfiguration(settingsRoot: String): HostPluginLifecycleConfigurationFile {
    let root = canonicalize(Path(settingsRoot))
    var path = root
    for (component in ["plugins", "ingress.json"]) {
        path = path.join(component)
        hostLifecycleRequire(exists(path) && !FileInfo(path).isSymbolicLink(), "plugin.ingress_not_configured")
    }
    let resolved = canonicalize(path).toString()
    hostLifecycleRequire(hostLifecycleWithin(root.toString(), resolved) && FileInfo(path).isRegular())
    hostLifecycleRequire(FileInfo(path).size <= 65536, "plugin.ingress_configuration_limit")
    let file = File(path, OpenMode.Read)
    try {
        let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
        while (true) {
            let count = file.read(buffer); if (count == 0) { break }
            hostLifecycleRequire(count <= 65536 - bytes.size, "plugin.ingress_configuration_limit")
            for (index in 0..count) { bytes.add(buffer[index]) }
        }
        HostPluginLifecycleConfigurationFile(resolved, String.fromUtf8(bytes.toArray()))
    } finally { file.close() }
}

class HostStdioIngressGrant <: HostNativeServiceEndpointGrant {
    let targetThread: ThreadId
    let maintenanceThread: ThreadId
    let namespace: String
    let route: String
    let expectedGeneration: UInt64
    let instanceIdentity: String
    let digest: String
    private let mountDecoder: ExternalDecoderIdentity
    private let selectionLock = Mutex()
    private var selectedBinding: ?ExternalIngressBinding = None
    prop decoder: ExternalDecoderIdentity { get() {
        selectionLock.lock()
        try { match (selectedBinding) { case Some(value) => value.decoder.getOrThrow(); case None => mountDecoder } }
        finally { selectionLock.unlock() }
    } }
    let binding: ExternalIngressBinding
    let context: ToolInvocationContext
    let catalogue: String
    let protocolLimits: ServiceProtocolLimits
    let payloadLimits: ?ServicePayloadLimits
    prop resultUploadBytes: Int64 { get() { match (payloadLimits) {
        case Some(limits) => limits.maxInputBytes
        case None => 65536
    } } }
    prop responseBytes: Int64 { get() { match (payloadLimits) {
        case Some(limits) => (limits.maxPrepareBytes - 4096) / 2
        case None => 24576
    } } }
    prop uploadChunkBytes: Int64 { get() { match (payloadLimits) {
        case Some(limits) => min(131072, (limits.maxInputBytes - 1024) / 2)
        case None => 4096
    } } }
    prop outputQueueBytes: Int64 { get() { if (payloadLimits.isSome()) { 16777216 } else { 131072 } } }
    private let file: HostPluginLifecycleConfigurationFile
    private let settingsRoot: String
    private let host: HostJavaScriptPluginHost
    private let catalog: ToolCatalog
    private let exportNames: Array<String>
    private let ancestry: Array<String>
    private let endpointText: String
    private let live = AtomicBool(true)

    init(settingsRoot: String, workspaceRoot: String, grantId: String, host: HostJavaScriptPluginHost,
        catalog: ToolCatalog, hostAncestry: Array<String>, contextForRoot: (String) -> ToolContextDescriptor) {
        file = hostIngressReadConfiguration(settingsRoot); this.settingsRoot = settingsRoot
        this.host = host; this.catalog = catalog; ancestry = hostAncestry.clone()
        let document = parseUnifiedJson(file.text, maxBytes: 65536)
        hostLifecycleExact(document, ["schema", "grants"])
        hostLifecycleRequire(hostLifecycleText(document, "schema") == "axyndra.stdio-ingress-grants/v1")
        let grants = document.field("grants").getOrThrow()
        hostLifecycleRequire(grants.unifiedKind == ValueKind.List && grants.items.size <= 32)
        var selected: ?AgentValue = None
        let ids = HashSet<String>()
        for (item in grants.items) {
            let expected = ArrayList<String>(["id", "namespace", "package_digest", "service", "principal", "thread_id", "exports", "capabilities", "lifetime_ms"])
            if (item.field("protocol_limits").isSome()) { expected.add("protocol_limits") }
            if (item.field("payload_limits").isSome()) { expected.add("payload_limits") }
            hostLifecycleExact(item, expected.toArray())
            hostLifecycleRequire(serviceProtocolLimits(item).isOk() && servicePayloadLimits(item).isOk(), "plugin.ingress_limits_invalid")
            // Only an explicit operator profile enables larger parser buffers.
            match (servicePayloadLimits(item).value().getOrThrow()) {
                case Some(limits) => hostLifecycleRequire(limits.maxInputBytes >= 16384 && limits.maxPrepareBytes >= 65536,
                    "plugin.ingress_limits_invalid")
                case None => hostLifecycleRequire(item.field("protocol_limits").isNone(), "plugin.ingress_limits_incomplete")
            }
            let id = hostLifecycleText(item, "id"); hostLifecycleRequire(hostLifecycleIdentifier(id, 128) && !ids.contains(id)); ids.add(id)
            if (id == grantId) { selected = Some(item) }
        }
        hostLifecycleRequire(selected.isSome(), "plugin.ingress_grant_missing")
        let selectedGrant = selected.getOrThrow()
        protocolLimits = serviceProtocolLimits(selectedGrant).value().getOrThrow()
        payloadLimits = servicePayloadLimits(selectedGrant).value().getOrThrow()
        namespace = hostLifecycleText(selectedGrant, "namespace"); route = hostLifecycleText(selectedGrant, "service")
        hostLifecycleRequire(!ancestry.contains(namespace) && ancestry.size < 8, "plugin.ingress_cycle")
        targetThread = ThreadId(hostLifecycleText(selectedGrant, "thread_id"))
        expectedGeneration = host.instanceGeneration(namespace)
        let descriptor = host.servicePackageData81(namespace, expectedGeneration).value().getOrThrow()
        hostLifecycleRequire(descriptor.contentDigest == hostLifecycleText(selectedGrant, "package_digest") &&
            descriptor.entryKind == PluginEntryKind.NativeExecutable, "plugin.ingress_package_mismatch")
        // The decoder has no ambient broker authority, including process.channel.
        hostLifecycleRequire(descriptor.requestedCapabilities.isEmpty(), "plugin.ingress_decoder_not_powerless")
        instanceIdentity = host.serviceInstanceIdentity(namespace, expectedGeneration).value().getOrThrow()
        let nonce = hostNewPluginInstanceIdentity().value().getOrThrow()
        maintenanceThread = ThreadId("ingress-maintenance-" + nonce)
        hostLifecycleRequire(maintenanceThread.value != targetThread.value)
        let capValues = selectedGrant.field("capabilities").getOrThrow()
        hostLifecycleRequire(capValues.unifiedKind == ValueKind.List && capValues.items.size <= 7)
        let capabilities = ArrayList<Capability>(); let capNames = HashSet<String>()
        for (item in capValues.items) {
            hostLifecycleRequire(item.unifiedKind == ValueKind.Text && !capNames.contains(item.text)); capNames.add(item.text)
            let kind = match (item.text) {
                case "workspace.read" => CapabilityKind.WorkspaceRead; case "workspace.write" => CapabilityKind.WorkspaceWrite
                case "process.spawn" => CapabilityKind.ProcessSpawn; case "network.access" => CapabilityKind.NetworkAccess
                case "extension.invoke" => CapabilityKind.ExtensionInvoke; case "peer.message" => CapabilityKind.PeerMessage
                case "delegate" => CapabilityKind.Delegate; case _ => throw IllegalArgumentException("unknown ingress capability")
            }
            capabilities.add(Capability(kind))
        }
        let lifetime = hostLifecycleInt(selectedGrant, "lifetime_ms", 3600000)
        hostLifecycleRequire(lifetime > 0 && lifetime <= 3600000)
        let deadline = agentUtcMillis() + lifetime
        context = ToolInvocationContext(RunId("ingress-binding-probe"), SessionId(targetThread.value),
            CapabilitySet(values: capabilities.toArray()), toolContext: contextForRoot(workspaceRoot),
            budget: ExecutionBudget(maxConcurrentTools: 1, deadlineMillis: deadline))
        let names = selectedGrant.field("exports").getOrThrow()
        hostLifecycleRequire(names.unifiedKind == ValueKind.List && names.items.size <= 256)
        let namesSeen = HashSet<String>(); let exports = ArrayList<String>()
        for (item in names.items) {
            hostLifecycleRequire(item.unifiedKind == ValueKind.Text && item.text != "" && !namesSeen.contains(item.text))
            // Host ancestry identifies actual plugin namespaces, not client metadata.
            for (ancestor in hostIngressAncestry(ancestry, namespace)) {
                hostLifecycleRequire(!item.text.startsWith("plugin." + ancestor + ".") && item.text != ancestor, "plugin.ingress_cycle")
            }
            exports.add(item.text); namesSeen.add(item.text)
        }
        exportNames = exports.toArray()
        let snapshot = catalog.toolSetSnapshot("ingress-" + nonce, context.capabilities, threadId: Some(targetThread))
        let identities = ArrayList<ExternalExportBinding>(); let definitions = ArrayList<AgentValue>()
        for (name in exportNames) {
            var found = false
            for (entry in snapshot.entries where entry.name == name && entry.availableAtSnapshot) {
                identities.add(ExternalExportBinding(entry.name, entry.executorVersion, entry.implementationFingerprint, entry.schemaDigest))
                definitions.add(objectValue([ValueField("name", textValue(entry.name)), ValueField("description", textValue(entry.description)),
                    ValueField("input_schema", entry.inputSchema)])); found = true
            }
            hostLifecycleRequire(found, "plugin.ingress_export_unavailable")
        }
        catalogue = stringifyUnifiedJson(listValue(definitions.toArray()))
        hostLifecycleRequire(catalogue.size <= 65536, "plugin.ingress_catalogue_limit")
        mountDecoder = ExternalDecoderIdentity(namespace, descriptor.contentDigest, modelPolicySha256Text(file.text), instanceIdentity, route)
        digest = modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("operator_grant", selectedGrant),
            ValueField("decoder", externalDecoderIdentityValue(mountDecoder)), ValueField("connection", textValue(nonce)),
            ValueField("permission_domain", textValue(externalInvocationAuthorityScope(context)))])))
        binding = ExternalIngressBinding("ingress-" + digest, "stdio-" + nonce, hostLifecycleText(selectedGrant, "principal"), 1,
            targetThread, externalInvocationAuthorityScope(context), identities.toArray(), capabilities.toArray(), deadline,
            hostIngressAncestry(ancestry, namespace), decoder: Some(mountDecoder))
        let endpointFields = ArrayList<ValueField>([ValueField("namespace", textValue(namespace)),
            ValueField("package_digest", textValue(descriptor.contentDigest)), ValueField("workspace_root", textValue(workspaceRoot)),
            ValueField("permission_domain", textValue(hostPluginInvocationAuthorityScope(context))), ValueField("lifetime_ms", integerValue(lifetime))])
        match (payloadLimits) {
            case Some(limits) => endpointFields.add(ValueField("protocol_limits", protocolLimits.toValue()))
                endpointFields.add(ValueField("payload_limits", limits.toValue()))
            case None => ()
        }
        endpointText = stringifyUnifiedJson(objectValue(endpointFields.toArray()))
    }
    public func endpointTargetThread(): ThreadId { targetThread }
    public func endpointInstanceIdentity(): String { instanceIdentity }
    public func endpointGrantDigest(): String { digest }
    public func endpointBinding(): AgentValue { parseUnifiedJson(endpointText, maxBytes: 16384) }
    func revoke(): Unit { live.store(false) }
    public func stillCurrent(): Result<Unit> {
        if (!live.load() || agentUtcMillis() >= binding.expiresAtMillis) { return hostLifecycleError("plugin.ingress_revoked", "ingress grant expired or closed") }
        try {
            let current = hostIngressReadConfiguration(settingsRoot)
            hostLifecycleRequire(current.path == file.path && modelPolicySha256Text(current.text) == decoder.configurationDigest)
            hostLifecycleRequire(host.serviceInstanceIdentity(namespace, expectedGeneration).value().getOrThrow() == instanceIdentity)
            let descriptor = host.servicePackageData81(namespace, expectedGeneration).value().getOrThrow()
            match (host.registryPackageMatches81(descriptor.root, digest: Some(decoder.packageDigest))) {
                case Result.Ok(value) => hostLifecycleRequire(value)
                case Result.Err(_) => throw IllegalArgumentException("decoder package changed")
            }
            Result.Ok(())
        } catch (_: Exception) { live.store(false); hostLifecycleError("plugin.ingress_changed", "operator grant, decoder instance or fixed export snapshot changed") }
    }
    // Effect admission still requires every original fixed export identity.
    // Losing an export revokes the External connection; it does not destroy
    // the independent, powerless decoder before owned terminal bytes settle.
    func fixedExportsCurrent(): Result<Unit> {
        try {
            let snapshot = catalog.toolSetSnapshot("ingress-revalidate", context.capabilities, threadId: Some(targetThread))
            for (name in exportNames) {
                let expected = binding.exported(name).getOrThrow(); var found = false
                for (entry in snapshot.entries where entry.name == name && entry.availableAtSnapshot) {
                    found = entry.executorVersion == expected.version && entry.implementationFingerprint == expected.fingerprint && entry.schemaDigest == expected.schemaDigest
                }
                hostLifecycleRequire(found, "plugin.ingress_export_changed")
            }
            Result.Ok(())
        } catch (_: Exception) {
            hostLifecycleError("plugin.ingress_changed", "fixed export snapshot changed")
        }
    }
    func bindDecoderEndpoint(endpoint: HostPinnedNativeServiceEndpoint): Result<Unit> {
        match (stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!endpoint.available() || endpoint.namespace != namespace || endpoint.targetThread.value != targetThread.value ||
            endpoint.maintenanceThread.value != maintenanceThread.value || endpoint.route != route ||
            endpoint.generation.instanceIdentity != instanceIdentity || endpoint.generation.instanceGeneration != expectedGeneration) {
            return hostLifecycleError("plugin.ingress_endpoint_mismatch", "actual fixed decoder endpoint does not match its operator grant")
        }
        selectionLock.lock()
        try {
            if (selectedBinding.isSome()) { return hostLifecycleError("plugin.ingress_endpoint_rebound", "ingress cannot replace its fixed decoder worker") }
            let exact = ExternalDecoderIdentity(namespace, mountDecoder.packageDigest, mountDecoder.configurationDigest,
                endpoint.endpointIdentity, route)
            selectedBinding = Some(ExternalIngressBinding(binding.grantId, binding.connectionId, binding.principalId,
                binding.generation, binding.threadId, binding.permissionDomain,
                exportNames.map({ name => binding.exported(name).getOrThrow() }), binding.ceiling.values,
                binding.expiresAtMillis, hostIngressAncestry(ancestry, namespace), decoder: Some(exact)))
            Result.Ok(())
        } finally { selectionLock.unlock() }
    }
    public func currentBinding(): Result<ExternalIngressBinding> {
        match (stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (fixedExportsCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        selectionLock.lock()
        try { match (selectedBinding) {
            case Some(value) => Result.Ok(value)
            case None => hostLifecycleError("plugin.ingress_endpoint_required", "connection requires an actual fixed decoder worker")
        } } finally { selectionLock.unlock() }
    }
}

func hostIngressAncestry(parent: Array<String>, namespace: String): Array<String> {
    let values = ArrayList<String>(parent); values.add(namespace); values.toArray()
}
class HostIngressAuthorizer <: ExternalIngressAuthorizer {
    private let grant: HostStdioIngressGrant
    init(grant: HostStdioIngressGrant) { this.grant = grant }
    public func currentBinding(): Result<ExternalIngressBinding> { grant.currentBinding() }
}
