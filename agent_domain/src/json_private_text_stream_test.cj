package agent_domain

import yjson.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson_support.*

class PrivateTextTestCollector {
    let raw=ArrayList<Byte>()
    let widths=ArrayList<Int64>()
    var offset:Int64=0
    func append(expected:Int64,bytes:Array<Byte>):Unit{
        if(expected!=offset || bytes.isEmpty() || bytes.size>65536){throw IllegalStateException("private test callback skipped or exceeded a window")}
        raw.add(all:bytes);widths.add(bytes.size);offset+=bytes.size
    }
}
class PrivateTextTestHashCollector {
    let hash=SHA256()
    var offset:Int64=0
    var largest:Int64=0
    func append(expected:Int64,bytes:Array<Byte>):Unit{
        if(expected!=offset || bytes.isEmpty() || bytes.size>65536){throw IllegalStateException("private hash callback skipped or exceeded a window")}
        hash.write(bytes);offset+=bytes.size;largest=max(largest,bytes.size)
    }
}
func privateTextTestScan(raw:String,width:Int64,owner:LogicalJsonOwnerReservation,
    collector:PrivateTextTestCollector):JsonFieldStreamProjector{
    let scanner=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw),[JsonFieldProjectionRule(["tag"])],owner,
        privateText:Some(JsonFieldStreamPrivateTextSink(["record","id"],{offset,bytes=>collector.append(offset,bytes)})))
    let bytes=raw.toArray();var offset:Int64=0
    while(offset<bytes.size){let end=min(bytes.size,offset+width);scanner.append(offset,bytes[offset..end]);offset=end}
    let _=scanner.finish();scanner
}

@Test
class JsonPrivateTextStreamTests {
    @TestCase
    func DecodedPrivateBytesMatchEscapedUnicodeNulAndUntrimmedOriginalText():Unit{
        let raw="{\"tag\":\"public\",\"record\":{\"id\":\" \\u0061\\uD834\\uDD1E音\\u0000\\t \"}}"
        let expected=" a𝄞音\u{0000}\t "
        for(width in [1,2,3,7,65536]){
            let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536);let collector=PrivateTextTestCollector()
            try{
                let scanner=privateTextTestScan(raw,width,owner,collector)
                let observed=scanner.privateTextObservation()
                @Expect(observed.kind,"string");@Expect(observed.bytes,expected.size)
                @Expect(observed.digest,modelPolicySha256Text(expected));@Expect(collector.raw.toArray(),expected.toArray())
            }finally{owner.close()}
            @Expect(budget.usage()[0],0)
        }
    }
    @TestCase
    func PrivateObserverAddsNoFieldToTheOriginalPublicProjection():Unit{
        let raw="{\"tag\":\"public\",\"record\":{\"id\":\"private identity\"}}"
        let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
        try{
            let old=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw),[JsonFieldProjectionRule(["tag"])],owner)
            old.append(0,raw.toArray());let oldValue=old.finish().value
            let collector=PrivateTextTestCollector()
            let current=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw),[JsonFieldProjectionRule(["tag"])],owner,
                privateText:Some(JsonFieldStreamPrivateTextSink(["record","id"],{offset,bytes=>collector.append(offset,bytes)})))
            current.append(0,raw.toArray());let value=current.finish().value
            @Expect(canonicalAgentValue(value),canonicalAgentValue(oldValue))
            @Expect(value.field("fields").getOrThrow().items.size,1)
            @Expect(canonicalAgentValue(value).contains("identity"),false)
            @Expect(canonicalAgentValue(value).contains("sha256"),false)
        }finally{owner.close()}
    }
    @TestCase
    func ExistingPublicRuleCanAlsoHaveAPrivateSinkWithoutDuplicatingThePath():Unit{
        let raw="{\"record\":{\"id\":\"a\\u0000b\"}}";let collector=PrivateTextTestCollector()
        let owner=LogicalJsonOwnerBudget().acquire(65536)
        try{
            let scanner=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw),[JsonFieldProjectionRule(["record","id"])],owner,
                privateText:Some(JsonFieldStreamPrivateTextSink(["record","id"],{offset,bytes=>collector.append(offset,bytes)})))
            scanner.append(0,raw.toArray());let result=scanner.finish()
            @Expect(result.value.field("fields").getOrThrow().items.size,1)
            @Expect(scanner.privateTextObservation().digest,modelPolicySha256Text("a\u{0000}b"))
        }finally{owner.close()}
    }
    @TestCase
    func MissingOrNonStringKnownFieldsNeverBecomeNullOrDecodedPrivateBytes():Unit{
        for(value in ["",",\"id\":null",",\"id\":false",",\"id\":123",",\"id\":{}",",\"id\":[]"]){
            let raw="{\"record\":{\"other\":true"+value+"}}";let collector=PrivateTextTestCollector()
            let owner=LogicalJsonOwnerBudget().acquire(65536)
            try{
                let scanner=privateTextTestScan(raw,1,owner,collector);let observed=scanner.privateTextObservation()
                @Expect(observed.kind=="string",false);@Expect(observed.bytes,0);@Expect(observed.digest,"")
                @Expect(collector.raw.size,0)
            }finally{owner.close()}
        }
        let owner=LogicalJsonOwnerBudget().acquire(65536);let collector=PrivateTextTestCollector()
        try{let scanner=privateTextTestScan("{\"record\":{\"id\":\"\"}}",1,owner,collector)
            @Expect(scanner.privateTextObservation().kind,"string")
            @Expect(scanner.privateTextObservation().digest,modelPolicySha256([]))
        }finally{owner.close()}
    }
    @TestCase
    func GiantPrivateTextRemainsFixedChunksAndFullDigestWithoutAValueString():Unit{
        let prefix="{\"record\":{\"id\":\"";let suffix="\"},\"tag\":true}";let length:Int64=2097155
        let chunk=Array<Byte>(65536,repeat:b'x');let inputHash=SHA256();let valueHash=SHA256()
        inputHash.write(prefix.toArray());var offset:Int64=0
        while(offset<length){let width=min(chunk.size,length-offset);inputHash.write(chunk[0..width]);valueHash.write(chunk[0..width]);offset+=width}
        inputHash.write(suffix.toArray());let owner=LogicalJsonOwnerBudget().acquire(65536);let collector=PrivateTextTestHashCollector()
        try{
            let scanner=JsonFieldStreamProjector(prefix.size+length+suffix.size,logicalJsonEncodeHex(inputHash.finish()),[JsonFieldProjectionRule(["tag"])],owner,
                privateText:Some(JsonFieldStreamPrivateTextSink(["record","id"],{position,bytes=>collector.append(position,bytes)})))
            scanner.append(0,prefix.toArray());offset=0
            while(offset<length){let width=min(chunk.size,length-offset);scanner.append(prefix.size+offset,chunk[0..width]);offset+=width}
            scanner.append(prefix.size+length,suffix.toArray());let result=scanner.finish();let observed=scanner.privateTextObservation()
            @Expect(observed.bytes,length);@Expect(collector.offset,length);@Expect(collector.largest,65536)
            @Expect(observed.digest,logicalJsonEncodeHex(valueHash.finish()));@Expect(observed.digest,logicalJsonEncodeHex(collector.hash.finish()))
            @Expect(result.value.field("fields").getOrThrow().items.size,1)
        }finally{owner.close()}
    }
    @TestCase
    func CompleteGrammarAndDuplicatesAreRequiredAfterThePrivateScalar():Unit{
        for(raw in ["{\"record\":{\"id\":\"a\",\"\\u0069d\":\"b\"}}",
            "{\"record\":{\"id\":\"a\"},\"unknown\":{\"x\":1,\"x\":2}}",
            "{\"record\":{\"id\":\"a\"},\"unknown\":1e+}",
            "{\"record\":{\"id\":\"a\"},\"unknown\":\"\\uD800\"}",
            "{\"record\":{\"id\":\"a\"}} true"]){
            let owner=LogicalJsonOwnerBudget().acquire(65536);let collector=PrivateTextTestCollector();var refused=false
            try{let _=privateTextTestScan(raw,1,owner,collector)}catch(_:Exception){refused=true}finally{owner.close()}
            @Expect(refused,true)
        }
    }
    @TestCase
    func ObservationRequiresTheExactWholeInputHashAndCompletedEOF():Unit{
        let raw="{\"record\":{\"id\":\"a\"}}";let owner=LogicalJsonOwnerBudget().acquire(65536)
        let collector=PrivateTextTestCollector()
        try{
            let scanner=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw+"changed"),[JsonFieldProjectionRule(["tag"])],owner,
                privateText:Some(JsonFieldStreamPrivateTextSink(["record","id"],{offset,bytes=>collector.append(offset,bytes)})))
            scanner.append(0,raw.toArray());var early=false
            try{let _=scanner.privateTextObservation()}catch(_:Exception){early=true};@Expect(early,true)
            var changed=false;try{let _=scanner.finish()}catch(_:Exception){changed=true};@Expect(changed,true)
            var after=false;try{let _=scanner.privateTextObservation()}catch(_:Exception){after=true};@Expect(after,true)
        }finally{owner.close()}
    }
    @TestCase
    func CallbackFailureAbortsRatherThanAcknowledgingThePrivateWindow():Unit{
        let raw="{\"record\":{\"id\":\"a\"}}";let owner=LogicalJsonOwnerBudget().acquire(65536)
        try{
            let scanner=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw),[JsonFieldProjectionRule(["tag"])],owner,
                privateText:Some(JsonFieldStreamPrivateTextSink(["record","id"],{_,_=>throw IllegalStateException("actual callback cancelled")})))
            var aborted=false;try{scanner.append(0,raw.toArray())}catch(_:Exception){aborted=true};@Expect(aborted,true)
            var observed=false;try{let _=scanner.privateTextObservation()}catch(_:Exception){observed=true};@Expect(observed,true)
        }finally{owner.close()}
    }
}
