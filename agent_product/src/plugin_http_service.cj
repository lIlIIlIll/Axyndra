package agent_product

import agent_host_runtime
import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

func registerPluginHttpService(catalog: ToolCatalog, host: ProductJavaScriptPluginHost,
    operations: OperationRuntimePort, settingsRoot: String, caBundle: String): Result<Unit> { agent_host_runtime.hostRegisterPluginHttpService(catalog, host, operations, settingsRoot, caBundle) }

func pluginHttpCurlArguments(request: AgentValue, credentials: Array<ProductPluginHttpCredentialValue>): Result<Array<String>> { agent_host_runtime.hostPluginHttpCurlArguments(request, credentials) }

func pluginHttpPercentEncode(value: String): String { agent_host_runtime.hostPluginHttpPercentEncode(value) }

