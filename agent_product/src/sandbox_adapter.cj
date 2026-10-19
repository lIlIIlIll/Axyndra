package agent_product

import agent_domain.*
import agent_host_runtime.*
import sandbox4cj.*
import std.collection.*

// sandbox4cj is deliberately independent from the Agent domain.  This is the
// single product boundary that translates its mechanical enforcement errors
// into runtime errors; callers must not reinterpret sandbox failures.
func sandboxAgentError(error: SandboxError): AgentError { hostSandboxAgentError(error) }
