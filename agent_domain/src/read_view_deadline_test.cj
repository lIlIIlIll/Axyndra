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
}
