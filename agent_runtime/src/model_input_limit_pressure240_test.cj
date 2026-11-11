package agent_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

private func inputLimitPressureSnapshot240(owner: OwnedToolSetSnapshot159): Unit {
    owner.installSnapshot159(ToolSetSnapshot("input-limit-pressure", []))
}

@Test
class ModelInputLimitPressure240Tests {
    @TestCase
    func scalarQueryNeedsNoNewLaneOrLeaseAtTheOriginalFullBank(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let root = bank.acquire(131072)
        let data = root.deriveRetainedLease(); data.ensureRetainedPeak(131072)
        let source = OwnedToolSetSnapshot159(data)
        inputLimitPressureSnapshot240(source); source.returnedSnapshotProducer159()
        let shared = source.transferSharedSnapshot159()
        let lane = modelLaneWithSharedToolSet159(ModelLaneRole.Main, "provider", "model", "responses",
            ModelLaneCapabilitiesSnapshot(), 1000, 100, 20, "estimator", "retry", "cache", shared, "system")
        let runtime = AgentThreadRuntime(
            ThreadCoordinator(ThreadId("input-limit-pressure"), "workspace", InMemoryThreadCommitSink()),
            ContextProjector("input-limit-pressure", ConservativeThreadTokenEstimator()), { => 10 })
        @Expect(runtime.activeModelInputLimit240(), 0)
        let initial = runtime.startTurn(SemanticTurnId("input-limit-turn"), RunId("input-limit-run"),
            ItemId("input-limit-user"), ThreadItemContent.UserMessage(textMessageParts("input")),
            lane, InvocationContextProjection()).value().getOrThrow()
        let pressure = root.deriveRetainedLease()
        try {
            let usage = root.retainedCustodyUsage113()
            pressure.ensureRetainedPeak(usage[1] - usage[0])
            let before = root.retainedCustodyUsage113()
            @Assert(bank.usage()[1], bank.capacity())
            for (_ in 0..100) { @Expect(runtime.activeModelInputLimit240(), 880) }
            let after = root.retainedCustodyUsage113()
            @Expect(after[0], before[0]); @Expect(after[1], before[1]); @Expect(after[2], before[2])
        } finally {
            pressure.close()
            match (runtime.finish(RunState.Completed, 1000)) {
                case Result.Ok(value) => value.run.returnOwnedLaneView159()
                case Result.Err(error) => throw IllegalStateException(error.describe()) }
            @Expect(runtime.activeModelInputLimit240(), 0)
            initial.returnOwnedLaneView159(); lane.returnOwnedLaneFrame159(); shared.close159(); root.close()
        }
        // The historical InMemory sink still owns its original DATA. No bank
        // zero, SQL receipt, Source or external-task return is invented here.
    }
}
