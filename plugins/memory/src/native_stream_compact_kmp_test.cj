package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func compactContextTestUpload(data:MemoryLatestContextData,raw:String,query:String,maximum:Int64):Unit{
    let parameters=stringifyUnifiedJson(latestContextRpcTestParameters(query,maximum))
    @Expect(parameters.size<=CONTENT_PAYLOAD_MESSAGE_BYTES,true)
    let start=latestContextRpcTestRequest("begin",1,[ValueField("input_payload",objectValue([
        ValueField("bytes",integerValue(parameters.size)),ValueField("sha256",textValue(modelPolicySha256Text(parameters)))])),
        ValueField("stream",objectValue([ValueField("reference",latestJournalFrameTestReference(raw.size,modelPolicySha256Text(raw)).toValue()),
            ValueField("request_digest",textValue(modelPolicySha256Text("actual request"))),
            ValueField("access_policy_digest",textValue(modelPolicySha256Text("actual frozen policy"))),
            ValueField("view_policy_digest",textValue(modelPolicySha256Text("actual frozen latest view")))]))])
    let _=data.query(start);let bytes=parameters.toArray();var offset:Int64=0
    while(offset<bytes.size){let end=min(bytes.size,offset+65536)
        let _=data.query(latestContextRpcTestRequest("append_input",1,[ValueField("offset",integerValue(offset)),
            ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes[offset..end])))]));offset=end}
    let _=data.query(latestContextRpcTestRequest("finish_input",1,[]))
}

@Test
class NativeMemoryCompactQueryTests {
    @TestCase
    func CompactUnsignedPrefixTransitionsMatchOriginalKmpAtEveryUtf8AndDuplicateBoundary():Unit{
        for(pattern in ["ababa","界a界","alpha","aaaaab"]){
            let text="aaba界A界 ALPHA aaaaab ababa";let bytes=text.toArray()
            let compact=MemoryStreamCompactKmp();var oldMatched:Int64=0;var oldFound=false
            var newMatched:Int64=0;var newFound=false
            try{
                // UTF8 text callbacks themselves are complete scalar strings;
                // compare every scalar-width input boundary the old API sees.
                for(part in ["aa","ba","界","A","界 ","ALPHA ","aaaaab ","ababa"]){
                    let expected=memoryFragmentMatch(pattern,part,oldMatched,oldFound)
                    let actual=compact.advance(0,pattern,part,newMatched,newFound)
                    @Expect(actual[0],expected[0]);@Expect(actual[1],expected[1])
                    oldMatched=expected[0];oldFound=expected[1];newMatched=actual[0];newFound=actual[1]
                }
                // A new slot replaces the single cached table and cannot
                // keep a second multi-MiB prefix allocation alive.
                @Expect(compact.advance(1,"needle","needle",0,false)[1],true)
                @Expect(compact.advance(0,pattern,text,0,false)[1],memoryFragmentMatch(pattern,text,0,false)[1])
            }finally{compact.close()}
        }
    }
    @TestCase
    func NearOriginalMessageMaximumQueryFitsDefaultPoolAndMatchesWholeBusinessOracle():Unit{
        let query=String.fromUtf8(Array<Byte>(CONTENT_PAYLOAD_MESSAGE_BYTES-4096,repeat:b'a'))
        let event=latestContextTestEvent("max-query",query+" end","session","actual-thread")
        let raw=latestContextTestStream([event],[event]);let budget=LogicalJsonOwnerBudget()
        let incoming=budget.acquire(1);let outgoing=budget.acquire(1);let wire=budget.acquireFixedBuffer(8192)
        let data=MemoryLatestContextData(allocate:{_=>budget.acquire(1)})
        try{
            compactContextTestUpload(data,raw,query,65536)
            let progress=LatestContextRpcTestProgress()
            @Expect(latestContextTestContent(latestContextRpcTestFinish(data,raw,65536,1,progress)),
                latestContextTestOriginal([event],query,65536))
            @Expect(progress.passes,2);@Expect(budget.usage()[0],3);@Expect(budget.usage()[1],33562624)
        }finally{data.close();wire.close();outgoing.close();incoming.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func CompactStateKeepsEveryOriginalDuplicateScoreAndRetiresAllTableOwners():Unit{
        let raw=streamEventTestRaw(quoteUnifiedJson("alpha beta alpha"))
        let original=memoryV3DecodeEvent(parseUnifiedJson(raw)).value().getOrThrow()
        for(query in ["alpha alpha beta","ALPHA  alpha\tBETA","界 alpha alpha"]){
            let normalized=query.trimAscii().toAsciiLower();let budget=LogicalJsonOwnerBudget()
            let eventOwner=budget.acquire(1)
            let batch=MemoryStreamLexicalBatch(normalized,0,includeWholeQuery:true,compactQuery:true,normalizedInput:true,
                allocate:{_=>budget.acquire(1)})
            try{
                let decoder=MemoryEventStreamDecoder(raw.size,modelPolicySha256Text(raw),eventOwner,
                    boundedMetadata:true,validationAllocate:{_=>budget.acquire(1)},consume:{field,offset,text=>batch.consume(field,offset,text)})
                try{
                    let bytes=raw.toArray();var offset:Int64=0
                    while(offset<bytes.size){let end=min(bytes.size,offset+7);decoder.append(offset,bytes[offset..end]);offset=end}
                    let event=decoder.complete();let score=batch.finish(event)
                    @Expect(if(score>0){score+original.importancePermille/10}else{0},memoryV3LexicalScore(original,normalized))
                }finally{decoder.close()}
            }finally{batch.close();eventOwner.close()}
            @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }
    }
}
