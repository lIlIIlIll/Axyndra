package acp_lifecycle_contract

import agent_domain.*
import agent_rpc.*

// Caller has already prepaid the original fixed 64KiB observation-buffer
// receipt before entering this helper. Its original oracle does not prompt
// or start an ACP worker, so a new outer Future would introduce unnecessary
// scheduler custody. Any genuine server worker still has its original
// actual Future/emit join guard, and can prevent this exact scope retiring.
func runAcpOriginalSynchronousScope113(root: String, closeFailure: Bool): LogicalJsonOwnerReservation {
    let owner = newAcpOwnedWorkerControl113()
    // All path/closure copies in the fixed original oracle are funded before
    // the new carrier or factory/closer callback exists. The actual borrowed
    // UTF8 size is used; no toArray/string copy or physical-floor inference.
    let rootUtf8 = unsafe { root.rawData().size }
    owner.ensureFrontendRegistryMetadata113(65536 + rootUtf8 * 128)
    owner.beginUnsafeFixtureUnitScope113()
    let driver = AcpUnsafeSynchronousScope113(owner)
    driver.runAndDetach113(root, closeFailure)
    // driver/owner/body/helper references all disappear upon THIS return.
    // The caller can only then close the detached original parent receipt.
}

class AcpUnsafeSynchronousScope113 {
    private var control: ?AcpOwnedWorkerControl113
    init(control: AcpOwnedWorkerControl113) { this.control = Some(control) }
    private func originalWholeUnitHelper113(root: String, closeFailure: Bool): Unit {
        let owner = control.getOrThrow()
        if (closeFailure) { runCloseFailureContractUnsafeBody113(root, owner) }
        else { runDurableBindingAndOwnershipUnsafeBody113(root, owner) }
    }
    func runAndDetach113(root: String, closeFailure: Bool): LogicalJsonOwnerReservation {
        originalWholeUnitHelper113(root, closeFailure)
        let owner = control.getOrThrow()
        owner.observeUnsafeFixtureWholeBodyReturn113()
        let detached = owner.detachUnsafeFixtureRootAfterTaskAndAliasReturn113()
        if (detached.isNone()) { throw IllegalStateException("ACP Support retains real cleanup/alias debt") }
        control = None<AcpOwnedWorkerControl113>
        detached.getOrThrow()
    }
}
