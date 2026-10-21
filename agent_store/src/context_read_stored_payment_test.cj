package agent_store

import agent_domain.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func storedPaymentOriginalAccepts(raw:String):Bool{
    try{let _=decodeStoredValue(raw);true}catch(_:Exception){false}
}
func storedPaymentMeterAccepts(raw:String):Bool{
    let budget=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=budget.acquire(1)
    try{let meter=StoredValuePaymentMeter(raw,owner);let _=meter.complete();true}catch(_:Exception){false}
    finally{owner.close()}
}
func storedPaymentConsumption(raw:String):String{
    match(decodeStoredThreadContent(raw)){
        case ThreadItemContent.ToolCall(id,name,_)=>"call:"+id.value+":"+name
        case ThreadItemContent.ToolResult(id,_,_,_,_)=>"result:"+id.value
        case _=>"other"
    }
}
func storedPaymentProjectedConsumption(raw:String,owner:LogicalJsonOwnerReservation):String{
    let meter=StoredValuePaymentMeter(raw,owner);let _=meter.complete()
    storedPaymentConsumption(encodeStoredValue(meter.consumptionHeader()))
}
func storedPaymentOutcome(raw:String,projected:Bool):String{
    let owner=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY).acquire(1)
    try{if(projected){storedPaymentProjectedConsumption(raw,owner)}else{storedPaymentConsumption(raw)}}
    catch(_:Exception){"rejected"}finally{owner.close()}
}
func storedPaymentResult(id:String,body:String):String{
    encodeStoredThreadContent(ThreadItemContent.ToolResult(CanonicalToolCallId(id),OperationId("mechanical-operation"),
        "mechanical-receipt",textValue(body),false))
}
// Payment-only actual SQLite fixture. It neither constructs a ContextRead
// Source nor authorizes a Root. Success means old body bytes were measured
// and fully checked with bounded live memory, not that a read was admitted.
class StoredPaymentRowsFixture {
    let root:String
    let database:SqliteDatabase
    init(){
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/payment.sqlite")
        database.execute("INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal) VALUES ('payment-thread',0,'payment-workspace','active',1)")
        database.execute("INSERT INTO turns(id,thread_id,ordinal,state,user_item_id) VALUES ('payment-turn','payment-thread',1,'active','payment-user')")
        this.root=root;this.database=database
    }
    func add(rowid:Int64,id:String,ordinal:Int64,raw:String):Unit{
        database.execute("INSERT INTO items(rowid,id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) "+
            "VALUES (?,?,'payment-thread','payment-turn',?,'tool_result',?,'n',1)",
            [SqlParameter.Int64Value(rowid),SqlParameter.Text(id),SqlParameter.Int64Value(ordinal),SqlParameter.Text(raw)])
    }
    func close():Unit{database.close();remove(root,recursive:true)}
}
class StoredPaymentCount {var value:Int64=0}

@Test
class ContextReadStoredPaymentTests {
    @TestCase
    func meterMatchesOriginalNonJsonNumbersLeadingZeroFramesAndCollectionCountSpelling():Unit{
        for(raw in ["n","t","f","s0001:x","l01:1n","l2:+1n","l2:01n","d1:0","d2:-0","d3:1e2","d4:01.0","d1:x","d0:"]){
            @Expect(storedPaymentMeterAccepts(raw),storedPaymentOriginalAccepts(raw))}
    }
    @TestCase
    func fullUnknownFieldsStillCheckDuplicateUtf8DepthTruncationAndTrailingBytes():Unit{
        var deep="n";for(_ in 0..66){deep="l1:1"+deep}
        for(raw in ["o1:21:an1:an","s1:你","s9:short","nignored",deep,"l7:1000001"]){
            @Expect(storedPaymentOriginalAccepts(raw),false);@Expect(storedPaymentMeterAccepts(raw),false)}
        let valid=objectValue([ValueField("kind",textValue("tool_result")),ValueField("call_id",textValue("call")),
            ValueField("operation_id",textValue("op")),ValueField("receipt_id",textValue("receipt")),
            ValueField("result",nullValue()),ValueField("is_error",boolValue(false)),ValueField("ignored",textValue("你"))])
        let raw=encodeStoredValue(valid);@Expect(storedPaymentMeterAccepts(raw),true)
        @Expect(storedPaymentMeterAccepts(raw+"n"),false)
    }
    @TestCase
    func originalHeaderPredicatesKeepMissingAndWrongRequiredFieldsInsteadOfNullifyingThem():Unit{
        let valid=objectValue([ValueField("kind",textValue("tool_result")),ValueField("call_id",textValue("call")),
            ValueField("operation_id",textValue("op")),ValueField("receipt_id",textValue("")),
            ValueField("result",nullValue()),ValueField("is_error",boolValue(false))])
        let raw=encodeStoredValue(valid);@Expect(storedPaymentOutcome(raw,true),storedPaymentOutcome(raw,false))
        for(field in ["kind","call_id","operation_id","receipt_id","is_error"]){
            let changed=decodeStoredValue(raw);changed.put(field,listValue([nullValue()]))
            let encoded=encodeStoredValue(changed)
            @Expect(storedPaymentOutcome(encoded,true),storedPaymentOutcome(encoded,false));@Expect(storedPaymentOutcome(encoded,true),"rejected")}
        let missing=objectValue([ValueField("kind",textValue("tool_result")),ValueField("call_id",textValue("call")),
            ValueField("operation_id",textValue("op")),ValueField("receipt_id",textValue("")),ValueField("is_error",boolValue(false))])
        @Expect(storedPaymentOutcome(encodeStoredValue(missing),true),"rejected")
    }
    @TestCase
    func arbitraryArgumentsAndUnknownMetadataRemainSyntaxValidatedWithoutAFullDomInvoice():Unit{
        let ordinary=encodeStoredThreadContent(ThreadItemContent.ToolCall(CanonicalToolCallId("call"),"tool",listValue([textValue("你"),numberValue("-0")])) )
        let largeList="l7:1000000"+String.fromUtf8(Array<Byte>(1000000,{_=>b'n'}))
        let large="o1:44:kinds9:tool_call7:call_ids4:call4:names4:tool9:arguments"+largeList
        let budget=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=budget.acquire(1)
        try{let meter=StoredValuePaymentMeter(large,owner);@Expect(meter.complete()>1000000,true)
            @Expect(storedPaymentConsumption(encodeStoredValue(meter.consumptionHeader())),storedPaymentConsumption(ordinary))
            @Expect(budget.usage()[1],16777216)
        }finally{owner.close()};@Expect(budget.usage()[0],0)
    }
    @TestCase
    func provenanceProjectionDropsOnlyIgnoredRootFieldsAfterCompleteOriginalValidation():Unit{
        let original=encodeStoredProvenance(ItemProvenance("direct_tool",runId:Some(RunId("run")),operationId:Some(OperationId("op"))))
        let value=decodeStoredValue(original);value.put("ignored",listValue([textValue("secret"),nullValue()]))
        let budget=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=budget.acquire(1)
        try{let meter=StoredValuePaymentMeter(encodeStoredValue(value),owner);let _=meter.complete()
            let projected=decodeStoredProvenance(encodeStoredValue(meter.topProjection(["source","run_id","operation_id","direct_origin","continuation_origin","continuation_history"])))
            @Expect(encodeStoredProvenance(projected),original)
        }finally{owner.close()}
    }
    @TestCase
    func actualSqliteVisitsNegativeZeroAndPositiveRowidsWithOneResultOwner():Unit{
        let fixture=StoredPaymentRowsFixture();let budget=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let count=StoredPaymentCount()
        try{fixture.add(-7,"negative",1,storedPaymentResult("negative","first"));fixture.add(0,"zero",2,storedPaymentResult("zero","second"))
            fixture.add(9,"positive",3,storedPaymentResult("positive","third"))
            fixture.database.readTransaction<Unit>({tx=>eachContextReadToolResultPaid(tx,"payment-thread","payment-turn",{bytes=>budget.acquire(bytes)},
                {=>Result<Unit>.Ok(())},{content=>match(content){case ThreadItemContent.ToolResult(_,_,_,_,_)=>count.value++;case _=>throw IllegalStateException("wrong mechanical fixture")}})})
            @Expect(count.value,3);@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{fixture.close()}
    }
    @TestCase
    func threeNearEightMiBOriginalResultsAreNotSummedIntoAnAggregateTurnDom():Unit{
        let fixture=StoredPaymentRowsFixture();let budget=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let base=budget.acquire(1);let parent=budget.acquire(1)
        let body=String.fromUtf8(Array<Byte>(8388096,{_=>b'x'}));let raw=storedPaymentResult("call",body);let count=StoredPaymentCount()
        @Expect(raw.size<8388608,true);@Expect(raw.size>8388000,true)
        try{for(index in 0..3){fixture.add(index,"large-"+index.toString(),index+1,raw)}
            fixture.database.readTransaction<Unit>({tx=>eachContextReadToolResultPaid(tx,"payment-thread","payment-turn",{bytes=>budget.acquire(bytes)},
                {=>Result<Unit>.Ok(())},{content=>match(content){case ThreadItemContent.ToolResult(id,_,_,_,_)=>@Expect(id.value,"call");count.value++
                    case _=>throw IllegalStateException("wrong mechanical fixture")}})})
            @Expect(count.value,3);@Expect(budget.usage()[0],2);@Expect(budget.usage()[1],33554432)
        }finally{parent.close();base.close();fixture.close()};@Expect(budget.usage()[0],0)
    }
    @TestCase
    func cancellationAfterARealPaidSqliteBodyReadDoesNotLeakItsCharge():Unit{
        let fixture=StoredPaymentRowsFixture();let budget=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let calls=StoredPaymentCount()
        try{fixture.add(0,"cancelled",1,storedPaymentResult("call","complete body"));var rejected=false
            try{fixture.database.readTransaction<Unit>({tx=>eachContextReadToolResultPaid(tx,"payment-thread","payment-turn",{bytes=>budget.acquire(bytes)},
                {=>calls.value++;if(calls.value>=3){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"payment.cancelled","current owner cancelled"))}
                    else{Result<Unit>.Ok(())}},{_=>()})})}catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{fixture.close()}
    }
}
