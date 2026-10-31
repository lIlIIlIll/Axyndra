package agent_product

import agent_domain.*
import agent_ports.*
import agent_extension_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func channelEncodingValue(result: JavaScriptHostResult<String>): AgentValue {
    match (result) {
        case JavaScriptHostResult.Ok(value) => parseUnifiedJson(value)
        case JavaScriptHostResult.Err(error) => throw IllegalStateException(error.code)
    }
}
func channelEncodingRejected(result: JavaScriptHostResult<String>): Bool {
    match (result) { case JavaScriptHostResult.Err(_) => true; case _ => false }
}
func channelEncodingArguments(encoding: AgentValue): AgentValue {
    objectValue([ValueField("stream", textValue("stdout")), ValueField("max_bytes", integerValue(1)),
        ValueField("wait_ms", integerValue(1000)), ValueField("encoding", encoding)])
}

@Test
class ProductPluginChannelEncodingTests {
    @TestCase
    func directBinaryReadUsesActualWriteReceiptAndKeepsDefaultStartupHex(): Unit {
        let fixture = LifecycleManagerFixture(completeCapabilities: true)
        try {
            // Unmodified startup fixture explicitly expects bytes_hex. Only
            // this actual call asks for Base64, preserving the old peer path.
            let _ = lifecycleTestRequire(fixture.startProtocol("base64-direct", "base64-direct-start"))
            let bytes = "006869ff800a"
            let result = managedCompleted(channelTestCall(fixture, "base64-direct", "binary",
                channelTestInput(bytes, mode: "read_base64")))
            @Expect(!result.isError)
            @Expect(lifecycleText(result.output.field("result").getOrThrow(), "bytes_hex"), bytes)
            @Expect(channelTestChildren(fixture, "base64-direct", "completed"), 1)
            @Expect(channelTestHandoffs(fixture, "base64-direct"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func committedBinaryReadStillRequiresTheFrozenActualApproval(): Unit {
        let fixture = LifecycleManagerFixture(approval: ApprovalMode.AlwaysAsk, completeCapabilities: true)
        try {
            let _ = lifecycleTestRequire(fixture.startProtocol("base64-committed", "base64-committed-start"))
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("base64-committed")))
            let bytes = "e99baa00ff0a"
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("binary-approved", fixture.name,
                channelTestInput(bytes, mode: "read_base64"))
            lifecycleTestRequire(session.submit("Read the approved binary echo."))
            let approval = session.approval().getOrThrow()
            @Expect(channelTestHandoffs(fixture, "base64-committed"), 0)
            let before = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?",
                [SqlParameter.Text(approval.operationId.value)])[0].required(0)
            lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Approve))
            let output = channelTestOutput(fixture, "base64-committed", "binary-approved")
            @Expect(lifecycleText(output.field("result").getOrThrow(), "bytes_hex"), bytes)
            @Expect(channelTestChildren(fixture, "base64-committed", "completed"), 1)
            @Expect(channelTestHandoffs(fixture, "base64-committed"), 1)
            @Expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?",
                [SqlParameter.Text(approval.operationId.value)])[0].required(0), before)
        } finally { fixture.close() }
    }

    @TestCase
    func malformedEncodingIsRejectedBeforeReadingAnActualApprovedStartupPipe(): Unit {
        let fixture = LifecycleManagerFixture(completeCapabilities: true)
        try {
            let started = fixture.manager.start(fixture.product.vnext, fixture.context("base64-startup"),
                ThreadId("base64-startup-maintenance"), fixture.config, "stdio", "session",
                fixture.product.vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace))),
                { _, lease, context, prepared =>
                    let observer = ProductManagedStartupObserver(lease, context, prepared)
                    try {
                        let expected: Array<Byte> = [0u8, 255u8, 128u8, 233u8, 155u8, 170u8]
                        lifecycleTestRequire(lease.startupWrite(expected))
                        var sequence: Int64 = 0
                        for (encoding in [nullValue(), integerValue(1), boolValue(true), textValue("BASE64"), textValue("utf8")]) {
                            sequence += 1
                            @Expect(channelEncodingRejected(observer.onServiceRequest("binary-startup", "invalid-" + sequence.toString(),
                                "process.channel.read", stringifyUnifiedJson(channelEncodingArguments(encoding)))))
                        }
                        let extra = channelEncodingArguments(textValue("base64")); extra.put("path", textValue("forbidden"))
                        @Expect(channelEncodingRejected(observer.onServiceRequest("binary-startup", "invalid-extra",
                            "process.channel.read", stringifyUnifiedJson(extra))))
                        // Every invalid request asked for one byte and a real
                        // wait. All original bytes must still be on the pipe.
                        for (index in 0..expected.size) {
                            let response = channelEncodingValue(observer.onServiceRequest("binary-startup", "valid-" + index.toString(),
                                "process.channel.read", stringifyUnifiedJson(channelEncodingArguments(textValue("base64")))))
                            @Expect(httpIntentExactFields(response, ["bytes_base64", "eof"]))
                            @Expect(lifecycleText(response, "bytes_base64"), productBase64Bytes([expected[index]]))
                            @Expect(!response.field("eof").getOrThrow().asBool())
                        }
                        let legacy = objectValue([ValueField("stream", textValue("stderr")),
                            ValueField("max_bytes", integerValue(1)), ValueField("wait_ms", integerValue(0))])
                        let quiet = channelEncodingValue(observer.onServiceRequest("binary-startup", "legacy-quiet",
                            "process.channel.read", stringifyUnifiedJson(legacy)))
                        @Expect(httpIntentExactFields(quiet, ["bytes_hex", "eof"]))
                        @Expect(lifecycleText(quiet, "bytes_hex"), "")
                        @Expect(!quiet.field("eof").getOrThrow().asBool())
                        Result<AgentValue>.Ok(objectValue([ValueField("tools", listValue([objectValue([
                            ValueField("name", textValue("echo")), ValueField("description", textValue("Binary echo fixture")),
                            ValueField("input_schema", objectValue([ValueField("type", textValue("object"))]))])]))]))
                    } finally { observer.close() }
                }, ApprovalDecision.Approve)
            @Expect(lifecycleTestRequire(started).service.getOrThrow().active())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func base64EncodingOccursAfterActualSecretFilteringAndKeepsRawMeterAndCloseAck(): Unit {
        let fixture = RawChannelFixture("base64-secret", "os.write(2,b'safe|private-'); os.read(0,1); os.write(2,b'token-72ca'); time.sleep(5)")
        let filtered = ProductProcessSecretChannel(fixture.channel, ["private-token-72ca"], 65536)
        try {
            let published = ArrayList<Byte>()
            var rejected = false
            var safePrefixAcknowledged = false
            let deadline = MonoTime.now() + Duration.second * 3
            while (!rejected && MonoTime.now() < deadline) {
                match (filtered.read(ProcessChannelStream.Stderr, 16384, 25)) {
                    case Result.Ok(value) =>
                        let encoded = channelEncodingValue(managedChannelReadResult(value, encoding: "base64"))
                        @Expect(httpIntentExactFields(encoded, ["bytes_base64", "eof"]))
                        @Expect(lifecycleText(encoded, "bytes_base64"), productBase64Bytes(value.bytes))
                        published.add(all: value.bytes)
                        // Real pipe ACK makes the split deterministic even if
                        // scheduling delays the first read. The secret suffix
                        // cannot be emitted before the safe bytes were consumed.
                        if (!safePrefixAcknowledged && published.size == 5) {
                            @Expect(String.fromUtf8(published.toArray()), "safe|")
                            lifecycleTestRequire(filtered.write("G".toArray()))
                            safePrefixAcknowledged = true
                        }
                    case Result.Err(error) =>
                        @Expect(error.code, "process.channel_output_withheld")
                        rejected = true
                }
            }
            @Expect(safePrefixAcknowledged && rejected)
            @Expect(String.fromUtf8(published.toArray()), "safe|")
            var acknowledged = false
            let closeDeadline = MonoTime.now() + Duration.second * 5
            while (!acknowledged && MonoTime.now() < closeDeadline) {
                acknowledged = filtered.close().isOk()
                if (!acknowledged) { sleep(Duration.millisecond * 5) }
            }
            @Expect(acknowledged && filtered.read(ProcessChannelStream.Stdout, 1, 0).isError())
            @Expect(lifecycleTestRequire(filtered.receivedOutputBytes()) >= 23)
            @Expect(fixture.releases.load(), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func actualQueuedThirtyTwoKibBinaryReadFitsTheOriginalFrameAndKeepsRawAccounting(): Unit {
        let fixture = RawChannelFixture("base64-32k", "os.write(1,bytes(range(256))*128); os.read(0,1)")
        try {
            let arguments = objectValue([ValueField("stream", textValue("stdout")),
                ValueField("max_bytes", integerValue(65536)), ValueField("wait_ms", integerValue(0)),
                ValueField("encoding", textValue("base64"))])
            let (_, maximum, _, encoding) = lifecycleTestRequire(managedChannelReadArguments(arguments))
            @Expect(maximum, 32768); @Expect(encoding, "base64")
            arguments.put("encoding", textValue("hex"))
            let (_, legacyMaximum, _, _) = lifecycleTestRequire(managedChannelReadArguments(arguments))
            @Expect(legacyMaximum, 16384)
            let legacy = objectValue([ValueField("stream", textValue("stdout")),
                ValueField("max_bytes", integerValue(65536)), ValueField("wait_ms", integerValue(0))])
            let (_, defaultMaximum, _, _) = lifecycleTestRequire(managedChannelReadArguments(legacy))
            @Expect(defaultMaximum, 16384)
            // Meter charging precedes queue insertion. Use the queue's own
            // completed appends to prove a single maximal coalesced read;
            // the actual pipe below must still accept every legal short read.
            let expected = Array<Byte>(32768, repeat: 0)
            for (index in 0..expected.size) { expected[index] = UInt8(index % 256) }
            let queue = ProductProcessChannelQueue()
            for (offset in 0..32768:4096) { @Expect(queue.append(expected[offset..offset + 4096])) }
            let value = lifecycleTestRequire(queue.poll(maximum))
            @Expect(rawChannelSameBytes(value.bytes, expected)); @Expect(!value.eof)
            let actual = ArrayList<Byte>()
            let deadline = MonoTime.now() + Duration.second * 3
            while (actual.size < expected.size && MonoTime.now() < deadline) {
                let read = lifecycleTestRequire(fixture.channel.read(ProcessChannelStream.Stdout, maximum, 25))
                @Expect(read.bytes.size <= maximum && !read.eof)
                let encoded = channelEncodingValue(managedChannelReadResult(read, encoding: encoding))
                @Expect(lifecycleText(encoded, "bytes_base64"), productBase64Bytes(read.bytes))
                actual.add(all: read.bytes)
            }
            @Expect(rawChannelSameBytes(actual.toArray(), expected))
            @Expect(lifecycleTestRequire(fixture.channel.receivedOutputBytes()), 32768)
            let result = channelEncodingValue(managedChannelReadResult(value, encoding: encoding))
            @Expect(httpIntentExactFields(result, ["bytes_base64", "eof"]))
            @Expect(lifecycleText(result, "bytes_base64"), productBase64Bytes(value.bytes))
            @Expect(lifecycleText(result, "bytes_base64").size, 43692)
            // The runtime serializes service results as an inner JSON string.
            // Even double encoding has ample room below the unchanged frame cap.
            let envelope = objectValue([ValueField("type", textValue("service_response")),
                ValueField("protocol", textValue("axyndra-js-host-v2")), ValueField("ok", boolValue(true)),
                ValueField("result_json", textValue(stringifyUnifiedJson(result)))])
            @Expect(stringifyUnifiedJson(envelope).size < 49152)
            @Expect(lifecycleTestRequire(fixture.channel.receivedOutputBytes()), 32768)
            lifecycleTestRequire(fixture.channel.write("G".toArray()))
            let rest = rawChannelReadAll(fixture.channel, ProcessChannelStream.Stdout)
            @Expect(rest.isEmpty())
            var acknowledged = false
            let closeDeadline = MonoTime.now() + Duration.second * 5
            while (!acknowledged && MonoTime.now() < closeDeadline) {
                acknowledged = fixture.channel.close().isOk()
                if (!acknowledged) { sleep(Duration.millisecond * 5) }
            }
            @Expect(acknowledged); @Expect(fixture.releases.load(), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func actualBinaryEofAndRepresentationBoundsPreserveDefaultHex(): Unit {
        let fixture = RawChannelFixture("base64-eof", "os.write(1,bytes([0,255,128,233,155,170]))")
        try {
            let bytes = rawChannelReadAll(fixture.channel, ProcessChannelStream.Stdout, maxBytes: 1)
            @Expect(rawChannelSameBytes(bytes, [0u8, 255u8, 128u8, 233u8, 155u8, 170u8]))
            let eof = lifecycleTestRequire(fixture.channel.read(ProcessChannelStream.Stdout, 1, 0))
            @Expect(eof.eof)
            let encoded = channelEncodingValue(managedChannelReadResult(eof, encoding: "base64"))
            @Expect(lifecycleText(encoded, "bytes_base64"), "")
            @Expect(encoded.field("eof").getOrThrow().asBool())
            @Expect(lifecycleText(channelEncodingValue(managedChannelReadResult(ProcessChannelRead(bytes, true))), "bytes_hex"), "00ff80e99baa")
            let maximum = ProcessChannelRead(Array<Byte>(32768, repeat: 0), false)
            @Expect(lifecycleText(channelEncodingValue(managedChannelReadResult(maximum, encoding: "base64")), "bytes_base64").size, 43692)
            @Expect(channelEncodingRejected(managedChannelReadResult(ProcessChannelRead(Array<Byte>(32769, repeat: 0), false), encoding: "base64")))
            @Expect(lifecycleText(channelEncodingValue(managedChannelReadResult(ProcessChannelRead(Array<Byte>(16384, repeat: 0), false))), "bytes_hex").size, 32768)
            @Expect(channelEncodingRejected(managedChannelReadResult(ProcessChannelRead(Array<Byte>(16385, repeat: 0), false))))
            @Expect(channelEncodingRejected(managedChannelReadResult(eof, encoding: "unknown")))
        } finally { fixture.close() }
    }
}
