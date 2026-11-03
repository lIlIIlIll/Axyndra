package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class ToolInputAttachmentTests {
    @TestCase
    func literalSelectorIsBoundedAndCannotNameAPathOrHostEnvelope(): Unit {
        @Expect(toolInputAttachmentFieldValid("code")); @Expect(toolInputAttachmentFieldValid("_input7"))
        for (field in ["", "host_plan", CONTEXT_READ_INPUT_FIELD, "../code", "a.b", "/code", "0code", "code\u{0000}", "é"]) {
            @Expect(!toolInputAttachmentFieldValid(field))
        }
        @Expect(!toolInputAttachmentFieldValid(String.fromUtf8(Array<Byte>(65, repeat: b'a'))))
    }
    @TestCase
    func ProfileRequiresExactCanonicalLimitAndNoAuthorityFields(): Unit {
        let valid = objectValue([ValueField("field", textValue("code")), ValueField("max_bytes", integerValue(262144))])
        @Expect(toolInputAttachmentProfileValid(valid))
        for (limit in ["0", "-1", "262145", "262144.0", "2.62144e5"]) {
            let value = objectValue([ValueField("field", textValue("code")), ValueField("max_bytes", parseUnifiedJson(limit))])
            @Expect(!toolInputAttachmentProfileValid(value))
        }
        valid.put("grant", boolValue(true)); @Expect(!toolInputAttachmentProfileValid(valid))
    }
    @TestCase
    func OperatorGrantsRejectDuplicateContributionsAndUnboundedSelectors(): Unit {
        let grant = objectValue([ValueField("contribution", textValue("run")), ValueField("field", textValue("code")), ValueField("max_bytes", integerValue(262144))])
        @Expect(validToolInputAttachmentGrants(listValue([])))
        @Expect(validToolInputAttachmentGrants(listValue([grant])))
        @Expect(!validToolInputAttachmentGrants(listValue([grant, grant])))
        grant.put("artifact_ref", textValue("blob:sha256:" + modelPolicySha256Text("not an authority")))
        @Expect(!validToolInputAttachmentGrants(listValue([grant])))
    }
}
