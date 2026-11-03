package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

public let HOST_PLUGIN_LIFECYCLE_REFRESH_TOOL = "host.plugin.lifecycle.refresh"

class HostLifecycleRefreshAdmission {
    let service: HostPluginManagedService
    let maintenance: SessionId
    let origin: HostServiceOrigin
    let callId: String
    private let planText: String
    var entered = false
    var context: ?ToolInvocationContext = None
    var prepared: ?PreparedToolInvocation = None
    var output: ?AgentValue = None
    init(service: HostPluginManagedService, maintenance: SessionId, origin: HostServiceOrigin,
        callId: String, plan: AgentValue) {
        this.service = service; this.maintenance = maintenance; this.origin = origin; this.callId = callId
        planText = stringifyUnifiedJson(plan)
    }
    prop plan: AgentValue { get() { parseUnifiedJson(planText, maxBytes: 131072) } }
}

// Transient host admission records only. This reuses canonical control Run,
// approval, handoff and Receipt; it owns neither a Tool directory nor a lease.
class HostPluginLifecycleRefreshControl <: ToolExecutor {
    private let lock = Mutex()
    private let admissions = ArrayList<HostLifecycleRefreshAdmission>()
    private let toolName: String
    private let implementation: String
    private let baseCapability: Capability
    init(toolName!: String = HOST_PLUGIN_LIFECYCLE_REFRESH_TOOL,
        implementation!: String = "host-plugin-lifecycle-refresh-v1",
        baseCapability!: Capability = Capability(CapabilityKind.ProcessSpawn)) {
        this.toolName = toolName; this.implementation = implementation; this.baseCapability = baseCapability
    }

    func descriptor(): ToolDescriptor {
        ToolDescriptor(ModelToolDefinition(toolName,
            "Refresh one configured service directory within its exact finite approved resource window.",
            objectValue([ValueField("type", textValue("object"))])),
            baseCapability, controlOnly: true, sideEffecting: true, neverReplay: true,
            implementationVersion: implementation, implementationFingerprint: implementation,
            additionalCapabilityResolver: Some({ call => match (lookup(call)) {
                case Result.Ok(value) => hostManagedAdditionalCapabilities(value.service.requiredCapabilities(), baseCapability)
                case Result.Err(_) => []
            } }),
            networkPolicyResolver: Some({ call => match (lookup(call)) {
                case Result.Ok(value) => value.service.networkPolicy()
                case Result.Err(error) => Result.Err(error)
            } }),
            canonicalArgumentsResolver: Some({ context, call => match (lookup(call)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(value) =>
                    if (!context.trustedControl || context.sessionId.value != value.maintenance.value ||
                        hostPluginInvocationAuthorityScope(context) != hostLifecycleText(value.plan.field("launch").getOrThrow(), "permission_domain")) {
                        hostLifecycleLeaseError("plugin.lifecycle_refresh_scope_mismatch")
                    } else { value.service.validateRefreshCandidate(value.plan) }
            } }))
    }

    func refresh(control: HostServiceToolControl, service: HostPluginManagedService,
        targetContext: ToolInvocationContext, approval: ApprovalDecision,
        budget: ExecutionBudget): Result<ToolInvocationResult> {
        let maintenance = match (service.refreshMaintenanceThread()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        let plan = match (service.beginRefresh(targetContext, maintenance)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        let launch = plan.field("launch").getOrThrow()
        let nonce = match (hostNewPluginInstanceIdentity()) {
            case Result.Err(error) => service.finishRefresh(); return Result.Err(error)
            case Result.Ok(value) => value
        }
        let callId = "lifecycle-refresh-" + nonce
        let origin = HostServiceOrigin(hostLifecycleText(launch, "service_id"), hostLifecycleText(launch, "namespace"),
            hostLifecycleText(launch, "package_digest"), hostLifecycleText(launch, "configuration_digest"),
            hostLifecycleText(launch, "instance_identity"), HostServiceAction.Refresh, callId)
        let admission = HostLifecycleRefreshAdmission(service, maintenance, origin, callId, plan)
        lock.lock()
        let admitted = try {
            if (admissions.size >= 32) { false } else { admissions.add(admission); true }
        } finally { lock.unlock() }
        if (!admitted) { service.finishRefresh(); return hostLifecycleLeaseError("plugin.lifecycle_refresh_capacity") }
        var published = false
        try {
            let outcome = match (invokeHostServiceTool(control, maintenance, origin, targetContext.capabilities,
                ToolCall(callId, toolName, plan), approvalDecision: Some(approval), budget: budget)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
            }
            let success = match (outcome) { case ToolInvocationResult.Completed(value) => !value.isError; case _ => false }
            if (!success) { return Result.Ok(outcome) }
            if (admission.context.isNone() || admission.prepared.isNone() || admission.output.isNone()) {
                return hostLifecycleLeaseError("plugin.lifecycle_refresh_uncommitted")
            }
            // A successful discovery Receipt is not a catalog commit. CAS
            // failure is returned explicitly and withdraws this whole service.
            match (service.commitRefresh(admission.context.getOrThrow(), admission.prepared.getOrThrow(),
                plan, admission.output.getOrThrow())) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
            }
            published = true
            Result.Ok(outcome)
        } finally {
            if (admission.entered && !published) { service.noteRefreshFailure(); let _ = service.revoke() }
            service.finishRefresh()
            lock.lock()
            try { for (index in 0..admissions.size where refEq(admissions[index], admission)) { admissions.remove(at: index); break } }
            finally { lock.unlock() }
        }
    }

    public func acquireHandoffLease(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolExecutionHandoffLease> {
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let selected = match (lookup(hostRegistryRootCall(prepared))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        selected.service.acquireRegistryHandoff()
    }

    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        let admission = match (lookup(ToolCall(prepared.call.callId, prepared.call.name, prepared.operationPlan.canonicalArguments))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        let root = match (prepared.source.operationRoot) {
            case Some(OperationRootSource.Direct(value)) => value
            case _ => return hostLifecycleLeaseError("plugin.lifecycle_refresh_source_required")
        }
        if (!context.trustedControl || context.sessionId.value != admission.maintenance.value ||
            !sameDirectCallOrigin(root.origin, DirectCallOrigin.HostService(admission.origin))) {
            return hostLifecycleLeaseError("plugin.lifecycle_refresh_scope_mismatch")
        }
        lock.lock()
        try {
            if (admission.entered) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_replayed") }
            admission.entered = true
        } finally { lock.unlock() }
        try {
            let value = match (admission.service.executeRefresh(context, prepared, admission.plan)) {
                case Result.Err(error) => return hostLifecycleRefreshFailure(context, error); case Result.Ok(value) => value
            }
            admission.context = Some(context); admission.prepared = Some(prepared); admission.output = Some(value)
            Result.Ok(ToolResult(prepared.call.callId, value))
        } catch (_: Exception) { hostLifecycleRefreshFailure(context, hostLifecycleLeaseFailure("plugin.lifecycle_refresh_unknown")) }
    }

    private func lookup(call: ToolCall): Result<HostLifecycleRefreshAdmission> {
        if (call.name != toolName) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_admission_missing") }
        lock.lock()
        try {
            for (entry in admissions where entry.callId == call.callId &&
                canonicalAgentValue(call.arguments) == canonicalAgentValue(entry.plan)) { return Result.Ok(entry) }
            hostLifecycleLeaseError("plugin.lifecycle_refresh_admission_missing")
        } finally { lock.unlock() }
    }
}

func hostLifecycleRefreshFailure<T>(context: ToolInvocationContext, error: AgentError): Result<T> {
    // Endpoint/lease revocation is not evidence that the actual caller cancelled
    // its canonical Run. Keep resource loss Unknown using the same policy as an
    // active channel call; only the actual caller token may choose Cancelled.
    if (error.kind == AgentErrorKind.Cancelled && hostManagedChannelCallerCancelled(context)) { return Result.Err(error) }
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "plugin.lifecycle_refresh_unknown",
        "refresh has no verified completion; the service is withdrawn and must not be replayed",
        retryable: false, fallbackAllowed: false))
}

func hostManagedAdditionalCapabilities(values: Array<Capability>, base: Capability): Array<Capability> {
    let result = ArrayList<Capability>()
    for (item in values where item.kind != base.kind || item.resource != base.resource) { result.add(item) }
    result.toArray()
}
