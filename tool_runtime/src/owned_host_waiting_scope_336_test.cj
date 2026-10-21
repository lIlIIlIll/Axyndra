package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// These are real bank/typed data controls only. Private None-root fixtures
// cannot execute through actual Pipeline Source gates and fabricate no Known,
// Receipt, durable approval, Host installation, physical ACK or Root proof.
private class HostWaitingScopeTestCustody336 <: OwnedKernelPreparedReferenceCustody {
    private let ancestor:LogicalJsonOwnerReservation
    private var held:?OwnedKernelPreparedReferenceDebt=None<OwnedKernelPreparedReferenceDebt>
    init(ancestor:LogicalJsonOwnerReservation){this.ancestor=ancestor}
    public func retainPendingPreparedAliases(_:PreparedToolInvocation,_:PreparedToolInvocation):Result<LogicalJsonOwnerReservation>{
        try{Result.Ok(ancestor.deriveRetainedLease())}
        catch(_:Exception){ownedPreparedWaitingError<LogicalJsonOwnerReservation>("test.reference_pressure")}
    }
    public func adoptKernelPreparedReferenceDebt(debt:OwnedKernelPreparedReferenceDebt):Result<Unit>{held=Some(debt);Result.Ok(())}
    public func pendingPreparedAliasesRetired(_:OwnedPendingPreparedAliasRetirement):Result<Unit>{
        ownedPreparedWaitingError<Unit>("test.no_host_retirement")}
    public func releaseTransient():Result<Unit>{Result.Ok(())}
    public func close():Result<Unit>{ancestor.close();Result.Ok(())}
    func capture(parent:PreparedToolInvocation,child:PreparedToolInvocation):Result<OwnedToolExecutionContinuation>{
        Result.Ok(OwnedToolExecutionContinuation(parent,child,child.approval.getOrThrow(),this))}
}
private func hostWaitingPrepared336(context:ToolInvocationContext,id:String,arguments:AgentValue,
    request!:?ApprovalRequest=None<ApprovalRequest>):PreparedToolInvocation{
    let actualCall=ToolCall(id,"test.host_scope",arguments)
    let plan=NormalizedOperationPlan(actualCall.name,arguments,[],OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Never,"test-host-scope-binding")
    PreparedToolInvocation(OperationId(id),actualCall,exclusiveToolConcurrency(),
        if(request.isSome()){PreparedAuthorization.ApprovalRequired}else{PreparedAuthorization.StaticPolicy},
        plan,PreparedInvocationSource(PreparedInvocationSourceKind.Direct,context),approval:request)
}
private func hostWaitingControl336(parent:PreparedToolInvocation,custody:HostWaitingScopeTestCustody336,
    debt:OwnedKernelPreparedReferenceDebt):OwnedToolExecutionControl{
    OwnedToolExecutionControl(None<PreparedToolInvocation>,{=>Result<Unit>.Ok(())},
        {_,_,_=>ownedControlError<ToolPreparation>()},{child,_=>custody.capture(parent,child)},
        {_,_=>ownedControlError<ToolInvocationResult>()},terminalParent:Some(parent),referenceDebt:Some(debt))
}
private class HostWaitingActionProbe336 {let calls=AtomicInt64(0)}

@Test
class OwnedHostWaitingScope336Tests {
    @TestCase
    func sameActualConsumedPhaseRejectsForeignDebtCustodyAndFreshWitnessReplay():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        let context=ToolInvocationContext(RunId("host-scope-run"),SessionId("host-scope-thread"),CapabilitySet())
        let parent=hostWaitingPrepared336(context,"host-scope-parent",objectValue([]))
        let request=ApprovalRequest(OperationId("host-scope-child"),"host-scope-child","test.host_scope",Capability(CapabilityKind.WorkspaceRead))
        let child=hostWaitingPrepared336(context,"host-scope-child",objectValue([]),request:Some(request))
        let custody=HostWaitingScopeTestCustody336(ancestor)
        let debt=retainOwnedKernelPreparedReferenceDebt(custody,parent,None<PreparedToolInvocation>).value().getOrThrow()
        let control=hostWaitingControl336(parent,custody,debt)
        let phase=control.awaitPreparedPhase(child,custody).value().getOrThrow()
        @Expect(phase.claimHostWaitingScope336(custody,debt),false)
        @Expect(phase.fieldsWitness().isError(),true)
        let witness=phase.consumeInputPhase({_,_=>Result<Unit>.Ok(())}).value().getOrThrow()
        let foreignCustody=HostWaitingScopeTestCustody336(ancestor)
        let foreignDebt=retainOwnedKernelPreparedReferenceDebt(foreignCustody,parent,None<PreparedToolInvocation>).value().getOrThrow()
        let sameCustodyOtherDebt=retainOwnedKernelPreparedReferenceDebt(custody,parent,None<PreparedToolInvocation>).value().getOrThrow()
        let charged=bank.usage()
        @Expect(witness.matchesHostWaitingScope336(foreignCustody,debt),false)
        @Expect(witness.claimHostWaitingScope336(foreignCustody,foreignDebt),false)
        @Expect(witness.matchesHostWaitingScope336(custody,sameCustodyOtherDebt),false)
        @Expect(witness.claimHostWaitingScope336(custody,sameCustodyOtherDebt),false)
        @Expect(witness.matchesHostWaitingScope336(custody,debt),true)
        @Expect(witness.claimHostWaitingScope336(custody,debt),true)
        @Expect(witness.claimHostWaitingScope336(custody,debt),false)
        let newlyIssued=phase.fieldsWitness().value().getOrThrow()
        @Expect(newlyIssued.isKernelInputFieldsCleared(),true)
        @Expect(newlyIssued.matchesHostWaitingScope336(custody,debt),false)
        @Expect(newlyIssued.claimHostWaitingScope336(custody,debt),false)
        let otherControl=hostWaitingControl336(parent,custody,sameCustodyOtherDebt)
        let later=otherControl.awaitPreparedPhase(child,custody).value().getOrThrow()
        let laterWitness=later.consumeInputPhase({_,_=>Result<Unit>.Ok(())}).value().getOrThrow()
        @Expect(laterWitness.claimHostWaitingScope336(custody,debt),false)
        @Expect(laterWitness.claimHostWaitingScope336(custody,sameCustodyOtherDebt),true)
        @Expect(newlyIssued.claimHostWaitingScope336(custody,sameCustodyOtherDebt),false)
        @Expect(phase.closeAfterInputRetirement().isError(),true)
        @Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1]>=charged[1],true)
        control.close();otherControl.close()
        @Expect(debt.closeAfterScopeRetirement().isError(),true)
        @Expect(sameCustodyOtherDebt.closeAfterScopeRetirement().isError(),true)
    }

    @TestCase
    func actualTypedActionClearsPrivateInputOnlyAndKeepsOriginalBankPaid():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        let context=ToolInvocationContext(RunId("host-action-run"),SessionId("host-action-thread"),CapabilitySet())
        let payload=String.fromUtf8(Array<Byte>(8192,repeat:b'a'))+"雪\u{0000}"
        let request=ApprovalRequest(OperationId("host-action-child"),"host-action-child","test.host_scope",Capability(CapabilityKind.WorkspaceRead))
        let child=hostWaitingPrepared336(context,"host-action-child",objectValue([ValueField("payload",JsonNode.string(payload))]),request:Some(request))
        let backing=ancestor.deriveRetainedLease()
        let action=retainOwnedHostPreparedActionData336(backing,child,ApprovalDecision.RejectWithReason(payload)).value().getOrThrow()
        let probe=HostWaitingActionProbe336()
        @Expect(action.inputFieldsCleared336(),false)
        @Expect(action.consumeInput336({actual,decision,approval=>
            let _=probe.calls.fetchAdd(1)
            @Expect(refEq(actual,child),true);@Expect(refEq(approval.getOrThrow(),request),true)
            let sameReason=match(decision){case ApprovalDecision.RejectWithReason(reason)=>reason==payload;case _=>false}
            @Expect(sameReason,true)
            Result<Unit>.Ok(())}).isOk(),true)
        @Expect(probe.calls.load(),1);@Expect(action.inputFieldsCleared336(),true)
        let ledger=objectValue([ValueField("payload",JsonNode.string(payload))])
        @Expect(action.retainLedgerOccurrence336(ledger).isOk(),true)
        let charged=bank.usage()
        @Expect(action.consumeInput336({_,_,_=>let _=probe.calls.fetchAdd(1);Result<Unit>.Ok(())}).isError(),true)
        @Expect(probe.calls.load(),1);@Expect(action.closeAfterRetirement336().isError(),true)
        ancestor.close()
        @Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1],charged[1])
        @Expect(child.call.arguments.field("payload").getOrThrow().asString(),payload)
    }

    @TestCase
    func uncertainActualActionRetainsInputAndCannotReplayOrClaimPrivateFields():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        let context=ToolInvocationContext(RunId("host-action-fail-run"),SessionId("host-action-fail-thread"),CapabilitySet())
        let request=ApprovalRequest(OperationId("host-action-fail"),"host-action-fail","test.host_scope",Capability(CapabilityKind.WorkspaceRead))
        let child=hostWaitingPrepared336(context,"host-action-fail",objectValue([]),request:Some(request))
        let action=retainOwnedHostPreparedActionData336(ancestor.deriveRetainedLease(),child,ApprovalDecision.Approve).value().getOrThrow()
        let probe=HostWaitingActionProbe336();let charged=bank.usage()
        @Expect(action.consumeInput336({_,_,_=>let _=probe.calls.fetchAdd(1);
            ownedPreparedWaitingError<Unit>("test.uncertain_host_action")}).error().getOrThrow().code,"test.uncertain_host_action")
        @Expect(action.inputFieldsCleared336(),false)
        @Expect(action.consumeInput336({_,_,_=>let _=probe.calls.fetchAdd(1);Result<Unit>.Ok(())}).isError(),true)
        @Expect(probe.calls.load(),1);@Expect(action.closeAfterRetirement336().isError(),true)
        ancestor.close();@Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1],charged[1])
    }

    @TestCase
    func completeMetadataAndBothLedgerOccurrencesSumOnOneOriginalAllocation():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(16777216)
        let payload=JsonNode.string(String.fromUtf8(Array<Byte>(65536,repeat:b'a'))+"雪\u{0000}")
        let graph=objectValue([ValueField("payload",payload)])
        let empty=ancestor.deriveRetainedLease();let one=ancestor.deriveRetainedLease();let three=ancestor.deriveRetainedLease()
        let baseline=ownedHostJsonOccurrenceInvoice336(empty,JsonNode.nullValue,JsonNode.nullValue,JsonNode.nullValue).value().getOrThrow()
        let once=ownedHostJsonOccurrenceInvoice336(one,graph,JsonNode.nullValue,JsonNode.nullValue).value().getOrThrow()
        let thrice=ownedHostJsonOccurrenceInvoice336(three,graph,graph,graph).value().getOrThrow()
        @Expect(thrice-baseline,3*(once-baseline))
        let charged=bank.usage();@Expect(charged[0],1)
        @Expect(charged[1]>=16777216+baseline+once+thrice,true)
        ancestor.close();empty.close();one.close()
        @Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1],charged[1])
        @Expect(graph.field("payload").getOrThrow().asString().size,65540)
        three.close();@Expect(bank.usage()[0],0);@Expect(bank.usage()[1],0)
    }

    @TestCase
    func originalFull128MiBBankRejectsCompleteActionBeforePublishingHolder():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        let backing=ancestor.deriveRetainedLease();backing.ensureRetainedPeak(8192)
        let context=ToolInvocationContext(RunId("host-action-pressure-run"),SessionId("host-action-pressure-thread"),CapabilitySet())
        let payload=JsonNode.string(String.fromUtf8(Array<Byte>(1048576,repeat:b'a')))
        let child=hostWaitingPrepared336(context,"host-action-pressure",objectValue([ValueField("payload",payload)]))
        let p0=bank.acquire(1);let p1=bank.acquire(1);let p2=bank.acquire(1);let p3=bank.acquire(1)
        let p4=bank.acquire(1);let p5=bank.acquire(1);let p6=bank.acquire(1)
        let charged=bank.usage();@Expect(charged[0],8);@Expect(charged[1],134217728)
        @Expect(retainOwnedHostPreparedActionData336(backing,child,ApprovalDecision.Approve).error().getOrThrow().code,"tool.host_input_invoice_unpaid")
        @Expect(ownedHostJsonOccurrenceInvoice336(backing,payload,payload,payload).error().getOrThrow().code,"tool.host_metadata_occurrence_unpaid")
        @Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1],charged[1])
        p0.close();p1.close();p2.close();p3.close();p4.close();p5.close();p6.close()
        ancestor.close();backing.close();@Expect(bank.usage()[0],0);@Expect(bank.usage()[1],0)
    }
}
