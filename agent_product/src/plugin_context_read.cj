package agent_product

import agent_host_runtime
import agent_host_runtime.*

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import yjson.*
import yjson_support.*

func prepareProductContextRead(host: ProductJavaScriptPluginHost, context: ToolInvocationContext,
    call: ToolCall): Result<AgentValue> {
    agent_host_runtime.hostPrepareContextRead(host, context, call)
}

func productContextReadCapabilities(call: ToolCall): Array<Capability> {
    agent_host_runtime.hostContextReadCapabilities(call)
}

func productContextReadApproval(call: ToolCall): ToolApprovalMetadata {
    agent_host_runtime.hostContextReadApproval(call)
}

func registerProductContextRead(catalog: ToolCatalog, host: ProductJavaScriptPluginHost,
    operations: OperationRuntimePort, documentObserver!: ?PluginDocumentReadObserver = None,
    payloadArtifacts!: ?ProductArtifactStore = None): Result<Unit> {
    agent_host_runtime.hostRegisterContextRead(catalog, host, operations, documentObserver: documentObserver, payloadArtifacts: payloadArtifacts)
}
