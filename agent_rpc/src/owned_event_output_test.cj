package agent_rpc

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256

private class OwnedRpcTestOutput <: OwnedRpcFrameOutput {
    var frames: Int64 = 0
    var small = ""
    var maximum: Int64 = 0
    var last: ?OwnedRpcOutputFrame = None
    var acknowledge = true
    var fail = false
    let hash = SHA256()
    public func write(frame: OwnedRpcOutputFrame): Result<Unit> {
        frames++; last = Some(frame)
        let result = frame.withFrame({ value =>
            maximum = max(maximum, value.size)
            @Expect(frame.closeAfterFrameRetirement().isOk(), false)
            let decoded = decodeAgentValue(value).value().getOrThrow()
            if (decoded.field("type").getOrThrow().text == "rpc_chunk") {
                @Expect(decoded.field("chunkId").getOrThrow().text, "rpc-owned-test")
                @Expect(decoded.field("index").getOrThrow().asInt64(), frames - 1)
                @Expect(decoded.field("count").getOrThrow().asInt64() > 1, true)
                hash.write(ownedRpcTestBase64(decoded.field("data").getOrThrow().text))
            } else {
                hash.write(value.toArray())
                if (value.size < 4096) { small = value }
            }
            Result.Ok(())
        })
        match (result) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (fail) { return ownedRpcOutputError("test.owned_rpc_write_failed") }
        if (acknowledge) { return frame.closeAfterFrameRetirement() }
        Result.Ok(())
    }
}

private func ownedRpcTestFixture(pool: LogicalJsonOwnerBudget, bytes: Int64, nul: Bool): OwnedAgentEvent {
    let paid = pool.acquire(max(1, bytes))
    paid.ensureRetainedPeak(bytes * 8 + 1048576)
    var root: ?OwnedCanonicalThreadItemCustody = None
    try {
        let text = String.fromUtf8(Array<Byte>(bytes, repeat: if (nul) { 0u8 } else { b'x' })) + "雪🙂"
        root = Some(OwnedCanonicalThreadItemCustody(ThreadItem(ItemId("owned-rpc-item"), ThreadId("owned-rpc-thread"),
            SemanticTurnId("owned-rpc-turn"), 1, ThreadItemContent.SystemNote(text), ItemProvenance("system")), paid))
        let alias = root.getOrThrow().retainAliasCustody().value().getOrThrow()
        let event = OwnedAgentEvent(EventMeta(1, TraceId("owned-rpc-trace"), RunId("owned-rpc-run")),
            { item => match (item.content) {
                case ThreadItemContent.SystemNote(value) => AgentEventPayload.Extension(AgentEventKind.Tool,
                    objectValue([ValueField("code", textValue("tool.execution_completed")), ValueField("output", textValue(value))]))
                case _ => throw IllegalStateException("actual complete original row required") } }, alias)
        @Expect(root.getOrThrow().closeAfterConsumption().isOk(), true); root = None
        event
    } catch (error: Exception) {
        match (root) { case Some(value) => let _ = value.closeAfterConsumption(); case None => paid.close() }
        throw error
    }
}

private func ownedRpcTestBase64(value: String): Array<Byte> {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    let padding: Int64 = if (value.endsWith("==")) { 2 } else if (value.endsWith("=")) { 1 } else { 0 }
    let result = Array<Byte>(value.size / 4 * 3 - padding, repeat: 0)
    var output: Int64 = 0
    for (index in 0..value.size / 4) {
        var bits: UInt32 = 0
        for (part in 0..4) {
            let byte = value[index * 4 + part]
            var code: Int64 = 0
            if (byte != b'=') {
                while (code < 64 && alphabet[code] != byte) { code++ }
                @Expect(code < 64, true)
            }
            bits = (bits << 6) | UInt32(code)
        }
        for (part in 0..3) {
            if (output < result.size) { result[output] = UInt8((bits >> UInt32(16 - part * 8)) & 255); output++ }
        }
    }
    result
}

@Test
class OwnedProductRpcEventOutputTests {
    @TestCase
    func CompleteSmallRawEventMatchesOriginalVocabularyAndOnlyActualFrameAckRetires(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedRpcTestFixture(pool, 8, false)
        let output = OwnedRpcTestOutput(); let delivery = OwnedProductRpcEventDelivery(event, output)
        @Expect(delivery.run(1, { => "rpc-owned-test" }).isOk(), true)
        @Expect(event.isAcknowledged(), false)
        @Expect(output.small, "{\"type\":\"agent_event\",\"sequence\":1,\"runId\":\"owned-rpc-run\",\"event\":{\"code\":\"tool.execution_completed\",\"output\":\"xxxxxxxx雪🙂\"}}")
        @Expect(delivery.closeAfterDeliveryRetirement().isOk(), true)
        @Expect(event.isAcknowledged(), true); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func OriginalV2Base64ChunksReassembleCompleteNulAndUnicodeWithoutLogicalAggregateString(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedRpcTestFixture(pool, 1048576, true)
        let output = OwnedRpcTestOutput(); let delivery = OwnedProductRpcEventDelivery(event, output)
        @Expect(delivery.run(2, { => "rpc-owned-test" }).isOk(), true)
        let expected = SHA256()
        expected.write("{\"type\":\"agent_event\",\"sequence\":1,\"runId\":\"owned-rpc-run\",\"event\":{\"code\":\"tool.execution_completed\",\"output\":\"".toArray())
        let block = String.fromUtf8(Array<Byte>(65536 * 6, { index => "\\u0000"[index % 6] })).toArray()
        for (_ in 0..16) { expected.write(block) }
        expected.write("雪🙂\"}}".toArray())
        @Expect(logicalJsonEncodeHex(output.hash.finish()), logicalJsonEncodeHex(expected.finish()))
        @Expect(output.maximum < 1048576 && output.frames > 20, true)
        @Expect(delivery.closeAfterDeliveryRetirement().isOk(), true)
        @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func OriginalV1OversizeFailureStillHasNoEmptyIdAndFullDataAliasRetiresAfterPhysicalFrameAck(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedRpcTestFixture(pool, 1048576, false)
        let output = OwnedRpcTestOutput(); let delivery = OwnedProductRpcEventDelivery(event, output)
        @Expect(delivery.run(1, { => "rpc-owned-test" }).isOk(), true)
        @Expect(output.small, failure("", "frame", "RPC output exceeds the v1 frame limit; negotiate protocol v2"))
        @Expect(output.frames, 1)
        @Expect(delivery.closeAfterDeliveryRetirement().isOk(), true); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func TypedCallbackReturningOkWithoutActualAckKeepsOriginalAndFramePaidUntilLaterRetirement(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedRpcTestFixture(pool, 8, false)
        let output = OwnedRpcTestOutput(); output.acknowledge = false
        let delivery = OwnedProductRpcEventDelivery(event, output)
        @Expect(delivery.run(2, { => "rpc-owned-test" }).isOk(), false)
        @Expect(delivery.closeAfterDeliveryRetirement().isOk(), false)
        @Expect(event.isAcknowledged(), false); @Expect(pool.usage()[1] > 0, true)
        @Expect(output.last.getOrThrow().closeAfterFrameRetirement().isOk(), true)
        @Expect(delivery.closeAfterDeliveryRetirement().isOk(), true)
        @Expect(output.frames, 1); @Expect(event.isAcknowledged(), true); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func ActualWriteErrorCanBePhysicallyCleanedAfterLaterAckWithoutReplayingOrChangingFailure(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedRpcTestFixture(pool, 8, false)
        let output = OwnedRpcTestOutput(); output.fail = true
        let delivery = OwnedProductRpcEventDelivery(event, output)
        let failed = delivery.run(2, { => "rpc-owned-test" })
        @Expect(failed.isOk(), false)
        @Expect(delivery.closeAfterDeliveryRetirement().isOk(), false)
        @Expect(output.last.getOrThrow().closeAfterFrameRetirement().isOk(), true)
        @Expect(delivery.closeAfterDeliveryRetirement().isOk(), true)
        @Expect(delivery.run(2, { => "never-replay" }).isOk(), false)
        @Expect(failed.isOk(), false); @Expect(output.frames, 1); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func OriginalBankPressureRejectsBeforeFrameConstructionAndErrorCleanupClosesOnlyActualProducerData(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedRpcTestFixture(pool, 1048576, false)
        let pressure = [pool.acquire(1), pool.acquire(1), pool.acquire(1), pool.acquire(1), pool.acquire(1), pool.acquire(1), pool.acquire(1)]
        let output = OwnedRpcTestOutput(); let delivery = OwnedProductRpcEventDelivery(event, output)
        @Expect(delivery.run(2, { => "rpc-owned-test" }).isOk(), false)
        @Expect(output.frames, 0)
        @Expect(delivery.closeAfterDeliveryRetirement().isOk(), true)
        for (paid in pressure) { paid.close() }
        @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func ActualAcpExtensionOmissionAcknowledgesFullToolDataWithoutTouchingTypedToolRules(): Unit {
        let pool = LogicalJsonOwnerBudget(); let event = ownedRpcTestFixture(pool, 1048576, true)
        @Expect(event.withEvent(65536, { actual => @Expect(acpUpdateFromEvent(actual).isNone(), true); Result.Ok(()) }).isOk(), true)
        @Expect(ignoreOwnedAcpToolExtension(event).isOk(), true)
        @Expect(event.isAcknowledged(), true); @Expect(pool.usage()[1], 0)
    }
}
