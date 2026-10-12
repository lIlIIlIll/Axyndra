package agent_domain

import yjson.*
import yjson_support.*

// Data only. This separate schema contains no effect intent, child, Source,
// execution admission or Receipt. The actual Host must bind it to the current
// installed Provider and original selected invocation before canonical use.
public let PLUGIN_PREPARED_COMPLETION152 = "axyndra.frozen-data-completion/v1"

public func pluginPreparedCompletionArgumentsValid152(arguments: AgentValue): Bool {
    try {
        if (!httpIntentExactFields(arguments, ["input", "configuration", "host_plan"]) ||
            arguments.field("input").getOrThrow().unifiedKind != ValueKind.Object ||
            arguments.field("configuration").getOrThrow().unifiedKind != ValueKind.Object) { return false }
        let host = arguments.field("host_plan").getOrThrow()
        if (!(httpIntentExactFields(host, ["version", "binding", "permission", "completion"]) ||
            httpIntentExactFields(host, ["version", "binding", "permission", "completion", "invocation_capability"])) ||
            httpIntentText(host, "version") != PLUGIN_PREPARED_COMPLETION152 ||
            validatePluginDocumentBinding(host.field("binding").getOrThrow()).isError() ||
            !pluginPrimitiveService111(httpIntentText(host, "permission")) ||
            !pluginPrimitiveInvocationSelection111(host, httpIntentText(host, "permission"))) { return false }
        let completion = host.field("completion").getOrThrow()
        httpIntentExactFields(completion, ["output", "is_error"]) &&
            completion.field("is_error").getOrThrow().unifiedKind == ValueKind.Boolean
    } catch (_: Exception) { false }
}

public func isFrozenPluginPreparedCompletion152(plan: NormalizedOperationPlan): Bool {
    if (!pluginPreparedCompletionArgumentsValid152(plan.canonicalArguments)) { return false }
    try {
        let host = plan.canonicalArguments.field("host_plan").getOrThrow()
        let binding = host.field("binding").getOrThrow()
        let permission = httpIntentText(host, "permission")
        if (plan.toolName != httpIntentText(binding, "contribution") ||
            plan.implementation.implementationFingerprint != httpIntentText(binding, "implementation_fingerprint") ||
            plan.implementation.schemaDigest != httpIntentText(binding, "schema_digest") ||
            plan.effectClass != OperationEffectClass.ReadOnly ||
            plan.retryDisposition != OperationRetryDisposition.Never || plan.idempotencyKey != "" ||
            !networkPolicyModeIsDenied(plan.networkPolicy.mode) || !plan.networkPolicy.egress.isEmpty() ||
            !plan.networkPolicy.publish.isEmpty() || !plan.resolvedPaths.isEmpty() || !plan.resolvedHosts.isEmpty() ||
            !plan.relevantEnvironment.isEmpty() || !plan.contextReadFacts.isEmpty()) { return false }
        let invoke = pluginPrimitiveInvocationName111(plan.canonicalArguments)
        let effect = pluginPrimitiveRequiredCapability111(permission)
        if (invoke == "extension.invoke") {
            if (plan.requiredCapabilities.size != 2) { return false }
            var selected = false; var original = false
            for (cap in plan.requiredCapabilities) {
                if (cap.kind == CapabilityKind.ExtensionInvoke && cap.resource == httpIntentText(binding, "namespace") && !selected) { selected = true }
                else if (cap.kind == effect && cap.resource == "" && !original) { original = true }
                else { return false }
            }
            if (!selected || !original) { return false }
        } else if (plan.requiredCapabilities.size != 1 || plan.requiredCapabilities[0].kind != effect ||
            plan.requiredCapabilities[0].resource != "") { return false }
        match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }
    } catch (_: Exception) { false }
}

public func pluginPrimitiveArgumentsEffect152(arguments: AgentValue): OperationEffectClass {
    if (pluginPreparedCompletionArgumentsValid152(arguments)) { OperationEffectClass.ReadOnly }
    else { pluginPrimitiveEffect111(pluginPrimitiveArgumentsService111(arguments)) }
}
