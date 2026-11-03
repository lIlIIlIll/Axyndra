package agent_core

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*

func nestedSlotTestControl(): CoreRunControl {
    let runtime = AgentThreadRuntime(ThreadCoordinator(ThreadId("slot-unit"), "fixture", InMemoryThreadCommitSink()),
        ContextProjector("slot-unit", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
    CoreRunControl(RunId("slot-unit"), ResourceBudget(maxConcurrentTools: 1, maxToolCalls: 2), runtime)
}

// Counter interleavings complement the real Core/Direct execution contracts.
// They do not assert that descriptive IDs grant any Tool execution authority.
@Test
class NestedToolSlotTests {
    @TestCase
    func parentReturnDuringYieldRetainsTheInFlightTransition(): Unit {
        for (restore in [false, true]) {
            let control = nestedSlotTestControl(); let operation = OperationId("parent")
            control.reserve(BudgetCharge(toolsStarted: 1)).value().getOrThrow()
            control.registerScheduledToolSlot(operation, "plugin.fixture").value().getOrThrow()
            control.beginNestedToolSlot(operation).value().getOrThrow()
            @Expect(control.unregisterScheduledToolSlot(operation), false)
            @Expect(control.ledger.snapshot().activeTools, 1)
            control.ledger.releaseTools().value().getOrThrow()
            control.reserve(BudgetCharge(toolsStarted: 1)).value().getOrThrow()
            let outcome = if (restore) { control.restoreYieldedToolSlot(operation) }
                else { control.activateNestedToolSlot(operation) }
            @Expect(outcome.isError(), true)
            @Expect(outcome.error().getOrThrow().code, "run.tool_parent_finished")
            @Expect(control.ledger.snapshot().activeTools, 0)
        }
    }

    @TestCase
    func activeChildAloneMayReleaseItsPendingParentSlot(): Unit {
        let control = nestedSlotTestControl(); let operation = OperationId("parent")
        control.reserve(BudgetCharge(toolsStarted: 1)).value().getOrThrow()
        control.registerScheduledToolSlot(operation, "plugin.fixture").value().getOrThrow()
        control.beginNestedToolSlot(operation).value().getOrThrow()
        control.ledger.releaseTools().value().getOrThrow()
        control.reserve(BudgetCharge(toolsStarted: 1)).value().getOrThrow()
        control.activateNestedToolSlot(operation).value().getOrThrow()
        @Expect(control.unregisterScheduledToolSlot(operation), false)
        @Expect(control.ledger.snapshot().activeTools, 1)
        @Expect(control.reserve(BudgetCharge(toolsStarted: 1)).isError(), true)
        @Expect(control.returnNestedToolSlot(operation).isOk(), true)
        @Expect(control.ledger.snapshot().activeTools, 0)
        @Expect(control.returnNestedToolSlot(operation).isError(), true)
        @Expect(control.ledger.snapshot().activeTools, 0)
    }
}
