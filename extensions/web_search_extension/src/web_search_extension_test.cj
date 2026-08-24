package web_search_extension

import agent_sdk.*
import json4cj.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class WebSearchExtensionTests {
    @TestCase
    func validatesAndPreparesNetworkIntent() {
        let tool = WebSearchExtensionTool()
        let input = JsonValue.objectValue([
            JsonField("query", JsonValue.stringValue("cangjie")),
            JsonField("recency", JsonValue.stringValue("week"))
        ])
        @Assert(tool.prepare(ToolInvocation("web-1", input, "/workspace", "/workspace")).isOk())
        @Expect(tool.definition().capabilities[0].name, "network.http")
        @Expect(tool.definition().effect == ExtensionEffect.ReadOnly)
    }

    @TestCase
    func rejectsEmptyQueryAndInvalidRecency() {
        let tool = WebSearchExtensionTool()
        @Expect(tool.validate(JsonValue.objectValue([])).isOk(), false)
        @Expect(tool.validate(JsonValue.objectValue([
            JsonField("query", JsonValue.stringValue("x")),
            JsonField("recency", JsonValue.stringValue("forever"))
        ])).isOk(), false)
    }
}
