package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func latestContextTestEvent(id:String,content:String,scope:String,key:String,extra!:String=""):String{
    "{\"version\":3,\"operation\":\"retain\",\"record\":{\"id\":"+quoteUnifiedJson(id)+",\"kind\":\"project_fact\",\"scopeKind\":"+
        quoteUnifiedJson(scope)+",\"scopeKey\":"+quoteUnifiedJson(key)+",\"status\":\"active\",\"revision\":1,\"content\":"+
        quoteUnifiedJson(content)+",\"context\":\" note\\tcontext \""+extra+"}}"
}
func latestContextTestStream(events:Array<String>,current:Array<String>):String{
    var raw=MEMORY_LATEST_JOURNAL_FRAME_MAGIC+latestJournalFrameTestStart(events.size,current.size)
    for(index in 0..events.size){let value=events[index];raw+=latestJournalFrameTestBodyHeader("event",index,value.size,modelPolicySha256Text(value),false)+value}
    for(index in 0..current.size){let value=current[index];raw+=latestJournalFrameTestBodyHeader("row",index,value.size,modelPolicySha256Text(value),false)+value}
    raw+latestJournalFrameTestEnd(events.size,current.size,events.size,current.size)
}
func latestContextTestCollect(raw:String,query:String,bound:Int64,width:Int64):AgentValue{
    let now=DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
    let collector=MemoryLatestJournalContextCollector(latestJournalFrameTestReference(raw.size,modelPolicySha256Text(raw)),
        modelPolicySha256Text("actual request"),modelPolicySha256Text("actual frozen policy"),modelPolicySha256Text("actual frozen latest view"),
        latestJournalFrameTestAnnotations(),query,bound,now,renderNow:{=>now})
    try{let bytes=raw.toArray();var ready=false
        while(!ready){collector.beginPass();var offset:Int64=0
            while(offset<bytes.size){let end=min(bytes.size,offset+width);collector.append(offset,bytes[offset..end]);offset=end}
            ready=collector.finishPass()}
        collector.result()
    }finally{collector.close()}
}
func latestContextTestOriginal(events:Array<String>,query:String,bound:Int64):String{
    let history=events.map{raw=>memoryV3DecodeEvent(parseUnifiedJson(raw,maxBytes:67108864,maxDepth:32)).value().getOrThrow()}
    let journal=NativeMemoryJournal(history,DateTime.nowUTC().toUnixTimeStamp().toMilliseconds())
    let runtime=NativeMemoryTools(journal,NativeManagedSkillProposals([]),"/settings","/workspace",[])
    runtime.contextFor(query,SessionId("actual-thread"),"/workspace",bound).value().getOrThrow()
}
func latestContextTestContent(value:AgentValue):String{
    let rows=value.field("contributions").getOrThrow().items
    if(rows.isEmpty()){return ""};memoryDocumentText(rows[0],"content")
}

@Test
class NativeMemoryLatestContextCollectorTests {
    @TestCase
    func streamedContextMatchesOriginalWholeBusinessWithRepeatedTokensAndExactInlineNormalization():Unit{
        let event=latestContextTestEvent("row-a"," \r\nalpha\t beta beta   \n","session","actual-thread",extra:",\"importancePermille\":250")
        let raw=latestContextTestStream([event],[event])
        let streamed=latestContextTestContent(latestContextTestCollect(raw,"alpha alpha beta",4096,1))
        @Expect(streamed,latestContextTestOriginal([event],"alpha alpha beta",4096))
        @Expect(streamed.contains("alpha beta beta"),true)
    }
    @TestCase
    func everyTokenBatchBeyondThirtyTwoIsReplayedAndMatchesOriginalLexicalScoreOrder():Unit{
        let one=latestContextTestEvent("a","beta","session","actual-thread")
        let two=latestContextTestEvent("b","alpha","session","actual-thread")
        var query="";for(_ in 0..65){query+="beta "};query+="alpha"
        let raw=latestContextTestStream([one,two],[one,two])
        @Expect(latestContextTestContent(latestContextTestCollect(raw,query,4096,11)),latestContextTestOriginal([one,two],query,4096))
    }
    @TestCase
    func perScopeEightThenClampedCombinedEightAndTiesPreserveOriginalContext():Unit{
        let events=ArrayList<String>()
        for(index in 0..12){events.add(latestContextTestEvent("w-"+index.toString(),"alpha alpha","workspace","/workspace",extra:",\"updatedAt\":"+index.toString()))}
        for(index in 0..12){events.add(latestContextTestEvent("s-"+index.toString(),"alpha beta","session","actual-thread",extra:",\"updatedAt\":"+index.toString()))}
        let all=events.toArray();let raw=latestContextTestStream(all,all)
        @Expect(latestContextTestContent(latestContextTestCollect(raw,"alpha alpha alpha alpha",4096,37)),latestContextTestOriginal(all,"alpha alpha alpha alpha",4096))
    }
    @TestCase
    func currentFramesAloneDecideVisibilityAndNeverInferCurrentFromOldReadableHistory():Unit{
        let old=latestContextTestEvent("hidden","alpha old global","global","")
        let current=latestContextTestEvent("visible","alpha current","session","actual-thread")
        let raw=latestContextTestStream([old,current],[current])
        let value=latestContextTestContent(latestContextTestCollect(raw,"alpha",4096,17))
        @Expect(value.contains("alpha current"),true);@Expect(value.contains("old global"),false)
    }
    @TestCase
    func aMalformedHistoricalVersionCannotBeSkippedByAValidCurrentRowOrEmptyQuery():Unit{
        let row=latestContextTestEvent("visible","alpha","session","actual-thread")
        let invalid=row.replace("\"version\":3","\"version\":2")
        var rejected=false
        try{let _=latestContextTestCollect(latestContextTestStream([invalid],[row]),"",4096,19)}catch(_:Exception){rejected=true}
        @Expect(rejected,true)
    }
    @TestCase
    func multiMiBUtf8SourceAndLongLeadingWhitespaceKeepExactBoundedOriginalRendering():Unit{
        let bytes=ArrayList<Byte>()
        for(_ in 0..3000){bytes.add(all:" \t\r\n".toArray())};bytes.add(all:"alpha ".toArray())
        let glyphs="界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界".toArray()
        for(_ in 0..32768){bytes.add(all:glyphs)}
        let content=String.fromUtf8(bytes.toArray());@Expect(content.size>6291456,true)
        let row=latestContextTestEvent("large"," "+content+"  ","session","actual-thread")
        let raw=latestContextTestStream([row],[row])
        let value=latestContextTestContent(latestContextTestCollect(raw,"alpha",4096,65536))
        @Expect(value,latestContextTestOriginal([row],"alpha",4096));@Expect(value.size<=4096,true)
    }
}
