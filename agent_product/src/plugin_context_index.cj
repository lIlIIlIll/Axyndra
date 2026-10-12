package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// A bounded, metadata-only index. Directory and file witnesses come from
// verified handles; this helper never reads a candidate's content. Selectors
// and document formats remain entirely in the content provider.
type ProductContextIndex = agent_host_runtime.HostContextIndex

func contextIndexRequestValid(value: AgentValue): Bool {
    agent_host_runtime.hostContextIndexRequestValid(value)
}
