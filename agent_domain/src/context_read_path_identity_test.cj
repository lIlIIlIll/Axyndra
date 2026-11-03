package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func identityShapePlan(directory: Bool, witness: String): AgentValue {
    objectValue([ValueField("schema", textValue(CONTEXT_READ_RESOURCE_SCHEMA)), ValueField("binding", objectValue([])),
        ValueField("requires_approval", boolValue(false)), ValueField("resources", listValue([objectValue([
            ValueField("kind", textValue(CONTEXT_READ_PATH_IDENTITY_KIND)), ValueField("source", textValue("/workspace/program")),
            ValueField("path", textValue("dap/program")), ValueField("witness", textValue(witness)), ValueField("bytes", integerValue(0)),
            ValueField("permission", textValue("workspace.read")), ValueField("is_directory", boolValue(directory))])]))])
}

@Test
class ContextReadPathIdentityShapeTests {
    @TestCase
    func ZeroContentIdentityDoesNotApplyTheOriginalFileContentCap(): Unit {
        // A metadata witness may name a large physical file, including an
        // invalid UTF-8 binary. The snapshot contains zero content bytes.
        let file = identityShapePlan(false, "f:1:2:3:67108865:5")
        let directory = identityShapePlan(true, "d:1:2:3:0:5")
        @Expect(contextReadResourcePlanValid(file)); @Expect(contextReadResourcePlanValid(directory))
        @Expect(!contextReadResourceRequiresApproval(file))
        let item = file.field("resources").getOrThrow().items[0]
        for (invalid in [integerValue(1), numberValue("1.5"), numberValue("-1"), numberValue("9223372036854775808")]) {
            item.put("bytes", invalid); @Expect(!contextReadResourcePlanValid(file)) }
        item.put("bytes", integerValue(0)); item.put("is_directory", textValue("false"))
        @Expect(!contextReadResourcePlanValid(file))
    }
    @TestCase
    func ExactPhysicalKindAndNormalClassificationCannotBeCallerWeakened(): Unit {
        let plan = identityShapePlan(false, "d:1:2:3:0:5")
        @Expect(!contextReadResourcePlanValid(plan))
        let item = plan.field("resources").getOrThrow().items[0]
        item.put("is_directory", boolValue(true)); item.put("permission", textValue("sensitive-path.read"))
        @Expect(!contextReadResourcePlanValid(plan)); @Expect(contextReadResourceRequiresApproval(plan))
        plan.put("requires_approval", boolValue(true)); @Expect(contextReadResourcePlanValid(plan))
        item.put("text", textValue("caller supplied binary")); @Expect(!contextReadResourcePlanValid(plan))
        let ordinary = resourceTestPlan(); ordinary.field("resources").getOrThrow().items[0].put("bytes", integerValue(4194305))
        @Expect(!contextReadResourcePlanValid(ordinary))
    }
}
