package agent_product

import agent_domain.*
import agent_ports.*
import agent_store.*
import std.env.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func capacityTestProfile(): AgentValue {
    objectValue([ValueField("max_frame_bytes", integerValue(4194304)), ValueField("max_input_bytes", integerValue(1048576)),
        ValueField("max_prepare_bytes", integerValue(2097152)), ValueField("max_result_bytes", integerValue(4128768)),
        ValueField("max_directory_bytes", integerValue(2097152)), ValueField("max_tools", integerValue(8192)),
        ValueField("call_timeout_ms", integerValue(120000))])
}
func capacityTestConfiguration(): AgentValue {
    let value = mcpTestConfiguration(); value.put("request_timeout_ms", integerValue(15000))
    value.put("directory", objectValue([ValueField("max_pages", integerValue(1024)), ValueField("max_tools", integerValue(8192))]))
    value
}
func capacityTestFixture(mode!: String = "echo", refresh!: Bool = false): McpProductFixture {
    McpProductFixture(mode: mode, refresh: refresh, configuration: Some(capacityTestConfiguration()), capacityProfile: Some(capacityTestProfile()),
        peerPath: Some(getVariable("AXYNDRA_MCP_CAPACITY_SERVER").getOrThrow()))
}

@Test
class PluginServiceCapacityTests {
    @TestCase
    func operatorProfilePublishesSeventyTwoToolsAndPreservesLargeCanonicalInputOutput(): Unit {
        let fixture = capacityTestFixture(mode: "large-directory", refresh: true)
        try {
            let thread = "profile-capacity"
            let _ = managedCompleted(fixture.start(thread))
            var tools: Int64 = 0
            for (value in fixture.product.tools(threadId: Some(ThreadId(thread))) where value.name.startsWith("plugin.axyndra:mcp-client.service.stdio.")) { tools += 1 }
            @Expect(tools, 72)
            let startup = fixture.database.query("SELECT receipt.detail FROM operation_receipts receipt JOIN operation_effect_records effect " +
                "ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.plugin.lifecycle.start' AND receipt.outcome='completed'")
            @Expect(startup.size, 1)
            @Expect(stringifyUnifiedJson(decodeStoredValue(startup[0].required(0))).size > 131072)
            var pages: Int64 = 0
            for (line in fixture.observed() where lifecycleText(parseUnifiedJson(line), "method") == "tools/list") { pages += 1 }
            @Expect(pages, 9)
            let text = String.fromUtf8(Array<Byte>(98304, repeat: b'x'))
            for (mode in ["input", "output"]) {
                let input = objectValue([ValueField("mode", textValue(mode))])
                if (mode == "input") { input.put("input", textValue(text)) } else { input.put("size", integerValue(98304)) }
                let _ = managedCompleted(fixture.call(thread, mode, input: input))
                let durable = mcpProductOutput(fixture.database, thread, mode)
                let returned = durable.field("result").getOrThrow().field("content").getOrThrow().items[0].field("text").getOrThrow().text
                @Expect(returned, text)
                @Expect(returned.toArray().size, 98304)
                @Expect(modelPolicySha256Text(returned), modelPolicySha256Text(text))
                @Expect(encodeStoredValue(durable).size > 196608)
            }
            @Expect(fixture.calls(), 2); @Expect(fixture.childReceipts("completed"), 2)
            let rows = fixture.database.query("SELECT normalized_plan FROM operation_effect_records WHERE tool_id=?",
                [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL)])
            @Expect(rows.size, 2)
            for (row in rows) {
                let plan = decodeStoredValue(row.required(0)); let binding = plan.field("arguments").getOrThrow().field("binding").getOrThrow()
                @Expect(canonicalAgentValue(binding.field("protocol_limits").getOrThrow()), canonicalAgentValue(capacityTestProfile()))
            }
            let _ = managedCompleted(mcpRefresh(fixture, thread))
            @Expect(mcpRefreshRevision(fixture, thread), 2)
            let refreshed = fixture.database.query("SELECT receipt.detail FROM operation_receipts receipt JOIN operation_effect_records effect " +
                "ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.plugin.lifecycle.refresh' AND receipt.outcome='completed'")
            @Expect(refreshed.size, 1)
            @Expect(stringifyUnifiedJson(decodeStoredValue(refreshed[0].required(0))).size > 131072)
        } finally { fixture.close() }
    }

    @TestCase
    func preparedChunkWriterPreservesRealBinaryBytesAndHash(): Unit {
        let bytes = Array<Byte>(98304, repeat: 0)
        for (index in 0..bytes.size) { bytes[index] = UInt8(index % 256) }
        let fixture = RawChannelFixture("prepared-chunk-hash",
            "import hashlib\ndata=sys.stdin.buffer.read(98304)\nassert len(data)==98304\n" +
            "print(hashlib.sha256(data).hexdigest(),flush=True)")
        let writes = AtomicInt64(0)
        let validations = AtomicInt64(0)
        try {
            let result = lifecycleWritePreparedChunks(bytes, { part =>
                @Expect(part.size <= 65536)
                let _ = writes.fetchAdd(1)
                fixture.channel.write(part)
            }, { => let _ = validations.fetchAdd(1); Result.Ok(()) })
            @Expect(result.isOk())
            @Expect(writes.load(), 2)
            @Expect(validations.load(), 2)
            @Expect(String.fromUtf8(rawChannelReadAll(fixture.channel, ProcessChannelStream.Stdout)).trimAscii(),
                modelPolicySha256(bytes))
        } finally { fixture.close() }
    }

    @TestCase
    func preparedChunkWriterStopsAfterActualPrefixOnFailureOrCancellation(): Unit {
        // The real Python child receives the first chunk. Only the second-write
        // failure and caller cancellation are controlled; no Store proof is mocked.
        for (cancel in [false, true]) {
            let bytes = Array<Byte>(98304, repeat: 120)
            let fixture = RawChannelFixture("prepared-chunk-stop",
                "import hashlib\ndata=sys.stdin.buffer.read(65536)\nassert len(data)==65536\n" +
                "print(hashlib.sha256(data).hexdigest(),flush=True)")
            let source = CancellationSource()
            let writes = AtomicInt64(0)
            let validations = AtomicInt64(0)
            try {
                let result = lifecycleWritePreparedChunks(bytes, { part =>
                    let count = writes.fetchAdd(1)
                    if (count > 0) {
                        return Result.Err(AgentError(AgentErrorKind.Internal, "fixture.second_write_failed", "second raw write failed"))
                    }
                    let first = fixture.channel.write(part)
                    if (cancel) { let _ = source.cancel() }
                    first
                }, { =>
                    let _ = validations.fetchAdd(1)
                    if (source.token.isCancelled()) { lifecycleIoCancelled<Unit>() } else { Result.Ok(()) }
                })
                @Expect(result.isError())
                let error = result.error().getOrThrow()
                @Expect(error.kind, if (cancel) { AgentErrorKind.Cancelled } else { AgentErrorKind.RecoveryRequired })
                @Expect(!error.retryable && !error.fallbackAllowed)
                @Expect(writes.load(), if (cancel) { 1 } else { 2 })
                @Expect(validations.load(), 2)
                @Expect(String.fromUtf8(rawChannelReadAll(fixture.channel, ProcessChannelStream.Stdout)).trimAscii(),
                    modelPolicySha256(bytes[0..65536]))
            } finally { source.close(); fixture.close() }
        }
    }

    @TestCase
    func explicitFifteenSecondConfigCompletesRealElevenSecondCall(): Unit {
        let fixture = capacityTestFixture()
        try {
            let _ = managedCompleted(fixture.start("profile-delay"))
            let begun = MonoTime.now()
            let _ = managedCompleted(fixture.call("profile-delay", "delay", input: objectValue([
                ValueField("mode", textValue("delay")), ValueField("delay_ms", integerValue(11000))])))
            @Expect((MonoTime.now() - begun).toMilliseconds() >= 10500)
            @Expect((MonoTime.now() - begun).toMilliseconds() < 20000)
            @Expect(fixture.calls(), 1); @Expect(fixture.childReceipts("completed"), 1)
            @Expect(lifecycleText(mcpProductOutput(fixture.database, "profile-delay", "delay"), "status"), "complete")
        } finally { fixture.close() }
    }

    @TestCase
    func oversizedInputAndChangedOperatorProfileCannotStartAnotherWrite(): Unit {
        let fixture = capacityTestFixture()
        try {
            let _ = managedCompleted(fixture.start("profile-denied"))
            let oversized = objectValue([ValueField("mode", textValue("input")),
                ValueField("input", textValue(String.fromUtf8(Array<Byte>(1048576, repeat: b'x'))))])
            let rejected = fixture.call("profile-denied", "oversized", input: oversized)
            @Expect(rejected.isError() || match (rejected.value().getOrThrow()) {
                case ToolInvocationResult.Completed(result) => result.isError; case _ => true })
            @Expect(fixture.calls(), 0); @Expect(fixture.childReceipts("completed"), 0)
            let path = fixture.files.settings + "/plugins/lifecycle.json"
            let document = parseUnifiedJson(String.fromUtf8(File.readFrom(path)), maxBytes: 262144)
            document.field("plugins").getOrThrow().items[0].field("services").getOrThrow().items[0]
                .field("protocol_limits").getOrThrow().put("max_tools", integerValue(72))
            File.writeTo(path, stringifyUnifiedJson(document).toArray())
            let changed = fixture.call("profile-denied", "changed", input: objectValue([ValueField("mode", textValue("output")), ValueField("size", integerValue(1))]))
            @Expect(changed.isError() || match (changed.value().getOrThrow()) { case ToolInvocationResult.Completed(result) => result.isError; case _ => true })
            @Expect(fixture.calls(), 0); @Expect(fixture.childReceipts("completed"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func responseBeyondSelectedFramePreservesUnknownAndWithdrawsService(): Unit {
        let fixture = capacityTestFixture()
        try {
            let _ = managedCompleted(fixture.start("profile-overflow"))
            let result = fixture.call("profile-overflow", "overflow", input: objectValue([
                ValueField("mode", textValue("output")), ValueField("size", integerValue(3145728))]))
            @Expect(result.isError()); @Expect(result.error().getOrThrow().kind, AgentErrorKind.RecoveryRequired)
            @Expect(fixture.calls(), 1); @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.query("SELECT receipt.id FROM operation_receipts receipt JOIN operation_effect_records effect " +
                "ON effect.operation_id=receipt.operation_id WHERE effect.tool_id=? AND receipt.outcome='unknown'",
                [SqlParameter.Text(fixture.name)]).size, 1)
            @Expect(!fixture.active("profile-overflow")); @Expect(!fixture.visible("profile-overflow"))
            let _ = fixture.call("profile-overflow", "must-not-retry", input: objectValue([ValueField("mode", textValue("output")), ValueField("size", integerValue(1))]))
            @Expect(fixture.calls(), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func profileSchemaAndDurableCodecBoundsAreCheckedIndependently(): Unit {
        @Expect(parseServiceProtocolLimits(capacityTestProfile()).isOk())
        for (key in ["max_frame_bytes", "max_input_bytes", "max_prepare_bytes", "max_tools", "call_timeout_ms"]) {
            let profile = capacityTestProfile(); profile.put(key, integerValue(0))
            @Expect(parseServiceProtocolLimits(profile).isError())
        }
        let unknown = capacityTestProfile(); unknown.put("allow", boolValue(true))
        @Expect(parseServiceProtocolLimits(unknown).isError())
        @Expect(!sameServiceProtocolLimits(objectValue([]), objectValue([ValueField("protocol_limits", capacityTestProfile())])))
        let tooLarge = textValue(String.fromUtf8(Array<Byte>(8388608, repeat: b'x')))
        @Expect(!managedServiceDurableValueFits(tooLarge))
        @Expect(managedServiceDurableValueFits(textValue("small")))
    }
}
