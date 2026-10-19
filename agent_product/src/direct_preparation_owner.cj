package agent_product

import agent_domain.*
import agent_host_runtime

// Source compatibility only. The actual waiting owner and scheduler live in
// the shared canonical host package; Product keeps no second approval state.
type ProductDirectPreparationOwner = agent_host_runtime.HostDirectPreparationOwner
type ProductTrustedControlToolExecutor = agent_host_runtime.HostTrustedControlToolExecutor

func directPreparationError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, code, "Direct preparation requires its retained actual user owner"))
}
