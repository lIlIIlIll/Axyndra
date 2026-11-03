package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

public func managedInvocationAuthorityScope(context: ToolInvocationContext,
    ceiling!: ?CapabilitySet = None): String {
    let capabilities = ArrayList<AgentValue>()
    for (capability in (match (ceiling) { case Some(value) => value; case None => context.capabilities }).values) {
        capabilities.add(objectValue([
            ValueField("kind", textValue(capabilityDisplayName(capability.kind))),
            ValueField("resource", textValue(capability.resource))
        ]))
    }
    let environment = ArrayList<AgentValue>()
    for (entry in context.environment.entries()) {
        environment.add(objectValue([
            ValueField("name", textValue(entry.name)),
            ValueField("value", textValue(entry.value))
        ]))
    }
    // This is an isolation key, never an authorization proof. Every broker
    // request is still admitted against the live parent Operation.
    modelPolicySha256Text(stringifyUnifiedJson(objectValue([
        ValueField("workspace", textValue(context.workspaceRoot)),
        ValueField("cwd", textValue(context.cwd)),
        ValueField("capabilities", listValue(capabilities.toArray())),
        ValueField("environment", listValue(environment.toArray()))
    ])))
}

func managedJobRoot(source: PreparedInvocationSource): ?DirectToolCallRef {
    match (source.operationRoot) {
        case Some(OperationRootSource.Direct(value)) => if (value.managedJob.isSome()) { Some(value) } else { None }
        case _ => None
    }
}

func validateManagedJobContext(context: ToolInvocationContext, root: DirectToolCallRef,
    ceiling: CapabilitySet): Result<Unit> {
    let binding = root.managedJob.getOrThrow().binding
    if (context.trustedControl || root.threadId.value != context.sessionId.value || root.runId.value != context.runId.value ||
        root.epoch != context.epoch || !root.matchesExternalCancellation(context.cancellation) ||
        managedInvocationAuthorityScope(context, ceiling: Some(ceiling)) != binding.permissionDomain) {
        return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "task.managed_job_context_changed",
            "managed job changed its actual child owner, cancellation or retained permission domain"))
    }
    for (capability in context.capabilities.values) {
        if (!ceiling.allows(capability.kind, resource: capability.resource)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "task.managed_job_capability_changed",
                "managed job exceeds its retained root capability ceiling"))
        }
    }
    root.validateLiveSource()
}

// This runs only after exact parent/child plan and request-key matching.
// A descriptive ManagedJob origin is not a live Task admission. Keep the
// ordinary Thread fence; only the already sealed Task source can retain the
// original service's Thread, and only for its exact approved service binding.
func exactServiceChildTargetAllowed(context: ToolInvocationContext,
    source: PreparedInvocationSource, plan: NormalizedOperationPlan): Bool {
    if (plan.toolName != HOST_CHANNEL_WRITE_TOOL && plan.toolName != HOST_HTTP_STREAM_TOOL) { return true }
    let service = match (plan.canonicalArguments.field("binding")) { case Some(value) => value; case None => return false }
    match (managedJobRoot(source)) {
        case Some(root) =>
            if (source.kind != PreparedInvocationSourceKind.Derived) { return false }
            let ceiling = match (source.managedJobCeiling) { case Some(value) => value; case None => return false }
            if (validateManagedJobContext(context, root, ceiling).isError()) { return false }
            let launch = root.managedJob.getOrThrow().binding
            httpIntentText(service, "target_thread_id") == launch.parentThreadId.value &&
                modelPolicySha256Text(canonicalAgentValue(service)) == launch.serviceBindingDigest
        case None => httpIntentText(service, "target_thread_id") == context.sessionId.value
    }
}
