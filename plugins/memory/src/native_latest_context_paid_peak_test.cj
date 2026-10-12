package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func latestContextPaidTestRun(raw:String,query:String,budget:LogicalJsonOwnerBudget,expected:String):Unit{
    let now=DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
    let collector=MemoryLatestJournalContextCollector(latestJournalFrameTestReference(raw.size,modelPolicySha256Text(raw)),
        modelPolicySha256Text("actual request"),modelPolicySha256Text("actual frozen policy"),modelPolicySha256Text("actual frozen latest view"),
        latestJournalFrameTestAnnotations(),query,4096,now,allocate:{_=>budget.acquire(1)},renderNow:{=>now})
    try{let bytes=raw.toArray();var ready=false
        while(!ready){collector.beginPass();var offset:Int64=0
            while(offset<bytes.size){let end=min(bytes.size,offset+65536);collector.append(offset,bytes[offset..end]);offset=end}
            ready=collector.finishPass()}
        // Consume output while its real collector owner is still alive.
        let value=latestContextTestContent(collector.result())
        @Expect(value.size<=4096,true);@Expect(value,expected)
    }finally{collector.close()}
}

@Test
class NativeMemoryLatestContextPaidPeakTests {
    @TestCase
    func combinedWholeQueryAndTokenBatchMatchOldWholeLexicalIncludingDuplicateContextTokens():Unit{
        let raw=streamEventTestRaw(quoteUnifiedJson("alpha beta"))
        let original=memoryV3DecodeEvent(parseUnifiedJson(raw)).value().getOrThrow()
        for(query in ["alpha beta","alpha alpha beta","note note context","not-found"]){
            let budget=LogicalJsonOwnerBudget();let eventOwner=budget.acquire(1)
            let batch=MemoryStreamLexicalBatch(query,0,includeWholeQuery:true,allocate:{_=>budget.acquire(1)})
            try{
                let decoder=MemoryEventStreamDecoder(raw.size,modelPolicySha256Text(raw),eventOwner,
                    boundedMetadata:true,validationAllocate:{_=>budget.acquire(1)},consume:{field,offset,text=>batch.consume(field,offset,text)})
                try{decoder.append(0,raw.toArray());let event=decoder.complete()
                    let score=batch.finish(event)
                    @Expect(if(score>0){score+original.importancePermille/10}else{0},memoryV3LexicalScore(original,query))
                }finally{decoder.close()}
            }finally{batch.close();eventOwner.close()}
            @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }
    }
    @TestCase
    func oneFieldOwnerMayFinishFromExactPriorBytesButNeverFromPrematureOrChangedCounts():Unit{
        let field=MemoryStreamInlineField("context",8,4097)
        try{field.consume("context",0," \tnote ")
            var early=false;try{let _=field.finishBytes(8)}catch(_:Exception){early=true};@Expect(early,true)
            field.consume("context",7," ")
            var changed=false;try{let _=field.finishBytes(7)}catch(_:Exception){changed=true};@Expect(changed,true)
            @Expect(field.finishBytes(8),"note")
        }finally{field.close()}
    }
    @TestCase
    func default128MiBPoolRetainsTwoWireOwnersAndBufferAcrossAll3001SourceRows():Unit{
        let rows=ArrayList<String>()
        for(index in 0..3001){rows.add(latestContextTestEvent("row-"+index.toString(),"alpha beta","session","actual-thread"))}
        let all=rows.toArray();let raw=latestContextTestStream(all,all)
        let budget=LogicalJsonOwnerBudget();let incoming=budget.acquire(1);let result=budget.acquire(1)
        let wire=budget.acquireFixedBuffer(8192)
        try{
            latestContextPaidTestRun(raw,"alpha beta",budget,latestContextTestOriginal(all,"alpha beta",4096))
            @Expect(budget.usage()[0],3);@Expect(budget.usage()[1],33562624)
        }finally{wire.close();result.close();incoming.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func default128MiBPoolKeepsFull6MiBUtf8AndReversedContextContentFieldOrder():Unit{
        let glyphs="界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界".toArray()
        let bytes=ArrayList<Byte>();for(_ in 0..32768){bytes.add(all:glyphs)}
        let content=" \talpha "+String.fromUtf8(bytes.toArray())+" \r\n";@Expect(content.size>6291456,true)
        let row="{\"version\":3,\"operation\":\"retain\",\"record\":{\"id\":\"large\",\"kind\":\"project_fact\","+
            "\"scopeKind\":\"session\",\"scopeKey\":\"actual-thread\",\"status\":\"active\",\"revision\":1,"+
            "\"context\":\" note context \",\"source\":\"between fields\",\"content\":"+quoteUnifiedJson(content)+"}}"
        let raw=latestContextTestStream([row],[row]);let budget=LogicalJsonOwnerBudget()
        let incoming=budget.acquire(1);let result=budget.acquire(1);let wire=budget.acquireFixedBuffer(8192)
        try{
            latestContextPaidTestRun(raw,"alpha",budget,latestContextTestOriginal([row],"alpha",4096))
            @Expect(budget.usage()[0],3);@Expect(budget.usage()[1],33562624)
        }finally{wire.close();result.close();incoming.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
