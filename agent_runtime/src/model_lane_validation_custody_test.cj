package agent_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private class LaneValidationRecordingSink233 <: ThreadCommitSink {
    private let delegate = InMemoryThreadCommitSink()
    var captured: ?RunModelLaneChange = None<RunModelLaneChange>
    public func commit(transition: ThreadTransition): Result<Unit> {
        if (transition.modelLaneChange.isSome()) { captured = transition.modelLaneChange }
        delegate.commit(transition)
    }
    public func recordOperationReceipt(runId: RunId, receipt: VNextOperationReceipt): Result<Unit> {
        delegate.recordOperationReceipt(runId, receipt)
    }
    public func recordRunTransition(threadId: ThreadId, turnId: SemanticTurnId, runId: RunId,
        epoch: Int64, transition: RunTransition, observedAtMillis: Int64): Result<Unit> {
        delegate.recordRunTransition(threadId, turnId, runId, epoch, transition, observedAtMillis)
    }
    public func recordModelUsage(sample: RunModelUsageSample): Result<Unit> { delegate.recordModelUsage(sample) }
}
private func validationSnapshotProducer233(owner: OwnedToolSetSnapshot159, version: String, thread: ThreadId): Unit {
    let schema = objectValue([])
    owner.installSnapshot159(ToolSetSnapshot("validation-" + version,
        [ToolSnapshotEntry("fixture.read", version, schema, version, [],
            implementationFingerprint: "fixture-" + version,
            schemaDigest: modelPolicySha256Text(canonicalAgentValue(schema)))], threadId: Some(thread)))
}
private func validationSnapshot233(root: LogicalJsonOwnerReservation, version: String,
    thread: ThreadId): SharedToolSetSnapshot159 {
    let data = root.deriveRetainedLease(); data.ensureRetainedPeak(131072)
    let producer = OwnedToolSetSnapshot159(data)
    validationSnapshotProducer233(producer, version, thread); producer.returnedSnapshotProducer159()
    producer.transferSharedSnapshot159()
}

@Test
class ModelLaneValidationCustody233Tests {
    @TestCase
    func ClosedRevalidationReusesItsPaidScratchWhileEscapedCopiesRemainCharged(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 150994944)
        let root = bank.acquire(131072)
        let thread = ThreadId("validation-thread")
        let first = validationSnapshot233(root, "first", thread)
        let second = validationSnapshot233(root, "second", thread)
        let lane = modelLaneWithSharedToolSet159(ModelLaneRole.Main, "provider", "model", "responses",
            ModelLaneCapabilitiesSnapshot(), 1000, 100, 20, "estimator", "retry", "cache", first, "system")
        let sink = LaneValidationRecordingSink233()
        let runtime = AgentThreadRuntime(ThreadCoordinator(thread, "workspace", sink),
            ContextProjector("validation", ConservativeThreadTokenEstimator()), { => 10 })
        let run = RunId("validation-run")
        let initial = runtime.startTurn(SemanticTurnId("validation-turn"), run, ItemId("validation-user"),
            ThreadItemContent.UserMessage(textMessageParts("input")), lane,
            InvocationContextProjection()).value().getOrThrow()
        var updated: ?ActiveRunSnapshot = None<ActiveRunSnapshot>
        try {
            let result = runtime.replaceOwnedToolSetAtSafeCut159(run, initial.epoch, initial.lane, second)
            @Assert(result.isOk()); updated = Some(result.value().getOrThrow())
            let change = sink.captured.getOrThrow()
            let paid = root.retainedCustodyUsage113()[0]
            for (_ in 0..4) { validateModelLaneChange(change, thread) }
            @Expect(root.retainedCustodyUsage113()[0], paid)
            var rejected = false
            try { validateModelLaneChange(change, ThreadId("wrong-thread")) }
            catch (_: IllegalArgumentException) { rejected = true }
            @Expect(rejected); @Expect(root.retainedCustodyUsage113()[0], paid)
            // A returned graph can escape and mutate. Its original public
            // getter must still reserve another complete, retained copy.
            let escaped = change.nextLane()
            @Expect(escaped.toolSet.id, "validation-second")
            @Assert(root.retainedCustodyUsage113()[0] > paid)
            let withCopy = root.retainedCustodyUsage113()[0]
            escaped.toolSet.entries[0] = change.previousLane().toolSet.entries[0]
            validateModelLaneChange(change, thread)
            @Assert(root.retainedCustodyUsage113()[0] > withCopy)
            @Expect(updated.getOrThrow().lane.toolSet.id, "validation-second")
        } finally {
            let terminal = runtime.finish(RunState.Failed, 1000)
            match (terminal) { case Result.Ok(value) => value.run.returnOwnedLaneView159(); case Result.Err(_) => () }
            match (updated) { case Some(value) => value.returnOwnedLaneView159(); case None => () }
            initial.returnOwnedLaneView159(); lane.returnOwnedLaneFrame159()
            first.close159(); second.close159(); root.close()
            // This ordinary sink provides no SQL consumption receipt. The
            // actual cut custody stays conservatively retained, without a fake ACK.
        }
    }
}
