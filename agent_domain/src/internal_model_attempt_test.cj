package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class InternalModelInputTests {
    @TestCase
    func frozenNeutralInputDoesNotAliasCallerValues(): Unit {
        let args = objectValue([ValueField("a", textValue("before"))])
        let request = ModelRequest("model", [ModelMessage(ModelRole.User,
            [ModelBlock(ModelBlockKind.Text, text: "review", arguments: args)])], requestId: "review",
            tools: [], parallelToolCalls: false, toolChoice: ModelToolChoice.NoTools)
        let input = InternalModelAttemptInput(InternalModelPurpose.ApprovalReview, ThreadId("thread"), RunId("run"), 2, request)
        let digest = input.semanticDigest; let expected = canonicalAgentValue(input.request)
        args.put("a", textValue("after")); input.request.put("system", textValue("forged"))
        @Expect(input.semanticDigest == digest && canonicalAgentValue(input.request) == expected)
        @Expect(internalModelPurposeName(input.purpose) == "approval_review")
    }
    @TestCase
    func pureInputRejectsMissingOwnerAndToolAuthority(): Unit {
        var rejected: Int64 = 0
        for (epoch in [0, -1]) {
            try { let _ = InternalModelAttemptInput(InternalModelPurpose.ContextCompaction, ThreadId("t"), RunId("r"), epoch,
                ModelRequest("m", [], requestId: "input", tools: [], toolChoice: ModelToolChoice.NoTools)) }
            catch (_: Exception) { rejected += 1 }
        }
        try { let _ = InternalModelAttemptInput(InternalModelPurpose.ApprovalReview, ThreadId("t"), RunId("r"), 1,
            ModelRequest("m", [], requestId: "input", tools: [ModelToolDefinition("write", "write", objectValue([]))])) }
        catch (_: Exception) { rejected += 1 }
        @Expect(rejected == 3)
    }
}
