package agent_domain

import yjson.*
import yjson_support.*

// These are the ordinary Domain decoders, not a second policy evaluator. The
// optional SDK resolver cannot supply a raw-data callback. Its typed results
// must not borrow even the String backing of a JSON leaf.
func resolverOutputText(value: String): String { String.fromUtf8(value.toArray()) }
func resolverPolicyOutput(result: Result<NetworkPolicy>): Result<NetworkPolicy> {
    match (result) {
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(policy) =>
            // The decoder allocated the arrays and numeric publish rules. Only
            // text in its egress rules can still refer to a source JSON field.
            for (index in 0..policy.egress.size) {
                let rule = policy.egress[index]
                policy.egress[index] = NetworkEgressRule(resolverOutputText(rule.host), rule.port,
                    privateAddresses: rule.privateAddresses.map { ip => resolverOutputText(ip) })
            }
            Result.Ok(policy)
    }
}
func resolverCapabilityOutput(caps: Array<Capability>): Array<Capability> {
    for (i in 0..caps.size) {
        let cap = caps[i]
        if (!cap.resource.isEmpty()) { caps[i] = Capability(cap.kind, resource: resolverOutputText(cap.resource)) }
    }
    caps
}

public func resolverNetworkPolicy(input: ToolResolverInput, path: Array<ToolResolverStep>): Result<NetworkPolicy> {
    input.projectNode(path, { value => resolverPolicyOutput(parseNetworkPolicy(value)) })
}
public func resolverHttpIntentPolicy(input: ToolResolverInput): Result<NetworkPolicy> {
    input.domainProjection({ call => resolverPolicyOutput(httpIntentPolicy(call.arguments.field("intent").getOrThrow())) })
}
public func resolverHttpStreamPolicy(input: ToolResolverInput): Result<NetworkPolicy> {
    input.domainProjection({ call => resolverPolicyOutput(httpStreamIntentPolicy(call.arguments.field("intent").getOrThrow(),
        binding: call.arguments.field("binding"))) })
}
public func resolverChannelCapabilities(input: ToolResolverInput, managed!: Bool = false): Result<Array<Capability>> {
    input.domainProjection({ call =>
        let binding = call.arguments.field("binding").getOrThrow()
        let required = if (managed) { managedChannelRuntimeRequiredCapabilities(binding) } else { channelServiceRequiredCapabilities(binding) }
        match (required) { case Result.Err(error) => Result<Array<Capability>>.Err(error)
            case Result.Ok(caps) => Result.Ok(resolverCapabilityOutput(caps)) }
    })
}
public func resolverReadViewCapabilities(input: ToolResolverInput): Array<Capability> {
    input.domainProjection({ call => resolverCapabilityOutput(readViewRequiredCapabilities(call.arguments)) })
}
public func resolverPrimitiveService(input: ToolResolverInput): String {
    input.domainProjection({ call => resolverOutputText(pluginPrimitiveArgumentsService111(call.arguments)) })
}
public func resolverPrimitivePermissionEquals(input: ToolResolverInput, permission: String): Bool {
    input.domainProjection({ call => pluginPrimitiveInvocationName111(call.arguments) == permission })
}
public func resolverPrimitiveEffect(input: ToolResolverInput): OperationEffectClass {
    input.domainProjection({ call => pluginPrimitiveArgumentsEffect152(call.arguments) })
}
public func resolverPrimitiveChildEffect(input: ToolResolverInput): OperationEffectClass {
    input.domainProjection({ call => pluginPrimitiveEffect111(pluginPrimitiveArgumentsService111(call.arguments)) })
}
public func resolverPrimitiveChildCapability(input: ToolResolverInput): Capability {
    input.domainProjection({ call => pluginPrimitiveInvocationCapability111(call.arguments,
        resolverOutputText(httpIntentText(call.arguments.field("binding") ?? nullValue(), "namespace"))) })
}
public func resolverPrimitiveAdditional(input: ToolResolverInput): Array<Capability> {
    input.domainProjection({ call => pluginPrimitiveAdditionalCapabilities111(call.arguments) })
}

public func resolverHttpMethodIsGet(input: ToolResolverInput): Bool {
    input.domainProjection({ call => match (call.arguments.field("intent")) {
        case Some(intent) => match (intent.field("request")) { case Some(request) => httpIntentText(request, "method") == "GET"; case None => false }
        case None => false
    } })
}
public func resolverDocumentCapability(input: ToolResolverInput): Capability {
    input.domainProjection({ call => Capability(CapabilityKind.ExtensionInvoke,
        resource: resolverOutputText(httpIntentText(call.arguments.field("binding") ?? nullValue(), "namespace"))) })
}
public func resolverDocumentSideEffect(input: ToolResolverInput): Bool {
    input.domainProjection({ call =>
        if (httpIntentText(call.arguments, "schema") == PLUGIN_DOCUMENT_ROW_JOURNAL_INTENT_SCHEMA) {
            match (parsePluginDocumentRowJournalIntent(call.arguments)) { case Result.Ok(value) => value.append; case Result.Err(_) => true }
        } else { match (parsePluginDocumentIntent(call.arguments)) { case Result.Ok(value) => value.compareExchange; case Result.Err(_) => true } }
    })
}
public func resolverLiveEffectCapability(input: ToolResolverInput): Capability {
    input.domainProjection({ call =>
        if (!pluginLivePolicyStreamingChildValueValid(call.arguments)) {
            throw IllegalArgumentException("strict live child arguments required")
        }
        let effect = call.arguments.field("effect").getOrThrow()
        if (httpIntentText(effect, "kind") == "row_journal.append") {
            Capability(CapabilityKind.ExtensionInvoke,
                resource: resolverOutputText(httpIntentText(call.arguments.field("binding").getOrThrow(), "namespace")))
        } else { Capability(CapabilityKind.WorkspaceWrite, resource: resolverOutputText(httpIntentText(effect, "canonical_path"))) }
    })
}
