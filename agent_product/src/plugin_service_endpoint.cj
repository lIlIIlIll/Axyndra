package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import process4cj as process
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

// Host-only fixed package adapter authorization. This is not a process lease,
// canonical source or broker I/O grant. Each owner supplies its real policy.
type ProductNativeServiceEndpointGrant = agent_host_runtime.HostNativeServiceEndpointGrant

type ProductServiceEndpointSeal = agent_host_runtime.HostServiceEndpointSeal

type ProductServiceEndpointSelection = agent_host_runtime.HostServiceEndpointSelection

func serviceSelectionError(code: String, message: String): ProductServiceEndpointSelection {
    agent_host_runtime.hostServiceSelectionError(code, message)
}

func failedServiceSelection(endpoint: ProductPinnedNativeServiceEndpoint,
    original: AgentError): ProductServiceEndpointSelection {
    agent_host_runtime.hostFailedServiceSelection(endpoint, original)
}

type ProductPinnedNativeServiceEndpoint = agent_host_runtime.HostPinnedNativeServiceEndpoint
