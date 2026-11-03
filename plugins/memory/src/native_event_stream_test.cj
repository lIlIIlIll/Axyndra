package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import stdx.crypto.digest.SHA256
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func streamEventTestRaw(contentLiteral:String,extra!:String=""):String{
    "{\"version\":3,\"operation\":\"retain\",\"record\":{\"id\":\"m-stream\",\"kind\":\"project_fact\","+
        "\"scopeKind\":\"global\",\"scopeKey\":\"\",\"status\":\"active\",\"revision\":1,"+
        "\"content\":"+contentLiteral+",\"context\":\"note\\tcontext\",\"source\":\"fixture\""+extra+"}}"
}
class MemoryStreamEventTestProgress {
    var seen:Int64=0
    var fragments:Int64=0
}
class MemoryStreamEventTestOwner {
    let value:MemoryStreamedEvent
    private let owner:LogicalJsonOwnerReservation
    init(value:MemoryStreamedEvent,owner:LogicalJsonOwnerReservation){this.value=value;this.owner=owner}
    func close():Unit{owner.close()}
}
func streamEventTestDecode(raw:String,width:Int64):MemoryStreamEventTestOwner{
    let owner=reservePurePolicyRawData()
    try{
        let decoder=MemoryEventStreamDecoder(raw.size,modelPolicySha256Text(raw),owner)
        let bytes=raw.toArray();var offset:Int64=0
        while(offset<bytes.size){let end=min(bytes.size,offset+width);decoder.append(offset,bytes[offset..end]);offset=end}
        MemoryStreamEventTestOwner(decoder.complete(),owner)
    }catch(error:Exception){owner.close();throw error}
}
func streamEventTestRejected(raw:String,width!:Int64=1):Bool{
    try{let value=streamEventTestDecode(raw,width);value.close();false}catch(_:Exception){true}
}

@Test
class MemoryEventStreamTests {
    @TestCase
    func unicodeAndEscapesAcrossEveryByteKeepOriginalValues():Unit{
        let content="left \"quoted\" \\ / \n\r\t\u{0008}\u{000C} 音楽 𝄞 end"
        let raw=streamEventTestRaw(quoteUnifiedJson(content))
        for(width in [1,2,3,7,65536]){
            let owned=streamEventTestDecode(raw,width)
            try{let event=owned.value
            @Expect(event.metadataRecord.id,"m-stream")
            @Expect(event.field("content").getOrThrow().bytes,content.size)
            @Expect(event.field("content").getOrThrow().inlinePrefix(),content)
            @Expect(event.field("content").getOrThrow().digest,modelPolicySha256Text(content))
            @Expect(event.field("context").getOrThrow().inlinePrefix(),"note\tcontext")
            let field=event.field("content").getOrThrow()
            @Expect(parseUnifiedJson(raw[field.rawOffset..field.rawOffset+field.rawBytes]).text,content)
            }finally{owned.close()}
        }
        let escaped=streamEventTestRaw("\"\\uD834\\uDD1E\\u97F3\\u697D\\u0000\"")
        let owned=streamEventTestDecode(escaped,1)
        try{@Expect(owned.value.field("content").getOrThrow().inlinePrefix(),"𝄞音楽\u{0000}")}finally{owned.close()}
    }
    @TestCase
    func originalOptionalTypesUnknownFieldsAndEncodedKeysKeepCodecSemantics():Unit{
        let raw=streamEventTestRaw("\"text\"",extra:",\"importancePermille\":-10,\"expiresAt\":\"wrong-type\","+
            "\"conflictIds\":[1,\"one\",null,\"two\"],\"unknown\":{\"content\":\"nested\"},\"updatedAt\":123")
        let original=memoryV3DecodeEvent(parseUnifiedJson(raw,maxBytes:67108864,maxDepth:32)).value().getOrThrow()
        let owned=streamEventTestDecode(raw,3)
        try{let event=owned.value
        @Expect(event.metadataRecord.importancePermille,original.importancePermille)
        @Expect(event.metadataRecord.expiresAt,original.expiresAt)
        @Expect(event.metadataRecord.updatedAt,original.updatedAt)
        @Expect(event.metadataRecord.conflictIds.size,original.conflictIds.size)
        @Expect(event.metadataRecord.conflictIds[0],original.conflictIds[0])
        @Expect(event.metadataRecord.conflictIds[1],original.conflictIds[1])
        @Expect(event.fields.size,3)
        let encoded=raw.replace("\"record\"","\"rec\\u006frd\"").replace("\"content\":\"text\"","\"con\\u0074ent\":\"text\"")
        let encodedOwned=streamEventTestDecode(encoded,1)
        try{@Expect(encodedOwned.value.field("content").getOrThrow().inlinePrefix(),"text")}finally{encodedOwned.close()}
        }finally{owned.close()}
    }
    @TestCase
    func originalBadHistoricalCodecAndStringSyntaxCannotBecomeReady():Unit{
        let good=streamEventTestRaw("\"current valid content\"")
        let malformed=[good.replace("\"version\":3","\"version\":2"),
            good.replace("\"version\":3","\"version\":3,\"version\":3"),
            good.replace("\"current valid content\"","\"\\uD800x\""),
            good.replace("\"current valid content\"","\"\\uDC00\""),
            good.replace("\"current valid content\"","\"\\x00\""),
            good.replace("\"current valid content\"","\"bad\ncontrol\""),
            good.replace("\"current valid content\"","\"\""),
            good[..good.size-1],good+" true"]
        for(raw in malformed){@Expect(streamEventTestRejected(raw),true)}
        // The current event being valid does not erase a malformed earlier
        // history event. Every event decoder must finish before tool compute.
        @Expect(streamEventTestRejected(malformed[0]),true)
        @Expect(streamEventTestRejected(good),false)
        let bytes=good.toArray();let opening=good.indexOf("current").getOrThrow()
        bytes[opening]=0xC0;bytes[opening+1]=0xAF
        let owner=reservePurePolicyRawData();var rejected=false
        try{
            let decoder=MemoryEventStreamDecoder(bytes.size,modelPolicySha256(bytes),owner)
            decoder.append(0,bytes);let _=decoder.complete()
        }catch(_:Exception){rejected=true}finally{owner.close()}
        @Expect(rejected,true)
    }
    @TestCase
    func exactExtentHashContiguityAndOnceOnlyFinishAreRequired():Unit{
        let raw=streamEventTestRaw("\"value\"");let owner=reservePurePolicyRawData()
        try{
            let decoder=MemoryEventStreamDecoder(raw.size,modelPolicySha256Text(raw),owner)
            decoder.append(0,raw.toArray());let _=decoder.complete()
            var duplicate=false;try{let _=decoder.complete()}catch(_:Exception){duplicate=true}
            @Expect(duplicate,true)
            let other=MemoryEventStreamDecoder(raw.size,modelPolicySha256Text(raw+"changed"),owner)
            other.append(0,raw.toArray());var hash=false;try{let _=other.complete()}catch(_:Exception){hash=true};@Expect(hash,true)
            let skipped=MemoryEventStreamDecoder(raw.size,modelPolicySha256Text(raw),owner)
            var skip=false;try{skipped.append(1,raw.toArray())}catch(_:Exception){skip=true};@Expect(skip,true)
        }finally{owner.close()}
    }
    @TestCase
    func sixtyThreeMiBOriginalRecordUsesBoundedDecodedFragments():Unit{
        let head="{\"version\":3,\"operation\":\"retain\",\"record\":{\"id\":\"m-big\",\"kind\":\"project_fact\","+
            "\"scopeKind\":\"global\",\"scopeKey\":\"\",\"status\":\"active\",\"revision\":1,\"content\":\""
        let tail="\",\"context\":\"\",\"source\":\"\"}}"
        let chunk=Array<Byte>(65536,repeat:b'x');let count:Int64=1008 // 63MiB, event overhead stays below64MiB.
        let bytes=head.size+count*chunk.size+tail.size;let rawHash=SHA256();let textHash=SHA256()
        rawHash.write(head.toArray())
        for(_ in 0..count){rawHash.write(chunk);textHash.write(chunk)};rawHash.write(tail.toArray())
        let owner=reservePurePolicyRawData();let progress=MemoryStreamEventTestProgress()
        try{
            let decoder=MemoryEventStreamDecoder(bytes,logicalJsonEncodeHex(rawHash.finish()),owner,
                consume:{field,offset,text=>if(field=="content"){
                    @Expect(offset,progress.seen);@Expect(text.size<=65539,true);progress.seen+=text.size;progress.fragments++}})
            decoder.append(0,head.toArray());var offset=head.size
            for(_ in 0..count){decoder.append(offset,chunk);offset+=chunk.size}
            decoder.append(offset,tail.toArray());let event=decoder.complete()
            @Expect(bytes<67108864,true)
            @Expect(progress.seen,66060288)
            @Expect(progress.fragments,1008)
            @Expect(event.field("content").getOrThrow().bytes,66060288)
            @Expect(event.field("content").getOrThrow().digest,logicalJsonEncodeHex(textHash.finish()))
            @Expect(event.field("content").getOrThrow().inlinePrefix().size,65537)
            @Expect(event.field("context").getOrThrow().bytes,0)
            @Expect(event.metadataRecord.id,"m-big")
        }finally{owner.close()}
    }
    @TestCase
    func prefixEndsBeforeWholeScalarAndNeverSkipsIntoLaterText():Unit{
        let prefix=String.fromUtf8(Array<Byte>(65536,repeat:b'x'))
        let raw=streamEventTestRaw(quoteUnifiedJson(prefix+"音z"))
        let owned=streamEventTestDecode(raw,65536)
        try{let value=owned.value.field("content").getOrThrow()
        @Expect(value.inlinePrefix(),prefix)
        @Expect(value.bytes,prefix.size+4)
        @Expect(value.digest,modelPolicySha256Text(prefix+"音z"))
        }finally{owned.close()}
    }
}
