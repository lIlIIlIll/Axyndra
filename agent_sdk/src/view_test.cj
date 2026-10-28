package agent_sdk

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func sdkViewDocument(nodes: Array<JsonNode>, actions!: Array<JsonNode> = []): JsonNode {
    jsonObject([JsonObjectEntry("schema", jsonString(PLUGIN_VIEW_PROTOCOL)),
        JsonObjectEntry("title", jsonString("Business View")), JsonObjectEntry("summary", jsonString("Bounded data")),
        JsonObjectEntry("status", jsonString("ready")), JsonObjectEntry("interaction", jsonString("optional")),
        JsonObjectEntry("nodes", jsonArray(nodes)), JsonObjectEntry("actions", jsonArray(actions))])
}
func sdkViewText(id: String, text: String): JsonNode {
    jsonObject([JsonObjectEntry("id", jsonString(id)), JsonObjectEntry("kind", jsonString("text")),
        JsonObjectEntry("text", jsonString(text))])
}
func sdkViewAction(id: String, input!: JsonNode = jsonObject([])): JsonNode {
    jsonObject([JsonObjectEntry("id", jsonString(id)), JsonObjectEntry("label", jsonString("Select action")),
        JsonObjectEntry("command", jsonString("local_command")), JsonObjectEntry("input", input)])
}
func sdkViewAccepted(value: JsonNode): Bool {
    match (validatePluginViewDocument(value)) { case SdkResult.Ok(_) => true; case SdkResult.Err(_) => false }
}

@Test
class PluginViewDocumentTests {
    @TestCase
    func sourceBoundInputDoesNotRequireOrCopyDocumentTextIntoTheModel(): Unit {
        let input = jsonObject([JsonObjectEntry("id", jsonString("document")), JsonObjectEntry("kind", jsonString("input")),
            JsonObjectEntry("label", jsonString("Host-owned source")), JsonObjectEntry("source", jsonString("primary")),
            JsonObjectEntry("multiline", jsonBool(true))])
        @Expect(sdkViewAccepted(sdkViewDocument([input, sdkViewText("notice", "plain\n\t雪") ])))
        let ambiguous = jsonObject([JsonObjectEntry("id", jsonString("document")), JsonObjectEntry("kind", jsonString("input")),
            JsonObjectEntry("label", jsonString("Ambiguous")), JsonObjectEntry("source", jsonString("primary")),
            JsonObjectEntry("text", jsonString("independent text")), JsonObjectEntry("multiline", jsonBool(true))])
        @Expect(!sdkViewAccepted(sdkViewDocument([ambiguous])))
    }

    @TestCase
    func terminalControlsAndDirectionalOverridesAreNotPresentationAPIs(): Unit {
        for (text in ["\u{001b}[31m", "\r", "\u{0085}", "\u{009b}", "\u{202e}", "\u{2066}"]) {
            @Expect(!sdkViewAccepted(sdkViewDocument([sdkViewText("unsafe", text)])))
            @Expect(!isPluginViewPlainText(text))
        }
        @Expect(isPluginViewPlainText("plain\n\t雪"))
    }

    @TestCase
    func ambiguousNodeAndActionIdentitiesCannotDispatchADifferentSelection(): Unit {
        @Expect(!sdkViewAccepted(sdkViewDocument([sdkViewText("same", "first"), sdkViewText("same", "second")])))
        @Expect(!sdkViewAccepted(sdkViewDocument([], actions: [sdkViewAction("same"), sdkViewAction("same") ])))
        let list = jsonObject([JsonObjectEntry("id", jsonString("list")), JsonObjectEntry("kind", jsonString("list")),
            JsonObjectEntry("items", jsonArray([jsonObject([JsonObjectEntry("id", jsonString("actual")),
                JsonObjectEntry("text", jsonString("choice"))])])), JsonObjectEntry("selected_id", jsonString("foreign"))])
        @Expect(!sdkViewAccepted(sdkViewDocument([list])))
    }

    @TestCase
    func tableRowsMustMatchTheDisplayedColumns(): Unit {
        let table = jsonObject([JsonObjectEntry("id", jsonString("table")), JsonObjectEntry("kind", jsonString("table")),
            JsonObjectEntry("columns", jsonArray([jsonString("first"), jsonString("second")])),
            JsonObjectEntry("rows", jsonArray([jsonObject([JsonObjectEntry("id", jsonString("row")),
                JsonObjectEntry("cells", jsonArray([jsonString("only one cell")]))])]))])
        @Expect(!sdkViewAccepted(sdkViewDocument([table])))
    }

    @TestCase
    func nodeAndActionCeilingsHaveAnAcceptedBoundaryAndRejectTheNextEntry(): Unit {
        @Expect(sdkViewAccepted(sdkViewDocument(Array<JsonNode>(128, { index => sdkViewText("n" + index.toString(), "text") }))))
        @Expect(!sdkViewAccepted(sdkViewDocument(Array<JsonNode>(129, { index => sdkViewText("n" + index.toString(), "text") }))))
        @Expect(sdkViewAccepted(sdkViewDocument([], actions: Array<JsonNode>(16, { index => sdkViewAction("a" + index.toString()) }))))
        @Expect(!sdkViewAccepted(sdkViewDocument([], actions: Array<JsonNode>(17, { index => sdkViewAction("a" + index.toString()) }))))
    }

    @TestCase
    func aggregateTextAndCommandInputCannotHideAnUnboundedGraph(): Unit {
        @Expect(sdkViewAccepted(sdkViewDocument([sdkViewText("text", String.fromUtf8(Array<Byte>(64000, { _ => b'x' })))])))
        @Expect(!sdkViewAccepted(sdkViewDocument([sdkViewText("text", String.fromUtf8(Array<Byte>(66000, { _ => b'x' })))])))
        let bounded = jsonObject([JsonObjectEntry("values", jsonArray(Array<JsonNode>(200, { index => jsonNumber(index.toString()) })))])
        let dense = jsonObject([JsonObjectEntry("values", jsonArray(Array<JsonNode>(256, { index => jsonNumber(index.toString()) })))])
        @Expect(sdkViewAccepted(sdkViewDocument([], actions: [sdkViewAction("action", input: bounded)])))
        @Expect(!sdkViewAccepted(sdkViewDocument([], actions: [sdkViewAction("action", input: dense)])))
        var deep = jsonObject([])
        for (_ in 0..9) { deep = jsonObject([JsonObjectEntry("child", deep)]) }
        @Expect(!sdkViewAccepted(sdkViewDocument([], actions: [sdkViewAction("action", input: deep)])))
    }
}
