package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import agent_ports.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.math.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

func validatePluginReadViewParent(host: ProductJavaScriptPluginHost, settingsRoot: String,
    parent: NormalizedOperationPlan, namespace: String, tool: String, generation: UInt64): Result<AgentValue> {
    agent_host_runtime.hostValidatePluginReadViewParent(host, settingsRoot, parent, namespace, tool, generation)
}

func registerPluginReadViewService(catalog: ToolCatalog, host: ProductJavaScriptPluginHost,
    operations: OperationRuntimePort, settingsRoot: String, processes: ProcessPort): Result<Unit> {
    agent_host_runtime.hostRegisterPluginReadViewService(catalog, host, operations, settingsRoot, processes)
}

type ProductReadViewCleanup = agent_host_runtime.HostReadViewCleanup

type PluginReadViewExecutor = agent_host_runtime.HostPluginReadViewExecutor
