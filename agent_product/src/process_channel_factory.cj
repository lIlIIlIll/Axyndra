package agent_product

import agent_domain.*
import agent_host_runtime
import agent_host_runtime.*

func channelFactoryError(kind: AgentErrorKind, code: String, message: String): AgentError {
    agent_host_runtime.hostNativeChannelFactoryError(kind, code, message)
}
