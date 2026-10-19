package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// Not public, serializable, returned to IPC, or a separate authority registry.
// Every guard belongs to one actual prepared invocation held by its executor.
type ProductPluginDocumentGuard = agent_host_runtime.HostPluginDocumentGuard

func openProductPluginDocumentGuard(identity: ProductPluginServiceIdentity, context: ToolInvocationContext,
    prepared: PreparedToolInvocation): Result<ProductPluginDocumentGuard> {
    agent_host_runtime.hostOpenPluginDocumentGuard(identity, context, prepared)
}
