package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// Classification inputs only. Capabilities, approval, exact read witnesses,
// canonical Operations and Receipts remain at their existing boundaries.
type ProductContextReadScopes = agent_host_runtime.HostContextReadScopes

func productContextReadPermission(host: ProductJavaScriptPluginHost, scopes: ?ProductContextReadScopes,
    source: String, ordinary: String): String {
    agent_host_runtime.hostContextReadPermission(host, scopes, source, ordinary)
}

type ProductContextReadScopeConfiguration = agent_host_runtime.HostContextReadScopeConfiguration

func productContextReadScopeConfiguration(settingsRoot: String): Result<ProductContextReadScopeConfiguration> {
    agent_host_runtime.hostContextReadScopeConfiguration(settingsRoot)
}

func loadProductContextReadScopes(host: ProductJavaScriptPluginHost, settingsRoot: String,
    components: ?ProductContextComponentSnapshot): Result<ProductContextReadScopes> {
    agent_host_runtime.hostLoadContextReadScopes(host, settingsRoot, components)
}
