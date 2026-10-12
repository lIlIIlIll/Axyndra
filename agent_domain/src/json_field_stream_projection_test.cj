package agent_domain

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

func projectionTestRules():Array<JsonFieldProjectionRule>{[
    JsonFieldProjectionRule(["tag"],prefixBytes:64,includePrefix:true),
    JsonFieldProjectionRule(["secret"]),JsonFieldProjectionRule(["nested"]),
    JsonFieldProjectionRule(["nested","number"],prefixBytes:64,includePrefix:true),
    JsonFieldProjectionRule(["absent"])]}
func projectionTestScan(raw:String,width:Int64,owner:LogicalJsonOwnerReservation):JsonFieldStreamProjection{
    let scanner=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw),projectionTestRules(),owner,
        comparisons:[JsonFieldProjectionComparison(["secret"],"private音楽\u{0000}"),
            JsonFieldProjectionComparison(["secret"],"another private value")])
    let bytes=raw.toArray();var offset:Int64=0
    while(offset<bytes.size){let end=min(bytes.size,offset+width);scanner.append(offset,bytes[offset..end]);offset=end}
    scanner.finish()
}
func projectionTestRejected(raw:String):Bool{
    let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
    try{let _=projectionTestScan(raw,1,owner);false}catch(_:Exception){true}finally{owner.close()}
}
@Test
class JsonFieldStreamProjectionTests{
    @TestCase
    func ProjectionExposesOnlyFrozenTypesLengthsAndBoundedClassification():Unit{
        let raw="{\"tag\":\"𝄞音楽\",\"secret\":\"private音楽\\u0000\",\"nested\":{\"number\":-1.25e+3},\"other\":[true,null,{\"ignored\":\"value\"}]}"
        for(width in [1,2,3,7,65536]){
            let budget=LogicalJsonOwnerBudget();let owner=budget.acquire(65536)
            try{
                let actual=projectionTestScan(raw,width,owner);let fields=actual.value.field("fields").getOrThrow().items
                @Expect(fields[0].field("type").getOrThrow().text,"string")
                @Expect(fields[0].field("prefix").getOrThrow().text,"𝄞音楽")
                @Expect(documentContractInteger(fields[0].field("bytes").getOrThrow()),10)
                @Expect(documentContractInteger(fields[1].field("bytes").getOrThrow()),14)
                @Expect(fields[1].field("prefix").isNone(),true);@Expect(fields[1].field("sha256").isNone(),true)
                @Expect(fields[2].field("type").getOrThrow().text,"object")
                @Expect(fields[3].field("type").getOrThrow().text,"number")
                @Expect(fields[3].field("prefix").getOrThrow().text,"-1.25e+3")
                @Expect(documentContractInteger(fields[3].field("bytes").getOrThrow()),8)
                @Expect(fields[4].field("type").getOrThrow().text,"missing")
                @Expect(actual.comparisonMatches[0],true);@Expect(actual.comparisonMatches[1],false)
                @Expect(canonicalAgentValue(actual.value).contains("private"),false)
            }finally{owner.close()}
            @Expect(budget.usage()[0],0)
        }
    }
    @TestCase
    func UnknownFieldsStillRequireCompleteOriginalGrammarAndDuplicateRejection():Unit{
        let invalid=["{\"tag\":\"ok\",\"unknown\":{\"x\":1,\"x\":2}}",
            "{\"tag\":\"ok\",\"unknown\":{\"x\":1,\"\\u0078\":2}}",
            "{\"tag\":\"ok\",\"unknown\":\"\\uD800x\"}",
            "{\"tag\":\"ok\",\"unknown\":\"\\uDC00\"}",
            "{\"tag\":\"ok\",\"unknown\":\"bad\ncontrol\"}",
            "{\"tag\":\"ok\",\"unknown\":01}","{\"unknown\":1e}","{\"unknown\":1.}",
            "{\"unknown\":-}","{\"unknown\":1e+}","{\"unknown\":truee}",
            "{\"unknown\":false,true}","{\"unknown\":[1,]}","{\"unknown\":{\"a\":1,}}",
            "{\"unknown\":null} true","{\"unknown\":{[1]:2}}"]
        for(raw in invalid){@Expect(projectionTestRejected(raw),true)}
        for(raw in ["{\"unknown\":[-0,0,1,-1,1.2,1e2,1E-2,true,false,null,\"\\uD834\\uDD1E\"]}",
            "{\"tag\":\"a\",\"nested\":false}","{\"tag\":null,\"secret\":3}"]){
            @Expect(projectionTestRejected(raw),false)}
        let raw="{\"unknown\":\"ab\"}";let bytes=raw.toArray();let position=raw.indexOf("ab").getOrThrow()
        bytes[position]=0xC0;bytes[position+1]=0xAF
        let owner=LogicalJsonOwnerBudget().acquire(65536);var refused=false
        try{let scanner=JsonFieldStreamProjector(bytes.size,modelPolicySha256(bytes),projectionTestRules(),owner)
            scanner.append(0,bytes);let _=scanner.finish()}catch(_:Exception){refused=true}finally{owner.close()}
        @Expect(refused,true)
    }
    @TestCase
    func StreamExtentHashAndOnceOnlyFinishAreStrictAndPrefixKeepsWholeScalars():Unit{
        let tag=String.fromUtf8(Array<Byte>(63,repeat:b'x'))+"音z"
        let raw="{\"tag\":"+quoteUnifiedJson(tag)+"}"
        let owner=LogicalJsonOwnerBudget().acquire(65536)
        try{
            let result=projectionTestScan(raw,1,owner);let field=result.value.field("fields").getOrThrow().items[0]
            @Expect(field.field("prefix").getOrThrow().text,String.fromUtf8(Array<Byte>(63,repeat:b'x')))
            @Expect(documentContractInteger(field.field("bytes").getOrThrow()),67)
            let scanner=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw),projectionTestRules(),owner)
            var gap=false;try{scanner.append(1,raw.toArray())}catch(_:Exception){gap=true};@Expect(gap,true)
            scanner.append(0,raw.toArray());let _=scanner.finish()
            var repeated=false;try{let _=scanner.finish()}catch(_:Exception){repeated=true};@Expect(repeated,true)
            let changed=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw+"changed"),projectionTestRules(),owner)
            changed.append(0,raw.toArray());var hash=false;try{let _=changed.finish()}catch(_:Exception){hash=true};@Expect(hash,true)
        }finally{owner.close()}
    }
    @TestCase
    func SixtyThreeMiBUnknownStringIsFullyValidatedWithoutExposingItsBytes():Unit{
        let head="{\"secret\":\"";let tail="\",\"tag\":\"ok\"}"
        let chunk=Array<Byte>(65536,repeat:b'x');let hash=SHA256();hash.write(head.toArray())
        for(_ in 0..1008){hash.write(chunk)};hash.write(tail.toArray())
        let bytes=head.size+66060288+tail.size
        let budget=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536);let owner=budget.acquire(65536)
        try{
            let scanner=JsonFieldStreamProjector(bytes,logicalJsonEncodeHex(hash.finish()),projectionTestRules(),owner)
            scanner.append(0,head.toArray());var offset=head.size
            for(_ in 0..1008){scanner.append(offset,chunk);offset+=chunk.size}
            scanner.append(offset,tail.toArray());let result=scanner.finish()
            let fields=result.value.field("fields").getOrThrow().items
            @Expect(documentContractInteger(fields[1].field("bytes").getOrThrow()),66060288)
            @Expect(fields[1].field("prefix").isNone(),true);@Expect(fields[1].field("sha256").isNone(),true)
            @Expect(fields[0].field("prefix").getOrThrow().text,"ok")
            @Expect(canonicalAgentValue(result.value).size<2048,true)
            @Expect(budget.usage()[1],16777216)
        }finally{owner.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func RetiredUnknownObjectsDoNotCreateANodeCountOrAccumulatedKeyLimit():Unit{
        let head="{\"unknown\":[";let unit="{\"a\":1},";let tail="{\"a\":1}]}"
        let count:Int64=70000;let hash=SHA256();hash.write(head.toArray())
        for(_ in 0..count){hash.write(unit.toArray())};hash.write(tail.toArray())
        let bytes=head.size+count*unit.size+tail.size
        let budget=LogicalJsonOwnerBudget(maximumCharged:16777216,maximumMessage:65536);let owner=budget.acquire(65536)
        try{
            let scanner=JsonFieldStreamProjector(bytes,logicalJsonEncodeHex(hash.finish()),projectionTestRules(),owner)
            scanner.append(0,head.toArray());var offset=head.size
            for(_ in 0..count){scanner.append(offset,unit.toArray());offset+=unit.size}
            scanner.append(offset,tail.toArray());let result=scanner.finish()
            @Expect(result.value.field("fields").getOrThrow().items[0].field("type").getOrThrow().text,"missing")
            @Expect(budget.usage()[1],16777216)
        }finally{owner.close()}
        @Expect(budget.usage()[0],0)
    }
    @TestCase
    func OriginalDepth32BoundaryAndNumberGrammarMatchTheActualJsonParser():Unit{
        for(depth in 1..35){
            var raw="0";for(_ in 0..depth){raw="["+raw+"]"}
            var originalRejected=false
            try{let _=parseUnifiedJson(raw,maxBytes:67108864,maxDepth:32)}catch(_:Exception){originalRejected=true}
            @Expect(projectionTestRejected(raw),originalRejected)
        }
        for(raw in ["0","-0","3.0","3e0","1E-300","1e999","9223372036854775808","-9223372036854775809",
            "01","+1","1.","1e","NaN","Infinity","0x01"]){
            var originalRejected=false
            try{let _=parseUnifiedJson(raw,maxBytes:67108864,maxDepth:32)}catch(_:Exception){originalRejected=true}
            @Expect(projectionTestRejected(raw),originalRejected)
        }
    }
}
