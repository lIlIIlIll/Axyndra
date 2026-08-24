package ast_extension

import agent_sdk.*
import json4cj.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class AstExtensionTests {
    @TestCase
    func validatesAndPreparesExactReadIntent() {
        let tool = AstGrepExtensionTool()
        let input = JsonValue.objectValue([JsonField("pat", JsonValue.stringValue("$X"))])
        let prepared = tool.prepare(ToolInvocation("ast-1", input, "/workspace", "/workspace"))
        @Assert(prepared.isOk())
        match (prepared) {
            case SdkResult.Ok(OperationIntent.HostOperation(value)) =>
                @Expect(value.operation, "ast_grep")
                @Expect(value.input.stringify(), input.stringify())
            case _ => @Fail("expected exact host operation intent")
        }
    }

    @TestCase
    func rejectsUnsafeOrIncompleteEditInput() {
        let tool = AstEditExtensionTool()
        @Expect(tool.validate(JsonValue.objectValue([])).isOk(), false)
        @Expect(tool.definition().effect == ExtensionEffect.SideEffect)
        @Expect(tool.definition().capabilities[0].name, "workspace.write")
    }
}
