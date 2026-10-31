package agent_host_runtime

import agent_domain.*
import agent_plugin_registry.PluginRegistryExecutionFence
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.time.*
import yjson.*
import yjson_support.*

public let HOST_PLUGIN_HTTP_LIFECYCLE_TOOL = "host.plugin.http.lifecycle"
let HOST_PLUGIN_HTTP_LIFECYCLE_IMPLEMENTATION = "host-plugin-http-lifecycle-v1"
public let HOST_PLUGIN_HTTP_REFRESH_TOOL = "host.plugin.http.lifecycle.refresh"
let HOST_PLUGIN_HTTP_REFRESH_IMPLEMENTATION = "host-plugin-http-lifecycle-refresh-v1"

// Fixed-endpoint authorization only, never a process launch lease. Concrete
// HTTP effects still require a current actual HostService window or an exact
// approved derived intent. No worker exists while this value is constructed.
class HostHttpServiceGrant <: HostNativeServiceEndpointGrant {
    let configuration: HostPluginHttpConfiguration
    let namespace: String
    let serviceId: String
    let route: String
    let expectedGeneration: UInt64
    let instanceIdentity: String
    let targetThread: ThreadId
    let digest: String
    private let host: HostJavaScriptPluginHost
    private let planText: String
    private let configurationText: String
    private let expires: MonoTime
    prop launchPlan: AgentValue { get() { parseUnifiedJson(planText, maxBytes: 131072) } }
    prop nonsecretConfiguration: AgentValue { get() { parseUnifiedJson(configurationText, maxBytes: 16384) } }

    init(host: HostJavaScriptPluginHost, configuration: HostPluginHttpConfiguration,
        context: ToolInvocationContext, serviceId: String, route: String, expectedGeneration: UInt64) {
        this.host = host; this.configuration = configuration; namespace = configuration.namespace
        this.serviceId = serviceId; this.route = route; this.expectedGeneration = expectedGeneration
        hostLifecycleRequire(hostLifecycleIdentifier(serviceId, 128) && hostLifecycleIdentifier(route, 128) && serviceId == route &&
            context.sessionId.value != "" && !context.cancellation.isCancelled(), "plugin.http_service_binding_invalid")
        targetThread = ThreadId(context.sessionId.value)
        instanceIdentity = host.serviceInstanceIdentity(namespace, expectedGeneration).value().getOrThrow()
        let descriptor = host.servicePackageData81(namespace, expectedGeneration).value().getOrThrow()
        hostLifecycleRequire(descriptor.entryKind == PluginEntryKind.NativeExecutable && descriptor.contentDigest == configuration.packageDigest &&
            descriptor.requestedCapabilities.contains("network.http"), "plugin.http_service_package_invalid")
        let requests = configuration.streamMaintenanceGrants().value().getOrThrow()
        hostLifecycleRequire(!requests.items.isEmpty(), "plugin.http_service_requests_missing")
        let rules = ArrayList<NetworkEgressRule>()
        for (entry in requests.items) {
            let network = parseNetworkPolicy(entry.field("network").getOrThrow()).value().getOrThrow()
            for (rule in network.egress) { rules.add(rule) }
        }
        let network = NetworkPolicy(NetworkPolicyMode.Mediated, egress: rules.toArray())
        configurationText = stringifyUnifiedJson(configuration.configuration)
        hostLifecycleRequire(configurationText.size <= 16384 && context.workspaceRoot == hostLifecycleDirectory(context.workspaceRoot),
            "plugin.http_service_configuration_invalid")
        // Operator request grants plus these explicit finite host ceilings are
        // visible in the canonical approval. They do not imply User approval.
        let inputWindow = match (configuration.payloadLimits) { case Some(value) => value.maxPrepareBytes; case None => 262144 }
        let outputWindow = match (configuration.payloadLimits) { case Some(value) => value.maxResultBytes; case None => 1048576 }
        let window = objectValue([ValueField("timeout_ms", integerValue(60000)),
            ValueField("max_requests", integerValue(32)), ValueField("max_input_bytes", integerValue(inputWindow)),
            ValueField("max_output_bytes", integerValue(outputWindow)), ValueField("requests", requests)])
        let plan = objectValue([ValueField("schema", textValue("axyndra.http-service-launch/v1")),
            ValueField("namespace", textValue(namespace)), ValueField("package_digest", textValue(configuration.packageDigest)),
            ValueField("configuration_digest", textValue(configuration.digest)), ValueField("service_id", textValue(serviceId)),
            ValueField("thread_id", textValue(targetThread.value)), ValueField("instance_identity", textValue(instanceIdentity)),
            ValueField("permission_domain", textValue(hostPluginInvocationAuthorityScope(context))),
            ValueField("workspace_root", textValue(context.workspaceRoot)), ValueField("network", networkPolicyCanonicalValue(network)),
            ValueField("lifetime_ms", integerValue(3600000)), ValueField("max_instances", integerValue(8)),
            ValueField("startup", window), ValueField("refresh", window)])
        if (configuration.protocolLimits.isExplicit) { plan.put("protocol_limits", configuration.protocolLimits.toValue()) }
        match (configuration.payloadLimits) { case Some(value) => plan.put("payload_limits", value.toValue()); case None => () }
        if (!configuration.readOnlyTools.isEmpty()) {
            plan.put("read_only_tools", listValue(configuration.readOnlyTools.map { name => textValue(name) }))
        }
        planText = stringifyUnifiedJson(plan); hostLifecycleRequire(planText.size <= 131072)
        digest = modelPolicySha256Text(canonicalAgentValue(plan))
        expires = MonoTime.now() + Duration.millisecond * 3600000
    }
    public func endpointTargetThread(): ThreadId { targetThread }
    public func endpointInstanceIdentity(): String { instanceIdentity }
    public func endpointGrantDigest(): String { digest }
    public func endpointBinding(): AgentValue { launchPlan }
    func enterRegistryEffect(): Result<PluginRegistryExecutionFence> {
        host.enterRegistryEffect(namespace, expectedGeneration)
    }
    private func currentDescriptor(): Result<PluginPackageDescriptor> {
        if (MonoTime.now() >= expires) { return hostLifecycleLeaseError("plugin.http_service_expired") }
        match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            hostLifecycleRequire(host.serviceInstanceIdentity(namespace, expectedGeneration).value().getOrThrow() == instanceIdentity)
            let descriptor = host.servicePackageData81(namespace, expectedGeneration).value().getOrThrow()
            hostLifecycleRequire(descriptor.contentDigest == configuration.packageDigest && descriptor.entryKind == PluginEntryKind.NativeExecutable &&
                descriptor.requestedCapabilities.contains("network.http"))
            Result.Ok(descriptor)
        } catch (_: Exception) { hostLifecycleLeaseError("plugin.http_service_grant_stale") }
    }
    // Inventory and cancellation observe the admitted resource's actual
    // lifetime. They neither admit another effect nor rehash package bodies.
    func lifetimeCurrent(): Result<Unit> {
        match (currentDescriptor()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => Result.Ok(())
        }
    }
    public func stillCurrent(): Result<Unit> {
        let descriptor = match (currentDescriptor()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        try {
            match (host.registryPackageMatches81(descriptor.root, digest: Some(configuration.packageDigest), namespace: Some(namespace))) {
                case Result.Ok(value) => hostLifecycleRequire(value)
                case Result.Err(_) => throw IllegalArgumentException("HTTP service package changed")
            }
            Result.Ok(())
        } catch (_: Exception) { hostLifecycleLeaseError("plugin.http_service_grant_stale") }
    }
    func requiredCapabilities(): Array<Capability> {
        let values = ArrayList<Capability>([Capability(CapabilityKind.ExtensionInvoke)])
        let policy = parseNetworkPolicy(launchPlan.field("network").getOrThrow()).value().getOrThrow()
        for (rule in policy.egress) { values.add(Capability(CapabilityKind.NetworkAccess, resource: networkEgressResource(rule))) }
        values.toArray()
    }
}
