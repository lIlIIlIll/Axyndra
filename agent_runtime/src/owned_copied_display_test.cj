package agent_runtime

import agent_domain.*
import logical_json_payload.LogicalJsonCopiedDisplayAllocation as ImportedLogicalJsonCopiedDisplayAllocation
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private class OwnedCopiedDisplayValue {
    var text = ""
    var entered = false
}

private func copiedDisplayActualEvent(pool: LogicalJsonOwnerBudget): OwnedAgentEvent {
    let payment = pool.acquire(1); payment.ensureRetainedPeak(67108864)
    var root: ?OwnedCanonicalThreadItemCustody = None
    try {
        let whole = String.fromUtf8(Array<Byte>(1048576, repeat: 0u8)) + "雪🙂\n"
        root = Some(OwnedCanonicalThreadItemCustody(ThreadItem(ItemId("copy-item"), ThreadId("copy-thread"),
            SemanticTurnId("copy-turn"), 1, ThreadItemContent.SystemNote(whole), ItemProvenance("system")), payment))
        let alias = root.getOrThrow().retainAliasCustody().value().getOrThrow()
        let event = OwnedAgentEvent(EventMeta(1, TraceId("copy-trace"), RunId("copy-run")),
            { item => match (item.content) {
                case ThreadItemContent.SystemNote(value) => AgentEventPayload.Extension(AgentEventKind.Tool,
                    objectValue([ValueField("output", textValue(value)), ValueField("preview", textValue("actual\u{0}雪🙂"))]))
                case _ => throw IllegalStateException("complete actual item missing") } }, alias)
        if (root.getOrThrow().closeAfterConsumption().isError()) { throw IllegalStateException("root borrow pending") }
        root = None; event
    } catch (error: Exception) {
        match (root) { case Some(actual) => let _ = actual.closeAfterConsumption(); case None => payment.close() }
        throw error
    }
}

@Test
class OwnedCopiedDisplayTests {
    @TestCase
    func RealEventCopyAndCachePaySimultaneouslyThenReleaseOnlyTheActualRow(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = copiedDisplayActualEvent(pool)
        let copy = event.acquireCopiedDisplayAllocation(196608).value().getOrThrow()
        let cache = copy.retainCopiedDisplayAllocation().value().getOrThrow()
        let display = OwnedCopiedDisplayValue()
        @Expect(event.withEvent(65536, { actual =>
            display.text = String.fromUtf8(actual.detail.field("preview").getOrThrow().text.toArray())
            @Expect(actual.detail.field("output").getOrThrow().text.size > 1048576, true)
            @Expect(event.closeAfterEventRetirement().isOk(), false)
            Result.Ok(()) }).isOk(), true)
        @Expect(pool.usage()[1] > 67108864 + 205824, true)
        @Expect(event.closeAfterEventRetirement().isOk(), true)
        @Expect(event.acquireCopiedDisplayAllocation(1024).isOk(), false)
        @Expect(pool.usage()[1], 205824 + 1024)
        @Expect(copy.closeAfterCopiedDisplayRetirement().isOk(), true)
        @Expect(cache.withCopiedDisplayBorrow({ =>
            @Expect(display.text, "actual\u{0}雪🙂")
            Result.Ok(()) }).isOk(), true)
        // Copied data survives only under the cache's real independent ticket.
        display.text = ""
        @Expect(cache.closeAfterCopiedDisplayRetirement().isOk(), true)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func OriginalBankPressureBlocksDisplayConstructionBeforeTheCopyCallback(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = copiedDisplayActualEvent(pool)
        let pressure = [pool.acquire(1), pool.acquire(1), pool.acquire(1)]
        let observed = OwnedCopiedDisplayValue(); let before = pool.usage()
        @Expect(event.acquireCopiedDisplayAllocation(16777216).isOk(), false)
        @Expect(observed.entered, false)
        let after = pool.usage()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
        for (actual in pressure) { actual.close() }
        let copy = event.acquireCopiedDisplayAllocation(73728).value().getOrThrow()
        @Expect(event.withEvent(65536, { actual =>
            observed.entered = true
            observed.text = String.fromUtf8(actual.detail.field("preview").getOrThrow().text.toArray())
            Result.Ok(()) }).isOk(), true)
        @Expect(observed.entered, true)
        @Expect(event.closeAfterEventRetirement().isOk(), true)
        @Expect(pool.usage()[1] > 73728 && pool.usage()[1] < 16777216, true)
        observed.text = ""
        @Expect(copy.closeAfterCopiedDisplayRetirement().isOk(), true)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}
