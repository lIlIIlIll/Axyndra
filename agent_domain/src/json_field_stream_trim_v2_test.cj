package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func trimProjectionTest(raw:String,expected:String):JsonFieldStreamProjection{
    let owner=LogicalJsonOwnerBudget().acquire(65536)
    try{
        let scanner=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw),
            [JsonFieldProjectionRule(["key"],asciiTrimmedLength:true)],owner,
            comparisons:[JsonFieldProjectionComparison(["key"],expected,asciiTrim:true)],
            projectedSchema:"axyndra.json-field-projection/v2")
        let bytes=raw.toArray()
        for(index in 0..bytes.size){scanner.append(index,[bytes[index]])}
        scanner.finish()
    }finally{owner.close()}
}
@Test
class JsonFieldStreamTrimV2Tests {
    @TestCase
    func AllAsciiBytesMatchTheActuallyPinnedStandardTrimAsciiDefinition():Unit{
        for(value in 0..128){
            let text=String.fromUtf8([UInt8(value)])
            @Expect(jsonStreamAsciiWhitespace(UInt8(value)),text.trimAscii()=="")
            let raw="{\"key\":"+quoteUnifiedJson(text+"needle"+text)+"}"
            let actual=trimProjectionTest(raw,"needle")
            let field=actual.value.field("fields").getOrThrow().items[0]
            @Expect(documentContractInteger(field.field("ascii_trimmed_bytes").getOrThrow()),(text+"needle"+text).trimAscii().size)
            @Expect(actual.comparisonMatches[0],(text+"needle"+text).trimAscii()=="needle")
            @Expect(field.field("prefix").isNone(),true);@Expect(field.field("sha256").isNone(),true)
        }
    }
    @TestCase
    func Utf8WhitespaceEmptyAndDifferentLongSamePrefixKeysUseCompleteEquality():Unit{
        let prefix=String.fromUtf8(Array<Byte>(65536,repeat:b'x'))
        for(key in ["", " \t\n\u{000B}\u{000C}\r ", "\u{0000}", " needle ", " \t音楽\r ",
            prefix+"a",prefix+"b","needle extra","need","needle\t inside"]){
            let raw="{\"key\":"+quoteUnifiedJson(key)+"}"
            let actual=trimProjectionTest(raw,prefix+"a")
            let field=actual.value.field("fields").getOrThrow().items[0]
            @Expect(documentContractInteger(field.field("ascii_trimmed_bytes").getOrThrow()),key.trimAscii().size)
            @Expect(actual.comparisonMatches[0],key.trimAscii()==prefix+"a")
            @Expect(canonicalAgentValue(actual.value).contains(prefix),false)
        }
    }
    @TestCase
    func ActualComparisonKeyKeepsItsOriginalUtf8BytesInsteadOfBeingTrimmed():Unit{
        let raw="{\"key\":"+quoteUnifiedJson(" \tneedle\r ")+"}"
        @Expect(trimProjectionTest(raw,"needle").comparisonMatches[0],true)
        for(actual in [" needle", "needle ", "\tneedle\r", "needle-other"]){
            @Expect(trimProjectionTest(raw,actual).comparisonMatches[0],false)}
    }
    @TestCase
    func V1DefaultShapeCannotSilentlyOptIntoTrimMetadataOrEquality():Unit{
        let raw="{\"key\":\" x \"}";let owner=LogicalJsonOwnerBudget().acquire(65536)
        try{
            var refused=false
            try{let _=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw),
                [JsonFieldProjectionRule(["key"],asciiTrimmedLength:true)],owner)}catch(_:Exception){refused=true}
            @Expect(refused,true)
            let scanner=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw),[JsonFieldProjectionRule(["key"])],owner)
            scanner.append(0,raw.toArray());let result=scanner.finish()
            @Expect(result.value.field("schema").getOrThrow().text,"axyndra.json-field-projection/v1")
            @Expect(result.value.field("fields").getOrThrow().items[0].field("ascii_trimmed_bytes").isNone(),true)
        }finally{owner.close()}
    }
}
