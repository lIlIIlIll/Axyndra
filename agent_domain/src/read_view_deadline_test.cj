package agent_domain
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func finiteReadViewTestIntent(millis: Int64): AgentValue {
    objectValue([ValueField("id", textValue("finite-read")), ValueField("requires_approval", boolValue(false)),
        ValueField("request", objectValue([ValueField("executable", textValue("bin/worker")), ValueField("arguments", listValue([])), ValueField("timeout_ms", integerValue(millis))])),
        ValueField("resources", listValue([objectValue([ValueField("kind", textValue("directory")), ValueField("source", textValue("/tmp/finite-view")),
            ValueField("path", textValue(".")), ValueField("witness", textValue("d:actual")), ValueField("bytes", integerValue(0)), ValueField("permission", textValue("workspace.read"))])]))])
}
@Test
class ReadViewFiniteDeadlineTests {
    @TestCase
    func defaultSixtySecondLimitIsStillExact(): Unit {
        @Expect(validateReadViewIntent(finiteReadViewTestIntent(60000)).isOk(), true)
        @Expect(validateReadViewIntent(finiteReadViewTestIntent(60001)).isError(), true)
    }
    @TestCase
    func explicitFiniteProfileKeepsOriginalResourceAndWorkerBounds(): Unit {
        let intent = finiteReadViewTestIntent(600000)
        intent.put("deadline_profile", objectValue([ValueField("version", textValue(READ_VIEW_FINITE_DEADLINE_VERSION)), ValueField("maximum_ms", integerValue(600000)), ValueField("schema_digest", textValue(modelPolicySha256Text("actual-ready-schema")))]))
        @Expect(validateReadViewIntent(intent).isOk(), true)
        intent.field("request").getOrThrow().put("timeout_ms", integerValue(600001))
        @Expect(validateReadViewIntent(intent).isError(), true)
        intent.field("request").getOrThrow().put("timeout_ms", integerValue(600000))
        intent.field("request").getOrThrow().put("executable", textValue("/bin/unbound"))
        @Expect(validateReadViewIntent(intent).isError(), true)
    }
    @TestCase
    func repeatedUnknownNonCanonicalAndUnboundedOperatorProfilesRefuse(): Unit {
        for (raw in ["[{\"contribution\":\"exec\",\"maximum_ms\":600001}]", "[{\"contribution\":\"exec\",\"maximum_ms\":0}]", "[{\"contribution\":\"exec\",\"maximum_ms\":1.0}]",
            "[{\"contribution\":\"exec\",\"maximum_ms\":1,\"grant\":true}]", "[{\"contribution\":\"exec\",\"maximum_ms\":1},{\"contribution\":\"exec\",\"maximum_ms\":1}]"]) {
            @Expect(validReadViewDeadlineGrants(parseUnifiedJson(raw)), false) }
        @Expect(validReadViewDeadlineGrants(parseUnifiedJson("[{\"contribution\":\"exec\",\"maximum_ms\":600000}]")), true)
    }
    @TestCase
    func privateInputEncoderReportsExactLengthAndRejectsOverflowOrRevocation(): Unit {
        let value = objectValue([ValueField("z", textValue("a\n\"界")), ValueField("a", integerValue(42))])
        let expected = stringifyUnifiedJson(value)
        let intent = finiteReadViewTestIntent(123)
        let request = intent.field("request").getOrThrow()
        request.put("input", value)
        let args = objectValue([ValueField("intent", intent), ValueField("tool_payload_limits", nullValue())])
        let exact = Array<Byte>(expected.size, repeat: 0)
        let saved = withToolResolverInput(ToolCall("worker-id", "worker-tool", args), { input =>
            @Expect(resolverReadViewResponseLimit(input).isNone())
            @Expect(resolverEncodeReadViewInput(input, Array<Byte>(1, repeat: 0)).getOrThrow(), expected.size)
            @Expect(resolverEncodeReadViewInput(input, exact).getOrThrow(), expected.size)
            let scratch = Array<Byte>(1, repeat: 0)
            value.put("z", textValue(String.fromUtf8(Array<Byte>(HOST_READ_VIEW_INPUT_BYTES, repeat: b'x'))))
            @Expect(resolverEncodeReadViewInput(input, scratch).isNone())
            request.put("input", nullValue())
            @Expect(resolverEncodeReadViewInput(input, exact).isNone())
            input
        })
        var stale = false
        try { let _ = resolverEncodeReadViewInput(saved, exact) } catch (_: IllegalStateException) { stale = true }
        @Expect(stale)
        @Expect(String.fromUtf8(exact), expected)
    }
}
