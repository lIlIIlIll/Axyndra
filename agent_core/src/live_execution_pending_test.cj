package agent_core

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*

func ownedResumeTestControl():CoreRunControl {
    let runtime=AgentThreadRuntime(ThreadCoordinator(ThreadId("owned-slot"),"fixture",InMemoryThreadCommitSink()),
        ContextProjector("owned-slot",ConservativeThreadTokenEstimator()),{=>agentUtcMillis()})
    CoreRunControl(RunId("owned-slot"),ResourceBudget(maxConcurrentTools:1,maxToolCalls:1),runtime)
}

// These exercise real shared scheduler accounting, not canonical authority.
// Genuine installed-Kernel parent/child/fault paths remain separate gates.
@Test
class OwnedResumeSlotTests {
    @TestCase
    func waitingThenResumeUsesOneOriginalCallChargeAndStillEnforcesOneSlot():Unit {
        let control=ownedResumeTestControl();let parent=OperationId("actual-parent-slot")
        control.reserve(BudgetCharge(toolCalls:1)).value().getOrThrow()
        let first=coreAcquireOwnedResumeSlot(control,parent,"plugin.fixture").value().getOrThrow()
        @Expect(control.ledger.snapshot().toolCalls,1)
        @Expect(control.ledger.snapshot().activeTools,1)
        @Expect(coreAcquireOwnedResumeSlot(control,OperationId("other"),"plugin.other").isError(),true)
        first.release().value().getOrThrow()
        let resumed=coreAcquireOwnedResumeSlot(control,parent,"plugin.fixture").value().getOrThrow()
        @Expect(control.ledger.snapshot().toolCalls,1)
        @Expect(control.ledger.snapshot().activeTools,1)
        @Expect(control.reserve(BudgetCharge(toolCalls:1)).isError(),true)
        // A repeated old ACK must not release the new activation's slot.
        first.release().value().getOrThrow()
        @Expect(control.ledger.snapshot().activeTools,1)
        resumed.release().value().getOrThrow()
        @Expect(control.ledger.snapshot().activeTools,0)
    }
    @TestCase
    func cancelledWaitingParentCannotReacquireOrSpendAnotherSlot():Unit {
        let control=ownedResumeTestControl();let parent=OperationId("cancelled-parent-slot")
        control.reserve(BudgetCharge(toolCalls:1)).value().getOrThrow()
        let first=coreAcquireOwnedResumeSlot(control,parent,"plugin.fixture").value().getOrThrow()
        first.release().value().getOrThrow()
        let _=control.source.cancel()
        @Expect(coreAcquireOwnedResumeSlot(control,parent,"plugin.fixture").isError(),true)
        @Expect(control.ledger.snapshot().activeTools,0)
        @Expect(control.ledger.snapshot().toolCalls,1)
    }
    @TestCase
    func parentLeaseReturnDuringNestedChildKeepsActualChildDebtAndCapacity():Unit {
        let control=ownedResumeTestControl();let parent=OperationId("nested-owned-parent")
        let first=coreAcquireOwnedResumeSlot(control,parent,"plugin.fixture").value().getOrThrow()
        control.beginNestedToolSlot(parent).value().getOrThrow()
        control.ledger.releaseTools().value().getOrThrow()
        control.reserve(BudgetCharge(toolsStarted:1)).value().getOrThrow()
        control.activateNestedToolSlot(parent).value().getOrThrow()
        first.release().value().getOrThrow()
        @Expect(control.ledger.snapshot().activeTools,1)
        @Expect(coreAcquireOwnedResumeSlot(control,OperationId("other"),"plugin.other").isError(),true)
        control.returnNestedToolSlot(parent).value().getOrThrow()
        @Expect(control.ledger.snapshot().activeTools,0)
        first.release().value().getOrThrow()
        @Expect(control.ledger.snapshot().activeTools,0)
    }
}
