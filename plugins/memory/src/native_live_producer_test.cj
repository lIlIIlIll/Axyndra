package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

func liveProducerTestOutput(pool:LogicalJsonOwnerBudget,node:AgentValue):MemoryLiveOutput{
    let turn=nativeMemoryReplayTurn([],1000,[],{_=>Result<ToolResult>.Ok(ToolResult("producer-test",node))},allocate:{bytes=>pool.acquire(bytes)})
    var transferred=false
    try{
        let result=MemoryLiveOutput(node,turn,"completed",false,"",{bytes=>pool.acquire(bytes)},{=>()})
        transferred=true;result
    }finally{if(!transferred){turn.close()}}
}

func liveProducerTestManifest(output:MemoryLiveOutput):AgentValue{
    let metadata=output.metadata();let descriptor=metadata.field("manifest").getOrThrow()
    let response=output.download("manifest",0,65536)
    let raw=memoryLiveHex(memoryDocumentText(response,"bytes_hex"))
    @Expect(memoryLiveBool(response,"last"),true)
    @Expect(raw.size,documentDataInteger(descriptor,"bytes"))
    @Expect(modelPolicySha256(raw),memoryDocumentText(descriptor,"sha256"))
    parseUnifiedJson(String.fromUtf8(raw))
}

// Narrow real writer/Future/shared-pool contracts. They are NOT physical
// process/Host effect or whole63MiB unique-history business acceptance.
@Test
class NativeMemoryLiveProducerTests {
    @TestCase
    func originalPinnedBytesSurviveShortReadsUtf8EscapesAndSlotBoundary():Unit{
        let pool=LogicalJsonOwnerBudget();let inputs=pool.acquire(1)
        var output:?MemoryLiveOutput=None
        try{
            inputs.ensureRetainedPeak(33554432)
            let text=String.fromUtf8(Array<Byte>(1400000,repeat:0))+"中\n\\\""
            let node=objectValue([ValueField("payload",textValue(text)),ValueField("number",numberValue("1.2300"))])
            let original=stringifyUnifiedJson(node).toArray()
            output=Some(liveProducerTestOutput(pool,node));let actual=output.getOrThrow()
            let manifest=liveProducerTestManifest(actual);@Expect(documentDataInteger(manifest,"payload_count"),2)
            var compared:Int64=0;var page:Int64=0;var requests:Int64=0
            while(page<documentDataInteger(manifest,"payload_count")){
                let descriptors=actual.describe(page,1)
                for(descriptor in descriptors.field("payloads").getOrThrow().items){
                    var offset:Int64=0;let size=documentDataInteger(descriptor,"bytes");let hash=SHA256()
                    while(offset<size){
                        let reply=actual.download(memoryDocumentText(descriptor,"slot"),offset,if(requests%3==0){4093}else{65536})
                        let raw=memoryLiveHex(memoryDocumentText(reply,"bytes_hex"))
                        @Expect(raw.size>0 && raw.size<=65536,true);hash.write(raw)
                        // JSON may split within UTF8; compare exact raw bytes.
                        @Expect(raw,original[compared..compared+raw.size]);compared+=raw.size;offset+=raw.size;requests++
                        @Expect(memoryLiveBool(reply,"last"),offset==size)
                    }
                    @Expect(logicalJsonEncodeHex(hash.finish()),memoryDocumentText(descriptor,"sha256"))
                };page=documentDataInteger(descriptors,"next_offset")
            }
            // The independent old pinned writer remains the byte oracle. The
            // fixture is paid for its full oracle/output copies before creation.
            @Expect(compared,original.size)
            @Expect(actual.complete(),true)
        }finally{match(output){case Some(value)=>value.close();case None=>()};inputs.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }

    @TestCase
    func onePublicationWaitsForRealNextOffsetAndCloseJoinsBlockedWriter():Unit{
        let pool=LogicalJsonOwnerBudget();let payment=pool.acquire(1)
        var producer:?MemoryLiveJsonProducer=None
        try{
            payment.ensureRetainedPeak(4194304)
            let node=textValue(String.fromUtf8(Array<Byte>(200000,repeat:b'x')))
            let count=MemoryLiveJsonStream({=>()},{extra=>payment.ensureRetainedPeak(4194304+extra)})
            node.writeJson(count,options:JsonWriteOptions.defaults);let frozen=count.finish()
            producer=Some(MemoryLiveJsonProducer(frozen[2],frozen[0],frozen[1]));producer.getOrThrow().start(node)
            let selected=producer.getOrThrow();let first=selected.take(0,17,{=>()})
            @Expect(first.size,17);let firstProgress=selected.progress();@Expect(firstProgress[0],17);@Expect(firstProgress[1],65536);@Expect(firstProgress[2],false);@Expect(firstProgress[3],false)
            let second=selected.take(17,65536,{=>()})
            @Expect(second.size,65536-17);let secondProgress=selected.progress();@Expect(secondProgress[0],65536);@Expect(secondProgress[1],65536);@Expect(secondProgress[2],false);@Expect(secondProgress[3],false)
            // Merely returning bytes did not let the producer advance or drop
            // its original scalar. No timing/sleep assumption is needed here.
            selected.close();let closedProgress=selected.progress();@Expect(closedProgress[0],65536);@Expect(closedProgress[1],0);@Expect(closedProgress[2],true);@Expect(closedProgress[3],true)
            @Expect(pool.usage()[0],1);selected.close();@Expect(pool.usage()[0],1)
        }finally{match(producer){case Some(value)=>value.close();case None=>()};payment.close()}
        @Expect(pool.usage()[0],0)
    }

    @TestCase
    func originalFullDataRpcCancellationAfterFirstChunkJoinsAndReleases():Unit{
        let pool=LogicalJsonOwnerBudget();let cancelled=AtomicBool(false)
        let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)},current:{=>
            if(cancelled.load()){throw PureProviderError("fixture.cancelled","original consumer revoked")}})
        try{
            let text=String.fromUtf8(Array<Byte>(200000,repeat:b'x'))
            let input=stringifyUnifiedJson(objectValue([ValueField("items",listValue([objectValue([ValueField("content",textValue(text))])]))]));let base=liveDataTestEmpty()
            let _=data.handle(liveDataTestBegin(base,input));liveDataTestUpload(data,"append_parameters",input)
            let _=data.handle(liveDataTestRequest("end_parameters"));liveDataTestUpload(data,"append_base",base)
            let _=data.handle(liveDataTestRequest("end_base"))
            let computed=data.handle(liveDataTestRequest("compute"))
            @Expect(memoryDocumentText(computed,"kind"),"effect")
            @Expect(memoryDocumentText(computed.field("effect").getOrThrow(),"kind"),"row_journal.append")
            let _=data.handle(liveDataTestRequest("describe",extra:[ValueField("offset",integerValue(0)),ValueField("count",integerValue(32))]))
            let first=data.handle(liveDataTestRequest("download",extra:[ValueField("slot",textValue("payload-0")),ValueField("offset",integerValue(0)),ValueField("max_bytes",integerValue(65536))]))
            @Expect(memoryLiveHex(memoryDocumentText(first,"bytes_hex")).size,65536)
            @Expect(pool.usage()[0]>0,true);cancelled.store(true);var rejected=false
            try{let _=data.handle(liveDataTestRequest("download",extra:[ValueField("slot",textValue("payload-0")),ValueField("offset",integerValue(65536)),ValueField("max_bytes",integerValue(65536))]))}
            catch(error:PureProviderError){rejected=error.code=="fixture.cancelled"}
            @Expect(rejected,true);@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        }finally{data.close()}
    }

    @TestCase
    func countPassDoesNotPermitChangedNodeToPublishSuccessfulEof():Unit{
        let pool=LogicalJsonOwnerBudget();let inputs=pool.acquire(1)
        var output:?MemoryLiveOutput=None
        try{
            let node=objectValue([ValueField("payload",textValue("before"))])
            output=Some(liveProducerTestOutput(pool,node));let selected=output.getOrThrow()
            let _=selected.describe(0,1)
            // Fault injection into a private test Node, never a worker-supplied
            // source. The second ORIGINAL writer must detect exact byte drift.
            node.put("payload",textValue("after!"));var rejected=false
            try{let _=selected.download("payload-0",0,65536)}catch(error:PureProviderError){rejected=error.code=="memory.live_data_invalid"}
            @Expect(rejected,true);@Expect(selected.complete(),false)
        }finally{match(output){case Some(value)=>value.close();case None=>()};inputs.close()}
        @Expect(pool.usage()[0],0)
    }

    @TestCase
    func largeEncodedOutputUsesAllEightReferencesWithoutRetainingEncodedSlots():Unit{
        let pool=LogicalJsonOwnerBudget();let inputs=pool.acquire(1)
        var output:?MemoryLiveOutput=None
        try{
            // The actual immutable scalar is shared. This proves large ENCODED
            // multi-slot output, not63MiB unique retained business/history data.
            inputs.ensureRetainedPeak(8388608)
            let scalar=String.fromUtf8(Array<Byte>(16380,repeat:b'x'))
            let node=listValue(Array<AgentValue>(4096,{_=>textValue(scalar)}))
            output=Some(liveProducerTestOutput(pool,node));let selected=output.getOrThrow()
            let manifest=liveProducerTestManifest(selected)
            @Expect(documentDataInteger(manifest,"total_bytes"),4096*(16380+3)+1)
            @Expect(documentDataInteger(manifest,"total_bytes")>66060288,true)
            @Expect(documentDataInteger(manifest,"payload_count"),8)
            let whole=SHA256();var next:Int64=0;var total:Int64=0
            while(next<8){let page=selected.describe(next,3)
                for(descriptor in page.field("payloads").getOrThrow().items){
                    let hash=SHA256();var offset:Int64=0;let size=documentDataInteger(descriptor,"bytes")
                    @Expect(size<=8388608,true)
                    while(offset<size){let part=selected.download(memoryDocumentText(descriptor,"slot"),offset,65536)
                        let raw=memoryLiveHex(memoryDocumentText(part,"bytes_hex"));hash.write(raw);whole.write(raw)
                        offset+=raw.size;total+=raw.size;@Expect(memoryLiveBool(part,"last"),offset==size)
                        @Expect(pool.usage()[1]<=134217728,true)
                    };@Expect(logicalJsonEncodeHex(hash.finish()),memoryDocumentText(descriptor,"sha256"))
                };next=documentDataInteger(page,"next_offset")
            }
            @Expect(total,documentDataInteger(manifest,"total_bytes"));@Expect(logicalJsonEncodeHex(whole.finish()),memoryDocumentText(manifest,"sha256"))
            @Expect(selected.complete(),true)
        }finally{match(output){case Some(value)=>value.close();case None=>()};inputs.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }

    @TestCase
    func skippingWholeReferenceOrRepeatingAcknowledgedOffsetFailsClosed():Unit{
        for(mode in ["skip","repeat"]){
            let pool=LogicalJsonOwnerBudget();let inputs=pool.acquire(1);var output:?MemoryLiveOutput=None
            try{
                inputs.ensureRetainedPeak(16777216)
                let node=textValue(String.fromUtf8(Array<Byte>(1400000,repeat:0)))
                output=Some(liveProducerTestOutput(pool,node));let selected=output.getOrThrow();let _=selected.describe(0,2)
                var rejected=false
                if(mode=="skip"){
                    try{let _=selected.download("payload-1",0,65536)}catch(_:Exception){rejected=true}
                }else{
                    let _=selected.download("payload-0",0,65536)
                    try{let _=selected.download("payload-0",0,65536)}catch(_:Exception){rejected=true}
                }
                @Expect(rejected,true);@Expect(selected.complete(),false)
            }finally{match(output){case Some(value)=>value.close();case None=>()};inputs.close()}
            @Expect(pool.usage()[0],0)
        }
    }
}
