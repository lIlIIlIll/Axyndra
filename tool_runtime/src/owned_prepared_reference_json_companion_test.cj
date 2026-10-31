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
private class PreparedJsonTestCustody <: OwnedKernelPreparedReferenceCustody {
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

private func jsonReferencePrepared(context:ToolInvocationContext,id:String,arguments:AgentValue,
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
private func jsonReferenceControl(parent:PreparedToolInvocation,child:?PreparedToolInvocation,
    custody:PreparedJsonTestCustody,debt:OwnedKernelPreparedReferenceDebt):OwnedToolExecutionControl{
    OwnedToolExecutionControl(child,{=>Result<Unit>.Ok(())},
        {_,_,_=>ownedControlError<ToolPreparation>()},
        {actual,_=>custody.capture(parent,actual)},
        {_,_=>ownedControlError<ToolInvocationResult>()},
        terminalParent:Some(parent),referenceDebt:Some(debt))
}

// Actual primary writer negative oracle, not a fabricated JsonKind DTO.
private class PreparedJsonUnsupportedNode <: JsonNode {
    private let advertised:JsonKind
    var kindCalls:Int64=0
    init(advertised:JsonKind){this.advertised=advertised}
    public func kind():JsonKind{kindCalls++;advertised}
    public func size():Int64{0}
    public func toString():String{"unsupported"}
    public func toPrettyString(indent:String):String{let _=indent;"unsupported"}
}
private func preparedJsonNested(containers:Int64):AgentValue{
    var value:AgentValue=JsonNode.int64(7)
    for(_ in 0..containers){value=JsonArray([value])}
    value
}

@Test
class OwnedPreparedJsonCompanionTests {
    @TestCase
    func postPreparationRealSelfCycleFailsBeforeWaitingCaptureAndClearsPaidPath():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        let context=ToolInvocationContext(RunId("json-cycle-run"),SessionId("json-cycle-thread"),CapabilitySet())
        let parent=jsonReferencePrepared(context,"json-cycle-parent",objectValue([]))
        let array=JsonArray([JsonNode.string("original")])
        let arguments:JsonObject=JsonObject().put("array",array)
        let request=ApprovalRequest(OperationId("json-cycle-child"),"json-cycle-child","test.reference",Capability(CapabilityKind.WorkspaceRead))
        let child=jsonReferencePrepared(context,"json-cycle-child",arguments,request:Some(request))
        let custody=PreparedJsonTestCustody(ancestor)
        let debt=retainOwnedKernelPreparedReferenceDebt(custody,parent,None<PreparedToolInvocation>).value().getOrThrow()
        let control=jsonReferenceControl(parent,None<PreparedToolInvocation>,custody,debt)
        array.insert(array.size(),array) // Actual mutable standard node, AFTER child Prepared.
        let writer=@AssertThrows[JsonException](stringifyUnifiedJson(arguments))
        let measure=OwnedPreparedReferenceMeasure(ancestor,8192)
        let current=@AssertThrows[JsonException](measure.prepared(child))
        @Expect(current.code,writer.code);@Expect(current.message,writer.message)
        @Expect(current.code,"cyclic_json_node");@Expect(measure.trackingIsEmpty(),true)
        let charged=bank.usage()
        @Expect(control.awaitChild(child,custody).isError(),true)
        @Expect(custody.captures.load(),0)
        @Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1],charged[1])
        control.close();@Expect(debt.controlFieldsWitness().isOk(),true)
        @Expect(debt.closeAfterScopeRetirement().isError(),true)
        // The actual caller-held cycle/Prepared still exists: NO refund.
        @Expect(bank.usage()[1]>0,true)
    }

    @TestCase
    func everyCustomAdvertisedKindIsRejectedWithoutCallingKindOrPublishing():Unit{
        for(kind in [JsonKind.Null,JsonKind.Boolean,JsonKind.Number,JsonKind.String,JsonKind.Array,JsonKind.Object]){
            let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
            let context=ToolInvocationContext(RunId("json-custom-run"),SessionId("json-custom-thread"),CapabilitySet())
            let parent=jsonReferencePrepared(context,"json-custom-parent",objectValue([]))
            let custom=PreparedJsonUnsupportedNode(kind)
            let arguments:JsonObject=JsonObject().put("unknown",custom)
            let request=ApprovalRequest(OperationId("json-custom-child"),"json-custom-child","test.reference",Capability(CapabilityKind.WorkspaceRead))
            let child=jsonReferencePrepared(context,"json-custom-child",arguments,request:Some(request))
            let custody=PreparedJsonTestCustody(ancestor)
            let debt=retainOwnedKernelPreparedReferenceDebt(custody,parent,None<PreparedToolInvocation>).value().getOrThrow()
            let control=jsonReferenceControl(parent,None<PreparedToolInvocation>,custody,debt)
            let writer=@AssertThrows[JsonException](stringifyUnifiedJson(arguments))
            let measure=OwnedPreparedReferenceMeasure(ancestor,8192)
            let current=@AssertThrows[JsonException](measure.prepared(child))
            @Expect(current.code,writer.code);@Expect(current.message,writer.message)
            @Expect(measure.trackingIsEmpty(),true);@Expect(custom.kindCalls,0)
            @Expect(control.awaitChild(child,custody).isError(),true)
            @Expect(custody.captures.load(),0);@Expect(custom.kindCalls,0)
            control.close();@Expect(debt.closeAfterScopeRetirement().isError(),true)
        }
    }

    @TestCase
    func sharedDagRetainsEveryOccurrenceAndAddsNoNewDataTraversalDepthPolicy():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        let context=ToolInvocationContext(RunId("json-dag-run"),SessionId("json-dag-thread"),CapabilitySet())
        let shared=JsonArray([JsonNode.string("shared")])
        let dag=objectValue([ValueField("left",shared),ValueField("right",shared)])
        let duplicate=objectValue([ValueField("left",JsonArray([JsonNode.string("shared")])),
            ValueField("right",JsonArray([JsonNode.string("shared")]))])
        let original=OwnedPreparedReferenceMeasure(ancestor,8192)
        original.prepared(jsonReferencePrepared(context,"json-dag",dag))
        let copied=OwnedPreparedReferenceMeasure(ancestor,8192)
        copied.prepared(jsonReferencePrepared(context,"json-dag",duplicate))
        @Expect(original.peak(),copied.peak());@Expect(original.trackingIsEmpty(),true)
        shared.set(0,JsonNode.string("shared!"))
        let changed=OwnedPreparedReferenceMeasure(ancestor,8192)
        changed.prepared(jsonReferencePrepared(context,"json-dag",dag))
        // Two call/plan occurrences times two DAG edges times eight layers.
        @Expect(changed.peak(),original.peak()+32)
        let scalars=JsonArray([JsonNode.nullValue,JsonNode.boolean(true),JsonNode.boolean(false),
            JsonNode.int64(Int64.Min),JsonNode.uint64(UInt64.Max),JsonNode.float64(1.5),
            JsonNode.number("1e-9"),JsonNode.string("雪\u{0000}")])
        let standard=OwnedPreparedReferenceMeasure(ancestor,8192)
        standard.prepared(jsonReferencePrepared(context,"json-standard",objectValue([ValueField("payload",scalars)])))
        @Expect(standard.trackingIsEmpty(),true)
        let deep=preparedJsonNested(257)
        let writer=@AssertThrows[JsonException](stringifyUnifiedJson(deep))
        @Expect(writer.code,"max_depth")
        let iterative=OwnedPreparedReferenceMeasure(ancestor,8192)
        iterative.prepared(jsonReferencePrepared(context,"json-deep",objectValue([ValueField("payload",deep)])))
        @Expect(iterative.trackingIsEmpty(),true);@Expect(iterative.peak()>0,true)
        // Pure data invoice adds no business depth cap. Actual original
        // writer/normal plan validation remains unchanged and rejects257.
    }

    @TestCase
    func originalAggregatePaysPathMetadataBeforeAllocationAndPressureClearsFrames():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(33554432)
        // Real original128MiB bank, seven slots. No reduced test pool.
        let p0=bank.acquire(1);let p1=bank.acquire(1);let p2=bank.acquire(1)
        let p3=bank.acquire(1);let p4=bank.acquire(1);let p5=bank.acquire(1)
        @Expect(bank.usage()[0],7);@Expect(bank.usage()[1],134217728)
        let context=ToolInvocationContext(RunId("json-path-pressure-run"),SessionId("json-path-pressure-thread"),CapabilitySet())
        let child=jsonReferencePrepared(context,"json-path-pressure",objectValue([ValueField("payload",preparedJsonNested(3))]))
        let measure=OwnedPreparedReferenceMeasure(ancestor,33554432)
        let _=@AssertThrows[LogicalJsonPayloadError](measure.prepared(child))
        @Expect(measure.trackingIsEmpty(),true)
        @Expect(bank.usage()[0],7);@Expect(bank.usage()[1],134217728)
        p0.close();p1.close();p2.close();p3.close();p4.close();p5.close()
        // All failed tracking frames were cleared; original caller-owned
        // Prepared remains funded by its live ancestor, never fake retired.
        @Expect(bank.usage()[0],1);@Expect(bank.usage()[1],33554432)
    }
}
