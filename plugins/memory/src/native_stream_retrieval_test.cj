package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

class NativeStreamRetrievalResult {
    let score:Int64
    let content:String
    let context:String
    init(score:Int64,content:String,context:String){this.score=score;this.content=content;this.context=context}
}
func nativeStreamRetrievalFixture(raw:String,query:String,width:Int64,bound:Int64):NativeStreamRetrievalResult{
    let original=memoryV3DecodeEvent(parseUnifiedJson(raw,maxBytes:67108864,maxDepth:32)).value().getOrThrow()
    let owner=reservePurePolicyRawData()
    try{
        let normalized=query.trimAscii().toAsciiLower();var cursor:Int64= -1;var score:Int64=0
        var content="";var context=""
        while(cursor<normalized.size){
            let lexical=MemoryStreamLexicalBatch(query,cursor)
            let inlineContent=MemoryStreamInlineField("content",original.content.size,bound)
            let inlineContext=MemoryStreamInlineField("context",original.context.size,bound)
            try{
                let decoder=MemoryEventStreamDecoder(raw.size,modelPolicySha256Text(raw),owner,
                    consume:{name,offset,text=>lexical.consume(name,offset,text)
                        inlineContent.consume(name,offset,text);inlineContext.consume(name,offset,text)})
                let bytes=raw.toArray();var offset:Int64=0
                while(offset<bytes.size){let end=min(offset+width,bytes.size);decoder.append(offset,bytes[offset..end]);offset=end}
                let event=decoder.complete();score+=lexical.finish(event)
                content=inlineContent.finish(event);context=inlineContext.finish(event);cursor=lexical.nextCursor
            }finally{inlineContext.close();inlineContent.close();lexical.close()}
        }
        NativeStreamRetrievalResult(if(score==0){0}else{score+original.importancePermille/10},content,context)
    }finally{owner.close()}
}
@Test
class NativeMemoryStreamRetrievalTests {
    @TestCase
    func OriginalLexicalScoresDuplicateTokensAndCrossFragmentMatchesStayExact():Unit{
        let content="PREFIX "+String.fromUtf8(Array<Byte>(65534,repeat:b'x'))+"AbCdEf 音楽 suffix"
        let raw=streamEventTestRaw(quoteUnifiedJson(content)).replace("note\\tcontext","only-context word")
        let original=memoryV3DecodeEvent(parseUnifiedJson(raw,maxBytes:67108864,maxDepth:32)).value().getOrThrow()
        for(query in ["abcdef","abc def","word word word","音楽","not-found","ABCDEF\tword ABCDEF"]){
            for(width in [1,7,65536]){
                let actual=nativeStreamRetrievalFixture(raw,query,width,4097)
                @Expect(actual.score,memoryV3LexicalScore(original,query.trimAscii().toAsciiLower()))
            }
        }
    }
    @TestCase
    func ContextBeforeContentAndMoreThanThirtyTwoTokensKeepOriginalOrderingAndCounts():Unit{
        var query="";for(_ in 0..70){query+="word "};query=query.trimAscii()
        let raw="{\"version\":3,\"operation\":\"retain\",\"record\":{\"context\":\"word\",\"content\":\"other\","+
            "\"id\":\"m-order\",\"kind\":\"project_fact\",\"scopeKind\":\"global\",\"scopeKey\":\"\",\"status\":\"active\",\"importancePermille\":750}}"
        let original=memoryV3DecodeEvent(parseUnifiedJson(raw)).value().getOrThrow()
        let actual=nativeStreamRetrievalFixture(raw,query,3,4097)
        @Expect(actual.score,memoryV3LexicalScore(original,query))
        @Expect(actual.score,2525)
    }
    @TestCase
    func LeadingAndTrailingWhitespaceBeyondRawPrefixUsesWholeOriginalInlineOracle():Unit{
        let whitespace=String.fromUtf8(Array<Byte>(131072,repeat:UInt8(32)))
        let content=whitespace+"音楽\r\n  internal\t  text"+whitespace
        let raw=streamEventTestRaw(quoteUnifiedJson(content))
        let normalized=content.replace("\r"," ").replace("\n"," ").replace("\t"," ").trimAscii()
        var expected=normalized;while(expected.contains("  ")){expected=expected.replace("  "," ")}
        for(width in [7,65536]){
            let actual=nativeStreamRetrievalFixture(raw,"text",width,4097)
            @Expect(actual.content,expected);@Expect(actual.context,"note context")
        }
    }
    @TestCase
    func Utf8BoundAndOptionalNonStringContextMatchOriginalFragmentBehavior():Unit{
        let content=String.fromUtf8(Array<Byte>(4096,repeat:b'x'))+"音z"
        let raw=streamEventTestRaw(quoteUnifiedJson(content)).replace("\"context\":\"note\\tcontext\"","\"context\":false")
        let actual=nativeStreamRetrievalFixture(raw,"z",3,4097)
        @Expect(actual.content,String.fromUtf8(Array<Byte>(4096,repeat:b'x')))
        @Expect(actual.context,"")
    }
}
