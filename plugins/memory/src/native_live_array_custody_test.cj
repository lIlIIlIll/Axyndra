package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// Independent holder fields, never captured mutable local counters. The
// fixture owns just one original record/body and bounded transport scratch.
class MemoryArrayCorpusWireProgress {
    var bytes:Int64=0
    var offset:Int64=0
}
func memoryArrayCorpusRecord(index:Int64,conflicts:Int64,emptyOnly!:Bool=false):MemoryV3Record {
    let ids=Array<String>(conflicts,{column=>if(emptyOnly){""}else{
        match(column%4){case 0=>"";case 1=>"duplicate";case 2=>"duplicate";case _=>"雪"}}})
    MemoryV3Record("array-"+index.toString(),MemoryKind.Preference,MemoryScope(MemoryScopeKind.Global),
        "needle-"+index.toString(),"array context","user",750,MemoryStatus.Active,0,"","",ids,"why","",1,1,0,1)
}
func memoryArrayCorpusWire(count:Int64,conflicts:Int64,emptyOnly:Bool,consume:(Array<Byte>)->Unit):Unit {
    consume(MEMORY_LATEST_JOURNAL_FRAME_MAGIC.toArray())
    consume(latestJournalFrameTestStart(0,count).toArray())
    for(index in 0..count){
        let body=stringifyUnifiedJson(memoryV3EventValue("retain",memoryArrayCorpusRecord(index,conflicts,emptyOnly:emptyOnly)))
        @Expect(body.size<65536,true)
        consume(latestJournalFrameTestBodyHeader("row",index,body.size,modelPolicySha256Text(body),false).toArray())
        consume(body.toArray())
    }
    consume(latestJournalFrameTestEnd(0,count,0,count).toArray())
}
func memoryArrayCorpusUpload(data:NativeMemoryLiveToolData,pool:LogicalJsonOwnerBudget,wire:MemoryArrayCorpusWireProgress,
    count:Int64,conflicts:Int64,emptyOnly:Bool):Unit {
    memoryArrayCorpusWire(count,conflicts,emptyOnly,{raw=>
        @Expect(raw.size>0 && raw.size<=65536,true)
        let _=data.handle(liveDataTestRequest("append_base",extra:[
            ValueField("offset",integerValue(wire.offset)),ValueField("bytes_hex",textValue(logicalJsonEncodeHex(raw)))]))
        wire.offset+=raw.size;@Expect(pool.usage()[1]<=134217728,true)
    })
}

@Test
class NativeMemoryArrayCustodyTests {
    @TestCase
    func smallRepeatedEmptyAndUnicodeConflictCorpusPreservesWholeOriginalReflectBytesAndJoinRetirement():Unit {
        let pool=LogicalJsonOwnerBudget();let fixture=pool.acquire(1)
        let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)},sharedCustody:true)
        try{
            fixture.ensureRetainedPeak(4194304)
            let hash=SHA256();let wire=MemoryArrayCorpusWireProgress()
            memoryArrayCorpusWire(32,64,false,{raw=>hash.write(raw);wire.bytes+=raw.size})
            let inputValue=objectValue([ValueField("query",textValue("needle-7")),
                ValueField("scope",textValue("global")),ValueField("limit",integerValue(1))])
            let input=stringifyUnifiedJson(inputValue)
            let _=data.handle(sharedCustodyTestBegin(wire.bytes,logicalJsonEncodeHex(hash.finish()),input))
            liveDataTestUpload(data,"append_parameters",input);let _=data.handle(liveDataTestRequest("end_parameters"))
            memoryArrayCorpusUpload(data,pool,wire,32,64,false)
            @Expect(wire.offset,wire.bytes)
            let _=data.handle(liveDataTestRequest("end_base"))
            let response=data.handle(liveDataTestRequest("compute"))
            @Expect(memoryDocumentText(response,"kind"),"completed");@Expect(memoryLiveBool(response,"is_error"),false)
            let actual=liveDataTestDrain(data,response)
            let originals=Array<MemoryV3Record>(32,{index=>memoryArrayCorpusRecord(index,64)})
            let original=NativeMemoryJournal(originals,1000,authoritativeCurrent:Some(originals))
            let tools=NativeMemoryTools(original,NativeManagedSkillProposals([]),"/settings","/workspace",[])
            let oracle=nativeMemoryTestRequire(tools.reflect(NativeMemoryToolContext(SessionId("actual-thread"),"/workspace"),
                ToolCall("shared-business","reflect",inputValue)))
            @Expect(actual.body,stringifyUnifiedJson(oracle.output))
            @Expect(memoryDocumentText(actual.manifest,"sha256"),modelPolicySha256Text(actual.body))
            let result=parseUnifiedJson(actual.body);@Expect(documentDataInteger(result,"count"),1)
            let selected=result.field("memories").getOrThrow().items[0]
            @Expect(memoryDocumentText(selected,"id"),"array-7")
            // The original reflect output is a summary. Validate the complete
            // original codec fields on its independently owned input oracle.
            let admitted=nativeMemoryTestRequire(memoryV3DecodeEvent(memoryV3EventValue("retain",originals[7])))
            @Expect(admitted.conflictIds.size,64)
            @Expect(admitted.conflictIds[0],"")
            @Expect(admitted.conflictIds[1],"duplicate")
            @Expect(admitted.conflictIds[2],"duplicate")
            @Expect(admitted.conflictIds[3],"雪")
            @Expect(pool.usage()[0],2);@Expect(pool.usage()[1]<=134217728,true)
            let _=data.handle(liveDataTestRequest("release"))
            @Expect(pool.usage()[0],1);@Expect(pool.usage()[1],16777216)
        }finally{data.close();fixture.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }

    @TestCase
    func manyOriginalValidSmallEmptyIdArraysRejectDuringUploadBeforeReplayClonesAndReleaseEveryOwner():Unit {
        let pool=LogicalJsonOwnerBudget();let fixture=pool.acquire(1)
        let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)},sharedCustody:true)
        try{
            fixture.ensureRetainedPeak(4194304)
            // The actual unchanged codec admits every empty and duplicate ID.
            // No new cardinality/record/corpus limit is used by this control.
            let original=memoryArrayCorpusRecord(0,4096,emptyOnly:true)
            let event=memoryV3EventValue("retain",original)
            let decoded=nativeMemoryTestRequire(memoryV3DecodeEvent(event))
            @Expect(decoded.conflictIds.size,4096);@Expect(decoded.conflictIds[0],"")
            @Expect(decoded.conflictIds[4095],"");@Expect(stringifyUnifiedJson(event).size<65536,true)
            let hash=SHA256();let wire=MemoryArrayCorpusWireProgress()
            memoryArrayCorpusWire(3500,4096,true,{raw=>hash.write(raw);wire.bytes+=raw.size})
            let input="{\"query\":\"needle-7\",\"scope\":\"global\",\"limit\":1}"
            let _=data.handle(sharedCustodyTestBegin(wire.bytes,logicalJsonEncodeHex(hash.finish()),input))
            liveDataTestUpload(data,"append_parameters",input);let _=data.handle(liveDataTestRequest("end_parameters"))
            var rejected=false
            try{memoryArrayCorpusUpload(data,pool,wire,3500,4096,true)}
            catch(_:LogicalJsonPayloadError){rejected=true}
            @Expect(rejected,true);@Expect(wire.offset<wire.bytes,true)
            // The worker fails before EOF/compute can allocate journal/current
            // arrays. The independent fixture's original floor is still paid.
            @Expect(pool.usage()[0],1);@Expect(pool.usage()[1],16777216)
        }finally{data.close();fixture.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
