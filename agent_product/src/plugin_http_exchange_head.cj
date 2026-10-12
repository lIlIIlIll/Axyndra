package agent_product

import agent_host_runtime
import agent_host_runtime.*

type ProductHttpExchangeHead = HostHttpExchangeHead
type ProductHttpExchangeHeadParser = HostHttpExchangeHeadParser

func httpExchangeHeaderText(bytes: Array<Byte>): String {
    agent_host_runtime.hostHttpExchangeHeaderText(bytes)
}

func httpExchangeHeaderName(value: String): Bool {
    agent_host_runtime.hostHttpExchangeHeaderName(value)
}
