package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// One optional operator section in the existing services.json. It grants only
// exact ordinary contributions; aliases are arbitrary data, not host business.
func validReadonlyDelegationGrants(value: AgentValue): Bool { hostValidReadonlyDelegationGrants(value) }

func preparePluginReadonlyDelegation(host: ProductJavaScriptPluginHost, settingsRoot: String,
    namespace: String, contribution: String, generation: UInt64, context: ToolInvocationContext,
    call: ToolCall): Result<AgentValue> {
    agent_host_runtime.hostPreparePluginReadonlyDelegation(host, settingsRoot, namespace, contribution, generation, context, call)
}

func validatePluginReadonlyDelegation(host: ProductJavaScriptPluginHost, settingsRoot: String,
    namespace: String, contribution: String, generation: UInt64, context: ToolInvocationContext,
    prepared: PreparedToolInvocation): Result<AgentValue> {
    agent_host_runtime.hostValidatePluginReadonlyDelegation(host, settingsRoot, namespace, contribution, generation, context, prepared)
}
