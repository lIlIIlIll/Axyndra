package agent_product

import agent_host_runtime
import agent_domain.*

// The trusted callers borrow the existing shared byte filter implementation.
type ProductHttpOutputByte = agent_host_runtime.HostOutputByte
type ProductHttpOutputDecoder = agent_host_runtime.HostOutputDecoder
type ProductHttpExchangeOutputGate = agent_host_runtime.HostTransportOutputGate

func httpOutputHex(value: Byte): Int64 { agent_host_runtime.hostOutputHex(value) }
func httpOutputUtf8(value: Int64): Array<Byte> { agent_host_runtime.hostOutputUtf8(value) }
