package agent_core

import agent_domain.*
import logical_json_payload.LogicalJsonCopiedDisplayAllocation as ImportedLogicalJsonCopiedDisplayAllocation
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*
import yjson.JsonNode

// These actual-bank/alias controls use a clearly data-only repository, not
// SQLite, Source, approval, effect or physical-ACK evidence.
private class OwnedToolStartObserved {
    var reads: Int64 = 0
    var stages: Int64 = 0
    var appends: Int64 = 0
    var deliveries: Int64 = 0
    var bytes: Int64 = 0
    var display = ""
    var copy: ?LogicalJsonCopiedDisplayAllocation = None
}
private func ownedToolStartRoot(pool: LogicalJsonOwnerBudget): OwnedCanonicalThreadItemCustody {
    let owner = pool.acquire(1)
    try {
        owner.ensureRetainedPeak(67108864)
        let payload = String.fromUtf8(Array<Byte>(3145728, repeat: b'a')) + "\u{0}雪🙂"
        let input = objectValue([ValueField("payload", textValue(payload)), ValueField("label", textValue("full\u{0}雪🙂"))])
        OwnedCanonicalThreadItemCustody(ThreadItem(ItemId("start-item"), ThreadId("start-thread"),
            SemanticTurnId("start-turn"), 1, ThreadItemContent.ToolCall(CanonicalToolCallId("start-call"), "start.tool", input),
            ItemProvenance("system")), owner)
    } catch (error: Exception) { owner.close(); throw error }
}
private class OwnedToolStartRead <: CoreOwnedCanonicalItemRead {
    private let pool: LogicalJsonOwnerBudget
    private let seen: OwnedToolStartObserved
    init(pool: LogicalJsonOwnerBudget, seen: OwnedToolStartObserved) { this.pool = pool; this.seen = seen }
    public func visit(guard: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit> {
        match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        var root: ?OwnedCanonicalThreadItemCustody = None
        try {
            root = Some(ownedToolStartRoot(pool)); seen.reads++
            let actual = root.getOrThrow()
            actual.withItem({ item => consume(item, actual) })
        } catch (_: Exception) { coreOwnedCanonicalDeliveryError("fixture.original_input_pressure") }
        finally { match (root) { case Some(actual) => let _ = actual.closeAfterConsumption(); case None => () } }
    }
}
private class OwnedToolStartWrite <: OwnedRunEventWrite {
    private let witness: OwnedCanonicalThreadItemRetirementWitness
    private var paid: ?LogicalJsonOwnerReservation
    private let seen: OwnedToolStartObserved
    private var closed = false
    init(witness: OwnedCanonicalThreadItemRetirementWitness, paid: LogicalJsonOwnerReservation, seen: OwnedToolStartObserved) {
        this.witness = witness; this.paid = Some(paid); this.seen = seen
    }
    public func appendAfterSourceAliasRetirement(): Result<Unit> {
        @Expect(witness.isItemRetired(), true)
        if (!witness.isItemRetired() || seen.appends != 0) { return coreOwnedCanonicalDeliveryError("fixture.real_input_retirement_required") }
        seen.appends++; Result.Ok(())
    }
    public func closeAfterStorageRetirement(): Result<Unit> {
        if (!closed) { paid.getOrThrow().close(); paid = None; closed = true }
        Result.Ok(())
    }
    public func isAcknowledged(): Bool { closed }
}
private class OwnedToolStartRepository <: OwnedRunEventRepository {
    private let seen: OwnedToolStartObserved
    init(seen: OwnedToolStartObserved) { this.seen = seen }
    public func stageOwned(event: OwnedAgentEvent): Result<OwnedRunEventWrite> {
        seen.stages++
        let witness = event.retirementWitness().value().getOrThrow()
        let paid = event.deriveRetainedAllocation(65536).value().getOrThrow()
        let result = event.withEvent(65536, { actual =>
            @Expect(actual.kind, AgentEventKind.Tool)
            @Expect(actual.meta.sequence, 17)
            @Expect(actual.meta.runId.value, "start-run")
            @Expect(actual.detail.field("code").getOrThrow().text, "tool.execution_started")
            @Expect(actual.detail.field("call_id").getOrThrow().text, "start-call")
            @Expect(actual.detail.field("name").getOrThrow().text, "start.tool")
            let input = actual.detail.field("arguments").getOrThrow()
            @Expect(input.field("payload").getOrThrow().text.size > 3145728, true)
            @Expect(input.field("payload").getOrThrow().text.endsWith("\u{0}雪🙂"), true)
            writeOwnedAgentValue(input, { chunk => seen.bytes += chunk.size; Result.Ok(()) }, { => Result.Ok(()) }) })
        if (result.isError()) { paid.close(); return Result.Err(result.error().getOrThrow()) }
        match (event.closeAfterEventRetirement()) { case Result.Err(error) => paid.close(); return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(OwnedToolStartWrite(witness, paid, seen))
    }
}
private class OwnedToolStartSink <: OwnedAgentEventSink {
    private let seen: OwnedToolStartObserved
    init(seen: OwnedToolStartObserved) { this.seen = seen }
    public func emit(event: OwnedAgentEvent): Result<Unit> {
        @Expect(seen.appends, 1); seen.deliveries++
        seen.copy = Some(event.acquireCopiedDisplayAllocation(65536).value().getOrThrow())
        match (event.withEvent(65536, { actual =>
            @Expect(actual.meta.sequence, 17)
            @Expect(actual.detail.field("arguments").getOrThrow().field("payload").getOrThrow().text.size > 3145728, true)
            seen.display = String.fromUtf8(actual.detail.field("arguments").getOrThrow().field("label").getOrThrow().text.toArray())
            Result.Ok(()) })) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        event.closeAfterEventRetirement()
    }
}
private func ownedToolStartDelivery(pool: LogicalJsonOwnerBudget, seen: OwnedToolStartObserved): CoreOwnedCanonicalEventDelivery {
    CoreOwnedCanonicalEventDelivery(OwnedToolStartRead(pool, seen), { => Result.Ok(()) },
        OwnedToolStartRepository(seen), OwnedToolStartSink(seen), EventMeta(17, TraceId("start-trace"), RunId("start-run")),
        CoreOwnedToolCallPayloadFactory("start.tool", ToolCallId("start-call"), ItemId("start-item")))
}

@Test
class OwnedCanonicalToolStartTests {
    @TestCase
    func WholeOriginalArgumentsStageBeforeDeliveryAndCopiedCardOutlivesOnlyActualRow(): Unit {
        let pool = LogicalJsonOwnerBudget(); let seen = OwnedToolStartObserved()
        let delivery = ownedToolStartDelivery(pool, seen)
        @Expect(delivery.run().isOk(), true)
        @Expect(delivery.isAcknowledged(), true)
        @Expect(seen.reads, 2); @Expect(seen.stages, 1); @Expect(seen.appends, 1); @Expect(seen.deliveries, 1)
        @Expect(seen.bytes > 3145728, true)
        @Expect(pool.usage()[1], 74240)
        @Expect(seen.copy.getOrThrow().withCopiedDisplayBorrow({ => @Expect(seen.display, "full\u{0}雪🙂"); Result.Ok(()) }).isOk(), true)
        @Expect(delivery.run().isOk(), false); @Expect(seen.deliveries, 1); @Expect(seen.appends, 1)
        seen.display = ""
        @Expect(seen.copy.getOrThrow().closeAfterCopiedDisplayRetirement().isOk(), true)
        seen.copy = None
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func OriginalPressureStopsBeforeWholeInputAllocationAndCannotReplayTheStart(): Unit {
        let pool = LogicalJsonOwnerBudget()
        let pressure = [pool.acquire(1), pool.acquire(1), pool.acquire(1), pool.acquire(1), pool.acquire(1), pool.acquire(1), pool.acquire(1)]
        let seen = OwnedToolStartObserved(); let delivery = ownedToolStartDelivery(pool, seen)
        @Expect(delivery.run().isOk(), false)
        @Expect(seen.reads, 0); @Expect(seen.stages, 0); @Expect(seen.appends, 0); @Expect(seen.deliveries, 0)
        @Expect(pool.usage()[1], 117440512)
        @Expect(delivery.run().isOk(), false)
        @Expect(delivery.closeAfterFailure().isOk(), true)
        for (owner in pressure) { owner.close() }
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}
