package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class LatestContextValidityTestClock {
    let early:Int64
    let later:Int64
    var calls:Int64=0
    init(early:Int64,later:Int64){this.early=early;this.later=later}
    func now():Int64{calls++;if(calls<3){early}else{later}}
}
func latestContextValidityRows(expires:Int64):Array<String>{
    let rows=ArrayList<String>()
    for(index in 0..8){rows.add(latestContextTestEvent("session-"+index.toString(),"alpha alpha alpha alpha","session","actual-thread"))}
    for(index in 0..8){rows.add(latestContextTestEvent("workspace-"+index.toString(),"alpha","workspace","/workspace",
        extra:",\"expiresAt\":"+expires.toString()))}
    rows.toArray()
}
func latestContextValidityCollector(raw:String,now:Int64,clock:LatestContextValidityTestClock,
    maximum!:Int64=4096,allocate!:(Int64)->LogicalJsonOwnerReservation={_=>reservePurePolicyRawData()}):MemoryLatestJournalContextCollector{
    MemoryLatestJournalContextCollector(latestJournalFrameTestReference(raw.size,modelPolicySha256Text(raw)),
        modelPolicySha256Text("actual request"),modelPolicySha256Text("actual frozen policy"),modelPolicySha256Text("actual frozen latest view"),
        latestJournalFrameTestAnnotations(),"alpha alpha alpha alpha",maximum,now,allocate:allocate,renderNow:{=>clock.now()})
}
func latestContextValidityRead(collector:MemoryLatestJournalContextCollector,raw:String):Unit{
    let bytes=raw.toArray();var ready=false
    while(!ready){collector.beginPass();var offset:Int64=0
        while(offset<bytes.size){let end=min(bytes.size,offset+65536);collector.append(offset,bytes[offset..end]);offset=end}
        ready=collector.finishPass()}
}

@Test
class NativeMemoryLatestContextValidityTests {
    @TestCase
    func anUnrenderedWorkspaceHitExpiryStillRejectsLikeTheOriginalSixteenFactConsumer():Unit{
        let actual=DateTime.nowUTC().toUnixTimeStamp().toMilliseconds();let frozen=actual-100;let expiry=actual-1
        let rows=latestContextValidityRows(expiry);let raw=latestContextTestStream(rows,rows)
        let clock=LatestContextValidityTestClock(actual,actual)
        let collector=latestContextValidityCollector(raw,frozen,clock)
        try{latestContextValidityRead(collector,raw);var rejected=false
            try{let _=collector.result()}catch(error:PureProviderError){rejected=error.code=="memory_v3.context_fact_expired_or_changed"}
            @Expect(rejected,true)
            let history=rows.map{value=>memoryV3DecodeEvent(parseUnifiedJson(value)).value().getOrThrow()}
            let journal=NativeMemoryJournal(history,frozen);let runtime=NativeMemoryTools(journal,NativeManagedSkillProposals([]),"/settings","/workspace",[])
            let original=runtime.contextFor("alpha alpha alpha alpha",SessionId("actual-thread"),"/workspace",4096)
            @Expect(original.isError(),true);@Expect(original.error().getOrThrow().code,"memory_v3.context_fact_expired_or_changed")
        }finally{collector.close()}
    }
    @TestCase
    func expiryBetweenPolicyRenderAndOriginalFinalValidationCannotEscapeInAnUnrenderedHit():Unit{
        let frozen=DateTime.nowUTC().toUnixTimeStamp().toMilliseconds();let expiry=frozen+100000
        let rows=latestContextValidityRows(expiry);let raw=latestContextTestStream(rows,rows)
        let clock=LatestContextValidityTestClock(frozen+1,expiry)
        let collector=latestContextValidityCollector(raw,frozen,clock)
        try{latestContextValidityRead(collector,raw);var rejected=false
            try{let _=collector.result()}catch(error:PureProviderError){rejected=error.code=="memory_v3.context_fact_expired_or_changed"}
            @Expect(rejected,true);@Expect(clock.calls,3)
        }finally{collector.close()}
    }
    @TestCase
    func unrenderedFutureExpiryIsValidatedButDoesNotInventAnEarlierRenderedContentCeiling():Unit{
        let frozen=DateTime.nowUTC().toUnixTimeStamp().toMilliseconds();let rows=latestContextValidityRows(frozen+100000)
        let raw=latestContextTestStream(rows,rows);let clock=LatestContextValidityTestClock(frozen,frozen)
        let collector=latestContextValidityCollector(raw,frozen,clock)
        try{latestContextValidityRead(collector,raw);let value=collector.result()
            @Expect(latestContextTestContent(value),latestContextTestOriginal(rows,"alpha alpha alpha alpha",4096))
            @Expect(value.field("contributions").getOrThrow().items[0].field("valid_until_millis").isNone(),true)
            @Expect(clock.calls,3)
        }finally{collector.close()}
    }
    @TestCase
    func allSixteenPrefixesAtOriginal65536BoundFitTheActualPoolWithTwoWireOwnersAndBuffer():Unit{
        let frozen=DateTime.nowUTC().toUnixTimeStamp().toMilliseconds();let rows=latestContextValidityRows(frozen+100000)
        let raw=latestContextTestStream(rows,rows);let clock=LatestContextValidityTestClock(frozen,frozen)
        let budget=LogicalJsonOwnerBudget();let incoming=budget.acquire(1);let result=budget.acquire(1);let wire=budget.acquireFixedBuffer(8192)
        let collector=latestContextValidityCollector(raw,frozen,clock,maximum:65536,allocate:{_=>budget.acquire(1)})
        try{latestContextValidityRead(collector,raw);let value=collector.result()
            @Expect(latestContextTestContent(value),latestContextTestOriginal(rows,"alpha alpha alpha alpha",65536))
        }finally{collector.close();@Expect(budget.usage()[0],3);@Expect(budget.usage()[1],33562624)
            wire.close();result.close();incoming.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
