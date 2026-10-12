package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

class MemoryContextCustodyWireProgress {
    var bytes:Int64=0
    var offset:Int64=0
}
func memoryContextCustodyRecord(content:String,conflicts:Array<String>):MemoryV3Record {
    MemoryV3Record("context-custody",MemoryKind.Preference,MemoryScope(MemoryScopeKind.Workspace,key:"/workspace"),
        content,"context 雪\u{0}","user",725,MemoryStatus.Active,0,"","",conflicts,"why 雪\u{0}","",1,2,0,1)
}
func memoryContextCustodyWire(record:MemoryV3Record,consume:(Array<Byte>)->Unit):Unit {
    consume(MEMORY_LATEST_JOURNAL_FRAME_MAGIC.toArray())
    consume(latestJournalFrameTestStart(0,1).toArray())
    let body=stringifyUnifiedJson(memoryV3EventValue("retain",record))
    @Expect(body.size<65536,true)
    consume(latestJournalFrameTestBodyHeader("row",0,body.size,modelPolicySha256Text(body),false).toArray())
    consume(body.toArray());consume(latestJournalFrameTestEnd(0,1,0,1).toArray())
}

@Test
class NativeMemoryContextCanonicalCustodyTests {
    @TestCase
    func actualSmallContextKeepsWholeOriginalNulUnicodeBytesAndComparatorAndRetiresAfterProducerJoin():Unit {
        let pool=LogicalJsonOwnerBudget();let fixture=pool.acquire(1)
        let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)},sharedCustody:true)
        try {
            fixture.ensureRetainedPeak(4194304)
            let record=memoryContextCustodyRecord("needle 雪\u{0} \"\\\n",["","duplicate","duplicate","雪\u{0}"])
            let hash=SHA256();let wire=MemoryContextCustodyWireProgress()
            memoryContextCustodyWire(record,{raw=>hash.write(raw);wire.bytes+=raw.size})
            let input="{\"query\":\"needle\",\"max_bytes\":4096}"
            let begin=sharedCustodyTestBegin(wire.bytes,logicalJsonEncodeHex(hash.finish()),input)
            let fields=begin.fields.map{field=>if(field.name=="tool"){ValueField("tool",textValue("memory_context"))}else{field}}
            let _=data.handle(objectValue(fields))
            liveDataTestUpload(data,"append_parameters",input);let _=data.handle(liveDataTestRequest("end_parameters"))
            memoryContextCustodyWire(record,{raw=>
                let _=data.handle(liveDataTestRequest("append_base",extra:[ValueField("offset",integerValue(wire.offset)),
                    ValueField("bytes_hex",textValue(logicalJsonEncodeHex(raw)))]))
                wire.offset+=raw.size;@Expect(pool.usage()[1]<=134217728,true)
            })
            @Expect(wire.offset,wire.bytes);let _=data.handle(liveDataTestRequest("end_base"))
            let response=data.handle(liveDataTestRequest("compute"))
            @Expect(memoryDocumentText(response,"kind"),"completed");@Expect(memoryLiveBool(response,"is_error"),false)
            let actual=liveDataTestDrain(data,response)
            let original=NativeMemoryJournal([],1000,authoritativeCurrent:Some([record]))
            let oldTools=NativeMemoryTools(original,NativeManagedSkillProposals([]),"/settings","/workspace",[])
            let expected=nativeMemoryTestRequire(oldTools.contextFor("needle",SessionId("actual-thread"),"/workspace",4096))
            @Expect(actual.body,stringifyUnifiedJson(objectValue([ValueField("content",textValue(expected))])))
            @Expect(memoryDocumentText(actual.manifest,"sha256"),modelPolicySha256Text(actual.body))
            let paid=NativeMemoryJournal([],1000,authoritativeCurrent:Some([record]),snapshotOwner:Some(fixture))
            let _=nativeMemoryTestRequire(paid.validateContextRecords([record]))
            @Expect(nativeMemoryOwnedContextRecordEqual(record,record,fixture),true)
            let changed=memoryV3Copy(record,revision:2)
            let oldMismatch=original.validateContextRecords([changed]);let paidMismatch=paid.validateContextRecords([changed])
            @Expect(oldMismatch.isError(),true);@Expect(paidMismatch.isError(),true)
            @Expect(paidMismatch.error().getOrThrow().code,oldMismatch.error().getOrThrow().code)
            @Expect(nativeMemoryOwnedContextRecordEqual(record,changed,fixture),false)
            @Expect(pool.usage()[0],2)
            let _=data.handle(liveDataTestRequest("release"))
            @Expect(pool.usage()[0],1);@Expect(pool.usage()[1],16777216)
        } finally {data.close();fixture.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }

    @TestCase
    func originalFullPoolPressureRejectsDomAndCanonicalPhasesBeforeTheirAllocationsAndReleasesEachChild():Unit {
        let pool=LogicalJsonOwnerBudget();let fixture=pool.acquire(1)
        fixture.ensureRetainedPeak(4194304)
        let arrayRecord=memoryContextCustodyRecord("small",Array<String>(4096,{_=>""}))
        let stringRecord=MemoryV3Record("canonical-string",MemoryKind.Preference,MemoryScope(MemoryScopeKind.Workspace,key:"/workspace"),
            String.fromUtf8(Array<Byte>(1048576,repeat:b'x')),"","user",725,MemoryStatus.Active,0,"","",[],"","",1,2,0,1)
        let journal=NativeMemoryJournal([],1000,authoritativeCurrent:Some([arrayRecord,stringRecord]),snapshotOwner:Some(fixture))
        let pressure=Array<LogicalJsonOwnerReservation>(7,{_=>pool.acquire(1)})
        try {
            @Expect(pool.usage()[0],8);@Expect(pool.usage()[1],134217728)
            // This first shape cannot pay both variable DOM graphs. The second
            // shape's DOMs fit the paid floor; its complete two-String invoice
            // cannot grow the original full pool before canonicalAgentValue.
            for(record in [arrayRecord,stringRecord]) {
                var rejected=false
                try {let _=journal.validateContextRecords([record])}
                catch(_:LogicalJsonPayloadError){rejected=true}
                @Expect(rejected,true)
                @Expect(pool.usage()[0],8);@Expect(pool.usage()[1],134217728)
                @Expect(journal.pendingEvents().size,0);@Expect(journal.pendingTransactions().size,0)
            }
            for(owner in pressure){owner.close()}
            @Expect(pool.usage()[0],1);@Expect(pool.usage()[1],16777216)
            let _=nativeMemoryTestRequire(journal.validateContextRecords([arrayRecord,stringRecord]))
            @Expect(pool.usage()[0],1);@Expect(pool.usage()[1]>16777216,true)
            @Expect(journal.pendingEvents().size,0);@Expect(journal.pendingTransactions().size,0)
            // Successful phase children have retired; their physical highwater
            // remains on the original ancestor until its actual close below.
        } finally {for(owner in pressure){owner.close()};fixture.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
