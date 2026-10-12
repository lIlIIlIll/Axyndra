package agent_product

import agent_domain.*
import agent_host_runtime
import agent_host_runtime.*

type ProductProcessChannelQueue = HostProcessChannelQueue
type ProductProcessChannel = HostNativeProcessChannel

func channelError(code: String, message: String): AgentError {
    agent_host_runtime.hostNativeChannelError(code, message)
}
