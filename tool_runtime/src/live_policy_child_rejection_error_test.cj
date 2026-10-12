package tool_runtime

import agent_domain.*

@Test
class LivePolicyActualChildRejectionErrorTests {
    @TestCase
    func plainUserDecisionUsesTheOriginalToolErrorAndFields(){
        let call=ToolCall("actual-original-call","plugin.memory.retain",objectValue([]))
        let actual=livePolicyChildRejectionError(call,ApprovalDecision.Reject)
        @Expect(actual.kind,AgentErrorKind.PermissionDenied)
        @Expect(actual.code,"tool.approval_rejected")
        @Expect(actual.message,"user rejected the pending tool operation")
        @Expect(actual.fields.size,1)
        @Expect(actual.fields[0].name,"tool")
        @Expect(actual.fields[0].value,call.name)
    }
    @TestCase
    func originalReasonTextIsPreservedWithoutChangingTheTrimDecision(){
        let call=ToolCall("same-call","plugin.memory.retain",objectValue([]))
        let actual=livePolicyChildRejectionError(call,ApprovalDecision.RejectWithReason("  不允许\n原理由  "))
        @Expect(actual.message,"user rejected the pending tool operation:   不允许\n原理由  ")
        @Expect(actual.fields.size,2)
        @Expect(actual.fields[1].name,"reason")
        @Expect(actual.fields[1].value,"  不允许\n原理由  ")
        let blank=livePolicyChildRejectionError(call,ApprovalDecision.RejectWithReason("\t\r\n "))
        @Expect(blank.message,"user rejected the pending tool operation")
        @Expect(blank.fields.size,1)
    }
    @TestCase
    func ActualObjectKeepsAllOriginalDefaultAttachments(){
        let call=ToolCall("same-call","plugin.memory.retain",objectValue([]))
        let actual=livePolicyChildRejectionError(call,ApprovalDecision.Reject)
        let original=AgentError(AgentErrorKind.PermissionDenied,"tool.approval_rejected",
            "user rejected the pending tool operation",fields:rejectionFields(call.name,""))
        @Expect(actual.retryable,original.retryable)
        @Expect(actual.fallbackAllowed,original.fallbackAllowed)
        @Expect(actual.attemptFailure.isNone(),original.attemptFailure.isNone())
        @Expect(actual.observation.isNone(),original.observation.isNone())
    }
    @TestCase
    func ApprovalCannotBeDescribedAsARejectedOperation(){
        var rejected=false
        try{let _=livePolicyChildRejectionError(ToolCall("call","plugin.memory.retain",objectValue([])),ApprovalDecision.Approve)}
        catch(_:IllegalArgumentException){rejected=true}
        @Expect(rejected,true)
    }
}
