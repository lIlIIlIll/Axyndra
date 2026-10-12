package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Actual same-bank private data fixtures. None Root cannot pass Pipeline
// Source/policy/SQL/receipt gates; these do not simulate installed acceptance.
private class PreparedPhaseRouteCustody <: OwnedKernelPreparedReferenceCustody {
    private let ancestor:LogicalJsonOwnerReservation
    private var debts:?OwnedKernelPreparedReferenceDebt=None<OwnedKernelPreparedReferenceDebt>
    let captures=AtomicInt64(0)
    init(ancestor:LogicalJsonOwnerReservation){this.ancestor=ancestor}
    public func retainPendingPreparedAliases(_:PreparedToolInvocation,_:PreparedToolInvocation):Result<LogicalJsonOwnerReservation>{
        try{Result.Ok(ancestor.deriveRetainedLease())}catch(_:Exception){ownedPreparedWaitingError<LogicalJsonOwnerReservation>("test.pressure")}}
    public func adoptKernelPreparedReferenceDebt(value:OwnedKernelPreparedReferenceDebt):Result<Unit>{debts=Some(value);Result.Ok(())}
    public func pendingPreparedAliasesRetired(_:OwnedPendingPreparedAliasRetirement):Result<Unit>{ownedPreparedWaitingError<Unit>("test.host_escapers_live")}
    public func releaseTransient():Result<Unit>{Result.Ok(())}
    public func close():Result<Unit>{ownedPreparedWaitingError<Unit>("test.original_funding_pin")}
    func capture(parent:PreparedToolInvocation,child:PreparedToolInvocation):Result<OwnedToolExecutionContinuation>{
        let _=captures.fetchAdd(1);Result.Ok(OwnedToolExecutionContinuation(parent,child,child.approval.getOrThrow(),this))}
}
private func preparedPhaseRouteData(context:ToolInvocationContext,id:String,request:?ApprovalRequest):PreparedToolInvocation{
    let args:JsonObject=JsonObject().put("host_plan",JsonObject().put("binding",JsonObject().put("lane_id",JsonNode.string("phase-lane"))))
    let call=ToolCall(id,"test.prepared-phase",args)
    let plan=NormalizedOperationPlan(call.name,args,[],OperationEffectClass.ReadOnly,OperationRetryDisposition.Never,"phase-data-binding")
    PreparedToolInvocation(OperationId(id),call,exclusiveToolConcurrency(),
        if(request.isSome()){PreparedAuthorization.ApprovalRequired}else{PreparedAuthorization.StaticPolicy},
        plan,PreparedInvocationSource(PreparedInvocationSourceKind.Direct,context),approval:request)
}
private func preparedPhaseRouteControl(parent:PreparedToolInvocation,custody:PreparedPhaseRouteCustody,
    debt:OwnedKernelPreparedReferenceDebt):OwnedToolExecutionControl{
    OwnedToolExecutionControl(None<PreparedToolInvocation>,{=>Result<Unit>.Ok(())},
        {_,_,_=>ownedControlError<ToolPreparation>()},{child,_=>custody.capture(parent,child)},
        {_,_=>ownedControlError<ToolInvocationResult>()},terminalParent:Some(parent),referenceDebt:Some(debt))
}
@Test
class OwnedPreparedPipelinePhaseTests {
    @TestCase
    func paidPublicationClosesRawChildAccessButLoansFullOriginalApprovalAndParent():Unit{
        let bank=LogicalJsonOwnerBudget();let ancestor=bank.acquire(1)
        let context=ToolInvocationContext(RunId("phase-route-run"),SessionId("phase-route-thread"),CapabilitySet())
        let parent=preparedPhaseRouteData(context,"phase-route-parent",None<ApprovalRequest>)
        let request=ApprovalRequest(OperationId("phase-route-child"),"phase-route-child","test.prepared-phase",Capability(CapabilityKind.WorkspaceRead))
        let child=preparedPhaseRouteData(context,"phase-route-child",Some(request))
        let custody=PreparedPhaseRouteCustody(ancestor)
        let debt=retainOwnedKernelPreparedReferenceDebt(custody,parent,None<PreparedToolInvocation>).value().getOrThrow()
        let control=preparedPhaseRouteControl(parent,custody,debt)
        let phase=control.awaitPreparedPhase(child,custody).value().getOrThrow()
        let publication=OwnedToolExecutionPublication(context,phase,phase.pendingProof().value().getOrThrow())
        @Expect(publication.isPreparedPhase(),true);@Expect(publication.matchesContext(context),true)
        @Expect(refEq(publication.preparedParent().value().getOrThrow(),parent),true)
        let same=publication.withPreparedApproval({actual=>Result<Bool>.Ok(refEq(actual,request))})
        @Expect(same.value().getOrThrow(),true)
        let rawClosed=try{let _=publication.continuation;false}catch(_:IllegalStateException){true}
        @Expect(rawClosed,true)
        let charged=bank.usage()
        @Expect(phase.consumeInputPhase({_,_=>Result<Unit>.Ok(())}).isOk(),true)
        @Expect(publication.matchesContext(context),false)
        @Expect(publication.preparedParent().isError(),true)
        @Expect(publication.withPreparedApproval({actual=>Result<Bool>.Ok(refEq(actual,request))}).isError(),true)
        @Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1],charged[1])
        // Original parent/request/child/public caller aliases still paid.
        @Expect(child.call.callId,"phase-route-child");@Expect(phase.closeAfterInputRetirement().isError(),true)
    }
    @TestCase
    func approvedInputModeCannotPrepareAnotherChildOrClaimAcknowledgementWithoutActualCarrier():Unit{
        let bank=LogicalJsonOwnerBudget();let ancestor=bank.acquire(1)
        let context=ToolInvocationContext(RunId("phase-only-run"),SessionId("phase-only-thread"),CapabilitySet())
        let parent=preparedPhaseRouteData(context,"phase-only-parent",None<ApprovalRequest>)
        let child=preparedPhaseRouteData(context,"phase-only-child",None<ApprovalRequest>)
        let foreignPrepared=preparedPhaseRouteData(context,"phase-only-foreign",None<ApprovalRequest>)
        let custody=PreparedPhaseRouteCustody(ancestor)
        let debt=retainOwnedKernelPreparedReferenceDebt(custody,parent,Some(child)).value().getOrThrow()
        let control=preparedPhaseRouteControl(parent,custody,debt)
        @Expect(control.enterPreparedInputMode(Some(child)).isOk(),true)
        @Expect(control.prepareChild(context,foreignPrepared.call,"other").error().getOrThrow().code,"tool.prepared_input_action_only")
        @Expect(control.executeRetainedChild(context,foreignPrepared,custody).error().getOrThrow().code,"tool.prepared_input_exact_child_changed")
        @Expect(control.preparedInputActionAcknowledged().error().getOrThrow().code,"tool.prepared_input_known_child_missing")
        @Expect(control.awaitPreparedPhase(foreignPrepared,custody).error().getOrThrow().code,"tool.prepared_input_action_only")
        @Expect(custody.captures.load(),0)
        let charged=bank.usage();control.close()
        @Expect(control.preparedControlFieldsWitness().isOk(),true)
        @Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1],charged[1])
        @Expect(debt.closeAfterScopeRetirement().isError(),true)
    }
    @TestCase
    func invalidReadOnlyChoiceAndContextLeaveSamePaidPendingAvailableForValidRetry():Unit{
        // Source-only read-only guard control, NOT installed Pipeline/Root
        // acceptance: None Source cannot pass the production full validator.
        let bank=LogicalJsonOwnerBudget();let ancestor=bank.acquire(1)
        let context=ToolInvocationContext(RunId("preflight-run"),SessionId("preflight-thread"),CapabilitySet())
        let wrongContext=ToolInvocationContext(RunId("preflight-other"),SessionId("preflight-thread"),CapabilitySet())
        let parent=preparedPhaseRouteData(context,"preflight-parent",None<ApprovalRequest>)
        let base=defaultToolApprovalMetadata(Capability(CapabilityKind.WorkspaceRead))
        let metadata=ToolApprovalMetadata(base.capabilityLabel,base.assessment,base.grantScope,
            writeSummary:base.writeSummary,sessionApprovalAllowed:false)
        let request=ApprovalRequest(OperationId("preflight-child"),"preflight-child","test.prepared-phase",
            Capability(CapabilityKind.WorkspaceRead),metadata:metadata,sessionApprovalAllowed:false)
        let sourceData=preparedPhaseRouteData(context,"preflight-child",Some(request))
        let plan=NormalizedOperationPlan(sourceData.call.name,sourceData.call.arguments,[],OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Never,"preflight-one-time",approvalMetadata:Some(metadata))
        let child=PreparedToolInvocation(sourceData.operationId,sourceData.call,sourceData.concurrency,
            sourceData.authorization,plan,sourceData.source,approval:Some(request))
        let custody=PreparedPhaseRouteCustody(ancestor)
        let debt=retainOwnedKernelPreparedReferenceDebt(custody,parent,None<PreparedToolInvocation>).value().getOrThrow()
        let control=preparedPhaseRouteControl(parent,custody,debt)
        let phase=control.awaitPreparedPhase(child,custody).value().getOrThrow()
        let proof=phase.pendingProof().value().getOrThrow()
        @Expect(proof.releaseForPublication().isOk(),true)
        let publication=OwnedToolExecutionPublication(context,phase,proof)
        let charged=bank.usage();let validated=AtomicInt64(0)
        let check:(ApprovalRequest)->Result<Unit>={actual=>
            let _=validated.fetchAdd(1)
            @Expect(refEq(actual,request),true)
            Result<Unit>.Ok(())}
        @Expect(preflightOwnedPreparedPhaseDecision(context,publication,ApprovalDecision.ApproveSession,check).error().getOrThrow().code,"approval.session_scope_forbidden")
        @Expect(validated.load(),0);@Expect(phase.pendingProof().isOk(),true)
        @Expect(proof.awaitingDecision(),true);@Expect(phase.fieldsWitness().isError(),true)
        @Expect(preflightOwnedPreparedPhaseDecision(wrongContext,publication,ApprovalDecision.Approve,check).isError(),true)
        @Expect(validated.load(),0);@Expect(phase.pendingProof().isOk(),true)
        @Expect(preflightOwnedPreparedPhaseDecision(context,publication,ApprovalDecision.Approve,check).isOk(),true)
        @Expect(validated.load(),1);@Expect(proof.awaitingDecision(),true)
        @Expect(refEq(phase.pendingProof().value().getOrThrow(),proof),true)
        @Expect(publication.matchesContext(context),true)
        @Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1],charged[1])
        @Expect(custody.captures.load(),1)
        // A successful guard minted no claim/action/ACK/global witness and
        // remains Captured. Real production rechecks full Source/current/SQL
        // after transition; uncertain failure remains non-retryable debt.
        @Expect(phase.closeAfterInputRetirement().isError(),true)
        control.close();@Expect(debt.closeAfterScopeRetirement().isError(),true)
    }
}
