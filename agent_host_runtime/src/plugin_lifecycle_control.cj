package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

// This callback is installed by the host manager, never decoded from a plugin
// request. The lease exposes only the approved, bounded startup window here.
public type HostPluginLifecycleStartup = (HostPluginLifecycleLease, ToolInvocationContext,
    PreparedToolInvocation) -> Result<AgentValue>

public class HostPluginLifecycleLaunch {
    public let outcome: ToolInvocationResult
    public let lease: ?HostPluginLifecycleLease
    init(outcome: ToolInvocationResult, lease: ?HostPluginLifecycleLease) {
        this.outcome = outcome; this.lease = lease
    }
}

class HostPluginLifecycleAdmission {
    let grant: HostPluginLifecycleLaunchGrant
    let maintenanceThread: SessionId
    let origin: HostServiceOrigin
    let callId: String
    let action: HostPluginLifecycleStartup
    let nativeDirectoryStartup:?(ToolInvocationContext,PreparedToolInvocation)->Result<AgentValue>
    var executing: Bool = false
    var lease: ?HostPluginLifecycleLease = None
    init(grant: HostPluginLifecycleLaunchGrant, maintenanceThread: SessionId,
        origin: HostServiceOrigin, callId: String, action: HostPluginLifecycleStartup,
        nativeDirectoryStartup!:?(ToolInvocationContext,PreparedToolInvocation)->Result<AgentValue>=None) {
        this.grant = grant; this.maintenanceThread = maintenanceThread
        this.origin = origin; this.callId = callId; this.action = action;this.nativeDirectoryStartup=nativeDirectoryStartup
    }
}

// A finite host-only admission table for the one generic control executor. It
// contains no public tool directory and no durable facts. Canonical execution,
// approval, handoff and receipt commitment remain in the shared host gateway.
public class HostPluginLifecycleControl <: ToolExecutor {
    private let owner: HostPluginLifecycleOwner
    private let lock = Mutex()
    private let admissions = ArrayList<HostPluginLifecycleAdmission>()
    public init(owner: HostPluginLifecycleOwner) { this.owner = owner }

    public func descriptor(): ToolDescriptor {
        ToolDescriptor(ModelToolDefinition(HOST_PLUGIN_LIFECYCLE_TOOL,
            "Start a configured plugin service within its exact finite lifecycle envelope.",
            objectValue([ValueField("type", textValue("object"))])),
            Capability(CapabilityKind.ProcessSpawn), sideEffecting: true, controlOnly: true, neverReplay: true,
            implementationVersion: "host-plugin-lifecycle-v1", implementationFingerprint: "host-plugin-lifecycle-v1",
            additionalCapabilityResolver: Some({ call => match (lookup(call)) {
                case Result.Ok(admission) => hostLifecycleControlCapabilities(admission.grant.launchPlan)
                case Result.Err(_) => []
            } }),
            networkPolicyResolver: Some({ call => match (lookup(call)) {
                case Result.Ok(admission) => parseNetworkPolicy(admission.grant.launchPlan.field("network").getOrThrow())
                case Result.Err(error) => Result.Err(error)
            } }),
            canonicalArgumentsResolver: Some({ context, call => match (lookup(call)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(admission) =>
                    if (!context.trustedControl || context.sessionId.value != admission.maintenanceThread.value ||
                        hostPluginInvocationAuthorityScope(context) != hostLifecycleText(admission.grant.launchPlan, "permission_domain")) {
                        hostLifecycleError("plugin.lifecycle_admission_mismatch", "lifecycle admission belongs to another host invocation")
                    } else {
                        match (admission.grant.stillCurrent()) {
                            case Result.Err(error) => Result.Err(error)
                            case Result.Ok(_) => Result.Ok(admission.grant.launchPlan)
                        }
                    }
            } }))
    }

    // The frontend supplies its ordinary capability ceiling and explicit
    // approval decision. An operator configuration is not ApprovalDecision.User.
    public func launch(control: HostServiceToolControl, maintenanceThread: SessionId,
        grant: HostPluginLifecycleLaunchGrant, capabilities: CapabilitySet,
        action: HostPluginLifecycleStartup, approvalDecision!: ?ApprovalDecision = None,
        budget!: ExecutionBudget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1),
        callerCancellation!: ?CancellationToken = None,
        nativeDirectoryStartup!:?(ToolInvocationContext,PreparedToolInvocation)->Result<AgentValue>=None
    ): Result<HostPluginLifecycleLaunch> {
        if (maintenanceThread.value == grant.targetThread.value) {
            return hostLifecycleError("plugin.lifecycle_maintenance_thread_required",
                "service startup requires its own canonical maintenance Thread")
        }
        let ceiling = CapabilitySet(values: capabilities.values.clone())
        match (grant.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let nonce = match (hostNewPluginInstanceIdentity()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        let plan = grant.launchPlan
        let requestId = "lifecycle-start-" + nonce
        let origin = HostServiceOrigin(hostLifecycleText(plan, "service_id"), hostLifecycleText(plan, "namespace"),
            hostLifecycleText(plan, "package_digest"), hostLifecycleText(plan, "configuration_digest"),
            grant.instanceIdentity, HostServiceAction.Start, requestId)
        let admission = HostPluginLifecycleAdmission(grant, maintenanceThread, origin, requestId, action,nativeDirectoryStartup:nativeDirectoryStartup)
        lock.lock()
        try {
            if (admissions.size >= 32) {
                return hostLifecycleError("plugin.lifecycle_admission_limit", "too many pending lifecycle admissions")
            }
            for (existing in admissions where existing.grant.instanceIdentity == grant.instanceIdentity &&
                existing.grant.targetThread.value == grant.targetThread.value &&
                hostLifecycleText(existing.grant.launchPlan, "namespace") == hostLifecycleText(plan, "namespace") &&
                hostLifecycleText(existing.grant.launchPlan, "permission_domain") == hostLifecycleText(plan, "permission_domain") &&
                hostLifecycleText(existing.grant.launchPlan, "service_id") == hostLifecycleText(plan, "service_id")) {
                return hostLifecycleError("plugin.lifecycle_admission_busy", "this plugin instance already has an active lifecycle admission")
            }
            admissions.add(admission)
        } finally { lock.unlock() }
        var activated = false
        try {
            let outcome = match (invokeHostServiceTool(control, maintenanceThread, origin, ceiling,
                ToolCall(requestId, HOST_PLUGIN_LIFECYCLE_TOOL, plan), approvalDecision: approvalDecision, budget: budget,
                callerCancellation: callerCancellation)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(value) => value
            }
            let succeeded = match (outcome) {
                case ToolInvocationResult.Completed(value) => !value.isError
                case _ => false
            }
            if (!succeeded) { return Result.Ok(HostPluginLifecycleLaunch(outcome, Option<HostPluginLifecycleLease>.None)) }
            if(admission.nativeDirectoryStartup.isSome()){
                // Actual normal HostService canonical completion already ran.
                // This pure directory startup owns no backend process lease.
                activated=true;return Result.Ok(HostPluginLifecycleLaunch(outcome,Option<HostPluginLifecycleLease>.None))
            }
            let lease = match (admission.lease) {
                case Some(value) => value
                case None => return hostLifecycleError("plugin.lifecycle_lease_missing", "completed startup did not retain its pending lease")
            }
            // This re-reads the exact canonical ToolResult and Completed
            // Receipt. The result variant above is not an activation proof.
            match (owner.activate(lease)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            activated = true
            Result.Ok(HostPluginLifecycleLaunch(outcome, Some(lease)))
        } finally {
            if (!activated) {
                match (admission.lease) { case Some(lease) => let _ = owner.revoke(lease); case None => () }
            }
            lock.lock()
            try {
                for (index in 0..admissions.size where refEq(admissions[index], admission)) {
                    admissions.remove(at: index)
                    break
                }
            } finally { lock.unlock() }
        }
    }

    public func acquireHandoffLease(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolExecutionHandoffLease> {
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let selected = match (lookup(hostRegistryRootCall(prepared))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        hostRegistryHandoff(selected.grant.enterRegistryEffect())
    }

    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        let admission = match (lookup(ToolCall(prepared.call.callId, prepared.call.name,
            prepared.operationPlan.canonicalArguments))) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        let root = match (prepared.source.operationRoot) {
            case Some(OperationRootSource.Direct(value)) => value
            case _ => return hostLifecycleError("plugin.lifecycle_source_required", "lifecycle startup requires its sealed canonical host source")
        }
        if (!context.trustedControl || context.sessionId.value != admission.maintenanceThread.value ||
            hostPluginInvocationAuthorityScope(context) != hostLifecycleText(admission.grant.launchPlan, "permission_domain") ||
            !sameDirectCallOrigin(root.origin, DirectCallOrigin.HostService(admission.origin))) {
            return hostLifecycleError("plugin.lifecycle_admission_mismatch", "lifecycle source differs from the admitted host request")
        }
        lock.lock()
        try {
            if (admission.executing) {
                return hostLifecycleError("plugin.lifecycle_already_started", "lifecycle launch is never replayed")
            }
            admission.executing = true
        } finally { lock.unlock() }
        var sealed = false
        try {
            match(admission.nativeDirectoryStartup){case Some(actual)=>
                let directory=match(actual(context,prepared)){
                    case Result.Err(error)=>return hostLifecycleStartupFailure(error);case Result.Ok(value)=>value}
                sealed=true;return Result.Ok(ToolResult(prepared.call.callId,directory))
                case None=>()}
            let lease = match (owner.start(context, prepared, admission.grant)) {
                case Result.Err(error) => return hostLifecycleStartupFailure(error)
                case Result.Ok(value) => value
            }
            admission.lease = Some(lease)
            let data = match (admission.action(lease, context, prepared)) {
                case Result.Err(error) => return hostLifecycleStartupFailure(error)
                case Result.Ok(value) => value
            }
            let summary = match (owner.startupSummary(lease, data)) {
                case Result.Err(error) => return hostLifecycleStartupFailure(error)
                case Result.Ok(value) => value
            }
            sealed = true
            Result.Ok(ToolResult(prepared.call.callId, summary))
        } catch (_: Exception) {
            hostLifecycleStartupFailure(AgentError(AgentErrorKind.RecoveryRequired,
                "plugin.lifecycle_start_unknown", "startup did not produce a verifiable completion"))
        } finally {
            if (!sealed) {
                match (admission.lease) { case Some(lease) => let _ = owner.revoke(lease); case None => () }
            }
        }
    }

    private func lookup(call: ToolCall): Result<HostPluginLifecycleAdmission> {
        if (call.name != HOST_PLUGIN_LIFECYCLE_TOOL) {
            return hostLifecycleError("plugin.lifecycle_admission_missing", "host lifecycle admission was not found")
        }
        let encoded = canonicalAgentValue(call.arguments)
        lock.lock()
        try {
            for (admission in admissions where admission.callId == call.callId &&
                canonicalAgentValue(admission.grant.launchPlan) == encoded) { return Result.Ok(admission) }
            hostLifecycleError("plugin.lifecycle_admission_missing", "host lifecycle admission was not found or its exact plan changed")
        } finally { lock.unlock() }
    }
}

func hostLifecycleStartupFailure<T>(error: AgentError): Result<T> {
    // ToolPipeline renders many transport/permission errors as completed error
    // results. Once a backend may have started or accepted a byte prefix that
    // would incorrectly turn uncertainty into a known Failed receipt.
    if (error.kind == AgentErrorKind.Cancelled) { return Result.Err(error) }
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "plugin.lifecycle_start_unknown",
        "service startup has no verifiable completion; reconcile it without replay",
        retryable: false, fallbackAllowed: false))
}

func hostLifecycleControlCapabilities(plan: AgentValue): Array<Capability> {
    let mode = hostLifecycleText(plan, "workspace_mode")
    if (mode == "workspace_readonly") {
        [Capability(CapabilityKind.ExtensionInvoke),
            Capability(CapabilityKind.WorkspaceRead, resource: hostLifecycleText(plan, "workspace_root"))]
    } else if (mode == "workspace_readwrite") {
        // This mode binds both effects explicitly. Write never implies Read.
        [Capability(CapabilityKind.ExtensionInvoke),
            Capability(CapabilityKind.WorkspaceRead, resource: hostLifecycleText(plan, "workspace_root")),
            Capability(CapabilityKind.WorkspaceWrite, resource: hostLifecycleText(plan, "workspace_root"))]
    } else { [Capability(CapabilityKind.ExtensionInvoke)] }
}
