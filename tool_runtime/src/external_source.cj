package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Host-computed isolation key. The connection authorizer binds this value;
// passing the same string from an untrusted request never grants authority.
public func externalInvocationAuthorityScope(context: ToolInvocationContext,
    ceiling!: ?CapabilitySet = None): String {
    let capabilities = match (ceiling) { case Some(value) => value; case None => context.capabilities }
    let caps = ArrayList<AgentValue>()
    for (entry in capabilities.values) { caps.add(objectValue([
        ValueField("kind", textValue(capabilityName(entry.kind))), ValueField("resource", textValue(entry.resource))])) }
    let environment = ArrayList<AgentValue>()
    for (entry in context.environment.entries()) { environment.add(objectValue([
        ValueField("name", textValue(entry.name)), ValueField("value", textValue(entry.value))])) }
    modelPolicySha256Text(canonicalAgentValue(objectValue([
        ValueField("schema", textValue("axyndra.external-invocation-scope/v1")),
        ValueField("workspace", textValue(context.workspaceRoot)), ValueField("cwd", textValue(context.cwd)),
        ValueField("capabilities", listValue(caps.toArray())), ValueField("environment", listValue(environment.toArray()))])))
}

func validateExternalInvocationContext(context: ToolInvocationContext, binding: ExternalIngressBinding,
    token: CancellationToken, derived: Bool): Result<Unit> {
    if (context.trustedControl || context.sessionId.value != binding.threadId.value ||
        !refEq(context.cancellation, token) || context.cancellation.isCancelled() ||
        externalInvocationAuthorityScope(context, ceiling: if (derived) { Some(binding.ceiling) } else { None }) != binding.permissionDomain) {
        return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "external.context_changed",
            "external invocation differs from its sealed Thread, permission domain or cancellation owner"))
    }
    for (capability in context.capabilities.values) {
        if (!binding.ceiling.allows(capability.kind, resource: capability.resource)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "external.capability_ceiling",
                "external invocation exceeds its fixed capability ceiling"))
        }
    }
    Result.Ok(())
}
