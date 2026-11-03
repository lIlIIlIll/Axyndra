package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// Mutable fields are shared by the synchronous callback. Cangjie closures
// cannot assign captured local var bindings; no payload bytes live here.
class MemoryUniquePeakWireProgress {
    var bytes:Int64=0
    var offset:Int64=0
}

let MEMORY_UNIQUE_PEAK_COUNT:Int64=4096
let MEMORY_UNIQUE_PEAK_SCALAR_BYTES:Int64=16380

// Every iteration constructs independent backing bytes and an independent
// String. The eight ASCII digits also make all4096 values distinguishable.
func memoryUniquePeakScalar(index:Int64):String {
    let raw=Array<Byte>(MEMORY_UNIQUE_PEAK_SCALAR_BYTES,repeat:b'x')
    var remaining=index
    var digit:Int64=7
    while(digit>=0){raw[digit]=UInt8(Int64(b'0')+remaining%10);remaining/=10;digit--}
    String.fromUtf8(raw)
}

func memoryUniquePeakRecord(index:Int64):MemoryV3Record {
    MemoryV3Record("unique-"+index.toString(),MemoryKind.Preference,
        MemoryScope(MemoryScopeKind.Global),memoryUniquePeakScalar(index),"","user",750,
        MemoryStatus.Active,0,"","",[],"","",1,1,0,1)
}

// Original v3 framing and original record writer, one independent current
// record at a time. Neither pass retains the whole encoded journal string.
func memoryUniquePeakWire(consume:(Array<Byte>)->Unit):Unit {
    consume(MEMORY_LATEST_JOURNAL_FRAME_MAGIC.toArray())
    consume(latestJournalFrameTestStart(0,MEMORY_UNIQUE_PEAK_COUNT).toArray())
    for(index in 0..MEMORY_UNIQUE_PEAK_COUNT){
        let body=stringifyUnifiedJson(memoryV3EventValue("retain",memoryUniquePeakRecord(index)))
        consume(latestJournalFrameTestBodyHeader("row",index,body.size,modelPolicySha256Text(body),false).toArray())
        consume(body.toArray())
    }
    consume(latestJournalFrameTestEnd(0,MEMORY_UNIQUE_PEAK_COUNT,0,MEMORY_UNIQUE_PEAK_COUNT).toArray())
}

// These are narrow real default-pool controls. They do not establish Host
// effect/Receipt authority, whole63MiB business acceptance or other platforms.
@Test
class NativeMemoryUniquePeakTests {
    @TestCase
    func genuinelyDistinctSixtyThreeMibOutputKeepsItsActualCallerGraphPaidUntilWriterJoin():Unit {
        let pool=LogicalJsonOwnerBudget()
        let inputs=pool.acquire(1)
        var output:?MemoryLiveOutput=None
        try{
            let uniqueBytes=MEMORY_UNIQUE_PEAK_COUNT*MEMORY_UNIQUE_PEAK_SCALAR_BYTES
            // Actual retained unique backing bytes + all4096 DOM cells +
            // bounded scalar construction/hash/transport scratch coexist.
            // This is an explicit caller hold, not the writer's max scalar.
            inputs.ensureRetainedPeak(uniqueBytes+MEMORY_UNIQUE_PEAK_COUNT*512+4194304)
            let nodes=ArrayList<AgentValue>()
            let oracle=SHA256();oracle.write("[".toArray())
            for(index in 0..MEMORY_UNIQUE_PEAK_COUNT){
                let scalar=memoryUniquePeakScalar(index)
                if(index!=0){oracle.write(",".toArray())}
                oracle.write("\"".toArray());oracle.write(scalar.toArray());oracle.write("\"".toArray())
                nodes.add(textValue(scalar))
            }
            oracle.write("]".toArray());let expectedDigest=logicalJsonEncodeHex(oracle.finish())
            let node=listValue(nodes.toArray())
            @Expect(uniqueBytes>66060288,true)
            @Expect(node.items[0].text[..8],"00000000")
            @Expect(node.items[1].text[..8],"00000001")
            @Expect(node.items[4095].text[..8],"00004095")
            @Expect(node.items[0].text!=node.items[1].text,true)
            output=Some(liveProducerTestOutput(pool,node));let actual=output.getOrThrow()
            let manifest=liveProducerTestManifest(actual)
            @Expect(documentDataInteger(manifest,"total_bytes"),MEMORY_UNIQUE_PEAK_COUNT*(MEMORY_UNIQUE_PEAK_SCALAR_BYTES+3)+1)
            @Expect(documentDataInteger(manifest,"payload_count"),8)
            @Expect(memoryDocumentText(manifest,"sha256"),expectedDigest)
            let hash=SHA256();var page:Int64=0;var total:Int64=0
            while(page<8){let described=actual.describe(page,3)
                for(descriptor in described.field("payloads").getOrThrow().items){
                    let partHash=SHA256();var offset:Int64=0;let size=documentDataInteger(descriptor,"bytes")
                    @Expect(size<=8388608,true)
                    while(offset<size){
                        let reply=actual.download(memoryDocumentText(descriptor,"slot"),offset,65536)
                        let raw=memoryLiveHex(memoryDocumentText(reply,"bytes_hex"))
                        @Expect(raw.size>0 && raw.size<=65536,true)
                        hash.write(raw);partHash.write(raw);offset+=raw.size;total+=raw.size
                        @Expect(memoryLiveBool(reply,"last"),offset==size)
                        @Expect(pool.usage()[1]<=134217728,true)
                    }
                    @Expect(logicalJsonEncodeHex(partHash.finish()),memoryDocumentText(descriptor,"sha256"))
                };page=documentDataInteger(described,"next_offset")
            }
            @Expect(total,documentDataInteger(manifest,"total_bytes"))
            @Expect(logicalJsonEncodeHex(hash.finish()),expectedDigest)
            @Expect(actual.complete(),true)
            // close performs the real Future join before caller drops the
            // unique backing strings. No GC timing is used as an ACK.
            actual.close();output=None
            @Expect(pool.usage()[0],1)
        }finally{match(output){case Some(value)=>value.close();case None=>()};inputs.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }

    @TestCase
    func currentFullBusinessRpcRejectsUniqueSixtyThreeMibCurrentBeforeItsUnpaidHistoryPeakAndReleases():Unit {
        let pool=LogicalJsonOwnerBudget()
        let fixture=pool.acquire(1)
        let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)})
        try{
            // Fixture retains one original record/JSON body plus transport
            // scratch only. No prebuilt63MiB oracle or fake pool is injected.
            fixture.ensureRetainedPeak(4194304)
            let countHash=SHA256();let wire=MemoryUniquePeakWireProgress()
            memoryUniquePeakWire({raw=>countHash.write(raw);wire.bytes+=raw.size})
            let digest=logicalJsonEncodeHex(countHash.finish())
            let input="{\"query\":\"unique\",\"max_bytes\":65536}"
            let begin=liveDataTestRequest("begin",extra:[ValueField("tool",textValue("memory_context")),
                ValueField("call_id",textValue("unique-business")),ValueField("now_millis",integerValue(1000)),
                ValueField("prior_receipts",liveDataTestLedger(0)),ValueField("input_payload",objectValue([
                    ValueField("bytes",integerValue(input.size)),ValueField("sha256",textValue(modelPolicySha256Text(input)))])),
                ValueField("stream",objectValue([
                    ValueField("reference",latestJournalFrameTestReference(wire.bytes,digest).toValue()),
                    ValueField("request_digest",textValue(modelPolicySha256Text("actual request"))),
                    ValueField("access_policy_digest",textValue(modelPolicySha256Text("actual frozen policy"))),
                    ValueField("view_policy_digest",textValue(modelPolicySha256Text("actual frozen latest view")))]))])
            let _=data.handle(begin);liveDataTestUpload(data,"append_parameters",input)
            let _=data.handle(liveDataTestRequest("end_parameters"))
            var capacityRejected=false
            try{
                memoryUniquePeakWire({raw=>
                    @Expect(raw.size<=65536,true)
                    let _=data.handle(liveDataTestRequest("append_base",extra:[
                        ValueField("offset",integerValue(wire.offset)),ValueField("bytes_hex",textValue(logicalJsonEncodeHex(raw)))]))
                    wire.offset+=raw.size})
                let _=data.handle(liveDataTestRequest("end_base"))
            }catch(_:LogicalJsonPayloadError){capacityRejected=true}
            // A DIAGNOSTIC negative for the current8x-retaining collector.
            // This explicitly keeps whole63MiB business acceptance OPEN.
            @Expect(capacityRejected,true);@Expect(wire.offset>0 && wire.offset<wire.bytes,true)
            @Expect(pool.usage()[0],1)
        }finally{data.close();fixture.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
