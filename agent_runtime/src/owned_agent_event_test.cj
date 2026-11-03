package agent_runtime

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

private class OwnedEventCalls { var value: Int64 = 0 }
private class OwnedEventStreamObservation {
    var bytes: Int64 = 0
    var chunks: Int64 = 0
    var maximum: Int64 = 0
    let hash = SHA256()
    func write(value: String): Result<Unit> {
        bytes += value.size; chunks++; maximum = max(maximum, value.size)
        // Each fixed chunk is decoded independently, so a split UTF8 scalar
        // or malformed escaped-output chunk cannot be hidden by concatenation.
        let raw = value.toArray(); hash.write(raw)
        @Expect(String.fromUtf8(raw), value)
        Result.Ok(())
    }
}

private func ownedEventFixture(pool: LogicalJsonOwnerBudget, nul!: Bool = false): OwnedAgentEvent {
    let payment = pool.acquire(1)
    payment.ensureRetainedPeak(16777216)
    var root: ?OwnedCanonicalThreadItemCustody = None
    try {
        let text = String.fromUtf8(Array<Byte>(1048576, repeat: if (nul) { 0u8 } else { b'x' })) + "雪🙂\n"
        root = Some(OwnedCanonicalThreadItemCustody(ThreadItem(ItemId("event-item"), ThreadId("event-thread"),
            SemanticTurnId("event-turn"), 1, ThreadItemContent.SystemNote(text), ItemProvenance("system")), payment))
        let alias = root.getOrThrow().retainAliasCustody().value().getOrThrow()
        let event = OwnedAgentEvent(EventMeta(1, TraceId("event-trace"), RunId("event-run")),
            { item => match (item.content) {
                case ThreadItemContent.SystemNote(value) => AgentEventPayload.Extension(AgentEventKind.Tool,
                    objectValue([ValueField("code", textValue("tool.execution_completed")), ValueField("output", textValue(value))]))
                case _ => throw IllegalStateException("complete original item missing") } }, alias)
        if (root.getOrThrow().closeAfterConsumption().isError()) { throw IllegalStateException("root borrow still active") }
        root = None
        event
    } catch (error: Exception) {
        match (root) { case Some(value) => let _ = value.closeAfterConsumption(); case None => payment.close() }
        throw error
    }
}

@Test
class OwnedAgentEventTests {
    @TestCase
    func RealFanoutRetainsCompleteEventUntilLastExplicitConsumerAcknowledgement(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedEventFixture(pool)
        let second = event.fanout().value().getOrThrow()
        @Expect(event.closeAfterEventRetirement().isOk(), true)
        @Expect(pool.usage()[1] >= 16777216, true)
        @Expect(second.withEvent(1048576, { value =>
            let text = value.detail.field("output").getOrThrow().text
            @Expect(text.size > 1048576 && text.endsWith("雪🙂\n"), true)
            Result.Ok(()) }).isOk(), true)
        @Expect(second.closeAfterEventRetirement().isOk(), true)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func Original128MiBPressureFailsBeforeActualObserverAllocation(): Unit {
        let pool = LogicalJsonOwnerBudget(maximumCharged: 134217728)
        let pressure = [pool.acquire(1), pool.acquire(1), pool.acquire(1), pool.acquire(1)]
        let event = ownedEventFixture(pool); let calls = OwnedEventCalls()
        @Expect(event.withEvent(50331648, { _ => calls.value++; Result.Ok(()) }).isOk(), false)
        @Expect(calls.value, 0); @Expect(event.isAcknowledged(), false)
        @Expect(event.closeAfterEventRetirement().isOk(), true)
        for (owner in pressure) { owner.close() }
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func Product144MiBBankRejectsTenthFloorAndReusesOnlyActualRelease(): Unit {
        let pool = LogicalJsonOwnerBudget()
        let owners = ArrayList<LogicalJsonOwnerReservation>()
        try {
            for (_ in 0..9) { owners.add(pool.acquire(1)) }
            @Expect(pool.usage()[0], 9)
            @Expect(pool.usage()[1], 150994944)
            var refused = false
            try { let extra = pool.acquire(1); extra.close() }
            catch (_: LogicalJsonPayloadError) { refused = true }
            @Expect(refused)
            owners[0].close()
            owners.add(pool.acquire(1))
            owners[0].close()
            @Expect(pool.usage()[0], 9)
            @Expect(pool.usage()[1], 150994944)
            refused = false
            try { let extra = pool.acquire(1); extra.close() }
            catch (_: LogicalJsonPayloadError) { refused = true }
            @Expect(refused)
        } finally { for (owner in owners) { owner.close() } }
        @Expect(pool.usage()[0], 0)
        @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func BorrowedEventCannotAcknowledgeBeforeItsActualFrameReferencesRetire(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedEventFixture(pool)
        @Expect(event.withEvent(1048576, { _ =>
            @Expect(event.closeAfterEventRetirement().isOk(), false)
            @Expect(event.isAcknowledged(), false)
            Result.Ok(()) }).isOk(), true)
        @Expect(event.closeAfterEventRetirement().isOk(), true)
        @Expect(event.fanout().isOk(), false)
        @Expect(event.withEvent(1, { _ => Result.Ok(()) }).isOk(), false)
        @Expect(event.closeAfterEventRetirement().isOk(), true)
        @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func NakedTransportCallbackReturnDoesNotAcknowledgeActualQueuedFrame(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedEventFixture(pool)
        @Expect(event.ensureAdditionalRetainedPeak(1024).isOk(), true)
        let frame = OwnedAgentEventFrame("exact encoded bytes", event)
        @Expect(frame.withFrame({ text => @Expect(text, "exact encoded bytes"); Result.Ok(()) }).isOk(), true)
        @Expect(frame.isAcknowledged(), false); @Expect(event.isAcknowledged(), false)
        @Expect(pool.usage()[1] >= 16777216, true)
        @Expect(frame.closeAfterFrameRetirement().isOk(), true)
        @Expect(frame.isAcknowledged(), true); @Expect(event.isAcknowledged(), true)
        @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func CompleteNulScalarEscapesStreamInFixedAlignedChunksWithoutAggregateCut(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedEventFixture(pool, nul: true)
        let observed = OwnedEventStreamObservation()
        @Expect(event.withEvent(4194304, { value =>
            writeOwnedAgentValue(value.detail.field("output").getOrThrow(), { part => observed.write(part) }, { => Result.Ok(()) })
        }).isOk(), true)
        let expected = SHA256()
        expected.write("\"".toArray())
        let block = String.fromUtf8(Array<Byte>(65536 * 6, { index => "\\u0000"[index % 6] })).toArray()
        for (_ in 0..16) { expected.write(block) }
        expected.write("雪🙂\\n\"".toArray())
        @Expect(logicalJsonEncodeHex(observed.hash.finish()), logicalJsonEncodeHex(expected.finish()))
        @Expect(observed.bytes, 1048576 * 6 + "雪🙂\\n".size + 2)
        @Expect(observed.maximum <= 16384 && observed.chunks > 300, true)
        @Expect(event.closeAfterEventRetirement().isOk(), true); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func StreamMatchesPinnedCompactWriterForFullNestedUnicodeNumbersAndEscapes(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedEventFixture(pool)
        // Small oracle text fits the already-paid event observer envelope.
        let value = objectValue([ValueField("雪\n", listValue([textValue("\u{0}\b\f\t\r\n\"\\/🙂"),
            numberValue("-123.5"), boolValue(true), boolValue(false), nullValue()])), ValueField("empty", objectValue([]))])
        let output = OwnedEventSmallCapture()
        @Expect(event.withEvent(4194304, { _ =>
            writeOwnedAgentValue(value, { part => output.append(part) }, { => Result.Ok(()) }) }).isOk(), true)
        @Expect(output.value, stringifyUnifiedJson(value))
        output.value = ""
        @Expect(event.closeAfterEventRetirement().isOk(), true); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func ActualStreamWriteFailureRemainsUnacknowledgedAndStopsFurtherChunks(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedEventFixture(pool)
        let calls = OwnedEventCalls()
        @Expect(event.withEvent(4194304, { value => writeOwnedAgentValue(value.detail,
            { _ => calls.value++; Result<Unit>.Err(AgentError(AgentErrorKind.Internal, "test.writer_failed", "actual test writer refused")) },
            { => Result.Ok(()) }) }).isOk(), false)
        @Expect(calls.value, 1); @Expect(event.isAcknowledged(), false)
        @Expect(pool.usage()[1] >= 16777216, true)
        @Expect(event.closeAfterEventRetirement().isOk(), true); @Expect(pool.usage()[1], 0)
    }
}

@Test
class OwnedAgentEventDepthTests {
    @TestCase
    func Original256ContainersAllowTheirDepth256ScalarAndMatchCompleteWriter(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedEventFixture(pool)
        let output = OwnedEventSmallCapture()
        try {
            @Expect(event.withEvent(4194304, { _ =>
                let value = ownedEventNestedList(256, nullValue())
                let result = writeOwnedAgentValue(value, { part => output.append(part) }, { => Result.Ok(()) })
                @Expect(result.isOk(), true)
                @Expect(output.value, stringifyUnifiedJson(value))
                result }).isOk(), true)
        } finally { output.value = ""; let _ = event.closeAfterEventRetirement() }
        @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func Original257thEmptyContainerIsRejectedBeforeStreamFinish(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedEventFixture(pool)
        let calls = OwnedEventCalls()
        try {
            @Expect(event.withEvent(4194304, { _ =>
                let value = ownedEventNestedList(256, listValue([]))
                var pinnedRejected = false
                try { let _ = stringifyUnifiedJson(value) }
                catch (_: Exception) { pinnedRejected = true }
                @Expect(pinnedRejected, true)
                writeOwnedAgentValue(value, { _ => calls.value++; Result.Ok(()) }, { => Result.Ok(()) })
            }).isOk(), false)
            @Expect(calls.value, 0); @Expect(event.isAcknowledged(), false)
        } finally { let _ = event.closeAfterEventRetirement() }
        @Expect(pool.usage()[1], 0)
    }
}
private func ownedEventNestedList(containers: Int64, leaf: AgentValue): AgentValue {
    var value = leaf
    for (_ in 0..containers) { value = listValue([value]) }
    value
}

private class OwnedEventSmallCapture {
    var value = ""
    func append(part: String): Result<Unit> { value += part; Result.Ok(()) }
}
