package agent_product

import agent_host_runtime
import agent_host_runtime.*

import agent_domain.*
import agent_ports.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.process.*
import std.sync.*
import std.time.*

public type LocalNetworkGatewayPort = agent_host_runtime.HostLocalNetworkGatewayPort

public func defaultNetworkGatewayExecutable(): String { agent_host_runtime.hostDefaultNetworkGatewayExecutable() }

