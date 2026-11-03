package agent_domain

import std.collection.*
import yjson.*
import yjson_support.*

// An operator assertion about an exact local contribution. Remote annotations
// are not consulted. This data alone grants neither a root nor a child effect;
// Store must prove the completed startup and the current canonical parent.
public func parseServiceReadOnlyTools(value: AgentValue): Result<Array<String>> {
    if (value.unifiedKind != ValueKind.List || value.items.size > 64) {
        return httpIntentError("service.effect_grant_invalid", "read-only contributions must be a bounded explicit list")
    }
    let names = ArrayList<String>()
    for (item in value.items) {
        if (item.unifiedKind != ValueKind.Text || !channelIntentIdentifier(item.text) ||
            item.text.size > 128 || names.contains(item.text)) {
            return httpIntentError("service.effect_grant_invalid", "read-only contributions must have unique exact local identities")
        }
        names.add(item.text)
    }
    Result.Ok(names.toArray())
}

public func serviceEffectGrantFields(value: AgentValue, required: Array<String>): Bool {
    let fields = ArrayList<String>(required)
    match (value.field("read_only_tools")) {
        case Some(tools) =>
            if (parseServiceReadOnlyTools(tools).isError()) { return false }
            fields.add("read_only_tools")
        case None => ()
    }
    if (value.field("protocol_limits").isSome()) {
        if (serviceProtocolLimits(value).isError()) { return false }; fields.add("protocol_limits")
    }
    if (value.field("payload_limits").isSome()) {
        if (servicePayloadLimits(value).isError()) { return false }; fields.add("payload_limits")
    }
    httpIntentExactFields(value, fields.toArray())
}

public func serviceGrantDeclaresReadOnly(grant: AgentValue, localName: String): Bool {
    match (grant.field("read_only_tools")) {
        case Some(tools) => match (parseServiceReadOnlyTools(tools)) {
            case Result.Ok(names) => names.contains(localName)
            case Result.Err(_) => false
        }
        case None => false
    }
}

public func serviceEffectBindingFields(binding: AgentValue, required: Array<String>): Bool {
    let fields = ArrayList<String>(required)
    match (binding.field("read_only_tool")) {
        case Some(name) =>
            if (name.unifiedKind != ValueKind.Text || !channelIntentIdentifier(name.text) || name.text.size > 128) { return false }
            fields.add("read_only_tool")
        case None => ()
    }
    if (binding.field("protocol_limits").isSome()) {
        if (serviceProtocolLimits(binding).isError()) { return false }; fields.add("protocol_limits")
    }
    if (binding.field("payload_limits").isSome()) {
        if (servicePayloadLimits(binding).isError()) { return false }; fields.add("payload_limits")
    }
    httpIntentExactFields(binding, fields.toArray())
}

public func serviceParentEffectAllowed(parent: NormalizedOperationPlan): Bool {
    if (parent.retryDisposition != OperationRetryDisposition.Never ||
        match (parent.replayDisposition) { case ReplayDisposition.NeverReplay => false; case _ => true }) { return false }
    let host = match (parent.canonicalArguments.field("host_plan")) { case Some(value) => value; case None => return false }
    let binding = match (host.field("binding")) { case Some(value) => value; case None => return false }
    match (binding.field("read_only_tool")) {
        case Some(name) =>
            name.unifiedKind == ValueKind.Text && channelIntentIdentifier(name.text) && name.text.size <= 128 &&
                parent.effectClass == OperationEffectClass.ReadOnly && parent.toolName.endsWith("." + name.text)
        case None => parent.effectClass == OperationEffectClass.ExternalMutation
    }
}

// Call only with the grant reconstructed from its actual Completed maintenance
// Operation/Receipt/ToolResult. A plugin's alleged grant is never sufficient.
public func serviceReadOnlyGrantAllows(grant: AgentValue, binding: AgentValue, parent: NormalizedOperationPlan): Bool {
    if (!serviceParentEffectAllowed(parent) || !sameServiceProtocolLimits(grant, binding) || !sameServicePayloadLimits(grant, binding)) { return false }
    match (binding.field("read_only_tool")) {
        case None => parent.effectClass == OperationEffectClass.ExternalMutation
        case Some(name) =>
            name.unifiedKind == ValueKind.Text && serviceGrantDeclaresReadOnly(grant, name.text) &&
                parent.effectClass == OperationEffectClass.ReadOnly &&
                parent.toolName == "plugin." + httpIntentText(grant, "namespace") + ".service." +
                    httpIntentText(grant, "service_id") + "." + name.text
    }
}
