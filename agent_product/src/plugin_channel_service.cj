package agent_product

import agent_host_runtime
import agent_host_runtime.*

import agent_domain.*
import agent_runtime.*
import agent_ports.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.sync.*
import yjson.*
import yjson_support.*

type ProductManagedChannelGate = agent_host_runtime.HostManagedChannelGate

func managedChannelReadArguments(args: AgentValue): Result<(ProcessChannelStream, Int64, Int64, String)> { agent_host_runtime.hostManagedChannelReadArguments(args) }

func managedChannelReadResult(value: ProcessChannelRead, encoding!: String = "hex"): JavaScriptHostResult<String> { agent_host_runtime.hostManagedChannelReadResult(value, encoding: encoding) }

type ProductManagedStartupObserver = agent_host_runtime.HostManagedStartupObserver

func managedChannelCallerCancelled(context: ToolInvocationContext): Bool { agent_host_runtime.hostManagedChannelCallerCancelled(context) }

func managedChannelFailure<T>(error: AgentError, wrote: Bool, callerCancelled!: Bool = false, readonlyParent!: Bool = false): Result<T> { agent_host_runtime.hostManagedChannelFailure<T>(error, wrote, callerCancelled: callerCancelled, readonlyParent: readonlyParent) }

func managedChannelTerminal(callId: String, response: ProductJavaScriptPluginInvocationResult,
    wrote: Bool): Result<ToolResult> { agent_host_runtime.hostManagedChannelTerminal(callId, response, wrote) }

