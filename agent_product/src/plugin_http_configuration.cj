package agent_product

import agent_host_runtime.*
import agent_domain.*
import yjson_support.*

let PLUGIN_HTTP_CONFIGURATION_MAX_BYTES: Int64 = HOST_PLUGIN_HTTP_CONFIGURATION_MAX_BYTES
let PLUGIN_HTTP_SECRET_MAX_BYTES: Int64 = HOST_PLUGIN_HTTP_SECRET_MAX_BYTES

type ProductPluginHttpCredentialValue = HostPluginHttpCredentialValue
type PluginHttpCredentialBinding = HostPluginHttpCredentialBinding
type PluginHttpRequestGrant = HostPluginHttpRequestGrant
type ProductPluginHttpConfiguration = HostPluginHttpConfiguration

func loadPluginHttpConfiguration(settingsRoot: String, namespace: String, packageDigest: String): Result<ProductPluginHttpConfiguration> {
    loadHostPluginHttpConfiguration(settingsRoot, namespace, packageDigest)
}

func parsePluginHttpCredentials(value: AgentValue): Result<Array<PluginHttpCredentialBinding>> {
    parseHostPluginHttpCredentials(value)
}

func pluginHttpHeaderPrefixValid(value: String): Bool {
    hostPluginHttpHeaderPrefixValid(value)
}

func parsePluginHttpRequests(value: AgentValue, credentials: Array<PluginHttpCredentialBinding>): Result<Array<PluginHttpRequestGrant>> {
    parseHostPluginHttpRequests(value, credentials)
}

func pluginHttpStringList(value: AgentValue, maximum: Int64): Result<Array<String>> {
    hostPluginHttpStringList(value, maximum)
}

func pluginHttpJsonPointerField(pointer: String): Result<String> {
    hostPluginHttpJsonPointerField(pointer)
}

func pluginHttpNamespace(value: String): Bool {
    hostPluginHttpNamespace(value)
}

func pluginHttpPackageDigest(value: String): Bool {
    hostPluginHttpPackageDigest(value)
}

func pluginHttpEnvironmentName(value: String): Bool {
    hostPluginHttpEnvironmentName(value)
}

func pluginHttpRelativePath(value: String): Bool {
    hostPluginHttpRelativePath(value)
}

func pluginHttpCredentialFile(settingsRoot: String, relative: String): Result<String> {
    hostPluginHttpCredentialFile(settingsRoot, relative)
}

func pluginHttpSafeFile(settingsRoot: String, relative: String, code: String): Result<String> {
    hostPluginHttpSafeFile(settingsRoot, relative, code)
}

func readPluginHttpConfiguration(settingsRoot: String): Result<String> {
    readHostPluginHttpConfiguration(settingsRoot)
}

func readPluginHttpBoundedText(path: String, maximum: Int64): Result<String> {
    readHostPluginHttpBoundedText(path, maximum)
}

func pluginHttpConfigError<T>(code: String, message: String): Result<T> {
    hostPluginHttpConfigError<T>(code, message)
}

func pluginReadViewConfigurationFields(value: AgentValue): Bool {
    hostPluginReadViewConfigurationFields(value)
}
