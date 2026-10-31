package agent_product

import agent_host_runtime

import agent_ports.*

import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

let PLUGIN_READONLY_PROCESS_TOOL = agent_host_runtime.PLUGIN_READONLY_PROCESS_TOOL

let PLUGIN_READONLY_PROCESS_OUTPUT_BYTES: Int64 = agent_host_runtime.PLUGIN_READONLY_PROCESS_OUTPUT_BYTES

type ProductPluginServiceIdentity = agent_host_runtime.HostPluginServiceIdentity

func registerPluginReadOnlyProcessService(
    catalog: ToolCatalog,
    host: ProductJavaScriptPluginHost,
    operations: OperationRuntimePort,
    processes: ProcessPort
): Result<Unit> {
    agent_host_runtime.hostRegisterPluginReadOnlyProcessService(catalog, host, operations, processes)
}

type PluginReadOnlyProcessExecutor = agent_host_runtime.HostPluginReadOnlyProcessExecutor

func validatePluginProcessArguments(arguments: AgentValue): Result<Unit> {
    agent_host_runtime.hostValidatePluginProcessArguments(arguments)
}

func pluginProcessTimeout(arguments: AgentValue): Int64 {
    agent_host_runtime.hostPluginProcessTimeout(arguments)
}

func validPluginProcessRelativePath(value: String): Bool {
    agent_host_runtime.hostValidPluginProcessRelativePath(value)
}

func resolvePluginProcessExecutable(root: String, relative: String): Result<String> {
    agent_host_runtime.hostResolvePluginProcessExecutable(root, relative)
}

func pluginProcessLimits(requested: ExecutionResourceLimits): ExecutionResourceLimits {
    agent_host_runtime.hostPluginProcessLimits(requested)
}

func pluginProcessCancellationContext(context: ToolInvocationContext, cancellation: CancellationToken): ToolInvocationContext {
    agent_host_runtime.hostPluginProcessCancellationContext(context, cancellation)
}

func pluginProcessError<T>(code: String, message: String): Result<T> { hostPluginResourceError<T>(code, message) }
