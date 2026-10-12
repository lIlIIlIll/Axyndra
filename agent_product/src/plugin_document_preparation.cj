package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

func prepareProductDocumentRead(host: ProductJavaScriptPluginHost, context: ToolInvocationContext,
    args: AgentValue): Result<AgentValue> {
    agent_host_runtime.hostPrepareDocumentRead(host, context, args)
}

func documentPreparationCurrent(host: ProductJavaScriptPluginHost, configuration: ProductPluginDocumentConfiguration,
    generation: UInt64, context: ToolInvocationContext, binding: AgentValue): Result<Unit> {
    agent_host_runtime.hostDocumentPreparationCurrent(host, configuration, generation, context, binding)
}

func productDocumentBinding(configuration: ProductPluginDocumentConfiguration, generation: UInt64,
    implementation: String, schemaDigest: String, context: ToolInvocationContext, call: ToolCall, lane: LaneId): AgentValue {
    agent_host_runtime.hostDocumentBinding(configuration, generation, implementation, schemaDigest, context, call, lane)
}

func queryDocumentPreparation(host: ProductJavaScriptPluginHost, namespace: String, localTool: String, generation: UInt64,
    configuration: ProductPluginDocumentConfiguration, context: ToolInvocationContext, call: ToolCall): Result<ProductJavaScriptPluginInvocationResult> {
    agent_host_runtime.hostQueryDocumentPreparation(host, namespace, localTool, generation, configuration, context, call)
}

func preparePluginDocumentRead(host: ProductJavaScriptPluginHost, operations: OperationRuntimePort,
    namespace: String, localTool: String, generation: UInt64, implementation: String, schemaDigest: String,
    context: ToolInvocationContext, call: ToolCall): Result<?ToolPreparationRead> {
    agent_host_runtime.hostPreparePluginDocumentRead(host, operations, namespace, localTool, generation, implementation, schemaDigest, context, call)
}

func canonicalizePluginDocument(host: ProductJavaScriptPluginHost, operations: OperationRuntimePort,
    namespace: String, localTool: String, generation: UInt64, implementation: String, schemaDigest: String,
    context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
    agent_host_runtime.hostCanonicalizePluginDocument(host, operations, namespace, localTool, generation, implementation, schemaDigest, context, call)
}

func reusePreparedPluginDocument(operations: OperationRuntimePort,
    configuration: ProductPluginDocumentConfiguration, localTool: String,
    context: ToolInvocationContext, call: ToolCall, binding: AgentValue,
    envelope: AgentValue): Result<?AgentValue> {
    agent_host_runtime.hostReusePreparedPluginDocument(operations, configuration, localTool, context, call, binding, envelope)
}

func executeProductDocumentRead(host: ProductJavaScriptPluginHost, operations: OperationRuntimePort,
    context: ToolInvocationContext, prepared: PreparedToolInvocation,
    observer: ?PluginDocumentReadObserver, payloadArtifacts!: ?ProductArtifactStore = None,
    retainPayload!: ?(ProductDocumentPayloadReader) -> Unit = None): Result<ToolResult> {
    agent_host_runtime.hostExecuteDocumentRead(host, operations, context, prepared, observer, payloadArtifacts: payloadArtifacts, retainPayload: retainPayload)
}

func queryDocumentPreparationProvider(host: ProductJavaScriptPluginHost, namespace: String, localTool: String,
    provider: String, generation: UInt64, configuration: ProductPluginDocumentConfiguration,
    context: ToolInvocationContext, call: ToolCall): Result<ProductJavaScriptPluginInvocationResult> {
    agent_host_runtime.hostQueryDocumentPreparationProvider(host, namespace, localTool, provider, generation, configuration, context, call)
}
