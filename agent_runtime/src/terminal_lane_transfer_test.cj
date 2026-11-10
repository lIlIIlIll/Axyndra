package agent_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

private func terminalLaneSnapshotProducer230(owner: OwnedToolSetSnapshot159): Unit {
    owner.installSnapshot159(ToolSetSnapshot("terminal-lane-canary", []))
}
private func terminalLaneCanary230(lane: ModelLane): Bool {
    lane.providerId == "provider-canary" && lane.modelId == "model-canary" &&
        lane.contextWindow == 1000 && lane.role == ModelLaneRole.Main
}

// Public Runtime transitions with an actual owned lane and an exhausted
// allocation group. The ephemeral commit sink supplies no SQLite/Source or
// external-service acceptance. No test-created return witness or refund exists.
private func terminalLanePressure230(terminal: RunState, cancel: Bool): Unit {
    let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
    let root = bank.acquire(131072)
    let data = root.deriveRetainedLease(); data.ensureRetainedPeak(131072)
    let producer = OwnedToolSetSnapshot159(data)
    terminalLaneSnapshotProducer230(producer); producer.returnedSnapshotProducer159()
    let shared = producer.transferSharedSnapshot159()
    let lane = modelLaneWithSharedToolSet159(ModelLaneRole.Main, "provider-canary", "model-canary", "responses",
        ModelLaneCapabilitiesSnapshot(), 1000, 100, 20, "estimator", "retry", "cache", shared, "system")
    let coordinator = ThreadCoordinator(ThreadId("terminal-lane-pressure"), "workspace", InMemoryThreadCommitSink())
    let runtime = AgentThreadRuntime(coordinator,
        ContextProjector("terminal-lane", ConservativeThreadTokenEstimator()), { => 10 })
    let run = RunId("terminal-lane-run")
    let initial = runtime.startTurn(SemanticTurnId("terminal-lane-turn"), run,
        ItemId("terminal-lane-user"), ThreadItemContent.UserMessage(textMessageParts("input")),
        lane, InvocationContextProjection()).value().getOrThrow()
    let pressure = root.deriveRetainedLease()
    var settled: ?RuntimeSettlement = None<RuntimeSettlement>
    try {
        let measured = root.retainedCustodyUsage113()
        pressure.ensureRetainedPeak(measured[1] - measured[0])
        let full = root.retainedCustodyUsage113()
        @Assert(full[0] == full[1]); @Assert(bank.usage()[1] == bank.capacity())
        // A stale caller cannot detach this live Runtime lane, even under
        // pressure. The same exact owner must still settle afterward.
        let stale = runtime.finish(RunState.Failed, 1000, expectedRunId: Some(RunId("stale-run")))
        @Expect(stale.isError()); @Expect(terminalLaneCanary230(initial.lane))
        let result = if (cancel) {
            runtime.cancel(1000, reason: Some(CancellationReason(CancellationReasonKind.User, "fixture.cancel", "cancel",
                cancelledAtMillis: 10)), expectedRunId: Some(run), expectedEpoch: Some(initial.epoch))
        } else {
            runtime.finish(terminal, 1000, expectedRunId: Some(run), expectedEpoch: Some(initial.epoch))
        }
        @Assert(result.isOk())
        let actual = result.value().getOrThrow(); settled = Some(actual)
        @Expect(actual.run.state, if (cancel) { RunState.Cancelled } else { terminal })
        @Expect(runtime.activeRunControl159().isNone())
        @Expect(coordinator.snapshot().thread.activeTurnId.isNone())
        @Expect(bank.usage()[1], bank.capacity())
        @Expect(terminalLaneCanary230(actual.run.lane))
        @Expect(terminalLaneCanary230(initial.lane))
        actual.run.returnOwnedLaneView159(); settled = None<RuntimeSettlement>
        // Returning the terminal consumer cannot retire the earlier view or
        // caller's independently prepaid lane metadata.
        @Expect(terminalLaneCanary230(initial.lane)); @Expect(terminalLaneCanary230(lane))
        var closed = false
        try { let _ = terminalLaneCanary230(actual.run.lane) }
        catch (_: IllegalStateException) { closed = true }
        @Expect(closed)
    } finally {
        pressure.close()
        match (settled) { case Some(value) => value.run.returnOwnedLaneView159(); case None => () }
        if (runtime.activeRunControl159().isSome()) {
            let cleanup = runtime.finish(RunState.Failed, 1000)
            match (cleanup) { case Result.Ok(value) => value.run.returnOwnedLaneView159(); case Result.Err(_) => () }
        }
        initial.returnOwnedLaneView159(); lane.returnOwnedLaneFrame159(); shared.close159(); root.close()
    }
}

@Test
class TerminalLaneTransfer230Tests {
    @TestCase
    func CompletedFailedAndRecoverySettlementDoNotAllocateAnotherLaneUnderPressure(): Unit {
        for (terminal in [RunState.Completed, RunState.Failed, RunState.RecoveryRequired]) {
            terminalLanePressure230(terminal, false)
        }
    }
    @TestCase
    func CancellationSettlementKeepsBothActualOutwardConsumersIndependent(): Unit {
        terminalLanePressure230(RunState.Cancelled, true)
    }
}
