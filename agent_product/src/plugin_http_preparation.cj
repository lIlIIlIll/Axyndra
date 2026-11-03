package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// No provider names, endpoint defaults or environment discovery belong here.
// The native executable computes pure request data; the operator configuration
// and the normal ToolPipeline supply every grant and approval.
func preparePluginHttpInvocation(
    host: ProductJavaScriptPluginHost,
    settingsRoot: String,
    namespace: String,
    tool: String,
    generation: UInt64,
    context: ToolInvocationContext,
    call: ToolCall
): Result<AgentValue> {
    agent_host_runtime.hostPreparePluginHttpInvocation(host, settingsRoot, namespace, tool, generation, context, call)
}

func pluginHttpRootNetworkPolicy(call: ToolCall, namespace: String, packageDigest: String): Result<NetworkPolicy> {
    agent_host_runtime.hostPluginHttpRootNetworkPolicy(call, namespace, packageDigest)
}
