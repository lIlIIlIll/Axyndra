package agent_core

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.JsonNode
import yjson_support.*

// Actual original-pool/alias consumer controls. The repository below is a
// data-only transport test adapter, not SQLite/Source/Receipt evidence. The
// actual fixed-FD SQLite staged writer is tested in agent_persistence.
private class OwnedDeliveryObservation {
    var reads: Int64 = 0
    var stages: Int64 = 0
    var appends: Int64 = 0
    var closes: Int64 = 0
    var deliveries: Int64 = 0
    var bytes: Int64 = 0
}
private func ownedDeliveryRoot(pool: LogicalJsonOwnerBudget): OwnedCanonicalThreadItemCustody {
    let paid = pool.acquire(1)
    try {
        paid.ensureRetainedPeak(67108864)
        let output = textValue(String.fromUtf8(Array<Byte>(3145728, repeat: b'r')) + "\u{0}雪🙂")
        OwnedCanonicalThreadItemCustody(ThreadItem(ItemId("delivery-item"), ThreadId("delivery-thread"),
            SemanticTurnId("delivery-turn"), 1, ThreadItemContent.ToolResult(CanonicalToolCallId("delivery-call"),
                OperationId("delivery-operation"), "receipt-delivery-operation", output, false),
            ItemProvenance("system", operationId: Some(OperationId("delivery-operation")))), paid)
    } catch (error: Exception) { paid.close(); throw error }
}
private class OwnedDeliveryRead <: CoreOwnedCanonicalItemRead {
    private let pool: LogicalJsonOwnerBudget
    private let seen: OwnedDeliveryObservation
    init(pool: LogicalJsonOwnerBudget, seen: OwnedDeliveryObservation) { this.pool = pool; this.seen = seen }
    public func visit(guard: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit> {
        match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        var root: ?OwnedCanonicalThreadItemCustody = None
        try {
            root = Some(ownedDeliveryRoot(pool)); seen.reads++
            let actual = root.getOrThrow()
            actual.withItem({ item => consume(item, actual) })
        } catch (_: Exception) { coreOwnedCanonicalDeliveryError("fixture.actual_pool_pressure") }
        finally { match (root) { case Some(value) => let _ = value.closeAfterConsumption(); case None => () } }
    }
}
private class OwnedDeliveryWrite <: OwnedRunEventWrite {
    private let witness: OwnedCanonicalThreadItemRetirementWitness
    private var allocation: ?LogicalJsonOwnerReservation
    private let seen: OwnedDeliveryObservation
    private let failFirstClose: Bool
    private var acknowledged = false
    init(witness: OwnedCanonicalThreadItemRetirementWitness, allocation: LogicalJsonOwnerReservation,
        seen: OwnedDeliveryObservation, failFirstClose: Bool) {
        this.witness = witness; this.allocation = Some(allocation)
        this.seen = seen; this.failFirstClose = failFirstClose
    }
    public func appendAfterSourceAliasRetirement(): Result<Unit> {
        @Expect(witness.isItemRetired(), true)
        if (!witness.isItemRetired() || allocation.isNone() || acknowledged || seen.appends != 0) {
            return coreOwnedCanonicalDeliveryError("fixture.actual_retirement_required") }
        seen.appends++; Result.Ok(())
    }
    public func closeAfterStorageRetirement(): Result<Unit> {
        if (acknowledged) { return Result.Ok(()) }
        seen.closes++
        if (failFirstClose && seen.closes == 1) {
            return coreOwnedCanonicalDeliveryError("fixture.storage_cleanup_pending") }
        allocation.getOrThrow().close(); allocation = None; acknowledged = true; Result.Ok(())
    }
    public func isAcknowledged(): Bool { acknowledged }
}
private class OwnedDeliveryRepository <: OwnedRunEventRepository {
    private let seen: OwnedDeliveryObservation
    private let failFirstClose: Bool
    init(seen: OwnedDeliveryObservation, failFirstClose!: Bool = false) {
        this.seen = seen; this.failFirstClose = failFirstClose
    }
    public func stageOwned(event: OwnedAgentEvent): Result<OwnedRunEventWrite> {
        seen.stages++
        let witness = event.retirementWitness().value().getOrThrow()
        @Expect(witness.isItemRetired(), false)
        let allocation = event.deriveRetainedAllocation(65536).value().getOrThrow()
        match (event.withEvent(65536, { actual =>
            @Expect(actual.kind, AgentEventKind.Tool)
            @Expect(actual.detail.field("code").getOrThrow().text, "tool.execution_completed")
            @Expect(actual.detail.field("name").getOrThrow().text, "delivery.tool")
            @Expect(actual.detail.field("call_id").getOrThrow().text, "delivery-call")
            @Expect(actual.detail.field("receipt_id").getOrThrow().text, "receipt-delivery-operation")
            @Expect(actual.detail.field("is_error").getOrThrow().boolValue, false)
            let output = actual.detail.field("output").getOrThrow()
            @Expect(output.text.endsWith("\u{0}雪🙂"), true)
            @Expect(output.text.size > 3145728, true)
            writeOwnedAgentValue(output, { chunk => seen.bytes += chunk.size; Result.Ok(()) }, { => Result.Ok(()) })
        })) {
            case Result.Err(error) => allocation.close(); return Result.Err(error)
            case Result.Ok(_) => () }
        match (event.closeAfterEventRetirement()) {
            case Result.Err(error) => allocation.close(); return Result.Err(error)
            case Result.Ok(_) => () }
        @Expect(witness.isItemRetired(), false) // Core still owns the first alias.
        Result.Ok(OwnedDeliveryWrite(witness, allocation, seen, failFirstClose))
    }
}
private class OwnedDeliverySink <: OwnedAgentEventSink {
    private let seen: OwnedDeliveryObservation
    private let acknowledge: Bool
    init(seen: OwnedDeliveryObservation, acknowledge!: Bool = true) { this.seen = seen; this.acknowledge = acknowledge }
    public func emit(event: OwnedAgentEvent): Result<Unit> {
        @Expect(seen.appends, 1); @Expect(seen.closes >= 1, true)
        seen.deliveries++
        let result = event.withEvent(0, { actual =>
            @Expect(actual.detail.field("output").getOrThrow().text.size > 3145728, true)
            @Expect(actual.detail.field("output").getOrThrow().text.endsWith("\u{0}雪🙂"), true)
            Result.Ok(()) })
        if (result.isError()) { return result }
        if (acknowledge) { event.closeAfterEventRetirement() } else { Result.Ok(()) }
    }
}
private func ownedDeliveryCarrier(pool: LogicalJsonOwnerBudget, seen: OwnedDeliveryObservation,
    failFirstClose!: Bool = false, acknowledge!: Bool = true): CoreOwnedCanonicalEventDelivery {
    CoreOwnedCanonicalEventDelivery(OwnedDeliveryRead(pool, seen), { => Result.Ok(()) },
        OwnedDeliveryRepository(seen, failFirstClose: failFirstClose),
        OwnedDeliverySink(seen, acknowledge: acknowledge), EventMeta(1, TraceId("delivery-trace"), RunId("delivery-run")),
        CoreOwnedToolResultPayloadFactory("delivery.tool", ToolCallId("delivery-call"),
            OperationId("delivery-operation"), "receipt-delivery-operation"))
}

@Test
class OwnedCanonicalDeliveryTests {
    @TestCase
    func CompleteEventRetiresFirstRealAliasBeforeAppendThenFreshReadbackDeliversOnce(): Unit {
        let pool = LogicalJsonOwnerBudget(); let seen = OwnedDeliveryObservation()
        let value = ownedDeliveryCarrier(pool, seen)
        @Expect(value.run().isOk(), true); @Expect(value.isAcknowledged(), true)
        @Expect(seen.reads, 2); @Expect(seen.stages, 1); @Expect(seen.appends, 1); @Expect(seen.deliveries, 1)
        @Expect(seen.bytes > 3145728, true)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func StorageCloseFailureKeepsSameRealAllocationAndCannotReplayAppendOrDeliver(): Unit {
        let pool = LogicalJsonOwnerBudget(); let seen = OwnedDeliveryObservation()
        let value = ownedDeliveryCarrier(pool, seen, failFirstClose: true)
        @Expect(value.run().isError(), true); @Expect(value.isAcknowledged(), false)
        @Expect(pool.usage()[1] >= 16777216, true)
        @Expect(value.run().isError(), true)
        @Expect(seen.reads, 1); @Expect(seen.stages, 1); @Expect(seen.appends, 1); @Expect(seen.deliveries, 0)
        @Expect(value.closeAfterFailure().isOk(), true); @Expect(value.isAcknowledged(), true)
        @Expect(seen.appends, 1); @Expect(seen.deliveries, 0)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func ObserverReturnWithoutActualAliasAckRetainsDebtAndDoesNotRepeatDelivery(): Unit {
        let pool = LogicalJsonOwnerBudget(); let seen = OwnedDeliveryObservation()
        let value = ownedDeliveryCarrier(pool, seen, acknowledge: false)
        @Expect(value.run().isError(), true); @Expect(value.isAcknowledged(), false)
        @Expect(pool.usage()[1] >= 16777216, true)
        @Expect(seen.reads, 2); @Expect(seen.deliveries, 1)
        @Expect(value.closeAfterFailure().isOk(), true); @Expect(value.isAcknowledged(), true)
        @Expect(seen.appends, 1); @Expect(seen.deliveries, 1)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func OriginalSevenOwnerPressureRejectsBeforeCompleteResultAllocationOrStaging(): Unit {
        // Same reason as the sibling case: seven owners must reach the
        // saturation point this case asserts, so pin the aggregate.
        let pool = LogicalJsonOwnerBudget(maximumCharged: 134217728); let seen = OwnedDeliveryObservation()
        let pressure = [pool.acquire(1), pool.acquire(1), pool.acquire(1), pool.acquire(1),
            pool.acquire(1), pool.acquire(1), pool.acquire(1)]
        let value = ownedDeliveryCarrier(pool, seen)
        @Expect(value.run().isError(), true)
        @Expect(seen.reads, 0); @Expect(seen.stages, 0); @Expect(seen.appends, 0); @Expect(seen.deliveries, 0)
        @Expect(pool.usage()[0], 7); @Expect(pool.usage()[1], 117440512)
        @Expect(value.closeAfterFailure().isOk(), true)
        for (owner in pressure) { owner.close() }
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}
