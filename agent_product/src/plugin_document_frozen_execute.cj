package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// v2 execution only consumes Host-frozen intents and complete result bytes.
// No pure worker cache or business algorithm is consulted after approval.
func executeFrozenProductDocument(host:ProductJavaScriptPluginHost,namespace:String,tool:String,generation:UInt64,
    context:ToolInvocationContext,prepared:PreparedToolInvocation,observer:ProductJavaScriptPluginInvocationObserver):Result<ToolResult> {
    agent_host_runtime.hostExecuteFrozenDocument(host, namespace, tool, generation, context, prepared, observer)
}
