package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func resourceTestPlan(permission!: String = "workspace.read", approval!: Bool = false): AgentValue {
    objectValue([ValueField("schema", textValue(CONTEXT_READ_RESOURCE_SCHEMA)), ValueField("binding", objectValue([])),
        ValueField("requires_approval", boolValue(approval)), ValueField("resources", listValue([
            objectValue([ValueField("kind", textValue("file")), ValueField("source", textValue("/workspace/file.txt")),
                ValueField("path", textValue("file.txt")), ValueField("witness", textValue("f:1:2:3:4:5")),
                ValueField("bytes", integerValue(4)), ValueField("permission", textValue(permission))])]))])
}
@Test
class ContextReadResourceShapeTests {
    @TestCase
    func classificationCannotBeSuppressedOrWeakenedWithExtraFields(): Unit {
        let ordinary = resourceTestPlan()
        @Expect(contextReadResourcePlanValid(ordinary)); @Expect(!contextReadResourceRequiresApproval(ordinary))
        let scoped = resourceTestPlan(permission: "outside-workspace.read", approval: true)
        scoped.put("read_scope_digest", textValue("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
        @Expect(contextReadResourcePlanValid(scoped)); @Expect(contextReadResourceRequiresApproval(scoped))
        for (invalid in [textValue(""), textValue("forged"), integerValue(1)]) {
            scoped.put("read_scope_digest", invalid); @Expect(!contextReadResourcePlanValid(scoped)) }
        let sensitive = resourceTestPlan(permission: "sensitive-path.read", approval: true)
        @Expect(contextReadResourcePlanValid(sensitive)); @Expect(contextReadResourceRequiresApproval(sensitive))
        sensitive.put("requires_approval", boolValue(false))
        @Expect(!contextReadResourcePlanValid(sensitive)); @Expect(contextReadResourceRequiresApproval(sensitive))
        ordinary.put("source", textValue("fake-host")); @Expect(!contextReadResourcePlanValid(ordinary))
        @Expect(contextReadResourceRequiresApproval(ordinary))
    }
    @TestCase
    func malformedSizesTraversalAndNoncanonicalResourceShapesAreRejected(): Unit {
        for (amount in [numberValue("-1"), numberValue("1.5"), numberValue("9223372036854775808"), integerValue(4194305)]) {
            let value = resourceTestPlan(); value.field("resources").getOrThrow().items[0].put("bytes", amount)
            @Expect(!contextReadResourcePlanValid(value))
        }
        for (path in ["../escape", "a//b", "/absolute", "a/./b"]) {
            let value = resourceTestPlan(); value.field("resources").getOrThrow().items[0].put("path", textValue(path))
            @Expect(!contextReadResourcePlanValid(value))
        }
        let value = resourceTestPlan(); value.field("resources").getOrThrow().items[0].put("kind", textValue("directory"))
        @Expect(!contextReadResourcePlanValid(value))
    }
    @TestCase
    func rawPayloadCannotSupplyAContextFactProjection(): Unit {
        let raw = objectValue([ValueField("plain", textValue("kept"))])
        @Expect(validateContextReadInputProjection(raw, []).isOk())
        raw.put(CONTEXT_READ_INPUT_FIELD, objectValue([ValueField("schema", textValue("axyndra.context-read-input/v1")),
            ValueField("data", objectValue([])), ValueField("facts", listValue([]))]))
        @Expect(validateContextReadInputProjection(raw, []).isError())
    }
}
