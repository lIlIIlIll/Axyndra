package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// No provider names, endpoint defaults or environment discovery belong here.
// The native executable computes pure request data; the operator configuration
// and the normal ToolPipeline supply every grant and approval.
public func hostPreparePluginHttpInvocation(
    host: HostJavaScriptPluginHost,
    settingsRoot: String,
    namespace: String,
    tool: String,
    generation: UInt64,
    context: ToolInvocationContext,
    call: ToolCall
): Result<AgentValue> {
    let descriptor = match (host.servicePackageData81(namespace, generation)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (descriptor.entryKind != PluginEntryKind.NativeExecutable ||
        !descriptor.requestedCapabilities.contains("network.http")) {
        return hostPluginResourceError("plugin.http_not_requested", "native plugin has not declared the HTTP preparation protocol")
    }
    let configuration = match (loadHostPluginHttpConfiguration(settingsRoot, namespace, descriptor.contentDigest)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let arguments = objectValue([
        ValueField("input", call.arguments),
        ValueField("configuration", configuration.configuration)
    ])
    let identity = JavaScriptHostInvocationIdentity(
        threadId: context.sessionId.value, runId: context.runId.value,
        epoch: context.epoch, operationId: "", callId: call.callId, kind: "prepare"
    )
    let result = match (host.invoke(namespace, tool, stringifyUnifiedJson(arguments),
        identity: identity, cancellation: context.cancellation,
        processLimits: context.budget.processLimits, timeoutMillis: 5000,
        expectedInstanceGeneration: generation,
        authorityScope: "pure-prepare:" + configuration.digest)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (result.isError) {
        return Result.Err(AgentError(AgentErrorKind.InvalidInput,
            "plugin.prepare_rejected", "plugin could not prepare the requested invocation"))
    }
    let intents = match (configuration.bindIntents(result.value)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    match (configuration.stillCurrent()) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(_) => ()
    }
    Result.Ok(objectValue([
        ValueField("input", call.arguments),
        ValueField("configuration", configuration.configuration),
        ValueField("host_plan", objectValue([
            ValueField("version", textValue(HOST_HTTP_INTENT_VERSION)),
            ValueField("plugin", textValue(namespace)),
            ValueField("package_digest", textValue(descriptor.contentDigest)),
            ValueField("generation", textValue(generation.toString())),
            ValueField("configuration_digest", textValue(configuration.digest)),
            ValueField("intents", listValue(intents))
        ]))
    ]))
}
