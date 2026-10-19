package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// Each body obeys the unchanged64 MiB record bound. The original v3 stream
// reference has no aggregate64 MiB ceiling; no new ceiling is introduced.
func sharedCustodyTestBegin(extent:Int64,digest:String,input:String):AgentValue {
    liveDataTestRequest("begin",extra:[ValueField("tool",textValue("reflect")),
        ValueField("call_id",textValue("shared-business")),ValueField("now_millis",integerValue(1000)),
        ValueField("prior_receipts",liveDataTestLedger(0)),ValueField("input_payload",objectValue([
            ValueField("bytes",integerValue(input.size)),ValueField("sha256",textValue(modelPolicySha256Text(input)))])),
        ValueField("stream",objectValue([
            ValueField("reference",latestJournalFrameTestReference(extent,digest).toValue()),
            ValueField("request_digest",textValue(modelPolicySha256Text("actual request"))),
            ValueField("access_policy_digest",textValue(modelPolicySha256Text("actual frozen policy"))),
            ValueField("view_policy_digest",textValue(modelPolicySha256Text("actual frozen latest view")))]))])
}

func sharedCustodyTestWireUpload(data:NativeMemoryLiveToolData,pool:LogicalJsonOwnerBudget):Int64 {
    let wire=MemoryUniquePeakWireProgress()
    memoryUniquePeakWire({raw=>
        @Expect(raw.size>0 && raw.size<=65536,true)
        let _=data.handle(liveDataTestRequest("append_base",extra:[
            ValueField("offset",integerValue(wire.offset)),ValueField("bytes_hex",textValue(logicalJsonEncodeHex(raw)))]))
        wire.offset+=raw.size;@Expect(pool.usage()[1]<=134217728,true)
    });wire.offset
}

@Test
class NativeMemorySharedCustodyTests {
    @TestCase
    func streamedSnapshotsPreserveAllOriginalCanonicalBytesHashesAndOrder():Unit {
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1)
        try {
            owner.ensureRetainedPeak(4194304)
            let records=[MemoryV3Record("z",MemoryKind.Preference,MemoryScope(MemoryScopeKind.Global),
                "雪\n\"\\\u{0}","nested:[]{}","source",725,MemoryStatus.Active,0,"","",["b","a"],"why","",1,2,0,1),
                memoryUniquePeakRecord(1),memoryUniquePeakRecord(0)]
            let groups:Array<Array<MemoryV3Record>> = [[],[records[0]],[records[1],records[2]],records]
            for(values in groups) {
                let original=canonicalAgentValue(listValue(values.map{record=>memoryV3RecordValue(record)}))
                @Expect(nativeMemoryOwnedSnapshotDigest(values,owner),modelPolicySha256Text(original))
                @Expect(memoryV3SnapshotDigest(values),modelPolicySha256Text(original))
                @Expect(pool.usage()[0],1)
            }
            @Expect(nativeMemoryOwnedSnapshotDigest([records[1],records[2]],owner)!=
                nativeMemoryOwnedSnapshotDigest([records[2],records[1]],owner),true)
            // The original detached constructor forwards immutable Strings
            // directly. Its scope object is the exact same reference; its
            // mutable conflict-ID array is independently detached as before.
            let detached=memoryV3Detached(records[0])
            @Expect(refEq(detached.scope,records[0].scope),true)
            @Expect(detached.content,records[0].content)
            @Expect(detached.context,records[0].context)
            @Expect(detached.source,records[0].source)
            detached.conflictIds[0]="changed"
            @Expect(records[0].conflictIds[0],"b")
        }finally{owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }

    @TestCase
    func realIndependentSixtySevenMillionByteCurrentCompletesOriginalReflectAndRetiresAfterJoin():Unit {
        let pool=LogicalJsonOwnerBudget();let fixture=pool.acquire(1)
        let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)},sharedCustody:true)
        try {
            fixture.ensureRetainedPeak(4194304)
            let uniqueBytes=MEMORY_UNIQUE_PEAK_COUNT*MEMORY_UNIQUE_PEAK_SCALAR_BYTES
            @Expect(uniqueBytes,67092480)
            let countHash=SHA256();let wire=MemoryUniquePeakWireProgress()
            memoryUniquePeakWire({raw=>countHash.write(raw);wire.bytes+=raw.size})
            let digest=logicalJsonEncodeHex(countHash.finish())
            let query=memoryUniquePeakScalar(1)
            let inputValue=objectValue([ValueField("query",textValue(query)),ValueField("scope",textValue("global")),ValueField("limit",integerValue(1))])
            let input=stringifyUnifiedJson(inputValue)
            let _=data.handle(sharedCustodyTestBegin(wire.bytes,digest,input))
            liveDataTestUpload(data,"append_parameters",input)
            let _=data.handle(liveDataTestRequest("end_parameters"))
            @Expect(sharedCustodyTestWireUpload(data,pool),wire.bytes)
            let _=data.handle(liveDataTestRequest("end_base"))
            // All4096 distinct body Strings and the original record graphs
            // remain held in the actual worker through both snapshot hashes.
            @Expect(pool.usage()[1]>=uniqueBytes+MEMORY_UNIQUE_PEAK_COUNT*8192,true)
            let response=data.handle(liveDataTestRequest("compute"))
            @Expect(memoryDocumentText(response,"kind"),"completed")
            @Expect(memoryLiveBool(response,"is_error"),false)
            let result=liveDataTestDrain(data,response)
            let decoded=parseUnifiedJson(result.body)
            @Expect(documentDataInteger(decoded,"count"),1)
            @Expect(memoryDocumentText(decoded.field("memories").getOrThrow().items[0],"id"),"unique-1")
            // Only this independently unique full token can match the query.
            // Original business code on that one original record is a complete
            // output-byte oracle, including original formatting and hit score.
            let original=NativeMemoryJournal([memoryUniquePeakRecord(1)],1000)
            let tools=NativeMemoryTools(original,NativeManagedSkillProposals([]),"/settings","/workspace",[])
            let oracle=nativeMemoryTestRequire(tools.reflect(NativeMemoryToolContext(SessionId("actual-thread"),"/workspace"),
                ToolCall("shared-business","reflect",inputValue)))
            @Expect(result.body,stringifyUnifiedJson(oracle.output))
            @Expect(memoryDocumentText(result.manifest,"sha256"),modelPolicySha256Text(result.body))
            @Expect(pool.usage()[0],2)
            @Expect(pool.usage()[1]<=134217728,true)
            // The original producer Future physically joins before decoded
            // input/history backing and the single physical slot are retired.
            let _=data.handle(liveDataTestRequest("release"))
            @Expect(pool.usage()[0],1);@Expect(pool.usage()[1],16777216)
        }finally{data.close();fixture.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }

    @TestCase
    func independentLiveOwnerPressureRejectsTheActualUniqueSumWithoutLeakingAnyPhase():Unit {
        let pool=LogicalJsonOwnerBudget();let fixture=pool.acquire(1);let pressure=pool.acquire(1)
        let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)},sharedCustody:true)
        try {
            fixture.ensureRetainedPeak(4194304)
            let countHash=SHA256();let wire=MemoryUniquePeakWireProgress()
            memoryUniquePeakWire({raw=>countHash.write(raw);wire.bytes+=raw.size})
            let input="{\"query\":\"unique\",\"scope\":\"global\",\"limit\":1}"
            let _=data.handle(sharedCustodyTestBegin(wire.bytes,logicalJsonEncodeHex(countHash.finish()),input))
            liveDataTestUpload(data,"append_parameters",input)
            let _=data.handle(liveDataTestRequest("end_parameters"))
            var rejected=false
            try{let _=sharedCustodyTestWireUpload(data,pool);let _=data.handle(liveDataTestRequest("end_base"));
                let _=data.handle(liveDataTestRequest("compute"))}
            catch(_:LogicalJsonPayloadError){rejected=true}
            @Expect(rejected,true)
            @Expect(pool.usage()[0],2);@Expect(pool.usage()[1],33554432)
        }finally{data.close();pressure.close();fixture.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }

    @TestCase
    func sharedInputHistoryReplayAndWriterKeepTheOriginalTwoDraftWholePrefixBytes():Unit {
        let pool=LogicalJsonOwnerBudget();let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)},sharedCustody:true)
        let input="{\"items\":[{\"content\":\"first\"},{\"content\":\"second\"}]}"
        try {
            liveDataTestStart(data,input)
            let first=liveDataTestDrain(data,data.handle(liveDataTestRequest("compute")));liveDataTestSettle(data,first,0)
            let second=liveDataTestDrain(data,data.handle(liveDataTestRequest("compute")));liveDataTestSettle(data,second,1)
            let complete=data.handle(liveDataTestRequest("compute"))
            @Expect(memoryDocumentText(complete,"kind"),"completed");@Expect(memoryLiveBool(complete,"is_error"),false)
            let actual=liveDataTestDrain(data,complete)
            let oracle=nativeMemoryTestRequire(memoryReplayOriginalRetain(NativeMemoryJournal([],1000)))
            @Expect(actual.body,stringifyUnifiedJson(oracle.output))
            @Expect(memoryDocumentText(actual.manifest,"sha256"),modelPolicySha256Text(actual.body))
            @Expect(pool.usage()[0],1)
            let _=data.handle(liveDataTestRequest("release"))
        }finally{data.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
