package memory_plugin
import agent_domain.*
import pure_provider_runtime.*
import stdx.crypto.digest.SHA256
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func boundedMetadataTestDecode(raw:String,width:Int64):MemoryStreamEventTestOwner{
    let owner=reservePurePolicyRawData()
    try{
        let decoder=MemoryEventStreamDecoder(raw.size,modelPolicySha256Text(raw),owner,boundedMetadata:true)
        try{let bytes=raw.toArray();var offset:Int64=0
            while(offset<bytes.size){let end=min(bytes.size,offset+width);decoder.append(offset,bytes[offset..end]);offset=end}
            MemoryStreamEventTestOwner(decoder.complete(),owner)
        }finally{decoder.close()}
    }catch(error:Exception){owner.close();throw error}}
func boundedMetadataTestReject(raw:String):Bool{
    try{let value=boundedMetadataTestDecode(raw,1);value.close();false}catch(_:Exception){true}}

@Test
class MemoryBoundedIgnoredMetadataTests {
    @TestCase
    func everyIgnoredRootAndRecordTypeKeepsOriginalCodecValues():Unit{
        let values=["null","false","1.25e+2","\"unknown 音楽\"","[null,true,1,{\"x\":\"y\"}]","{\"a\":[1,2]}"]
        for(value in values){
            let raw=streamEventTestRaw("\"text\"",extra:",\"ignored_record\":"+value)
            let withRoot=raw[..raw.size-1]+",\"ignored_root\":"+value+"}"
            let original=memoryV3DecodeEvent(parseUnifiedJson(withRoot,maxBytes:67108864,maxDepth:32)).value().getOrThrow()
            for(width in [1,3,65536]){
                let owned=boundedMetadataTestDecode(withRoot,width)
                try{let actual=owned.value.metadataRecord
                    @Expect(actual.id,original.id);@Expect(actual.kind,original.kind);@Expect(actual.scope.kind,original.scope.kind)
                    @Expect(actual.scope.key,original.scope.key);@Expect(actual.revision,original.revision)
                    @Expect(owned.value.field("content").getOrThrow().inlinePrefix(),original.content)
                }finally{owned.close()}}}}
    @TestCase
    func knownMalformedAndFallbackFieldsAreNeverMechanicallyDiscarded():Unit{
        let valid=streamEventTestRaw("\"text\"",extra:",\"expiresAt\":\"fallback\",\"conflictIds\":[1,\"one\",null],\"importancePermille\":-10")
        let original=memoryV3DecodeEvent(parseUnifiedJson(valid,maxBytes:67108864,maxDepth:32)).value().getOrThrow()
        let owned=boundedMetadataTestDecode(valid,1)
        try{@Expect(owned.value.metadataRecord.expiresAt,original.expiresAt)
            @Expect(owned.value.metadataRecord.conflictIds.size,1);@Expect(owned.value.metadataRecord.conflictIds[0],"one")
            @Expect(owned.value.metadataRecord.importancePermille,original.importancePermille)}finally{owned.close()}
        for(raw in [valid.replace("\"version\":3","\"version\":2"),valid.replace("\"active\"","\"invalid\""),
            valid.replace("\"project_fact\"","\"invalid\""),valid.replace("\"global\"","\"invalid\""),
            valid.replace("\"content\":\"text\"","\"content\":[]")]){@Expect(boundedMetadataTestReject(raw),true)}}
    @TestCase
    func ignoredSubtreesStillValidateEverySyntaxKeyUnicodeAndDepthByte():Unit{
        let valid=streamEventTestRaw("\"text\"",extra:",\"unknown\":{\"key\":1}")
        for(raw in [valid.replace("{\"key\":1}","{\"key\":1,\"key\":2}"),
            valid.replace("{\"key\":1}","{\"key\":01}"),valid.replace("{\"key\":1}","{\"key\":1e}"),
            valid.replace("{\"key\":1}","{\"key\":\"\\uD800x\"}"),
            valid.replace("{\"key\":1}","{\"key\":\"bad\ncontrol\"}"),valid+" true"]){@Expect(boundedMetadataTestReject(raw),true)}
        var deep="0";for(_ in 0..32){deep="["+deep+"]"}
        @Expect(boundedMetadataTestReject(valid.replace("{\"key\":1}",deep)),true)
        let encoded=valid.replace("\"unknown\"","\"unkn\\u006fwn\"")
        @Expect(boundedMetadataTestReject(encoded),false)}
    @TestCase
    func sixtyThreeMiBIgnoredStringDoesNotBecomeMetadataDOM():Unit{
        let base=streamEventTestRaw("\"visible\"")
        let head=base[..base.size-2]+",\"unknown\":\"";let tail="\"}}"
        let chunk=Array<Byte>(65536,repeat:b'x');let count:Int64=1008
        let hash=SHA256();hash.write(head.toArray());for(_ in 0..count){hash.write(chunk)};hash.write(tail.toArray())
        let owner=reservePurePolicyRawData()
        try{
            let decoder=MemoryEventStreamDecoder(head.size+count*chunk.size+tail.size,logicalJsonEncodeHex(hash.finish()),owner,boundedMetadata:true)
            try{decoder.append(0,head.toArray());var offset=head.size
                for(_ in 0..count){decoder.append(offset,chunk);offset+=chunk.size};decoder.append(offset,tail.toArray())
                let value=decoder.complete();@Expect(value.metadataRecord.id,"m-stream")
                @Expect(value.field("content").getOrThrow().inlinePrefix(),"visible")
                @Expect(value.fields.size,3)
            }finally{decoder.close()}
        }finally{owner.close()}}
}
