package agent_host_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

@Test
class HostServicePreparationError159Tests {
    @TestCase
    func canonicalRefusalCodeSurvivesThePreparationResultBoundary(): Unit {
        let actual = hostPluginServiceResultError(ToolResult("fixture-call", objectValue([
            ValueField("error", textValue("tool.not_found")), ValueField("message", textValue("actual refusal"))
        ]), isError: true))
        @Expect(actual.code, "tool.not_found")
        @Expect(actual.message, "actual refusal")
    }
    @TestCase
    func legacyCodePrecedenceAndMissingCodeFallbackStayUnchanged(): Unit {
        let legacy = hostPluginServiceResultError(ToolResult("fixture-call", objectValue([
            ValueField("code", textValue("legacy.refusal")), ValueField("error", textValue("other.refusal"))
        ]), isError: true))
        @Expect(legacy.code, "legacy.refusal")
        let absent = hostPluginServiceResultError(ToolResult("fixture-call", objectValue([]), isError: true))
        @Expect(absent.code, "extension.service_preparation_failed")
    }
}
