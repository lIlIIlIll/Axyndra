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
private class PreparedWaitingTestCustody <: OwnedKernelPreparedReferenceCustody {
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

private func waitingPrepared(context:ToolInvocationContext,id:String,arguments:AgentValue,
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
private func waitingControl(parent:PreparedToolInvocation,child:?PreparedToolInvocation,
    custody:PreparedWaitingTestCustody,debt:OwnedKernelPreparedReferenceDebt):OwnedToolExecutionControl{
    OwnedToolExecutionControl(child,{=>Result<Unit>.Ok(())},
        {_,_,_=>ownedControlError<ToolPreparation>()},
        {actual,_=>custody.capture(parent,actual)},
        {_,_=>ownedControlError<ToolInvocationResult>()},
        terminalParent:Some(parent),referenceDebt:Some(debt))
}

// Data-only phase controls. No Root/SQL/Known/effect/user approval/physical
// cleanup is simulated. None Source cannot pass the production Pipeline.
private class PreparedWaitingActionProbe {
    let calls=AtomicInt64(0)
    var seenBytes:Int64=0
}
@Test
class OwnedPreparedWaitingFieldsTests {
    @TestCase
    func fullPendingDataPhaseClearsOnlyItsOwnFieldsAndNeverRefundsExternalAliases():Unit{
        let bank=LogicalJsonOwnerBudget();let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(33554432)
        let context=ToolInvocationContext(RunId("waiting-fields-run"),SessionId("waiting-fields-thread"),CapabilitySet())
        let parent=waitingPrepared(context,"waiting-fields-parent",objectValue([]))
        let payload=String.fromUtf8(Array<Byte>(1048576,repeat:b'a'))+"\u{0000}雪"
        let request=ApprovalRequest(OperationId("waiting-fields-child"),"waiting-fields-child","test.reference",Capability(CapabilityKind.WorkspaceRead))
        let child=waitingPrepared(context,"waiting-fields-child",JsonObject().put("payload",JsonNode.string(payload)),request:Some(request))
        let custody=PreparedWaitingTestCustody(ancestor)
        let debt=retainOwnedKernelPreparedReferenceDebt(custody,parent,None<PreparedToolInvocation>).value().getOrThrow()
        let control=waitingControl(parent,None<PreparedToolInvocation>,custody,debt)
        let phase=control.awaitPreparedPhase(child,custody).value().getOrThrow()
        @Expect(custody.captures.load(),1);@Expect(phase.fieldsWitness().isError(),true)
        @Expect(control.prepareChild(context,child.call,"later").isError(),true)
        let charged=bank.usage();let probe=PreparedWaitingActionProbe()
        let witness=phase.consumeInputPhase({actual,approval=>
            let _=probe.calls.fetchAdd(1)
            @Expect(refEq(actual,child),true);@Expect(refEq(approval,request),true)
            probe.seenBytes=actual.call.arguments.field("payload").getOrThrow().asString().size
            Result<Unit>.Ok(())})
        @Expect(witness.isOk(),true);@Expect(witness.value().getOrThrow().isKernelInputFieldsCleared(),true)
        @Expect(probe.calls.load(),1);@Expect(probe.seenBytes,payload.size)
        @Expect(phase.consumeInputPhase({_,_=>Result<Unit>.Ok(())}).isError(),true)
        control.close();@Expect(debt.controlFieldsWitness().isOk(),true)
        @Expect(phase.closeAfterInputRetirement().error().getOrThrow().code,"tool.prepared_waiting_independent_escapers_pending")
        @Expect(debt.closeAfterScopeRetirement().isError(),true)
        @Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1],charged[1])
        // The test deliberately still holds full child/request/callback and
        // permanent parent. Limited field witness is not global retirement.
        @Expect(child.call.arguments.field("payload").getOrThrow().asString().size,payload.size)
        @Expect(bank.usage()[1]>0,true)
    }
    @TestCase
    func failedActionRetainsActualFieldsFundingAndCannotReplayOrMintWitness():Unit{
        let bank=LogicalJsonOwnerBudget();let ancestor=bank.acquire(1)
        let context=ToolInvocationContext(RunId("waiting-failure-run"),SessionId("waiting-failure-thread"),CapabilitySet())
        let parent=waitingPrepared(context,"waiting-failure-parent",objectValue([]))
        let request=ApprovalRequest(OperationId("waiting-failure-child"),"waiting-failure-child","test.reference",Capability(CapabilityKind.WorkspaceRead))
        let child=waitingPrepared(context,"waiting-failure-child",objectValue([]),request:Some(request))
        let custody=PreparedWaitingTestCustody(ancestor)
        let debt=retainOwnedKernelPreparedReferenceDebt(custody,parent,None<PreparedToolInvocation>).value().getOrThrow()
        let control=waitingControl(parent,None<PreparedToolInvocation>,custody,debt)
        let phase=control.awaitPreparedPhase(child,custody).value().getOrThrow()
        let probe=PreparedWaitingActionProbe();let charged=bank.usage()
        @Expect(phase.consumeInputPhase({_,_=>
            let _=probe.calls.fetchAdd(1);ownedPreparedWaitingError<Unit>("test.uncertain_action")}).error().getOrThrow().code,"test.uncertain_action")
        @Expect(phase.fieldsWitness().isError(),true)
        @Expect(phase.consumeInputPhase({_,_=>let _=probe.calls.fetchAdd(1);Result<Unit>.Ok(())}).isError(),true)
        @Expect(probe.calls.load(),1);control.close()
        @Expect(phase.closeAfterInputRetirement().isError(),true)
        @Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1],charged[1])
    }
    @TestCase
    func foreignCustodyAndRealOriginalPoolPressureFailBeforePrivateCapture():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged:134217728);let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(33554432)
        let context=ToolInvocationContext(RunId("waiting-pressure-run"),SessionId("waiting-pressure-thread"),CapabilitySet())
        let arguments:JsonObject=JsonObject().put("payload",JsonNode.string(String.fromUtf8(Array<Byte>(1048576,repeat:b'a'))))
        let parent=waitingPrepared(context,"waiting-pressure-parent",arguments)
        let request=ApprovalRequest(OperationId("waiting-pressure-child"),"waiting-pressure-child","test.reference",Capability(CapabilityKind.WorkspaceRead))
        let child=waitingPrepared(context,"waiting-pressure-child",arguments,request:Some(request))
        let custody=PreparedWaitingTestCustody(ancestor)
        let foreignCustody=PreparedWaitingTestCustody(ancestor)
        let debt=retainOwnedKernelPreparedReferenceDebt(custody,parent,None<PreparedToolInvocation>).value().getOrThrow()
        let control=waitingControl(parent,None<PreparedToolInvocation>,custody,debt)
        @Expect(control.awaitPreparedPhase(child,foreignCustody).error().getOrThrow().code,"tool.prepared_waiting_custody_changed")
        @Expect(custody.captures.load(),0);@Expect(foreignCustody.captures.load(),0)
        let pressure=bank.acquire(1);pressure.ensureRetainedPeak(67108864)
        let charged=bank.usage()
        @Expect(control.awaitPreparedPhase(child,custody).error().getOrThrow().code,"tool.prepared_reference_capacity")
        @Expect(custody.captures.load(),0)
        @Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1],charged[1])
        pressure.close()
        @Expect(control.awaitPreparedPhase(child,custody).isError(),true)
        control.close();@Expect(debt.closeAfterScopeRetirement().isError(),true)
    }
}
