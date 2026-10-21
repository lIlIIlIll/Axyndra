package tool_runtime

import agent_domain.*
import agent_runtime.*
import agent_ports.*
import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private class Preparation340Audit <: AuditPort {
    public func append(_:AgentEvent):Result<Unit>{Result<Unit>.Ok(())}
}
private class Preparation340Ids <: IdGenerator {
    var next:Int64=0
    public func nextRunId():RunId{RunId("preparation-340-run")}
    public func nextSessionId():SessionId{SessionId("preparation-340-thread")}
    public func nextOperationId():OperationId{next++;OperationId("preparation-340-op-"+next.toString())}
}
// Actual installed Pipeline preparation callback ordering and original-bank
// pressure control only. No Root/Receipt/Host/Native effect is synthesized.
private class Preparation340Executor <: ToolExecutor & OwnedPreparationInputExecutor340 {
    private let ancestor:LogicalJsonOwnerReservation
    private let loans=ArrayList<LogicalJsonOwnerReservation>()
    var paid=false
    var canonicalCalls:Int64=0
    var executions:Int64=0
    init(ancestor:LogicalJsonOwnerReservation){this.ancestor=ancestor}
    public func retainPreparationInput340(context:ToolInvocationContext,root:?OperationRootSource,
        call:ToolCall,facts:Array<ContextReadFactLink>):Result<Unit>{
        try{
            let loan=ancestor.deriveRetainedLease();loans.add(loan)
            match(ownedPreparationInputInvoice340(loan,context,root,call,facts)){
                case Result.Err(error)=>Result<Unit>.Err(error);case Result.Ok(_)=>paid=true;Result<Unit>.Ok(())}
        }catch(_:Exception){ownedPreparedWaitingError<Unit>("test.original_preparation_pressure")}
    }
    func canonical(_:ToolInvocationContext,call:ToolCall):Result<AgentValue>{
        @Expect(paid,true);canonicalCalls++;Result<AgentValue>.Ok(call.arguments)
    }
    public func execute(_:ToolInvocationContext,prepared:PreparedToolInvocation):Result<ToolResult>{
        executions++;Result.Ok(ToolResult(prepared.call.callId,textValue("unused")))
    }
}
private func preparation340Pipeline(actual:Preparation340Executor):ToolPipeline{
    let catalog=ToolCatalog()
    let schema=objectValue([ValueField("type",textValue("object"))])
    let descriptor=ToolDescriptor(ModelToolDefinition("test.preparation-340","data only",schema),
        Capability(CapabilityKind.WorkspaceRead),sideEffecting:false,
        canonicalArgumentsResolver:Some({context,call=>actual.canonical(context,call)}))
    @Expect(catalog.register(descriptor,actual).isOk(),true)
    ToolPipeline(catalog,InMemoryOperationRuntimePort(),Preparation340Audit(),Preparation340Ids())
}
private func preparation340Context():ToolInvocationContext{
    ToolInvocationContext(RunId("preparation-340-run"),SessionId("preparation-340-thread"),
        CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]))
}
@Test
class OwnedPreparationInputData340Tests {
    @TestCase
    func actualPublicPreparePaysWholeInputBeforeCanonicalCallbackAndNeverExecutes():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(16777216)
        let actual=Preparation340Executor(ancestor);let pipeline=preparation340Pipeline(actual)
        let args=objectValue([ValueField("payload",textValue("complete\u{0000}雪"))])
        let prepared=pipeline.prepare(preparation340Context(),ToolCall("preparation-340-call","test.preparation-340",args))
        @Expect(prepared.isOk(),true);@Expect(actual.paid,true)
        @Expect(actual.canonicalCalls,1);@Expect(actual.executions,0)
        let usage=bank.usage();ancestor.close()
        @Expect(bank.usage()[0],usage[0]);@Expect(bank.usage()[1],usage[1])
        // Returned public preparation and actual caller input aliases remain.
        @Expect(args.field("payload").getOrThrow().asString(),"complete\u{0000}雪")
    }
    @TestCase
    func originalFullAggregateRefusesBeforeAnyCanonicalCallbackOrExecution():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(16777216)
        let pressure=ArrayList<LogicalJsonOwnerReservation>()
        for(_ in 0..7){let value=bank.acquire(1);value.ensureRetainedPeak(16777216);pressure.add(value)}
        let actual=Preparation340Executor(ancestor);let pipeline=preparation340Pipeline(actual)
        let args=objectValue([ValueField("payload",textValue("pressure"))])
        let usage=bank.usage()
        let refused=pipeline.prepare(preparation340Context(),ToolCall("preparation-340-pressure","test.preparation-340",args))
        @Expect(refused.isError(),true);@Expect(actual.paid,false)
        @Expect(actual.canonicalCalls,0);@Expect(actual.executions,0)
        @Expect(bank.usage()[0],usage[0]);@Expect(bank.usage()[1],usage[1])
        @Expect(pressure.size,7)
    }
    @TestCase
    func realMutableSelfCycleFailsBeforeDescriptorCallbackWithoutNewShapeLimit():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        let actual=Preparation340Executor(ancestor);let pipeline=preparation340Pipeline(actual)
        let array:JsonNode=JsonArray(ArrayList<JsonNode>([JsonNode.string("unchanged")]));array.add(array)
        let args:JsonNode=JsonObject();args.put("array",array)
        let failed=pipeline.prepare(preparation340Context(),ToolCall("preparation-340-cycle","test.preparation-340",args))
        @Expect(failed.isError(),true);@Expect(actual.canonicalCalls,0);@Expect(actual.executions,0)
        @Expect(array.size(),2)
    }
    @TestCase
    func repeatedDagOccurrencesAreSummedUnderSameAncestorAndClearingNoCallerIsAcked():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        let text=String.fromUtf8(Array<Byte>(65536,repeat:b'a'))+"\u{0000}雪"
        let shared:JsonNode=JsonObject();shared.put("payload",JsonNode.string(text))
        let single=ancestor.deriveRetainedLease()
        let first=ownedPreparationInputInvoice340(single,preparation340Context(),None<OperationRootSource>,ToolCall("dag","test",JsonArray(ArrayList<JsonNode>([shared]))),[]).value().getOrThrow()
        let double=ancestor.deriveRetainedLease()
        let second=ownedPreparationInputInvoice340(double,preparation340Context(),None<OperationRootSource>,ToolCall("dag","test",JsonArray(ArrayList<JsonNode>([shared,shared]))),[]).value().getOrThrow()
        @Expect(second>first+text.size*8,true)
        let usage=bank.usage();ancestor.close()
        @Expect(bank.usage()[0],usage[0]);@Expect(bank.usage()[1],usage[1])
        @Expect(shared.field("payload").getOrThrow().asString(),text)
    }
}
