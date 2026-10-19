package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

type HostHttpServiceStartup = (ToolInvocationContext, PreparedToolInvocation) -> Result<AgentValue>

class HostHttpLifecycleAdmission {
    let resource: HostManagedHttpResource
    let maintenance: SessionId
    let origin: HostServiceOrigin
    let callId: String
    let action: HostHttpServiceStartup
    var entered = false
    init(resource: HostManagedHttpResource, maintenance: SessionId, origin: HostServiceOrigin,
        callId: String, action: HostHttpServiceStartup) {
        this.resource = resource; this.maintenance = maintenance; this.origin = origin
        this.callId = callId; this.action = action
    }
}

// Ephemeral pending callback association, exactly like the existing channel
// control facade. It cannot publish Tools, mint source or persist Run state.
class HostHttpLifecycleControl <: ToolExecutor {
    let store: DurableOperationStore
    private let lock = Mutex()
    private let admissions = ArrayList<HostHttpLifecycleAdmission>()
    init(store: DurableOperationStore) { this.store = store }
    func descriptor(): ToolDescriptor {
        ToolDescriptor(ModelToolDefinition(HOST_PLUGIN_HTTP_LIFECYCLE_TOOL,
            "Start one configured native HTTP service within its exact finite approved network window.",
            objectValue([ValueField("type", textValue("object"))])),
            Capability(CapabilityKind.ExtensionInvoke), sideEffecting: true, controlOnly: true, neverReplay: true,
            implementationVersion: HOST_PLUGIN_HTTP_LIFECYCLE_IMPLEMENTATION, implementationFingerprint: HOST_PLUGIN_HTTP_LIFECYCLE_IMPLEMENTATION,
            additionalCapabilityResolver: Some({ call => match (lookup(call)) {
                case Result.Ok(value) => value.resource.requiredCapabilities()[1..]
                case Result.Err(_) => []
            } }),
            networkPolicyResolver: Some({ call => match (lookup(call)) {
                case Result.Ok(value) => value.resource.networkPolicy()
                case Result.Err(error) => Result.Err(error)
            } }),
            canonicalArgumentsResolver: Some({ context, call => match (lookup(call)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(value) =>
                    if (!context.trustedControl || context.sessionId.value != value.maintenance.value ||
                        hostPluginInvocationAuthorityScope(context) != hostLifecycleText(value.resource.grant.launchPlan, "permission_domain")) {
                        hostLifecycleLeaseError("plugin.http_service_admission_mismatch")
                    } else {
                        match (value.resource.grant.stillCurrent()) {
                            case Result.Err(error) => Result.Err(error)
                            case Result.Ok(_) => Result.Ok(value.resource.startupArguments)
                        }
                    }
            } }))
    }
    func launch(control: HostServiceToolControl, targetContext: ToolInvocationContext, maintenance: SessionId,
        resource: HostManagedHttpResource, action: HostHttpServiceStartup, approval: ApprovalDecision,
        budget: ExecutionBudget): Result<ToolInvocationResult> {
        if (maintenance.value == resource.grant.targetThread.value || targetContext.cancellation.isCancelled()) {
            return hostLifecycleLeaseError("plugin.http_service_maintenance_required")
        }
        let grant = resource.grant
        match (grant.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let nonce = match (hostNewPluginInstanceIdentity()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let callId = "http-service-start-" + nonce
        let origin = HostServiceOrigin(grant.serviceId, grant.namespace, grant.configuration.packageDigest,
            grant.configuration.digest, grant.instanceIdentity, HostServiceAction.Start, callId)
        let admission = HostHttpLifecycleAdmission(resource, maintenance, origin, callId, action)
        lock.lock()
        try {
            if (admissions.size >= 32) { return hostLifecycleLeaseError("plugin.http_service_capacity") }
            for (entry in admissions where entry.resource.launchKey() == resource.launchKey()) {
                return hostLifecycleLeaseError("plugin.http_service_start_busy")
            }
            admissions.add(admission)
        } finally { lock.unlock() }
        var activated = false
        try {
            let result = match (invokeHostServiceTool(control, maintenance, origin, targetContext.capabilities,
                ToolCall(callId, HOST_PLUGIN_HTTP_LIFECYCLE_TOOL, resource.startupArguments), approvalDecision: Some(approval),
                budget: budget, callerCancellation: Some(targetContext.cancellation))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
            }
            let success = match (result) { case ToolInvocationResult.Completed(value) => !value.isError; case _ => false }
            if (!success) { return Result.Ok(result) }
            match (resource.activateCommitted()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            activated = true; Result.Ok(result)
        } finally {
            if (!activated) { let _ = resource.revoke() }
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
        hostRegistryHandoff(selected.resource.grant.enterRegistryEffect())
    }

    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        let admission = match (lookup(ToolCall(prepared.call.callId, prepared.call.name, prepared.operationPlan.canonicalArguments))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        let origin = match (prepared.source.operationRoot) {
            case Some(OperationRootSource.Direct(value)) => value.origin
            case _ => return hostLifecycleLeaseError("plugin.http_service_source_required")
        }
        if (!context.trustedControl || context.sessionId.value != admission.maintenance.value ||
            !sameDirectCallOrigin(origin, DirectCallOrigin.HostService(admission.origin))) {
            return hostLifecycleLeaseError("plugin.http_service_source_required")
        }
        lock.lock()
        try {
            if (admission.entered) { return hostLifecycleLeaseError("plugin.http_service_start_replayed") }
            admission.entered = true
        } finally { lock.unlock() }
        match (admission.resource.captureStartup(context, prepared)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            match (admission.action(context, prepared)) {
                case Result.Err(error) => hostLifecycleRefreshFailure(context, error)
                case Result.Ok(output) => Result.Ok(ToolResult(prepared.call.callId, output))
            }
        } catch (_: Exception) { hostManagedChannelUnknown() }
        finally { admission.resource.finishStartupExecution() }
    }
    private func lookup(call: ToolCall): Result<HostHttpLifecycleAdmission> {
        if (call.name != HOST_PLUGIN_HTTP_LIFECYCLE_TOOL) { return hostLifecycleLeaseError("plugin.http_service_admission_missing") }
        lock.lock()
        try {
            for (entry in admissions where entry.callId == call.callId &&
                canonicalAgentValue(entry.resource.startupArguments) == canonicalAgentValue(call.arguments)) { return Result.Ok(entry) }
            hostLifecycleLeaseError("plugin.http_service_admission_missing")
        } finally { lock.unlock() }
    }
    public func cancel(_: RunId): Result<Unit> { Result.Ok(()) }
}
