package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// A live Runtime seal selects the original resource domain while the actual
// invocation keeps the child Thread/Run/epoch/token. Descriptive metadata and
// preparation_ref alone can never open this route.
public func hostManagedJobSource(source: ?OperationRootSource): ?DirectToolCallRef {
    match (source) {
        case Some(OperationRootSource.Direct(root)) => if (root.managedJob.isSome()) { Some(root) } else { None }
        case _ => None
    }
}

public func hostValidateManagedJobResource(context: ToolInvocationContext, source: ?OperationRootSource,
    target: ThreadId, domain: String, binding!: ?AgentValue = None): Result<Unit> {
    let root = match (hostManagedJobSource(source)) { case Some(value) => value
        case None => return hostResourceError("task.managed_job_source_required") }
    let launch = root.managedJob.getOrThrow().binding
    if (context.trustedControl || root.threadId.value != context.sessionId.value || root.runId.value != context.runId.value ||
        root.epoch != context.epoch || !root.matchesExternalCancellation(context.cancellation) ||
        launch.parentThreadId.value != target.value || launch.permissionDomain != domain ||
        hostPluginInvocationAuthorityScope(context) != domain) {
        return hostResourceError("task.managed_job_resource_scope")
    }
    match (binding) { case Some(value) =>
        if (modelPolicySha256Text(canonicalAgentValue(value)) != launch.serviceBindingDigest) {
            return hostResourceError("task.managed_job_resource_binding") }
        case None => () }
    root.validateLiveSource()
}

public func hostManagedServiceExecutionArguments(localName: String, prepared: PreparedToolInvocation): AgentValue {
    let args = prepared.operationPlan.canonicalArguments
    let value = objectValue([ValueField("action", textValue("call")), ValueField("tool", textValue(localName)),
        ValueField("input", args.field("input").getOrThrow()), ValueField("host_plan", args.field("host_plan").getOrThrow())])
    match (hostManagedJobSource(prepared.source.operationRoot)) {
        case Some(root) => value.put("preparation_ref", managedJobPreparationReference(root.managedJob.getOrThrow().binding))
        case None => () }
    value
}
