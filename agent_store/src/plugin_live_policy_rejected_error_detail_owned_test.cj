package agent_store

import agent_domain.*
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PluginLivePolicyRejectedErrorDetailOwnedTests {
    @TestCase
    func CompleteActualErrorRetainsEveryTypedAttachmentAndBorrowedOwner():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        let failure=AttemptFailure(AttemptFailureKind.UserCancelled,
            diagnostics:AttemptFailureDiagnostics(elapsedMillis:9,softDeadlineMillis:11,hardDeadlineMillis:13,
                enteredCompletionGrace:true,lastProgressKind:AttemptProgressKind.ToolArgumentProgress,
                lastProgressAgeMillis:3,providerTerminalObserved:true,openContentBlockCount:2,
                toolCallsStarted:7,toolCallsCompleted:5))
        let error=AgentError(AgentErrorKind.PermissionDenied,"tool.approval_rejected","actual rejection \u{0000} Ω",
            retryable:true,fallbackAllowed:true,fields:[ErrorField("reason","exact \u{0000} 原因")],
            attemptFailure:Some(failure),observation:Some(OperationObservation("{\"raw\":\"Ω\"}")))
        try{
            let value=livePolicyRejectedErrorDetailOwned(error,owner,196608,{=>Result<Unit>.Ok(())})
            @Expect(value.fields.size,8)
            @Expect(value.field("kind").getOrThrow().text,"permission_denied")
            @Expect(value.field("code").getOrThrow().text,error.code)
            @Expect(value.field("message").getOrThrow().text,error.message)
            @Expect(value.field("retryable").getOrThrow().asBool(),true)
            @Expect(value.field("fallback_allowed").getOrThrow().asBool(),true)
            @Expect(value.field("fields").getOrThrow().items[0].field("value").getOrThrow().text,error.fields[0].value)
            let attached=value.field("attempt_failure").getOrThrow()
            @Expect(attached.field("kind").getOrThrow().text,"user_cancelled")
            @Expect(attached.field("diagnostics").getOrThrow().field("tool_calls_completed").getOrThrow().asNumberText(),"5")
            @Expect(canonicalAgentValue(value.field("observation").getOrThrow()),canonicalAgentValue(error.observation.getOrThrow().toValue()))
            @Expect(pool.usage()[0],1)
            @Expect(canonicalAgentValue(decodeStoredValue(encodeStoredValue(value))),canonicalAgentValue(value))
        }finally{owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func OriginalUserErrorHasExplicitNullsWithoutInventedPastAttachments():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        let error=AgentError(AgentErrorKind.PermissionDenied,"tool.approval_rejected","user rejected the pending tool operation")
        try{
            let value=livePolicyRejectedErrorDetailOwned(error,owner,0,{=>Result<Unit>.Ok(())})
            @Expect(value.fields.size,8);@Expect(value.field("fields").getOrThrow().items.size,0)
            @Expect(value.field("retryable").getOrThrow().asBool(),error.retryable)
            @Expect(value.field("fallback_allowed").getOrThrow().asBool(),error.fallbackAllowed)
            @Expect(value.field("attempt_failure").getOrThrow().unifiedKind==ValueKind.Null,true)
            @Expect(value.field("observation").getOrThrow().unifiedKind==ValueKind.Null,true)
        }finally{owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func AggregatePressureRejectsBeforeNewDomAndDoesNotRefundBorrowedOwner():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let result=pool.acquire(8388608)
        let session=pool.acquire(65536);let registry=pool.acquire(65536);let owner=pool.acquire(65536)
        // Actual complete typed data, not a forged transport invoice. The
        // retained error must be cloned only after the joint pool admits it.
        let message=String.fromUtf8(Array<Byte>(2097152,repeat:65))
        let error=AgentError(AgentErrorKind.PermissionDenied,"tool.approval_rejected",message)
        let charged=pool.usage()[1]
        try{
            var rejected=false
            try{let _=livePolicyRejectedErrorDetailOwned(error,owner,196608,{=>Result<Unit>.Ok(())})}
            catch(error:Exception){rejected=true}
            @Expect(rejected,true);@Expect(pool.usage()[0],4);@Expect(pool.usage()[1],charged)
        }finally{owner.close();registry.close();session.close();result.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func ActualGuardFailurePreventsAllocationAndPreservesOwner():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536);let charged=pool.usage()[1]
        let error=AgentError(AgentErrorKind.PermissionDenied,"tool.approval_rejected","actual reason")
        try{
            var rejected=false
            try{let _=livePolicyRejectedErrorDetailOwned(error,owner,0,{=>Result<Unit>.Err(
                AgentError(AgentErrorKind.Cancelled,"test.cancelled","actual cancelled guard"))})}
            catch(error:Exception){rejected=true}
            @Expect(rejected,true);@Expect(pool.usage()[0],1);@Expect(pool.usage()[1],charged)
        }finally{owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
