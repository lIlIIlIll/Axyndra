package agent_product

import agent_domain.*

// Called only after the Native physical process and stream helpers returned.
// None is the original non-mediated policy, not an inferred lost gateway.
func releaseDirectOwnedNetwork180(value:?DirectNetworkLease):Result<Unit>{
    match(value){case Some(actual)=>actual.gateway.release(actual.lease)
        case None=>Result<Unit>.Ok(())}
}
