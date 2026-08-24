package workspace_write_extension

import agent_sdk.*
import json4cj.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class WorkspaceWriteExtensionTests {
    @TestCase
    func advertisesBoundedSingleFileWrites() {
        let definition = WorkspaceWriteTool().definition()
        @Assert(definition.description.contains("one workspace file per call"))
        @Expect(
            definition.inputSchema.field("properties").getOrThrow()
                .field("content").getOrThrow()
                .field("maxLength").getOrThrow().number,
            "32768"
        )
    }

    @TestCase
    func rejectsOversizedUtf8Content() {
        var content = "x"
        for (_ in 0..16) {
            content += content
        }
        let result = WorkspaceWriteTool().validate(JsonValue.objectValue([
            JsonField("path", JsonValue.stringValue("app.js")),
            JsonField("content", JsonValue.stringValue(content))
        ]))
        @Expect(result.isOk(), false)
    }
}
