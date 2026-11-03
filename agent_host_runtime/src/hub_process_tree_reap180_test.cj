package agent_host_runtime

import agent_extension_runtime.reserveNativeControlMetadata
import agent_domain.LogicalJsonOwnerReservation as TreeReapTestOwner180
import process4cj.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ActualPartialNativeTreeReap180Tests {
    @TestCase
    func actualExecFailureReturnsOnlyAfterSubreaperReceiptAndParentReap180():Unit{
        let owner=reserveNativeControlMetadata(1048576)
        // This helper owns every native/error/carrier reference. It actually
        // returns before the outer original-pool owner is closed.
        try{actualPartialExecReapHelper180(owner)}finally{owner.close()}
    }
}

private func actualPartialExecReapHelper180(owner:TreeReapTestOwner180):Unit{
    owner.ensureRetainedPeak(2097152)
    let actual=ProcessNativeStartCustody180()
    let receipt=actual.failedStartReceiptBeforeEffect180()
    var refused=false
    try{
        let _=actual.start180(ProcessCommand("/proc/self/axyndra-executable-not-present180",
            terminateProcessTree:true),{bytes=>owner.ensureRetainedPeak(2097152+bytes)})
    }catch(_:ProcessError){refused=true}
    @Expect(refused)
    // This exercises the ORIGINAL real exec handshake failure, not a fake
    // failed-start marker or hand-seeded OS journal. The raw cleanup must
    // receive actual ECHILD and parent waitpid before either scalar is true.
    @Expect(receipt.resourcesReturned180())
    @Expect(actual.nativeFailedResourcesReturned180())
    @Expect(actual.clearAfterActualResources180())
}
