package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// No backend process is opened or retained here. This owns the actual fixed
// native endpoint's HTTP lifetime, while each stream invocation retains its
// own admitted exchange/cleanup. Shared manager inventory holds both until ACK.
class HostManagedHttpResource <: HostManagedServiceResource {
    let grant: HostHttpServiceGrant
    let resourceId: String
    private let store: DurableOperationStore
    private let lock = Mutex()
    private let lifetime = CancellationSource()
    private var closing = false
    private var active = false
    private var startupExecuting = false
    private var startupContext: ?ToolInvocationContext = None
    private var startupPrepared: ?PreparedToolInvocation = None
    private var endpointIdentity = ""
    private var startupOutput = ""
    init(grant: HostHttpServiceGrant, store: DurableOperationStore) {
        this.grant = grant; this.store = store
        resourceId = "http-resource-" + hostNewPluginInstanceIdentity().value().getOrThrow()
    }
    prop startupArguments: AgentValue { get() { objectValue([ValueField("grant", grant.launchPlan), ValueField("resource_id", textValue(resourceId))]) } }
    public func endpointGrant(): HostNativeServiceEndpointGrant { grant }
    public func launchKey(): String { hostManagedServiceLaunchKey(grant) }
    public func resourceIdentity(): String { resourceId }
    public func requiredCapabilities(): Array<Capability> { grant.requiredCapabilities() }
    public func networkPolicy(): Result<NetworkPolicy> { parseNetworkPolicy(grant.launchPlan.field("network").getOrThrow()) }
    public func cancellation(): CancellationToken { lifetime.token }
    public func observeRevocation(callback: () -> Unit): CancellationRegistration { lifetime.token.onCancel({ _ => callback() }) }
    public func resourcesReleased(): Bool { lock.lock(); try { closing && !startupExecuting } finally { lock.unlock() } }
    public func retainsStartup(): Bool { lock.lock(); try { startupExecuting } finally { lock.unlock() } }
    public func revoke(): Result<Unit> {
        lock.lock(); try { closing = true; active = false } finally { lock.unlock() }
        let _ = lifetime.cancel()
        if (resourcesReleased()) { Result.Ok(()) } else { hostLifecycleLeaseError("plugin.http_service_cleanup_pending") }
    }
    private func activeSnapshot(): Bool {
        lock.lock(); try { active && !closing } finally { lock.unlock() }
    }
    public func isActive(): Bool {
        if (!activeSnapshot()) { return false }
        if (grant.lifetimeCurrent().isError()) { let _ = revoke(); return false }
        true
    }
    public func validateActive(context: ToolInvocationContext): Result<Unit> {
        if (!activeSnapshot()) { return hostLifecycleLeaseError("plugin.http_service_scope_stale") }
        // Every invocation still checks the complete current package. Nested
        // binding/inventory observations above are not execution authority.
        if (grant.stillCurrent().isError()) {
            let _ = revoke(); return hostLifecycleLeaseError("plugin.http_service_scope_stale")
        }
        if (hostManagedChannelCallerCancelled(context) || context.sessionId.value != grant.targetThread.value ||
            context.workspaceRoot != hostLifecycleText(grant.launchPlan, "workspace_root") ||
            hostPluginInvocationAuthorityScope(context) != hostLifecycleText(grant.launchPlan, "permission_domain")) {
            return hostLifecycleLeaseError("plugin.http_service_scope_stale")
        }
        Result.Ok(())
    }
    public func bindingMetadata(endpoint: HostPinnedNativeServiceEndpoint): Result<AgentValue> {
        if (!isActive()) { return hostLifecycleLeaseError("plugin.http_service_scope_stale") }
        lock.lock()
        let operation = try {
            if (endpoint.endpointIdentity != endpointIdentity || startupPrepared.isNone()) { return hostLifecycleLeaseError("plugin.http_service_endpoint_mismatch") }
            startupPrepared.getOrThrow().operationId
        } finally { lock.unlock() }
        let plan = grant.launchPlan
        Result.Ok(objectValue([ValueField("plugin", textValue(grant.namespace)),
            ValueField("package_digest", textValue(grant.configuration.packageDigest)),
            ValueField("configuration_digest", textValue(grant.configuration.digest)),
            ValueField("instance_identity", textValue(grant.instanceIdentity)), ValueField("endpoint_identity", textValue(endpoint.endpointIdentity)),
            ValueField("resource_id", textValue(resourceId)), ValueField("grant_digest", textValue(grant.digest)),
            ValueField("startup_operation_id", textValue(operation.value)), ValueField("target_thread_id", textValue(grant.targetThread.value)),
            ValueField("permission_domain", plan.field("permission_domain").getOrThrow()),
            ValueField("workspace_root", plan.field("workspace_root").getOrThrow()), ValueField("network", plan.field("network").getOrThrow())]))
    }
    func captureStartup(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<Unit> {
        match (validateMaintenanceSource(context, prepared, HostServiceAction.Start)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (canonicalAgentValue(prepared.operationPlan.canonicalArguments) != canonicalAgentValue(startupArguments)) {
            return hostLifecycleLeaseError("plugin.http_service_start_plan_changed")
        }
        lock.lock()
        try {
            if (closing || startupPrepared.isSome()) { return hostLifecycleLeaseError("plugin.http_service_start_replayed") }
            startupContext = Some(context); startupPrepared = Some(prepared); startupExecuting = true
            Result.Ok(())
        } finally { lock.unlock() }
    }
    func finishStartupExecution(): Unit { lock.lock(); try { startupExecuting = false } finally { lock.unlock() } }
    func startupSummary(endpoint: HostPinnedNativeServiceEndpoint, directory: AgentValue): Result<AgentValue> {
        let checked = try { hostCheckedManagedRefreshDirectory(directory, limits: serviceProtocolLimits(grant.launchPlan).value().getOrThrow()) } catch (_: Exception) { return hostLifecycleLeaseError("plugin.lifecycle_directory_invalid") }
        lock.lock()
        try {
            if (closing || !startupExecuting || startupPrepared.isNone() || startupOutput != "" || !endpoint.available()) {
                return hostLifecycleLeaseError("plugin.http_service_start_stale")
            }
            endpointIdentity = endpoint.endpointIdentity
            let output = objectValue([ValueField("schema", textValue("axyndra.http-service-start-result/v1")),
                ValueField("resource_id", textValue(resourceId)), ValueField("grant_digest", textValue(grant.digest)),
                ValueField("endpoint_identity", textValue(endpointIdentity)), ValueField("directory", checked)])
            if (!hostManagedServiceDurableValueFits(output)) { return hostLifecycleIoUnknown<AgentValue>() }
            startupOutput = stringifyUnifiedJson(output)
            Result.Ok(output)
        } finally { lock.unlock() }
    }
    func activateCommitted(): Result<Unit> {
        lock.lock()
        let (context, prepared, output) = try {
            if (closing || startupExecuting || startupPrepared.isNone() || startupOutput == "") { return hostLifecycleLeaseError("plugin.http_service_start_uncommitted") }
            (startupContext.getOrThrow(), startupPrepared.getOrThrow(), parseUnifiedJson(startupOutput, maxBytes: hostManagedServiceSummaryLimit(grant.launchPlan, 131072)))
        } finally { lock.unlock() }
        match (verifyCommitted(context, prepared, output)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (grant.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let cancelled = hostManagedChannelCallerCancelled(context)
        lock.lock()
        try {
            if (closing || cancelled) { return hostLifecycleLeaseError("plugin.http_service_start_cancelled") }
            active = true; Result.Ok(())
        } finally { lock.unlock() }
    }
    private func verifyCommitted(context: ToolInvocationContext, prepared: PreparedToolInvocation, output: AgentValue): Result<Unit> {
        let source = match (prepared.source.operationRoot) { case Some(value) => value; case None => return hostLifecycleLeaseError("plugin.http_service_source_required") }
        store.verifyHttpStreamMaintenanceCommitted(prepared.operationId, context.runId, ThreadId(context.sessionId.value),
            context.epoch, source, prepared.operationPlan, output)
    }
    private func validateMaintenanceSource(context: ToolInvocationContext, prepared: PreparedToolInvocation, action: HostServiceAction): Result<Unit> {
        if (!context.trustedControl || prepared.source.kind == PreparedInvocationSourceKind.Derived || context.epoch < 1 ||
            prepared.source.runId.value != context.runId.value || prepared.source.sessionId.value != context.sessionId.value ||
            prepared.source.epoch != context.epoch || context.sessionId.value == grant.targetThread.value || hostManagedChannelCallerCancelled(context) ||
            context.workspaceRoot != hostLifecycleText(grant.launchPlan, "workspace_root") ||
            hostPluginInvocationAuthorityScope(context) != hostLifecycleText(grant.launchPlan, "permission_domain")) {
            return hostLifecycleLeaseError("plugin.http_service_source_required")
        }
        let origin = match (prepared.source.operationRoot) {
            case Some(OperationRootSource.Direct(value)) => match (value.origin) {
                case DirectCallOrigin.HostService(item) => item
                case _ => return hostLifecycleLeaseError("plugin.http_service_source_required")
            }
            case _ => return hostLifecycleLeaseError("plugin.http_service_source_required")
        }
        let expectedTool = if (action == HostServiceAction.Start) { HOST_PLUGIN_HTTP_LIFECYCLE_TOOL } else { HOST_PLUGIN_HTTP_REFRESH_TOOL }
        let expectedImpl = if (action == HostServiceAction.Start) { HOST_PLUGIN_HTTP_LIFECYCLE_IMPLEMENTATION } else { HOST_PLUGIN_HTTP_REFRESH_IMPLEMENTATION }
        if ((action != HostServiceAction.Start && action != HostServiceAction.Refresh) || origin.action != action ||
            origin.serviceId != grant.serviceId || origin.ownerNamespace != grant.namespace || origin.packageDigest != grant.configuration.packageDigest ||
            origin.configurationDigest != grant.configuration.digest || origin.instanceIdentity != grant.instanceIdentity ||
            origin.hostRequestId != prepared.call.callId || prepared.call.name != expectedTool || prepared.operationPlan.toolName != expectedTool ||
            prepared.operationPlan.implementation.implementationFingerprint != expectedImpl ||
            prepared.operationPlan.implementation.toolVersion != expectedImpl || prepared.operationPlan.retryDisposition != OperationRetryDisposition.Never ||
            prepared.operationPlan.effectClass != OperationEffectClass.ExternalMutation ||
            match (prepared.operationPlan.replayDisposition) { case ReplayDisposition.NeverReplay => false; case _ => true }) {
            return hostLifecycleLeaseError("plugin.http_service_source_required")
        }
        let ceiling = CapabilitySet(values: prepared.operationPlan.requiredCapabilities)
        for (capability in requiredCapabilities() where !ceiling.allows(capability.kind, resource: capability.resource)) {
            return hostLifecycleLeaseError("plugin.http_service_source_required")
        }
        if (!networkPoliciesEqual(prepared.operationPlan.networkPolicy, networkPolicy().value().getOrThrow())) {
            return hostLifecycleLeaseError("plugin.http_service_source_required")
        }
        match (grant.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        // A sealed in-memory source alone does not prove the durable handoff.
        // Do not hold the resource lock across Store / current-owner checks.
        store.verifyHttpStreamMaintenanceExecuting(prepared.operationId, context.runId, ThreadId(context.sessionId.value),
            context.epoch, prepared.source.operationRoot.getOrThrow(), prepared.operationPlan)
    }
    public func maintenancePlan(context: ToolInvocationContext, prepared: PreparedToolInvocation, action: HostServiceAction): Result<AgentValue> {
        match (validateMaintenanceSource(context, prepared, action)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        let valid = try {
            if (closing) { false } else if (action == HostServiceAction.Start) {
                startupExecuting && startupPrepared.isSome() && refEq(prepared, startupPrepared.getOrThrow())
            } else { active }
        } finally { lock.unlock() }
        if (!valid) { return hostLifecycleLeaseError("plugin.http_service_maintenance_stale") }
        let actual = prepared.operationPlan.canonicalArguments
        if (action == HostServiceAction.Start && canonicalAgentValue(actual) != canonicalAgentValue(startupArguments)) {
            return hostLifecycleLeaseError("plugin.http_service_maintenance_stale")
        }
        if (action == HostServiceAction.Refresh && (hostLifecycleText(actual, "schema") != "axyndra.http-service-refresh/v1" ||
            hostLifecycleText(actual, "resource_id") != resourceId || canonicalAgentValue(actual.field("launch").getOrThrow()) != canonicalAgentValue(grant.launchPlan))) {
            return hostLifecycleLeaseError("plugin.http_service_maintenance_stale")
        }
        Result.Ok(parseUnifiedJson(stringifyUnifiedJson(actual), maxBytes: 131072))
    }
    public func refreshPlan(endpoint: HostPinnedNativeServiceEndpoint, revision: Int64, directoryDigest: String): Result<AgentValue> {
        if (!isActive()) { return hostLifecycleLeaseError("plugin.http_service_refresh_stale") }
        Result.Ok(objectValue([ValueField("schema", textValue("axyndra.http-service-refresh/v1")), ValueField("launch", grant.launchPlan),
            ValueField("resource_id", textValue(resourceId)), ValueField("endpoint_identity", textValue(endpoint.endpointIdentity)),
            ValueField("expected_revision", integerValue(revision)), ValueField("directory_digest", textValue(directoryDigest)),
            ValueField("window", grant.launchPlan.field("refresh").getOrThrow())]))
    }
    public func validateRefresh(plan: AgentValue, endpoint: HostPinnedNativeServiceEndpoint, revision: Int64, directoryDigest: String): Result<Unit> {
        let expected = match (refreshPlan(endpoint, revision, directoryDigest)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (canonicalAgentValue(plan) != canonicalAgentValue(expected)) { hostLifecycleLeaseError("plugin.http_service_refresh_stale") } else { Result.Ok(()) }
    }
    public func refreshResult(plan: AgentValue, directory: AgentValue): Result<AgentValue> {
        try {
            let output = objectValue([ValueField("schema", textValue("axyndra.http-service-refresh-result/v1")),
            ValueField("resource_id", textValue(resourceId)), ValueField("grant_digest", textValue(grant.digest)),
            ValueField("endpoint_identity", plan.field("endpoint_identity").getOrThrow()),
            ValueField("expected_revision", plan.field("expected_revision").getOrThrow()),
            ValueField("directory", hostCheckedManagedRefreshDirectory(directory, limits: serviceProtocolLimits(grant.launchPlan).value().getOrThrow()))])
            if (!hostManagedServiceDurableValueFits(output)) { return hostLifecycleIoUnknown<AgentValue>() }
            Result.Ok(output)
        }
        catch (_: Exception) { hostLifecycleLeaseError("plugin.lifecycle_directory_invalid") }
    }
    public func commitRefresh(context: ToolInvocationContext, prepared: PreparedToolInvocation, plan: AgentValue, output: AgentValue): Result<AgentValue> {
        match (verifyCommitted(context, prepared, output)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            let directory = hostCheckedManagedRefreshDirectory(output.field("directory").getOrThrow(), limits: serviceProtocolLimits(grant.launchPlan).value().getOrThrow())
            let expected = refreshResult(plan, directory).value().getOrThrow()
            hostLifecycleRequire(canonicalAgentValue(output) == canonicalAgentValue(expected))
            Result.Ok(directory)
        } catch (_: Exception) { hostLifecycleLeaseError("plugin.http_service_refresh_uncommitted") }
    }
}
