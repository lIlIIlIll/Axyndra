package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Real original-bank data-only owner. No physical FD/Source/Receipt/User
// decision/Known/installed Host executor is simulated by these controls.
private class PreparedReferenceTestCustody <: OwnedKernelPreparedReferenceCustody {
    private let ancestor:LogicalJsonOwnerReservation
    private var held:?OwnedKernelPreparedReferenceDebt=None<OwnedKernelPreparedReferenceDebt>
    let captures=AtomicInt64(0)
    init(ancestor:LogicalJsonOwnerReservation){this.ancestor=ancestor}
    public func retainPendingPreparedAliases(_:PreparedToolInvocation,_:PreparedToolInvocation):Result<LogicalJsonOwnerReservation>{
        try{Result.Ok(ancestor.deriveRetainedLease())}
        catch(_:Exception){Result.Err(AgentError(AgentErrorKind.BudgetExceeded,"test.reference_pressure","original bank is exhausted"))}
    }
    public func adoptKernelPreparedReferenceDebt(debt:OwnedKernelPreparedReferenceDebt):Result<Unit>{held=Some(debt);Result.Ok(())}
    public func pendingPreparedAliasesRetired(_:OwnedPendingPreparedAliasRetirement):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"test.legacy_token_unavailable","Kernel-only scope is not Host retirement"))}
    public func releaseTransient():Result<Unit>{Result.Ok(())}
    public func close():Result<Unit>{ancestor.close();Result.Ok(())}
    func debt():OwnedKernelPreparedReferenceDebt{held.getOrThrow()}
    func capture(parent:PreparedToolInvocation,child:PreparedToolInvocation):Result<OwnedToolExecutionContinuation>{
        let _=captures.fetchAdd(1)
        Result.Ok(OwnedToolExecutionContinuation(parent,child,child.approval.getOrThrow(),this))
    }
}

private func referencePrepared(context:ToolInvocationContext,id:String,arguments:AgentValue,
    request!:?ApprovalRequest=None<ApprovalRequest>,read!:?ToolPreparationRead=None<ToolPreparationRead>):PreparedToolInvocation{
    let call=ToolCall(id,"test.reference",arguments)
    let plan=NormalizedOperationPlan(call.name,arguments,[],OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Never,"test-reference-binding")
    // These constructors are package-private data fixtures only. A None root
    // cannot execute through the actual Pipeline Source gate.
    PreparedToolInvocation(OperationId(id),call,exclusiveToolConcurrency(),
        if(request.isSome()){PreparedAuthorization.ApprovalRequired}else{PreparedAuthorization.StaticPolicy},
        plan,PreparedInvocationSource(PreparedInvocationSourceKind.Direct,context,contextReadPreparation:read),approval:request)
}
private func referenceControl(parent:PreparedToolInvocation,child:?PreparedToolInvocation,
    custody:PreparedReferenceTestCustody,debt:OwnedKernelPreparedReferenceDebt):OwnedToolExecutionControl{
    OwnedToolExecutionControl(child,{=>Result<Unit>.Ok(())},
        {_,_,_=>ownedControlError<ToolPreparation>()},
        {actual,_=>custody.capture(parent,actual)},
        {_,_=>ownedControlError<ToolInvocationResult>()},
        terminalParent:Some(parent),referenceDebt:Some(debt))
}

// The actual SDK rejects generic tuple @Expect inference. Both original
// tuple components are checked from the same single actual usage snapshot.
private func preparedReferenceExpectUsage(actual: (Int64, Int64), expected: (Int64, Int64)): Unit {
    @Expect(actual[0], expected[0]); @Expect(actual[1], expected[1])
}

@Test
class OwnedPreparedReferencePhaseTests {
    @TestCase
    func completeOccurrenceSumIsPaidBeforePendingCaptureAndScopeClearNeverRefundsEscapers():Unit{
        let bank=LogicalJsonOwnerBudget();let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(33554432)
        let payload=String.fromUtf8(Array<Byte>(1048576,repeat:b'a'))+"\u{0000}雪"
        let arguments=objectValue([ValueField("payload",textValue(payload))])
        let context=ToolInvocationContext(RunId("reference-run"),SessionId("reference-thread"),CapabilitySet())
        let parent=referencePrepared(context,"reference-parent",arguments)
        let approval=ApprovalRequest(OperationId("reference-child"),"reference-child","test.reference",
            Capability(CapabilityKind.WorkspaceRead),preview:objectValue([]))
        let child=referencePrepared(context,"reference-child",arguments,request:Some(approval))
        let custody=PreparedReferenceTestCustody(ancestor)
        let debt=retainOwnedKernelPreparedReferenceDebt(custody,parent,Some(child)).value().getOrThrow()
        // Four actual call/plan text occurrences are SUM, despite the same
        // argument reference/string backing being reused in all four places.
        @Expect(bank.usage()[1]>33554432+payload.size*32,true)
        let control=referenceControl(parent,Some(child),custody,debt)
        @Expect(debt.controlFieldsWitness().isError(),true)
        @Expect(control.executeChild(context,child).error().getOrThrow().code,"tool.prepared_reference_retained_entry_required")
        let before=bank.usage()[1]
        let waiting=control.awaitChild(child,custody)
        @Expect(waiting.isOk(),true);@Expect(custody.captures.load(),1)
        @Expect(bank.usage()[1]>before+payload.size*16,true)
        control.close()
        @Expect(debt.controlFieldsWitness().value().getOrThrow().isControlFieldsCleared(),true)
        @Expect(control.approvedPendingChild().error().getOrThrow().code,"tool.live_control_closed")
        let highWater=bank.usage()
        @Expect(debt.closeAfterScopeRetirement().error().getOrThrow().code,"tool.prepared_reference_escapers_pending")
        preparedReferenceExpectUsage(bank.usage(),highWater)
        @Expect(custody.close().isOk(),true)
        // Immutable legacy Waiting and permanent parent still exist. The
        // true last derived lease remains charged even after ancestor close.
        preparedReferenceExpectUsage(bank.usage(),highWater)
        @Expect(waiting.isOk(),true)
    }

    @TestCase
    func originalAggregatePressureRejectsWholeChildBeforeCaptureAndKeepsParentDebt():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged:134217728);let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(33554432)
        let arguments=objectValue([ValueField("payload",textValue(String.fromUtf8(Array<Byte>(1048576,repeat:b'a'))))])
        let context=ToolInvocationContext(RunId("reference-pressure-run"),SessionId("reference-pressure-thread"),CapabilitySet())
        let parent=referencePrepared(context,"reference-pressure-parent",arguments)
        let request=ApprovalRequest(OperationId("reference-pressure-child"),"reference-pressure-child","test.reference",Capability(CapabilityKind.WorkspaceRead))
        let child=referencePrepared(context,"reference-pressure-child",arguments,request:Some(request))
        let custody=PreparedReferenceTestCustody(ancestor)
        let debt=retainOwnedKernelPreparedReferenceDebt(custody,parent,None<PreparedToolInvocation>).value().getOrThrow()
        let control=referenceControl(parent,None<PreparedToolInvocation>,custody,debt)
        let pressure=bank.acquire(1);pressure.ensureRetainedPeak(67108864)
        let charged=bank.usage()
        let waiting=control.awaitChild(child,custody)
        @Expect(waiting.error().getOrThrow().code,"tool.prepared_reference_capacity")
        @Expect(custody.captures.load(),0);preparedReferenceExpectUsage(bank.usage(),charged)
        // No retry after a precise pending choice failed payment.
        pressure.close()
        @Expect(control.awaitChild(child,custody).error().getOrThrow().code,"tool.live_control_closed")
        control.close();@Expect(debt.controlFieldsWitness().value().getOrThrow().isControlFieldsCleared(),true)
        @Expect(debt.closeAfterScopeRetirement().isError(),true)
        ancestor.close();@Expect(bank.usage()[1]>0,true)
    }

    @TestCase
    func unsupportedOpaqueReadCaptureFailsClosedWithoutPublishingOrRefundingOriginalOwner():Unit{
        let bank=LogicalJsonOwnerBudget();let ancestor=bank.acquire(1)
        let context=ToolInvocationContext(RunId("reference-opaque-run"),SessionId("reference-opaque-thread"),CapabilitySet())
        let read=ToolPreparationRead("test.reference","sha256:"+String.fromUtf8(Array<Byte>(64,repeat:b'a')),
            String.fromUtf8(Array<Byte>(64,repeat:b'b')),objectValue([]),{_,_=>Result<AgentValue>.Err(AgentError(
                AgentErrorKind.RecoveryRequired,"test.no_read","opaque closure is not walked"))})
        let parent=referencePrepared(context,"reference-opaque-parent",objectValue([]),read:Some(read))
        let custody=PreparedReferenceTestCustody(ancestor)
        let charged=bank.usage()
        @Expect(retainOwnedKernelPreparedReferenceDebt(custody,parent,None<PreparedToolInvocation>).error().getOrThrow().code,
            "tool.prepared_reference_opaque_source")
        @Expect(custody.captures.load(),0)
        // The failed empty derived lease closes, original16MiB floor remains.
        preparedReferenceExpectUsage(bank.usage(),charged)
        // This control does not retire the still-live original opaque parent.
        // Its own original payment remains held; no callback-return fiction.
        @Expect(bank.usage()[1],16777216)
    }
}
