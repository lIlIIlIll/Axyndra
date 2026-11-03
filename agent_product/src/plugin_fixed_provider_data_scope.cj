package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.time.*
import yjson.*
import yjson_support.*

// One logical data query borrows one actual pure Provider connection. The
// caller supplies its original monotonic deadline and source-current checks;
// this class creates no Run, Operation, source authority or second timeout.
type ProductFixedProviderDataScope = agent_host_runtime.HostFixedProviderDataScope
