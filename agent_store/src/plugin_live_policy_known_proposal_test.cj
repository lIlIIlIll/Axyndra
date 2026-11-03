package agent_store

import agent_domain.*
import yjson.*
import yjson_support.*

@Test
class LivePolicyKnownProposalDataTests {
    @TestCase
    func exactOriginalErrorDataAndNullStayDataOnly(){
        @Expect(livePolicyKnownProposalErrorDataValid(nullValue()),true)
        let original=objectValue([ValueField("kind",textValue("permission_denied")),ValueField("code",textValue("tool.approval_rejected")),
            ValueField("message",textValue("user rejected the pending tool operation")),ValueField("retryable",boolValue(false)),
            ValueField("fallback_allowed",boolValue(false)),ValueField("fields",listValue([objectValue([ValueField("name",textValue("tool")),ValueField("value",textValue("plugin.memory.retain"))])])),
            ValueField("attempt_failure",nullValue()),ValueField("observation",nullValue())])
        @Expect(livePolicyKnownProposalErrorDataValid(original),true)
        @Expect(canonicalAgentValue(original).isEmpty(),false)
    }
    @TestCase
    func legacyTwoFieldErrorCannotBecomeFabricatedFullTypedReplay(){
        @Expect(livePolicyKnownProposalErrorDataValid(objectValue([ValueField("code",textValue("plugin.live_child_user_rejected")),
            ValueField("message",textValue("the user rejected this reviewed child before execution"))])),false)
        @Expect(livePolicyKnownProposalErrorDataValid(textValue("success")),false)
    }
    @TestCase
    func fieldsAndAttachmentsKeepOriginalOuterTypes(){
        let value=objectValue([ValueField("kind",textValue("conflict")),ValueField("code",textValue("memory.cas_conflict")),
            ValueField("message",textValue("unchanged")),ValueField("retryable",integerValue(0)),ValueField("fallback_allowed",boolValue(false)),
            ValueField("fields",listValue([])),ValueField("attempt_failure",nullValue()),ValueField("observation",nullValue())])
        @Expect(livePolicyKnownProposalErrorDataValid(value),false)
    }
}
