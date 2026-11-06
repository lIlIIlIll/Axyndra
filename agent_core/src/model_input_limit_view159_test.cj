package agent_core

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*

private func inputLimitSnapshotProducer159(owner: OwnedToolSetSnapshot159): Unit {
    owner.installSnapshot159(ToolSetSnapshot("input-limit-tools", []))
}
private func inputLimitStartFrame159(runtime: AgentThreadRuntime, lane: ModelLane): Result<ActiveRunSnapshot> {
    runtime.startTurn(SemanticTurnId("input-limit-turn"), RunId("input-limit-run"),
        ItemId("input-limit-user"), ThreadItemContent.UserMessage([ThreadMessagePart.Text("hello")]),
        lane, InvocationContextProjection())
}
private func inputLimitObserveFrame159(runtime: AgentThreadRuntime): Bool {
    for (_ in 0..100) {
        if (coreActiveModelInputLimit159(runtime) != 7040) { return false }
    }
    true
}

@Test
class ModelInputLimitView159Tests {
    @TestCase
    func scalarReadsReturnEveryActualLaneShare(): Unit {
        let bank = LogicalJsonOwnerBudget()
        let root = bank.acquire(131072)
        let source = root.deriveRetainedLease()
        source.ensureRetainedPeak(131072)
        let producer = OwnedToolSetSnapshot159(source)
        inputLimitSnapshotProducer159(producer)
        producer.returnedSnapshotProducer159()
        let shared = producer.transferSharedSnapshot159()
        let lane = modelLaneWithSharedToolSet159(ModelLaneRole.Main, "fixture", "fixture", "fixture",
            ModelLaneCapabilitiesSnapshot(), 8192, 1024, 128,
            "conservative-v1", "never", "default", shared, "system-v1")
        let runtime = AgentThreadRuntime(
            ThreadCoordinator(ThreadId("input-limit-thread"), "fixture", InMemoryThreadCommitSink()),
            ContextProjector("input-limit-thread", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
        @Expect(coreActiveModelInputLimit159(runtime), 0)
        let started = inputLimitStartFrame159(runtime, lane)
        @Expect(started.isOk(), true)
        started.value().getOrThrow().returnOwnedLaneView159()
        // The real InMemory sink is a historical consumer: its exported data
        // deliberately stays paid. This assertion checks only the additional
        // live leases made by the scalar observer, not a fabricated Store ACK.
        let before = root.retainedCustodyUsage113()
        @Expect(inputLimitObserveFrame159(runtime), true)
        let after = root.retainedCustodyUsage113()
        @Expect(after[0], before[0])
        @Expect(after[2], before[2])
        let _ = runtime.finish(RunState.Completed, 1000)
        lane.returnOwnedLaneFrame159()
        shared.close159()
        root.close()
    }
}
