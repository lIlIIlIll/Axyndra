package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import tool_runtime.*
import std.sync.*
import std.collection.*
import yjson.*
import yjson_support.*

// Adapter around the existing sealed process lease. No new backend process,
// startup authority, byte budget, cancellation source or persistence is created.
class HostManagedChannelResource <: HostManagedServiceResource {
    let grant: HostPluginLifecycleLaunchGrant
    private let owner: HostPluginLifecycleOwner
    private let lock = Mutex()
    private var lease: ?HostPluginLifecycleLease = None
    private var closing = false
    init(owner: HostPluginLifecycleOwner, grant: HostPluginLifecycleLaunchGrant) {
        this.owner = owner; this.grant = grant
    }
    func capture(value: HostPluginLifecycleLease): Unit {
        lock.lock()
        let stopped = try {
            if (lease.isSome()) { throw IllegalStateException("channel resource cannot replace its lease") }
            lease = Some(value); closing
        } finally { lock.unlock() }
        if (stopped) { let _ = owner.revoke(value) }
    }
    func actualLease(): HostPluginLifecycleLease {
        lock.lock(); try { lease.getOrThrow() } finally { lock.unlock() }
    }
    func stagePayload(context: ToolInvocationContext, call: ToolCall, binding: AgentValue, id: String, hex: String): Result<AgentValue> {
        match (validateActive(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        owner.stagePayload(context, call, binding, id, hex)
    }
    public func endpointGrant(): HostNativeServiceEndpointGrant { grant }
    public func launchKey(): String { hostManagedServiceLaunchKey(grant) }
    public func resourceIdentity(): String { actualLease().leaseId }
    public func requiredCapabilities(): Array<Capability> {
        let values = ArrayList<Capability>([Capability(CapabilityKind.ProcessSpawn)])
        for (value in hostLifecycleControlCapabilities(grant.launchPlan)) { values.add(value) }
        values.toArray()
    }
    public func networkPolicy(): Result<NetworkPolicy> { parseNetworkPolicy(grant.launchPlan.field("network").getOrThrow()) }
    public func bindingMetadata(endpoint: HostPinnedNativeServiceEndpoint): Result<AgentValue> {
        if (!isActive()) { return hostLifecycleLeaseError("plugin.lifecycle_invocation_stale") }
        let selected = actualLease(); let plan = grant.launchPlan
        Result.Ok(objectValue([
            ValueField("plugin", plan.field("namespace").getOrThrow()), ValueField("package_digest", plan.field("package_digest").getOrThrow()),
            ValueField("configuration_digest", plan.field("configuration_digest").getOrThrow()),
            ValueField("instance_identity", textValue(grant.instanceIdentity)), ValueField("endpoint_identity", textValue(endpoint.endpointIdentity)),
            ValueField("lease_id", textValue(selected.leaseId)), ValueField("launch_digest", textValue(grant.digest)),
            ValueField("startup_operation_id", textValue(selected.operationId.value)), ValueField("target_thread_id", textValue(grant.targetThread.value)),
            ValueField("permission_domain", plan.field("permission_domain").getOrThrow()), ValueField("workspace_root", plan.field("workspace_root").getOrThrow()),
            ValueField("workspace_mode", plan.field("workspace_mode").getOrThrow()), ValueField("network", plan.field("network").getOrThrow())]))
    }
    public func isActive(): Bool {
        lock.lock(); let selected = try { if (closing) { return false }; lease } finally { lock.unlock() }
        match (selected) { case Some(value) => value.isActive(); case None => false }
    }
    public func validateActive(context: ToolInvocationContext): Result<Unit> {
        if (!isActive() || context.sessionId.value != grant.targetThread.value || context.cancellation.isCancelled() ||
            hostPluginInvocationAuthorityScope(context) != hostLifecycleText(grant.launchPlan, "permission_domain")) {
            return hostLifecycleLeaseError("plugin.lifecycle_invocation_stale")
        }
        grant.stillCurrent()
    }
    public func validateInvocation(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        binding: AgentValue): Result<Unit> {
        if (hostManagedJobSource(prepared.source.operationRoot).isNone()) { return validateActive(context) }
        if (!isActive() || context.cancellation.isCancelled()) { return hostLifecycleLeaseError("plugin.lifecycle_invocation_stale") }
        match (hostValidateManagedJobResource(context, prepared.source.operationRoot, grant.targetThread,
            hostLifecycleText(grant.launchPlan, "permission_domain"), binding: Some(binding))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        grant.stillCurrent()
    }
    public func cancellation(): CancellationToken { actualLease().cancellationToken() }
    public func maintenancePlan(context: ToolInvocationContext, prepared: PreparedToolInvocation, action: HostServiceAction): Result<AgentValue> {
        let source = prepared.source.operationRoot
        if (!context.trustedControl || source.isNone() || prepared.source.kind == PreparedInvocationSourceKind.Derived ||
            prepared.source.runId.value != context.runId.value || prepared.source.sessionId.value != context.sessionId.value || prepared.source.epoch != context.epoch) {
            return hostLifecycleLeaseError("plugin.lifecycle_maintenance_source_required")
        }
        let origin = match (source.getOrThrow()) {
            case OperationRootSource.Direct(value) => match (value.origin) {
                case DirectCallOrigin.HostService(item) => item
                case _ => return hostLifecycleLeaseError("plugin.lifecycle_maintenance_source_required")
            }
            case _ => return hostLifecycleLeaseError("plugin.lifecycle_maintenance_source_required")
        }
        if (origin.action != action || origin.ownerNamespace != hostLifecycleText(grant.launchPlan, "namespace") ||
            origin.instanceIdentity != grant.instanceIdentity || context.sessionId.value == grant.targetThread.value ||
            hostPluginInvocationAuthorityScope(context) != hostLifecycleText(grant.launchPlan, "permission_domain")) {
            return hostLifecycleLeaseError("plugin.lifecycle_maintenance_source_required")
        }
        match (grant.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(prepared.operationPlan.canonicalArguments)
    }
    public func observeRevocation(callback: () -> Unit): CancellationRegistration { actualLease().observeRevocation(callback) }
    func stopFrozen():Result<Unit>{
        lock.lock();let selected=try{closing=true;lease}finally{lock.unlock()}
        match(selected){case Some(value)=>value.stopFrozen();case None=>
            if(owner.retainsLaunch(grant.digest)){hostLifecycleLeaseError("plugin.lifecycle_cleanup_pending")}else{Result.Ok(())}}
    }
    public func revoke(): Result<Unit> {
        lock.lock(); let selected = try { closing = true; lease } finally { lock.unlock() }
        match (selected) { case Some(value) => owner.revoke(value); case None =>
            if (owner.retainsLaunch(grant.digest)) { hostLifecycleLeaseError("plugin.lifecycle_cleanup_pending") } else { Result.Ok(()) } }
    }
    public func resourcesReleased(): Bool {
        lock.lock(); let selected = try { lease } finally { lock.unlock() }
        match (selected) { case Some(value) => value.resourcesReleased(); case None => !owner.retainsLaunch(grant.digest) }
    }
    public func retainsStartup(): Bool { owner.retainsLaunch(grant.digest) }
    public func refreshPlan(endpoint: HostPinnedNativeServiceEndpoint, revision: Int64, directoryDigest: String): Result<AgentValue> {
        let plan = grant.launchPlan; let window = plan.field("refresh").getOrThrow()
        if (!isActive() || window.unifiedKind != ValueKind.Object) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_not_granted") }
        Result.Ok(objectValue([ValueField("schema", textValue("axyndra.lifecycle-refresh/v1")), ValueField("launch", plan),
            ValueField("lease_id", textValue(actualLease().leaseId)), ValueField("endpoint_identity", textValue(endpoint.endpointIdentity)),
            ValueField("expected_revision", integerValue(revision)), ValueField("directory_digest", textValue(directoryDigest)), ValueField("window", window)]))
    }
    public func validateRefresh(plan: AgentValue, endpoint: HostPinnedNativeServiceEndpoint,
        revision: Int64, directoryDigest: String): Result<Unit> {
        if (!isActive()) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_stale") }
        match (grant.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            hostLifecycleExact(plan, ["schema", "launch", "lease_id", "endpoint_identity", "expected_revision", "directory_digest", "window"])
            hostLifecycleLeaseAssert(hostLifecycleText(plan, "schema") == "axyndra.lifecycle-refresh/v1" &&
                hostLifecycleText(plan, "lease_id") == actualLease().leaseId && hostLifecycleText(plan, "endpoint_identity") == endpoint.endpointIdentity &&
                hostLifecycleInt(plan, "expected_revision", 2147483646) == revision && hostLifecycleText(plan, "directory_digest") == directoryDigest &&
                canonicalAgentValue(plan.field("launch").getOrThrow()) == canonicalAgentValue(grant.launchPlan) &&
                canonicalAgentValue(plan.field("window").getOrThrow()) == canonicalAgentValue(grant.launchPlan.field("refresh").getOrThrow()))
            Result.Ok(())
        } catch (_: Exception) { hostLifecycleLeaseError("plugin.lifecycle_refresh_stale") }
    }
    public func refreshResult(plan: AgentValue, directory: AgentValue): Result<AgentValue> {
        try {
            let output = objectValue([ValueField("schema", textValue("axyndra.lifecycle-refresh-result/v1")),
            ValueField("lease_id", textValue(actualLease().leaseId)), ValueField("launch_digest", textValue(grant.digest)),
            ValueField("expected_revision", plan.field("expected_revision").getOrThrow()),
            ValueField("directory", hostCheckedManagedRefreshDirectory(directory, limits: serviceProtocolLimits(grant.launchPlan).value().getOrThrow()))])
            if (!hostManagedServiceDurableValueFits(output)) { return hostLifecycleIoUnknown<AgentValue>() }
            Result.Ok(output)
        }
        catch (_: Exception) { hostLifecycleLeaseError("plugin.lifecycle_directory_invalid") }
    }
    public func commitRefresh(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        plan: AgentValue, output: AgentValue): Result<AgentValue> {
        let selected = actualLease()
        match (selected.refreshCommitted(context, prepared, plan, output)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            hostLifecycleExact(output, ["schema", "lease_id", "launch_digest", "expected_revision", "directory"])
            hostLifecycleLeaseAssert(hostLifecycleText(output, "schema") == "axyndra.lifecycle-refresh-result/v1" &&
                hostLifecycleText(output, "lease_id") == selected.leaseId && hostLifecycleText(output, "launch_digest") == grant.digest &&
                hostLifecycleInt(output, "expected_revision", 2147483646) == hostLifecycleInt(plan, "expected_revision", 2147483646))
            Result.Ok(hostCheckedManagedRefreshDirectory(output.field("directory").getOrThrow(),
                limits: serviceProtocolLimits(grant.launchPlan).value().getOrThrow()))
        } catch (_: Exception) { hostLifecycleLeaseError("plugin.lifecycle_refresh_uncommitted") }
    }
}

func hostManagedServiceLaunchKey(grant: HostNativeServiceEndpointGrant): String {
    let plan = grant.endpointBinding()
    modelPolicySha256Text(canonicalAgentValue(listValue([plan.field("namespace").getOrThrow(),
        textValue(grant.endpointInstanceIdentity()), textValue(grant.endpointTargetThread().value),
        plan.field("permission_domain").getOrThrow(), plan.field("service_id").getOrThrow()])))
}

class HostManagedChannelTransport <: HostManagedServiceTransport {
    private let resource: HostManagedChannelResource
    private let runtime: HostJavaScriptPluginServiceRuntime
    private let configurationText: String
    init(resource: HostManagedChannelResource, runtime: HostJavaScriptPluginServiceRuntime, configuration: AgentValue) {
        this.resource = resource; this.runtime = runtime; configurationText = stringifyUnifiedJson(configuration)
    }
    public func requestedCapability(): String { "process.channel" }
    public func preparationArguments(phase: HostManagedServicePhase, localName: String, input: AgentValue): AgentValue {
        match (phase) {
            case HostManagedServicePhase.Call => objectValue([ValueField("action", textValue("call")),
                ValueField("tool", textValue(localName)), ValueField("input", input)])
            case HostManagedServicePhase.Start => objectValue([ValueField("action", textValue("start")),
                ValueField("configuration", parseUnifiedJson(configurationText, maxBytes: 16384))])
            case HostManagedServicePhase.Refresh => objectValue([ValueField("action", textValue("refresh")),
                ValueField("configuration", parseUnifiedJson(configurationText, maxBytes: 16384))])
        }
    }
    public func freezeIntents(context: ToolInvocationContext, call: ToolCall, input: AgentValue, purePreparation: AgentValue, binding: AgentValue): Result<AgentValue> {
        let _ = context
        if (!httpIntentExactFields(purePreparation, ["intents"])) { return hostLifecycleLeaseError("plugin.lifecycle_preparation_invalid") }
        let intents = purePreparation.field("intents").getOrThrow()
        if (intents.unifiedKind != ValueKind.List || intents.items.isEmpty()) { return hostLifecycleLeaseError("plugin.lifecycle_preparation_invalid") }
        let payload = servicePayloadLimits(binding).value().getOrThrow()
        if (payload.isSome()) {
            let maximum = payload.getOrThrow().maxWriteBytes
            if (intents.items.size > 16) { return hostLifecycleLeaseError("plugin.lifecycle_preparation_invalid") }
            let seen = HashSet<String>(); var total: Int64 = 0
            // Validate all plugin bytes before writing any artifact. Reference
            // DTOs, duplicate IDs and inline/source claims are not accepted.
            for (intent in intents.items) {
                let bytes = match (channelServiceWriteBytes(intent, maximumBytes: maximum)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
                }
                total += bytes.size
                let id = httpIntentText(intent, "id")
                if (total > maximum || seen.contains(id)) { return hostLifecycleLeaseError("plugin.lifecycle_preparation_invalid") }
                seen.add(id)
            }
            let references = ArrayList<AgentValue>()
            for (intent in intents.items) {
                match (resource.stagePayload(context, ToolCall(call.callId, call.name, input), binding,
                    httpIntentText(intent, "id"), httpIntentText(intent, "bytes_hex"))) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(value) => references.add(value)
                }
            }
            let value = objectValue([ValueField("input", input), ValueField("configuration", objectValue([])),
                ValueField("host_plan", objectValue([ValueField("version", textValue(HOST_CHANNEL_PAYLOAD_INTENT_VERSION)),
                    ValueField("binding", binding), ValueField("intents", listValue(references.toArray()))]))])
            match (channelServiceChildArguments(value, httpIntentText(references[0], "id"))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
            }
            if (!hostManagedServiceDurableValueFits(value)) { return hostLifecycleLeaseError("plugin.lifecycle_input_codec_limit") }
            return Result.Ok(value)
        }
        let value = objectValue([ValueField("input", input), ValueField("configuration", objectValue([])),
            ValueField("host_plan", objectValue([ValueField("version", textValue(HOST_CHANNEL_INTENT_VERSION)),
                ValueField("binding", binding), ValueField("intents", intents)]))])
        match (channelServiceChildArguments(value, httpIntentText(intents.items[0], "id"))) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: serviceProtocolLimits(binding).value().getOrThrow().canonicalBytes))
    }
    public func validateParent(context: ToolInvocationContext, prepared: PreparedToolInvocation, binding: AgentValue): Result<Unit> {
        let _ = context; let _ = binding
        if (!isFrozenChannelParentPlan(prepared.operationPlan)) { hostLifecycleLeaseError("plugin.lifecycle_canonical_source_required") } else { Result.Ok(()) }
    }
    public func beginInvocation(service: HostPluginManagedService, endpoint: HostPinnedNativeServiceEndpoint,
        rootContext: ToolInvocationContext, rootPrepared: PreparedToolInvocation, binding: AgentValue): Result<HostManagedServiceInvocation> {
        let identity = match (service.filePlanIdentity(endpoint)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        Result.Ok(HostManagedChannelInvocation(service, resource.actualLease(), rootContext, rootPrepared, binding,
            runtime.channelBroker(rootContext, rootPrepared, binding, identity)))
    }
    public func beginMaintenance(service: HostPluginManagedService, endpoint: HostPinnedNativeServiceEndpoint,
        context: ToolInvocationContext, prepared: PreparedToolInvocation, action: HostServiceAction): Result<HostManagedServiceInvocation> {
        let _ = service; let _ = endpoint
        match (action) {
            case HostServiceAction.Start =>
                let observer = HostManagedStartupObserver(resource.actualLease(), context, prepared)
                Result.Ok(HostChannelMaintenanceInvocation(observer, context, prepared,
                    { => hostManagedChannelCallerCancelled(context) }, { => observer.close(); Result.Ok(()) }))
            case HostServiceAction.Refresh =>
                let window = match (resource.actualLease().refreshWindow(context, prepared, prepared.operationPlan.canonicalArguments)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
                }
                let observer = HostManagedRefreshObserver(window)
                Result.Ok(HostChannelMaintenanceInvocation(observer, context, prepared, { => window.closedOrCancelled() },
                    { => observer.close(); window.close(); Result.Ok(()) }))
            case HostServiceAction.Stop => hostLifecycleLeaseError("plugin.lifecycle_maintenance_action_invalid")
        }
    }
}

// Common observer adapter for the existing finite startup/refresh windows. Its
// result is raw directory data, not the active Tool-call terminal envelope.
class HostChannelMaintenanceInvocation <: HostManagedServiceInvocation {
    private let observer: JavaScriptHostObserver
    private let context: ToolInvocationContext
    private let prepared: PreparedToolInvocation
    private let cancelled: () -> Bool
    private let cleanup: () -> Result<Unit>
    private let closed = AtomicBool(false)
    init(observer: JavaScriptHostObserver, context: ToolInvocationContext, prepared: PreparedToolInvocation,
        cancelled: () -> Bool, cleanup: () -> Result<Unit>) {
        this.observer = observer; this.context = context; this.prepared = prepared; this.cancelled = cancelled; this.cleanup = cleanup
    }
    public func owns(_: PreparedToolInvocation): Bool { false }
    public func executeChild(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> { hostLifecycleLeaseError("channel.maintenance_child_unsupported") }
    public func finish(response: Result<HostJavaScriptPluginInvocationResult>): Result<ToolResult> {
        if (hostManagedChannelCallerCancelled(context) || cancelled()) { return hostLifecycleIoCancelled() }
        match (response) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => if (value.isError) { hostLifecycleLeaseError("plugin.lifecycle_refresh_rejected") }
                else { Result.Ok(ToolResult(prepared.call.callId, value.value)) }
        }
    }
    public func close(): Result<Unit> { closed.store(true); cleanup() }
    public func onProgress(id: String, value: String): JavaScriptHostResult<Unit> {
        if (closed.load()) { return hostPluginServiceError("channel.maintenance_closed", "maintenance observer is closed") }
        observer.onProgress(id, value)
    }
    public func onServiceRequest(id: String, request: String, service: String, arguments: String): JavaScriptHostResult<String> {
        if (closed.load()) { return hostPluginServiceError("channel.maintenance_closed", "maintenance observer is closed") }
        observer.onServiceRequest(id, request, service, arguments)
    }
}
