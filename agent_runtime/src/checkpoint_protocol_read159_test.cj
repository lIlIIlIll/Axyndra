package agent_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

private func checkpointProtocolSnapshotProducer159(owner: OwnedToolSetSnapshot159): Unit {
    owner.installSnapshot159(ToolSetSnapshot("protocol-data-tools", []))
}
private func checkpointProtocolLane159(root: LogicalJsonOwnerReservation): ModelLane {
    let source = root.deriveRetainedLease(); source.ensureRetainedPeak(131072)
    let owner = OwnedToolSetSnapshot159(source)
    checkpointProtocolSnapshotProducer159(owner); owner.returnedSnapshotProducer159()
    let shared = owner.transferSharedSnapshot159()
    try { modelLaneWithSharedToolSet159(ModelLaneRole.Main, "fixture", "fixture", "actual-protocol",
        ModelLaneCapabilitiesSnapshot(), 8192, 1024, 0, "fixture", "fixture", "fixture", shared, "fixture") }
    finally { shared.close159() }
}
private func checkpointProtocolThread159(): AgentThreadSnapshot {
    ThreadCoordinator(ThreadId("protocol-data-thread"), "fixture", InMemoryThreadCommitSink()).snapshot()
}
private class ClosedCheckpointReader159 <: ContextCheckpointRepository & ContextCheckpointProtocolRead159 {
    var captured: ?ContextCheckpointProtocol159 = None
    let fails: Bool
    var matches = false
    init(fails: Bool) { this.fails = fails }
    public func loadLatest(_: AgentThreadSnapshot, _: String, _: String): ?ContextCheckpoint {
        throw IllegalStateException("closed reader must not receive Raw protocol text")
    }
    public func loadLatestMatchingProtocol159(_: AgentThreadSnapshot, _: String,
        protocol: ContextCheckpointProtocol159): ?ContextCheckpoint {
        captured = Some(protocol)
        matches = protocol.matches159("actual-protocol") && !protocol.matches159("other-protocol")
        if (fails) { throw IllegalStateException("fixture closed read failure") }
        None
    }
}
private class RawCheckpointReader159 <: ContextCheckpointRepository {
    var captured = ""
    public func loadLatest(_: AgentThreadSnapshot, _: String, protocol: String): ?ContextCheckpoint {
        captured = protocol; None
    }
}
private func checkpointProtocolReadFrame159(repository: ContextCheckpointRepository, lane: ModelLane): Unit {
    let _ = loadContextCheckpointForLane159(repository, checkpointProtocolThread159(), "fixture", lane)
}

// Protocol matching DATA only. No Run, checkpoint commit, Source or receipt is
// created. The production helper, not this fixture, retires the predicate.
@Test
class CheckpointProtocolRead159Tests {
    @TestCase
    func closedRepositoryGetsOnlyExactComparisonsAndExpiredPredicate(): Unit {
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let lane = checkpointProtocolLane159(root); let reader = ClosedCheckpointReader159(false)
        checkpointProtocolReadFrame159(reader, lane)
        @Expect(reader.matches, true)
        var rejected = false
        try { let _ = reader.captured.getOrThrow().matches159("actual-protocol") }
        catch (_: IllegalStateException) { rejected = true }
        @Expect(rejected, true)
        lane.returnOwnedLaneFrame159(); root.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
    @TestCase
    func throwingClosedReaderCannotRetainProtocolTextThroughItsPredicate(): Unit {
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let lane = checkpointProtocolLane159(root); let reader = ClosedCheckpointReader159(true)
        var failed = false
        try { checkpointProtocolReadFrame159(reader, lane) } catch (_: IllegalStateException) { failed = true }
        @Expect(failed, true); @Expect(reader.matches, true)
        var rejected = false
        try { let _ = reader.captured.getOrThrow().matches159("actual-protocol") }
        catch (_: IllegalStateException) { rejected = true }
        @Expect(rejected, true)
        lane.returnOwnedLaneFrame159(); root.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
    @TestCase
    func compatibilityRepositoryRetainsItsActualRawProtocolAndPayment(): Unit {
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let lane = checkpointProtocolLane159(root); let reader = RawCheckpointReader159()
        checkpointProtocolReadFrame159(reader, lane)
        lane.returnOwnedLaneFrame159(); root.close()
        @Expect(reader.captured, "actual-protocol")
        @Expect(bank.usage()[1] > 0, true)
    }
}
