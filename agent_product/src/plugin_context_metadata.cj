package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// Metadata only: openat2 O_PATH witnesses and verified directory enumeration.
// No regular-file content is opened here, including at execution revalidation.
func contextReadMetadataEntries(host: ProductJavaScriptPluginHost, context: ToolInvocationContext,
    source: String, witness: String, maximum: Int64, maximumBytes: Int64, scopes!: ?ProductContextReadScopes = None): Result<AgentValue> {
    agent_host_runtime.hostContextReadMetadataEntries(host, context, source, witness, maximum, maximumBytes, scopes: scopes)
}
