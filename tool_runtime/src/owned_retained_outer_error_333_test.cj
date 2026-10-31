package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

// Private data route controls only. Bare fixture Prepared data cannot pass
// actual Pipeline Source/current/policy/SQL/handoff gates; no Root claim.
private class OuterErrorRoute333 <: PluginLivePolicyOuterErrorDataOwner331 &
    AcknowledgedOperationTerminalDataOwner & LiveToolExecutionCustody &
    RetainedOwnedToolEffectExecutor & RetainedOwnedToolOuterErrorEffectExecutor331 {
    private let payment:LogicalJsonOwnerReservation
    private let error:AgentError
    let typed=AtomicInt64(0)
    let legacy=AtomicInt64(0)
    let closeAttempts=AtomicInt64(0)
    init(bank:LogicalJsonOwnerBudget){
        payment=bank.acquire(1);payment.ensureRetainedPeak(1048576)
        error=AgentError(AgentErrorKind.RecoveryRequired,"test.full_error","full\u{0000}雪")
    }
    public func matchesError(value:AgentError):Bool{refEq(value,error)}
    public func withError(consume:(AgentError)->Result<Unit>):Result<Unit>{consume(error)}
    public func isConsumerRetired():Bool{false}
    public func closeAfterConsumerRetirement():Result<Unit>{retainedOutputError("test.aliases_live")}
    public func withRetainedOutput(_:ToolResultPayloadLease,
        _:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        retainedOutputError("test.no_known_output")}
    public func closeUnpublishedOutput():Result<Unit>{
        let _=closeAttempts.fetchAdd(1);retainedOutputError("test.actual_ack_pending")}
    public func releaseTransient():Result<Unit>{Result.Ok(())}
    public func close():Result<Unit>{retainedOutputError("test.custody_still_paid")}
    public func executeRetainedEffect(_:ToolInvocationContext,_:PreparedToolInvocation,
        _:PreparedToolInvocation,_:LiveToolExecutionCustody):OwnedRetainedToolEffectOutcome{
        let _=legacy.fetchAdd(1)
        OwnedRetainedToolEffectOutcome(ToolExecutionOutcome(Result.Err(error)),this)
    }
    public func executeRetainedOuterErrorEffect331(_:ToolInvocationContext,_:PreparedToolInvocation,
        _:PreparedToolInvocation,_:LiveToolExecutionCustody):OwnedRetainedOuterErrorEffectOutcome331{
        let _=typed.fetchAdd(1);OwnedRetainedOuterErrorEffectOutcome331.Failed(this,this)
    }
}
private func outerErrorSame333(value:PluginLivePolicyOuterErrorDataOwner331,expected:OuterErrorRoute333):Bool{
    match(value as Object){case Some(actual)=>refEq(actual,expected);case None=>false}
}
private func outerErrorPrepared333(context:ToolInvocationContext,id:String):PreparedToolInvocation{
    let call=ToolCall(id,"test.outer-error",objectValue([]))
    let plan=NormalizedOperationPlan(call.name,call.arguments,[],OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Never,"test-data-only")
    PreparedToolInvocation(OperationId(id),call,exclusiveToolConcurrency(),PreparedAuthorization.StaticPolicy,
        plan,PreparedInvocationSource(PreparedInvocationSourceKind.Direct,context))
}
@Test
class OwnedRetainedOuterErrorRoute333Tests {
    @TestCase
    func actualTypedDispatchKeepsSameErrorAndUnpublishedCleanupOwnerWithoutRawError():Unit{
        let bank=LogicalJsonOwnerBudget();let route=OuterErrorRoute333(bank)
        let context=ToolInvocationContext(RunId("outer-run"),SessionId("outer-thread"),CapabilitySet())
        let parent=outerErrorPrepared333(context,"parent");let child=outerErrorPrepared333(context,"child")
        let request=OwnedRetainedChildRequest(parent,route)
        let result=request.execute(route,context,parent,child)
        @Expect(route.typed.load(),1);@Expect(route.legacy.load(),0)
        @Expect(result.result.error().getOrThrow().code,"tool.owned_outer_error_pending")
        @Expect(outerErrorSame333(request.outerErrorData333().getOrThrow(),route),true)
        let resources=OwnedRetainedInvocationResources();resources.admit(request)
        let failure=resources.failure().getOrThrow();let before=bank.usage()
        @Expect(outerErrorSame333(failure.outerErrorData333().getOrThrow(),route),true)
        @Expect(failure.closeAfterFailure().isError(),true);@Expect(failure.isAcknowledged(),false)
        @Expect(route.closeAttempts.load(),1)
        @Expect(bank.usage()[0],before[0]);@Expect(bank.usage()[1],before[1])
        // Missing paid subtype cannot silently fall back to its raw getter.
        let captureDenied=try{let _=OwnedOuterErrorPending333(route);false}
            catch(_:IllegalStateException){true}
        @Expect(captureDenied,true)
        @Expect(failure.isAcknowledged(),false)
        @Expect(bank.usage()[0],before[0]);@Expect(bank.usage()[1],before[1])
    }
    @TestCase
    func changedParentIsRejectedBeforeEitherEffectMethodAndCannotCaptureErrorOwner():Unit{
        let bank=LogicalJsonOwnerBudget();let route=OuterErrorRoute333(bank)
        let context=ToolInvocationContext(RunId("other-run"),SessionId("thread"),CapabilitySet())
        let parent=outerErrorPrepared333(context,"parent")
        let request=OwnedRetainedChildRequest(parent,route)
        let result=request.execute(route,context,outerErrorPrepared333(context,"different"),outerErrorPrepared333(context,"child"))
        @Expect(result.result.error().getOrThrow().code,"tool.retained_parent_changed")
        @Expect(route.typed.load(),0);@Expect(route.legacy.load(),0)
        @Expect(request.outerErrorData333().isNone(),true)
    }
}
