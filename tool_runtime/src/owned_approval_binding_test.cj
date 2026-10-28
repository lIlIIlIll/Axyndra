package tool_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

private func ownedBindingApproval(hash!:String="original-hash",resource!:String="ns",review!:?ApprovalReview=None):ApprovalRequest{
    ApprovalRequest(OperationId("original-operation"),"original-call","plugin.ns.tool",Capability(CapabilityKind.ExtensionInvoke,resource:resource),
        preview:objectValue([ValueField("input",listValue([integerValue(1),textValue("original")]))]),sessionId:"original-thread",
        argumentHash:hash,review:review)
}
@Test
class OwnedApprovalValueBindingTests{
    @TestCase
    func ApprovalDigestPreservesUtf8SubstringBoundariesAndEmbeddedZero():Unit{
        let source="prefix雪\u{0}ésuffix";let value=source[6..12]
        @Expect(approvalHash(value),"12967170585085956425")
        @Expect(value,"雪\u{0}é");@Expect(source,"prefix雪\u{0}ésuffix")
    }
    @TestCase
    func ReloadedEqualApprovalDoesNotNeedObjectIdentity():Unit{
        let retained=ownedBindingApproval();let reloaded=ownedBindingApproval()
        @Expect(refEq(retained,reloaded),false)
        @Expect(sameRetainedOwnedApproval(retained,reloaded),true)
    }
    @TestCase
    func DifferentArgumentDigestCannotReuseRetainedApproval():Unit{
        @Expect(sameRetainedOwnedApproval(ownedBindingApproval(),ownedBindingApproval(hash:"changed-hash")),false)
    }
    @TestCase
    func DifferentCapabilityResourceCannotReuseRetainedApproval():Unit{
        @Expect(sameRetainedOwnedApproval(ownedBindingApproval(),ownedBindingApproval(resource:"other-ns")),false)
    }
    @TestCase
    func DifferentReviewAndPreviewCannotReuseRetainedApproval():Unit{
        let retained=ownedBindingApproval(review:Some(ApprovalReview(ApprovalReviewDecision.AskUser,"original","low","reviewer")))
        let same=ownedBindingApproval(review:Some(ApprovalReview(ApprovalReviewDecision.AskUser,"original","low","reviewer")))
        @Expect(sameRetainedOwnedApproval(retained,same),true)
        @Expect(sameRetainedOwnedApproval(retained,ownedBindingApproval(review:Some(ApprovalReview(ApprovalReviewDecision.Approve,"original","low","reviewer")))),false)
        let changed=ApprovalRequest(same.operationId,same.callId,same.toolName,same.capability,preview:objectValue([]),
            sessionId:same.sessionId,argumentHash:same.argumentHash,review:same.review)
        @Expect(sameRetainedOwnedApproval(retained,changed),false)
    }
}
