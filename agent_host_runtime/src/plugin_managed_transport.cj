package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import tool_runtime.*

// Host-private composition interfaces, never implemented/selected from plugin
// JSON. They do not admit an Operation, issue an approval or mint a source.
// The one ProductPluginManagedService remains the catalog/publication owner.
enum HostManagedServicePhase { Start | Call | Refresh }

interface HostManagedServiceResource {
    func endpointGrant(): HostNativeServiceEndpointGrant
    // Stable launch domain: namespace/mount/target/permission-domain/service.
    // Used only for resource inventory quotas, never as execution authority.
    func launchKey(): String
    // Fresh actual retained resource identity. Channel uses its actual lease;
    // HTTP uses its own endpoint-lifetime resource, never a fictitious lease.
    func resourceIdentity(): String
    // Host-frozen metadata before publication fields are appended by the one
    // catalog owner. Each transport validates its complete typed wire shape.
    func bindingMetadata(endpoint: HostPinnedNativeServiceEndpoint): Result<AgentValue>
    func requiredCapabilities(): Array<Capability>
    func networkPolicy(): Result<NetworkPolicy>
    func isActive(): Bool
    func validateActive(context: ToolInvocationContext): Result<Unit>
    // HTTP and future transports remain Thread-local unless they explicitly
    // implement the sealed Task execution route.
    func validateInvocation(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        binding: AgentValue): Result<Unit> { validateActive(context) }
    func observeRevocation(callback: () -> Unit): CancellationRegistration
    func revoke(): Result<Unit>
    func cancellation(): CancellationToken
    func maintenancePlan(context: ToolInvocationContext, prepared: PreparedToolInvocation, action: HostServiceAction): Result<AgentValue>
    func resourcesReleased(): Bool
    // Failed startup can retain native/exchange cleanup without returning a
    // lease. Inventory quota is held until its real resource ACK is available.
    func retainsStartup(): Bool
    // Current publication witnesses are supplied only by the shared catalog
    // owner. The resource keeps transport-specific finite refresh authority.
    func refreshPlan(endpoint: HostPinnedNativeServiceEndpoint,
        revision: Int64, directoryDigest: String): Result<AgentValue>
    func validateRefresh(plan: AgentValue, endpoint: HostPinnedNativeServiceEndpoint,
        revision: Int64, directoryDigest: String): Result<Unit>
    func refreshResult(plan: AgentValue, directory: AgentValue): Result<AgentValue>
    func commitRefresh(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        plan: AgentValue, output: AgentValue): Result<AgentValue>
}

interface HostManagedServiceInvocation <: JavaScriptHostObserver {
    // A facade may only find this object through its actual single-level root
    // source. Plugin supplied IDs, returned headers and DTOs cannot select it.
    func owns(child: PreparedToolInvocation): Bool
    func executeChild(childContext: ToolInvocationContext,
        child: PreparedToolInvocation): Result<ToolResult>
    // Must reconcile actual child outcomes and close ACKs. A plugin terminal
    // cannot turn a failed/Unknown/unsettled exchange into a successful effect.
    func finish(response: Result<HostJavaScriptPluginInvocationResult>): Result<ToolResult>
    // Revokes the observer immediately, then acknowledges only real cleanup.
    // Err retains this object in the shared service until a later close retries.
    func close(): Result<Unit>
}

interface HostManagedServiceTransport {
    func requestedCapability(): String
    // All configuration is host-frozen nonsecret data. No capability, URL,
    // credential value or resource identity is inferred from plugin metadata.
    func preparationArguments(phase: HostManagedServicePhase, localName: String,
        input: AgentValue): AgentValue
    func freezeIntents(context: ToolInvocationContext, call: ToolCall, input: AgentValue,
        purePreparation: AgentValue, binding: AgentValue): Result<AgentValue>
    func validateParent(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, binding: AgentValue): Result<Unit>
    func beginInvocation(service: HostPluginManagedService,
        endpoint: HostPinnedNativeServiceEndpoint,
        rootContext: ToolInvocationContext, rootPrepared: PreparedToolInvocation,
        binding: AgentValue): Result<HostManagedServiceInvocation>
    // Startup/Refresh require a current sealed HostService source with its own
    // bounded prepared plan. A historical startup record grants no later I/O.
    func beginMaintenance(service: HostPluginManagedService,
        endpoint: HostPinnedNativeServiceEndpoint,
        context: ToolInvocationContext, prepared: PreparedToolInvocation,
        action: HostServiceAction): Result<HostManagedServiceInvocation>
}
