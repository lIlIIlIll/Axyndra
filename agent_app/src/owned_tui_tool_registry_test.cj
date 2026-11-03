package agent_app

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import agent_tui.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OwnedTuiRegistryTests {
    @TestCase
    func ActualFailedLinkedNodeKeepsIndependentMetadataPaidAfterCopiedPayloadClears(): Unit {
        let pool = LogicalJsonOwnerBudget(); let original = pool.acquire(1)
        let registryPayment = original.acquireCopiedDisplayAllocation(4096).value().getOrThrow()
        let copiedPayment = original.acquireCopiedDisplayAllocation(65536).value().getOrThrow()
        let node = OwnedTuiDisplayRegistration(registryPayment)
        let copied = OwnedTuiToolDisplay(copiedPayment, 65536)
        node.install(copied)
        @Expect(copied.installCopiedEvent(TuiAgentEvent.ToolStarted("generic", "copied")).isOk(), true)
        node.clearFailedDisplayReference()
        @Expect(copied.closeAfterCopiedDisplayRetirement().isOk(), true)
        original.close()
        @Expect(node.metadataIsAcknowledged(), false)
        @Expect(pool.usage()[1] > 4096 && pool.usage()[1] < 16384, true)
        // This source control intentionally retains its actual empty node;
        // callback/error/GC must not refund registry metadata by inference.
    }
}
