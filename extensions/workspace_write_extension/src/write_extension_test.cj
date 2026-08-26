package workspace_write_extension

import agent_sdk.*
import yjson.*
import yjson_support.*
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
        let result = WorkspaceWriteTool().validate(jsonObject([
            JsonObjectEntry("path", jsonString("app.js")),
            JsonObjectEntry("content", jsonString(content))
        ]))
        @Expect(result.isOk(), false)
    }
}
