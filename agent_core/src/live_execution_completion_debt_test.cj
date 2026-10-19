package agent_core

import agent_domain.*
import tool_runtime.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

// Pure result/debt carriers only. These do not mint a Source, canonical
// Receipt or Host custody and are not installed-Kernel acceptance tests.
@Test
class OwnedCompletionDebtCarrierTests {
    @TestCase
    func knownResultRetainsSamePayloadUntilOriginalConsumerAck():Unit {
        let released=AtomicBool(false)
        let lease=ToolResultPayloadLease({=>released.store(true)})
        let output=ToolResult("carrier-call",textValue("known"),receiptId:"carrier-parent",payloadLease:Some(lease))
        let result:Result<ToolInvocationResult> = Result.Ok(ToolInvocationResult.Completed(output))
        let debt=AgentError(AgentErrorKind.RecoveryRequired,"carrier.close_debt","physical collector remains unacknowledged")
        let slot=CoreOwnedSlotProgress(Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,debt)))
        @Expect(refEq(slot.settlementError.getOrThrow(),debt),true)
        match (slot.progress) {
            case Result.Ok(OwnedToolPipelineProgress.Completed(Result.Ok(ToolInvocationResult.Completed(actual)))) =>
                @Expect(refEq(actual,output),true)
                @Expect(refEq(actual.payloadLease.getOrThrow(),lease),true)
                @Expect(released.load(),false)
                actual.releasePayload()
            case _ => @Expect(false,true)
        }
        @Expect(released.load(),true)
    }
    @TestCase
    func physicalAndSchedulerFailuresRetainBothFullCauses():Unit {
        let output=ToolResult("carrier-call",textValue("known"))
        let result:Result<ToolInvocationResult> = Result.Ok(ToolInvocationResult.Completed(output))
        let debt=AgentError(AgentErrorKind.RecoveryRequired,"carrier.close_debt","close failed",fields:[ErrorField("owner","physical")])
        let scheduler=AgentError(AgentErrorKind.Internal,"carrier.sink_failed","event failed",fields:[ErrorField("phase","after-action")])
        let slot=CoreOwnedSlotProgress(Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,debt)),settlementError:Some(scheduler))
        let error=slot.settlementError.getOrThrow()
        @Expect(error.field("completion_cause").getOrThrow(),debt.code)
        @Expect(error.field("completion_detail").getOrThrow(),debt.describe())
        @Expect(error.field("settlement_cause").getOrThrow(),scheduler.code)
        @Expect(error.field("settlement_detail").getOrThrow(),scheduler.describe())
        @Expect(error.retryable,false)
        @Expect(error.fallbackAllowed,false)
    }
    @TestCase
    func canonicalCommitFailureRetainsEarlierPhysicalAndEventCauses():Unit {
        let debt=AgentError(AgentErrorKind.RecoveryRequired,"carrier.close_debt","close failed")
        let event=AgentError(AgentErrorKind.Internal,"carrier.event_failed","event failed")
        let earlier=coreOwnedMergeSettlementError(debt,Some(event))
        let commit=AgentError(AgentErrorKind.Conflict,"carrier.commit_failed","commit failed")
        let final=coreOwnedMergeSettlementError(commit,Some(earlier))
        @Expect(final.field("completion_cause").getOrThrow(),commit.code)
        @Expect(final.field("settlement_detail").getOrThrow(),earlier.describe())
        @Expect(earlier.field("completion_cause").getOrThrow(),debt.code)
        @Expect(earlier.field("settlement_cause").getOrThrow(),event.code)
    }
    @TestCase
    func ordinaryCompletedAndOuterErrorPreserveOriginalIdentity():Unit {
        let output=ToolResult("carrier-call",textValue("ordinary"))
        let result:Result<ToolInvocationResult> = Result.Ok(ToolInvocationResult.Completed(output))
        let completed=CoreOwnedSlotProgress(Result.Ok(OwnedToolPipelineProgress.Completed(result)))
        @Expect(completed.settlementError.isNone(),true)
        match (completed.progress) {
            case Result.Ok(OwnedToolPipelineProgress.Completed(Result.Ok(ToolInvocationResult.Completed(actual)))) => @Expect(refEq(actual,output),true)
            case _ => @Expect(false,true)
        }
        let error=AgentError(AgentErrorKind.RecoveryRequired,"carrier.unknown","no known terminal")
        let failed=CoreOwnedSlotProgress(Result.Err(error))
        @Expect(refEq(failed.progress.error().getOrThrow(),error),true)
        @Expect(failed.settlementError.isNone(),true)
        @Expect(refEq(coreOwnedMergeSettlementError(error,None),error),true)
        @Expect(refEq(coreOwnedMergeSettlementError(error,Some(error)),error),true)
    }
    @TestCase
    func innerUnknownWithDebtCannotBecomeCompleted():Unit {
        let unknown=AgentError(AgentErrorKind.RecoveryRequired,"carrier.unknown","no verified terminal")
        let debt=AgentError(AgentErrorKind.RecoveryRequired,"carrier.close_debt","close failed")
        let slot=CoreOwnedSlotProgress(Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(Result.Err(unknown),debt)))
        @Expect(slot.progress.isError(),true)
        let error=slot.progress.error().getOrThrow()
        @Expect(error.field("completion_cause").getOrThrow(),unknown.code)
        @Expect(error.field("settlement_cause").getOrThrow(),debt.code)
    }
    @TestCase
    func denialWithDebtCannotBecomeKnownCompleted():Unit {
        let reason=AgentError(AgentErrorKind.PermissionDenied,"carrier.denied","not a completed result")
        let debt=AgentError(AgentErrorKind.RecoveryRequired,"carrier.close_debt","close failed")
        let denied:Result<ToolInvocationResult> = Result.Ok(ToolInvocationResult.Denied(ToolDenial("carrier-call","carrier",reason)))
        let slot=CoreOwnedSlotProgress(Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(denied,debt)))
        @Expect(slot.progress.isError(),true)
        @Expect(slot.progress.error().getOrThrow().field("completion_cause").getOrThrow(),"tool.live_completed_debt_result_invalid")
        @Expect(slot.progress.error().getOrThrow().field("settlement_cause").getOrThrow(),debt.code)
    }
}
