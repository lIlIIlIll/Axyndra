package agent_product

import agent_host_runtime
import agent_host_runtime.*

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.deriving.*
import std.fs.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

let PLUGIN_LIFECYCLE_TOOL = agent_host_runtime.HOST_PLUGIN_LIFECYCLE_TOOL

type ProductPluginLifecycleOwner = agent_host_runtime.HostPluginLifecycleOwner

type ProductPluginLifecycleLease = agent_host_runtime.HostPluginLifecycleLease

func lifecycleLeaseError<T>(code: String): Result<T> { agent_host_runtime.hostLifecycleLeaseError<T>(code) }

func lifecycleNonReplayableLaunchPlan(plan: NormalizedOperationPlan): Bool { agent_host_runtime.hostLifecycleNonReplayableLaunchPlan(plan) }

func validateLifecycleStartupReceipt(database: SqliteDatabase, context: ToolInvocationContext,
    prepared: PreparedToolInvocation, grant: ProductPluginLifecycleLaunchGrant, summaryText: String): Result<Unit> { agent_host_runtime.hostValidateLifecycleStartupReceipt(database, context, prepared, grant, summaryText) }

func lifecycleWritePreparedChunks(bytes: Array<Byte>, write: (Array<Byte>) -> Result<Unit>,
    validate: () -> Result<Unit>): Result<Unit> { agent_host_runtime.hostLifecycleWritePreparedChunks(bytes, write, validate) }

func lifecycleIoCancelled<T>(): Result<T> { agent_host_runtime.hostLifecycleIoCancelled<T>() }

