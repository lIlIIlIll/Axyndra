package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import agent_extension_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

func registerPluginDocumentService(catalog: ToolCatalog): Result<Unit> {
    agent_host_runtime.hostRegisterPluginDocumentService(catalog)
}

type ProductPluginDocumentExecutor = agent_host_runtime.HostPluginDocumentExecutor

func documentChildContext(root: PreparedToolInvocation, context: ToolInvocationContext): ToolInvocationContext {
    agent_host_runtime.hostDocumentChildContext(root, context)
}

func executeProductPluginDocument(catalog: ToolCatalog, pipeline: ToolPipeline, operations: OperationRuntimePort,
    identity: ProductPluginServiceIdentity, context: ToolInvocationContext, root: PreparedToolInvocation,
    invocationId: String, requestId: String, arguments: AgentValue): JavaScriptHostResult<String> {
    agent_host_runtime.hostExecutePluginDocument(catalog, pipeline, operations, identity, context, root, invocationId, requestId, arguments)
}

func failProductDocumentChild(operations: OperationRuntimePort, context: ToolInvocationContext,
    root: PreparedToolInvocation, child: PreparedToolInvocation, error: AgentError): JavaScriptHostResult<String> {
    agent_host_runtime.hostFailDocumentChild(operations, context, root, child, error)
}
