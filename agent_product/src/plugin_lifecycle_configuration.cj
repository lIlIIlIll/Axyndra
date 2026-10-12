package agent_product

import agent_host_runtime
import agent_host_runtime.*

import agent_domain.*
import std.collection.*
import std.convert.*
import std.fs.*
import stdx.crypto.digest.*
import yjson.*
import yjson_support.*

let PLUGIN_LIFECYCLE_EXECUTABLE_BYTES: Int64 = agent_host_runtime.HOST_PLUGIN_LIFECYCLE_EXECUTABLE_BYTES

let PLUGIN_LIFECYCLE_TRANSPORT_OUTPUT_BYTES: Int64 = agent_host_runtime.HOST_PLUGIN_LIFECYCLE_TRANSPORT_OUTPUT_BYTES

type PluginLifecycleConfigurationFile = agent_host_runtime.HostPluginLifecycleConfigurationFile

type PluginLifecycleExecutable = agent_host_runtime.HostPluginLifecycleExecutable

type ProductPluginLifecycleConfiguration = agent_host_runtime.HostPluginLifecycleConfiguration

type ProductPluginLifecycleLaunchGrant = agent_host_runtime.HostPluginLifecycleLaunchGrant

func loadPluginLifecycleConfiguration(settingsRoot: String, namespace: String,
    packageDigest: String, packageRoot: String): Result<ProductPluginLifecycleConfiguration> { agent_host_runtime.hostLoadPluginLifecycleConfiguration(settingsRoot, namespace, packageDigest, packageRoot) }

func lifecycleExecutable(authored: String, maximumBytes!: Int64 = PLUGIN_LIFECYCLE_EXECUTABLE_BYTES): PluginLifecycleExecutable { agent_host_runtime.hostLifecycleExecutable(authored, maximumBytes: maximumBytes) }

func lifecycleWithin(root: String, path: String): Bool { agent_host_runtime.hostLifecycleWithin(root, path) }

func lifecycleIdentifier(value: String, maximum: Int64): Bool { agent_host_runtime.hostLifecycleIdentifier(value, maximum) }

func lifecycleExact(value: AgentValue, fields: Array<String>): Unit { agent_host_runtime.hostLifecycleExact(value, fields) }

func lifecycleText(value: AgentValue, name: String): String { agent_host_runtime.hostLifecycleText(value, name) }

func lifecycleInt(value: AgentValue, name: String, maximum: Int64): Int64 { agent_host_runtime.hostLifecycleInt(value, name, maximum) }

func lifecycleRequire(condition: Bool): Unit { agent_host_runtime.hostLifecycleRequire(condition) }

func lifecycleRequire(condition: Bool, code: String): Unit { agent_host_runtime.hostLifecycleRequire(condition, code) }

func lifecycleError<T>(code: String, message: String): Result<T> { agent_host_runtime.hostLifecycleError<T>(code, message) }

