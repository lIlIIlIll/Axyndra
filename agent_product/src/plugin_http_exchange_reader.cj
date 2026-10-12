package agent_product

import agent_domain.*
import agent_host_runtime
import agent_host_runtime.*

type ProductHttpExchangeReader = HostHttpExchangeReader

func httpExchangeReadFailure(): AgentError {
    agent_host_runtime.hostHttpExchangeReadFailure()
}
