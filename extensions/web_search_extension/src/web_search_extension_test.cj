package web_search_extension

import agent_sdk.*
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class WebSearchExtensionTests {
    @TestCase
    func validatesAndPreparesNetworkIntent() {
        let tool = WebSearchExtensionTool()
        let input = jsonObject([
            JsonObjectEntry("query", jsonString("cangjie")),
            JsonObjectEntry("recency", jsonString("week"))
        ])
        @Assert(tool.prepare(ToolInvocation("web-1", input, "/workspace", "/workspace")).isOk())
        @Expect(tool.definition().capabilities[0].name, "network.http")
        @Expect(tool.definition().effect == ExtensionEffect.ReadOnly)
    }

    @TestCase
    func rejectsEmptyQueryAndInvalidRecency() {
        let tool = WebSearchExtensionTool()
        @Expect(tool.validate(jsonObject([])).isOk(), false)
        @Expect(tool.validate(jsonObject([
            JsonObjectEntry("query", jsonString("x")),
            JsonObjectEntry("recency", jsonString("forever"))
        ])).isOk(), false)
    }
}
