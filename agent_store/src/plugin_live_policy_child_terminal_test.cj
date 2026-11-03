package agent_store

import agent_domain.*
import std.collection.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Pure descriptor and real empty-SQLite/payment controls. No canonical
// Source, approval, operation or Receipt is inserted to manufacture success.
// Genuine known terminal positives require actual Runtime/Host/Kernel gates.
class LiveTerminalCounter{var value:Int64=0}
func liveTerminalTestTip(sequence:Int64,outcome!:String="completed"):AgentValue{
    objectValue([ValueField("sequence",integerValue(sequence)),ValueField("operation_id",textValue("descriptor-child")),
        ValueField("receipt_id",textValue("receipt-descriptor-child")),ValueField("plan_sha256",textValue(modelPolicySha256Text("descriptor-plan"))),
        ValueField("outcome",textValue(outcome))])
}
func liveTerminalTestValue(tip:AgentValue):AgentValue{
    objectValue([ValueField("schema",textValue("axyndra.plugin-live-effect-result/v1")),ValueField("receipt",tip)])
}
func liveTerminalTestReplace(value:AgentValue,name:String,replacement:AgentValue):AgentValue{
    let fields=ArrayList<ValueField>();var found=false
    for(field in value.fields){
        if(field.name==name){fields.add(ValueField(name,replacement));found=true}else{fields.add(field)}}
    if(!found){fields.add(ValueField(name,replacement))}
    objectValue(fields.toArray())
}

@Test
class PluginLivePolicyChildTerminalTests{
    @TestCase
    func CanonicalHeaderChecksBothChildAndCallWithoutDroppingOtherFields():Unit{
        let child=OperationId("descriptor-child")
        for(content in [ThreadItemContent.ToolResult(CanonicalToolCallId("descriptor-call"),OperationId("other-child"),"receipt",nullValue(),false),
            ThreadItemContent.ToolResult(CanonicalToolCallId("other-call"),child,"receipt",nullValue(),true)]){
            var rejected=false
            try{livePolicyChildTerminalUnsettledHeader(content,child,"descriptor-call")}catch(_:Exception){rejected=true}
            @Expect(rejected,true)
        }
        var rejectedOther=false
        try{livePolicyChildTerminalUnsettledHeader(ThreadItemContent.ToolResult(CanonicalToolCallId("other-call"),
            OperationId("other-child"),"receipt",textValue("original output"),false),child,"descriptor-call")}
        catch(_:Exception){rejectedOther=true}
        @Expect(rejectedOther,false)
        var wrongKind=false
        try{livePolicyChildTerminalUnsettledHeader(ThreadItemContent.ToolCall(CanonicalToolCallId("other-call"),"read",nullValue()),child,"descriptor-call")}
        catch(_:Exception){wrongKind=true}
        @Expect(wrongKind,true)
    }
    @TestCase
    func KnownDescriptorShapesDoNotCloseTheCallerLeaseOrAcceptUnknown():Unit{
        let parent=OperationId("descriptor-parent");let child=OperationId("descriptor-child")
        let releases=LiveTerminalCounter();let lease=ToolResultPayloadLease({=>releases.value++})
        try{
            for(outcome in ["completed","rejected"]){
                let value=liveTerminalTestValue(liveTerminalTestTip(1,outcome:outcome))
                @Expect(livePolicyChildTerminalValueValid(value,parent,1),true)
                let result=ToolResult("descriptor-call",value,isError:outcome=="rejected",receiptId:child.value,payloadLease:Some(lease))
                @Expect(livePolicyChildTerminalResultValid(parent,child,1,"descriptor-call",result),true)
                @Expect(livePolicyChildTerminalResultValid(parent,child,1,"another-call",result),false)
                @Expect(livePolicyChildTerminalResultValid(parent,child,1,"descriptor-call",
                    ToolResult("descriptor-call",value,isError:outcome!="rejected",receiptId:child.value,payloadLease:Some(lease))),false)
                @Expect(livePolicyChildTerminalResultValid(parent,child,1,"descriptor-call",
                    ToolResult("descriptor-call",value,isError:outcome=="rejected",receiptId:child.value)),false)
                @Expect(livePolicyChildTerminalResultValid(parent,child,1,"descriptor-call",
                    ToolResult("descriptor-call",value,isError:outcome=="rejected",receiptId:"receipt-descriptor-child",payloadLease:Some(lease))),false)
            }
            for(outcome in ["unknown","failed","cancelled","timed_out","pending"]){
                @Expect(livePolicyChildTerminalValueValid(liveTerminalTestValue(liveTerminalTestTip(1,outcome:outcome)),parent,1),false)}
            @Expect(releases.value,0)
        }finally{lease.close()}
        @Expect(releases.value,1)
    }
    @TestCase
    func ExactTopAndFiveReceiptFieldsRejectExtraAndPrivateClaims():Unit{
        let parent=OperationId("descriptor-parent")
        let extra=liveTerminalTestReplace(liveTerminalTestValue(liveTerminalTestTip(1)),"Source",textValue("native-claim"))
        @Expect(livePolicyChildTerminalValueValid(extra,parent,1),false)
        let privateTip=liveTerminalTestReplace(liveTerminalTestTip(1),"private_event_fence",textValue(modelPolicySha256Text("private")))
        @Expect(livePolicyChildTerminalValueValid(liveTerminalTestValue(privateTip),parent,1),false)
        let wrong=liveTerminalTestReplace(liveTerminalTestValue(liveTerminalTestTip(1)),"schema",textValue("axyndra.plugin-live-effect-result/v2"))
        @Expect(livePolicyChildTerminalValueValid(wrong,parent,1),false)
        @Expect(livePolicyChildTerminalValueValid(liveTerminalTestValue(nullValue()),parent,1),false)
    }
    @TestCase
    func ReceiptSequencePreservesCanonicalInt63AndRejectsOtherSpellings():Unit{
        let parent=OperationId("descriptor-parent")
        let invalidLeadingZero=try{let _=numberValue("01");false}catch(_:IllegalArgumentException){true}
        @Expect(invalidLeadingZero,true)
        for(sequence in [Int64(1),Int64(65537),Int64.Max]){
            @Expect(livePolicyChildTerminalValueValid(liveTerminalTestValue(liveTerminalTestTip(sequence)),parent,sequence),true)}
        for(ordinal in [numberValue("1.0"),numberValue("-0"),numberValue("9223372036854775808"),textValue("1")]){
            let tip=liveTerminalTestReplace(liveTerminalTestTip(1),"sequence",ordinal)
            @Expect(livePolicyChildTerminalValueValid(liveTerminalTestValue(tip),parent,1),false)}
        @Expect(livePolicyChildTerminalValueValid(liveTerminalTestValue(liveTerminalTestTip(1)),parent,2),false)
        @Expect(livePolicyChildTerminalValueValid(liveTerminalTestValue(liveTerminalTestTip(0)),parent,0),false)
    }
    @TestCase
    func BoundedTypedScalarsAreCheckedBeforeAnyArbitraryResultEncoding():Unit{
        let parent=OperationId("descriptor-parent")
        for(field in ["operation_id","receipt_id"]){
            for(value in [textValue(".."),textValue("bad/identifier"),textValue(String.fromUtf8(Array<Byte>(129,repeat:65))),integerValue(1)]){
                let tip=liveTerminalTestReplace(liveTerminalTestTip(1),field,value)
                @Expect(livePolicyChildTerminalValueValid(liveTerminalTestValue(tip),parent,1),false)}
        }
        for(value in [textValue("sha256:"+modelPolicySha256Text("plan")),textValue("bad-digest"),listValue([textValue("not scalar")])]){
            let tip=liveTerminalTestReplace(liveTerminalTestTip(1),"plan_sha256",value)
            @Expect(livePolicyChildTerminalValueValid(liveTerminalTestValue(tip),parent,1),false)}
        let huge=liveTerminalTestReplace(liveTerminalTestTip(1),"receipt_id",textValue(String.fromUtf8(Array<Byte>(1048576,repeat:65))))
        @Expect(livePolicyChildTerminalValueValid(liveTerminalTestValue(huge),parent,1),false)
    }
    @TestCase
    func EmptyRealSqliteCannotTurnALeasedDescriptorIntoAnActualTerminal():Unit{
        let directory=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let database=SqliteDatabase(directory+"/terminal.sqlite")
        let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1);let probes=LiveTerminalCounter()
        try{
            for(_ in 0..8){
                var rejected=false
                try{withLivePolicyChildTerminalPayment({bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},{=>
                    @Expect(budget.usage()[0],2);@Expect(budget.usage()[1],33554432);probes.value++
                    database.readTransaction<Unit>{tx=>let _=livePolicyChildTerminalAdmissionRow(tx,
                        OperationId("descriptor-parent"),OperationId("descriptor-child"),RunId("descriptor-run"),ItemId("descriptor-call-item"),
                        1,"live-policy:descriptor-call:1",modelPolicySha256Text("descriptor-plan"),"descriptor-call:live:1")}
                })}catch(_:Exception){rejected=true}
                @Expect(rejected,true);@Expect(budget.usage()[0],1);@Expect(budget.usage()[1],16777216)
            }
            @Expect(probes.value,8)
            for(table in ["operations","operation_receipts","derived_operation_admissions","audit_events","items","approvals"]){
                @Expect(database.scalarInt("SELECT count(*) FROM "+table),0)}
        }finally{held.close();database.close();remove(directory,recursive:true)}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func CancellationAndThrownConsumerReleaseOnlyTheTerminalPhaseOwner():Unit{
        let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1)
        let allocations=LiveTerminalCounter();let checks=LiveTerminalCounter();let consumes=LiveTerminalCounter()
        try{
            for(threshold in [Int64(1),Int64(2),Int64(3)]){
                checks.value=0;allocations.value=0;consumes.value=0
                var rejected=false
                try{withLivePolicyChildTerminalPayment({bytes=>allocations.value++;budget.acquire(bytes)},{=>
                    checks.value++
                    if(checks.value>=threshold){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"terminal.cancelled","current owner cancelled"))}
                    else{Result<Unit>.Ok(())}}, {=>consumes.value++
                        @Expect(budget.usage()[0],2);@Expect(budget.usage()[1],33554432)
                    })}catch(_:Exception){rejected=true}
                @Expect(rejected,true);@Expect(allocations.value,if(threshold==1){0}else{1})
                @Expect(consumes.value,if(threshold==3){1}else{0})
                @Expect(budget.usage()[0],1);@Expect(budget.usage()[1],16777216)
            }
            var threw=false
            try{withLivePolicyChildTerminalPayment({bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},{=>
                throw IllegalStateException("actual Unit consumer failed")})}catch(_:Exception){threw=true}
            @Expect(threw,true);@Expect(budget.usage()[0],1);@Expect(budget.usage()[1],16777216)
        }finally{held.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
