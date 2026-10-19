package agent_domain

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class LogicalPayloadFixtureState {
    var decoded: ?AgentValue = None
    var chunks: Int64 = 0
    var allowed: Bool = true
}

func logicalPayloadUsageEqual(actual: (Int64, Int64), expected: (Int64, Int64)): Bool {
    actual[0] == expected[0] && actual[1] == expected[1]
}

func logicalPayloadTestHeader(kind: String, size: Int64, digest: String): AgentValue {
    let fields = ArrayList<ValueField>([ValueField("schema", textValue(LOGICAL_JSON_PAYLOAD_SCHEMA)),
        ValueField("window", textValue("fixed-window")), ValueField("transfer_sequence", integerValue(7))])
    if (kind == "payload_begin") {
        fields.add(ValueField("message_type", textValue("model_message")))
        fields.add(ValueField("bytes", integerValue(size))); fields.add(ValueField("sha256", textValue(digest)))
    }
    objectValue(fields.toArray())
}

@Test
class LogicalJsonPayloadTests {
    @TestCase
    func realChunkCodecRoundTripKeepsChargeUntilConsumerCloses(): Unit {
        let pool = LogicalJsonOwnerBudget(); let worker = LogicalJsonProcessBudget(pool)
        let source = objectValue([ValueField("text", textValue(String.fromUtf8(Array<Byte>(1048576, repeat: b'x')) + "雪"))]).stringify()
        let receiver = LogicalJsonReceiver(worker, 2097152, "fixed-window", 7, "model_message", { => () })
        let state = LogicalPayloadFixtureState()
        try {
            writeLogicalJsonPayload("fixed-window", 7, "model_message", source, 2097152, { => () }, { kind, header =>
                if (kind == "payload_chunk") { state.chunks += 1 }
                match (receiver.accept(kind, header)) { case Some(value) => state.decoded = Some(value); case None => () }
            })
            @Expect(state.chunks > 64)
            @Expect(state.decoded.getOrThrow().field("text").getOrThrow().text.endsWith("雪"))
            @Expect(state.decoded.getOrThrow().stringify(), source)
            @Expect(pool.usage()[0], 1)
            var replayRejected = false
            try { let _ = receiver.accept("payload_end", logicalPayloadTestHeader("payload_end", 0, "")) }
            catch (_: Exception) { replayRejected = true }
            @Expect(replayRejected)
        } finally { receiver.close() }
        @Expect(logicalPayloadUsageEqual(pool.usage(), (0, 0)))
    }

    @TestCase
    func badOffsetAndDigestNeverProduceDecodedMessageOrLoseAccounting(): Unit {
        for (mode in ["offset", "digest", "length", "window"]) {
            let pool = LogicalJsonOwnerBudget(); let worker = LogicalJsonProcessBudget(pool)
            let receiver = LogicalJsonReceiver(worker, 1024, "fixed-window", 7, "model_message", { => () })
            let source = "{\"ok\":true}"; var rejected = false; var decoded = false
            try {
                let digest = if (mode == "digest") { modelPolicySha256Text("wrong") } else { modelPolicySha256Text(source) }
                let _ = receiver.accept("payload_begin", logicalPayloadTestHeader("payload_begin",
                    if (mode == "length") { 2048 } else { source.size }, digest))
                let chunk = objectValue([ValueField("schema", textValue(LOGICAL_JSON_PAYLOAD_SCHEMA)),
                    ValueField("window", textValue(if (mode == "window") { "other-window" } else { "fixed-window" })),
                    ValueField("transfer_sequence", integerValue(7)), ValueField("offset", integerValue(if (mode == "offset") { 1 } else { 0 })),
                    ValueField("bytes_hex", textValue(logicalJsonEncodeHex(source.toArray())))])
                let _ = receiver.accept("payload_chunk", chunk)
                decoded = receiver.accept("payload_end", logicalPayloadTestHeader("payload_end", 0, "")).isSome()
            } catch (_: Exception) { rejected = true }
            finally { receiver.close() }
            @Expect(rejected && !decoded)
            @Expect(logicalPayloadUsageEqual(pool.usage(), (0, 0)))
        }
    }

    @TestCase
    func aggregateAndWorkerLimitsApplyBeforeAllocationAndCloseIsIdempotent(): Unit {
        let pool = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let first = LogicalJsonProcessBudget(pool); let second = LogicalJsonProcessBudget(pool)
        let reservation = first.acquire(1024)
        var rejected = false
        try { let _ = second.acquire(1024) } catch (_: Exception) { rejected = true }
        @Expect(rejected && pool.usage()[0] == 1)
        reservation.close(); reservation.close(); @Expect(logicalPayloadUsageEqual(pool.usage(), (0, 0)))
        let pool2 = LogicalJsonOwnerBudget(); let worker = LogicalJsonProcessBudget(pool2)
        let one = worker.acquire(1024); let two = worker.acquire(1024)
        try {
            rejected = false
            try { let _ = worker.acquire(1024) } catch (_: Exception) { rejected = true }
            @Expect(rejected && pool2.usage()[0] == 2)
        } finally { one.close(); two.close() }
        @Expect(logicalPayloadUsageEqual(pool2.usage(), (0, 0)))
    }

    @TestCase
    func sameReservationAccountsDenseDomBeforeDecodeAndCancellationRejectsEnd(): Unit {
        let pool = LogicalJsonOwnerBudget(); let worker = LogicalJsonProcessBudget(pool)
        let charge = worker.acquire(1024)
        try {
            let before = pool.usage()[1]
            charge.ensureDecoded(1024, 65536)
            @Expect(pool.usage()[0], 1)
            @Expect(pool.usage()[1] > before)
            var rejected = false
            try { charge.ensureDecoded(1024, 65537) } catch (_: Exception) { rejected = true }
            @Expect(rejected)
        } finally { charge.close() }
        let state = LogicalPayloadFixtureState()
        let receiver = LogicalJsonReceiver(worker, 1024, "fixed-window", 7, "model_message", { =>
            if (!state.allowed) { throw IllegalStateException("actual owner cancelled") }
        })
        var rejected = false
        try {
            writeLogicalJsonPayload("fixed-window", 7, "model_message", "{}", 1024, { => () }, { kind, header =>
                if (kind == "payload_end") { state.allowed = false }
                let _ = receiver.accept(kind, header)
            })
        } catch (_: Exception) { rejected = true }
        finally { receiver.close() }
        @Expect(rejected)
        @Expect(logicalPayloadUsageEqual(pool.usage(), (0, 0)))
    }
    @TestCase
    func ordinaryHttpTimeoutBoundsRemainStrictWhileActualOwnerCanSupplyLongPolicy(): Unit {
        for (timeout in [0, 3600000]) {
            let request = objectValue([ValueField("method", textValue("POST")), ValueField("url", textValue("https://example.com/inference")),
                ValueField("headers", objectValue([])), ValueField("body_hex", textValue("7b7d")),
                ValueField("credential_refs", listValue([])), ValueField("timeout_ms", integerValue(timeout)),
                ValueField("max_response_bytes", integerValue(1048576))])
            @Expect(validateHttpStreamRequest(request).isError())
            @Expect(validateHttpStreamRequest(request, timeoutMaximum: Int64.Max, allowZeroTimeout: true).isOk())
            request.put("timeout_ms", integerValue(-1))
            @Expect(validateHttpStreamRequest(request, timeoutMaximum: Int64.Max, allowZeroTimeout: true).isError())
            request.put("timeout_ms", integerValue(1)); request.put("url", textValue("https://user@example.com/inference"))
            @Expect(validateHttpStreamRequest(request, timeoutMaximum: Int64.Max, allowZeroTimeout: true).isError())
        }
    }


    @TestCase
    func fixedBuffersShareExactAggregateBytesWithoutReducingHostOrMessageCount(): Unit {
        let pool = LogicalJsonOwnerBudget(maximumCharged: 16777216, maximumTransfers: 2)
        let buffer = pool.acquireFixedBuffer(8192)
        try {
            @Expect(pool.usage()[0], 1); @Expect(pool.usage()[1], 8192)
            var exhausted = false
            try { let _ = pool.acquire(1) } catch (_: LogicalJsonPayloadError) { exhausted = true }
            @Expect(exhausted)
            for (size in [0, 1, 1023, 65537]) {
                var invalid = false
                try { let _ = pool.acquireFixedBuffer(size) } catch (_: LogicalJsonPayloadError) { invalid = true }
                @Expect(invalid)
            }
        } finally { buffer.close(); buffer.close() }
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
        let shared = LogicalJsonOwnerBudget(maximumCharged: 33554432, maximumTransfers: 1)
        let idle = ArrayList<LogicalJsonFixedBufferReservation>()
        try {
            for (_ in 0..64) { idle.add(shared.acquireFixedBuffer(8192)) }
            let message = shared.acquire(1)
            try {
                @Expect(shared.usage()[0], 65); @Expect(shared.usage()[1], 17301504)
                var messageLimited = false
                try { let _ = shared.acquire(1) } catch (_: LogicalJsonPayloadError) { messageLimited = true }
                @Expect(messageLimited)
            } finally { message.close() }
        } finally { for (entry in idle) { entry.close(); entry.close() } }
        @Expect(shared.usage()[0], 0); @Expect(shared.usage()[1], 0)
        let full = ArrayList<LogicalJsonFixedBufferReservation>()
        try {
            for (_ in 0..256) { full.add(pool.acquireFixedBuffer(65536)) }
            @Expect(pool.usage()[1], 16777216)
            var exhausted = false
            try { let _ = pool.acquireFixedBuffer(1024) } catch (_: LogicalJsonPayloadError) { exhausted = true }
            @Expect(exhausted)
        } finally { for (entry in full) { entry.close() } }
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}
