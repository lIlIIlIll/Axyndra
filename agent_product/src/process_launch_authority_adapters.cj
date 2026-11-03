package agent_product

import agent_domain.*
import agent_host_runtime.*
import model_provider_runtime.*
import sandbox4cj.*
import yjson_support.*
import yjson.*


func productModelProcessLaunchAuthority(): HostModelProcessLaunchAuthority {
    let authority: HostModelProcessLaunchAuthority = ProductModelProcessLaunchAuthority()
    authority
}

// Product composition selects these private adapters. Neither the adapters nor
// their concrete borrowed bindings are registered as plugin/SDK contributions.








// Only the original actual gate and dispatch are retained. A matching copy of
// the descriptive dispatch still fails the gate's refEq/canonical/Runtime check.
class ProductModelProcessLaunchClaim <: HostModelProcessLaunchClaim {
    private let dispatch: ModelProviderDispatch
    private let gate: ProductModelProviderDispatchGate
    init(dispatch: ModelProviderDispatch, gate: ProductModelProviderDispatchGate) {
        this.dispatch = dispatch; this.gate = gate
    }
    func verify(owner: ProcessResourceOwner): Result<Unit> { gate.verifyProcessOwner(dispatch, owner) }
    func cancellation(): CancellationToken { dispatch.cancellation }
}

class ProductModelProcessLaunchAuthority <: HostModelProcessLaunchAuthority {
    public func verify(claim: HostModelProcessLaunchClaim, owner: ProcessResourceOwner): Result<Unit> {
        match (claim as ProductModelProcessLaunchClaim) {
            case Some(actual) => actual.verify(owner)
            case None => hostVerifyInstalledModelProcessClaim(claim, owner)
        }
    }
    public func cancellation(claim: HostModelProcessLaunchClaim): Result<CancellationToken> {
        match (claim as ProductModelProcessLaunchClaim) {
            case Some(actual) => Result.Ok(actual.cancellation())
            case None => hostInstalledModelProcessClaimCancellation(claim)
        }
    }
}
