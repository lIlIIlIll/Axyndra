package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// Native probing reads metadata only. It refuses every symlink, magic link,
// multiply-linked file and non-regular object before content can be opened.

func readViewWitness(path: String): Result<String> { hostReadResourceWitness(path) }

func readViewDirectory(path: String, witness: String): Result<Array<String>> {
    agent_host_runtime.hostReadViewDirectory(path, witness)
}

func readViewCopy(source: String, witness: String, destination: String, maximum: Int64): Result<Int64> {
    hostReadResourceCopy(source, witness, destination, maximum)
}

func readViewHeader(source: String, witness: String, destination: String, maximum: Int64, startMarker: String, endMarker: String, trimASCII: Bool): Result<Int64> {
    agent_host_runtime.hostReadViewHeader(source, witness, destination, maximum, startMarker, endMarker, trimASCII)
}

func readViewCancellation(context: ToolInvocationContext): Result<Unit> {
    agent_host_runtime.hostReadViewCancellation(context)
}

type ProductReadViewCollector = agent_host_runtime.HostReadViewCollector

func preparePluginReadViewInvocation(host: ProductJavaScriptPluginHost, settingsRoot: String,
    namespace: String, tool: String, generation: UInt64, context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
    agent_host_runtime.hostPreparePluginReadViewInvocation(host, settingsRoot, namespace, tool, generation, context, call)
}

func pluginReadViewSideEffect(call: ToolCall): Bool {
    agent_host_runtime.hostPluginReadViewSideEffect(call)
}

func pluginReadViewCapabilities(call: ToolCall): Array<Capability> {
    agent_host_runtime.hostPluginReadViewCapabilities(call)
}

func pluginReadViewApprovalMetadata(call: ToolCall): ToolApprovalMetadata {
    agent_host_runtime.hostPluginReadViewApprovalMetadata(call)
}
