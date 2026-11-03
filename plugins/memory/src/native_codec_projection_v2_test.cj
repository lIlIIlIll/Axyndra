package memory_plugin

import yjson.*
import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

func codecV2StreamProject(raw:String,owner:LogicalJsonOwnerReservation):AgentValue{
    let rules=MEMORY_CODEC_PROJECTION_PATHS.map{path=>JsonFieldProjectionRule(path,
        prefixBytes:if(memoryCodecProjectionClassification(path)){64}else{0},
        includePrefix:memoryCodecProjectionClassification(path),
        asciiTrimmedLength:path.size==2 && path[0]=="record" && path[1]=="scopeKey")}
    let scanner=JsonFieldStreamProjector(raw.size,modelPolicySha256Text(raw),rules,owner,
        projectedSchema:"axyndra.json-field-projection/v2")
    let bytes=raw.toArray();var offset:Int64=0
    while(offset<bytes.size){let end=min(offset+7,bytes.size);scanner.append(offset,bytes[offset..end]);offset=end}
    scanner.finish().value
}
func codecV2OriginalAccepts(raw:String):Bool{
    try{memoryV3DecodeEvent(parseUnifiedJson(raw,maxBytes:67108864,maxDepth:32)).isOk()}catch(_:Exception){false}
}
func codecV2StreamAccepts(raw:String):Bool{
    let owner=reservePurePolicyRawData()
    try{memoryV3ValidateProjectedEventV2(codecV2StreamProject(raw,owner)).isOk()}catch(_:Exception){false}finally{owner.close()}
}
@Test
class NativeMemoryCodecProjectionV2Tests {
    @TestCase
    func EveryScopeKindAndWhitespaceKeyMatchesTheOriginalDecoderAndConstructor():Unit{
        for(scope in ["global","user","workspace","session","wrong"]){
            for(key in ["","x"," \t\r\nx\u{000B}\u{000C} "," \t\n\u{000B}\u{000C}\r "," ","\u{0000}"]){
                let event=codecProjectionValidFixture();let record=event.field("record").getOrThrow()
                record.put("scopeKind",textValue(scope));record.put("scopeKey",textValue(key))
                let raw=stringifyUnifiedJson(event)
                @Expect(codecV2StreamAccepts(raw),codecV2OriginalAccepts(raw))
            }
        }
    }
    @TestCase
    func RequiredTypesOptionalFallbackAndUnknownStructureUseTheRealMechanicalStream():Unit{
        for(name in ["id","content","scopeKey","kind","scopeKind","status","context","source","revision","conflictIds","expiresAt","unknown"]){
            for(value in [nullValue(),boolValue(true),integerValue(3),textValue(""),textValue("private"),textValue(" \t "),
                listValue([textValue("private-other-id"),integerValue(1)]),objectValue([])]){
                let event=codecProjectionValidFixture();event.field("record").getOrThrow().put(name,value)
                let raw=stringifyUnifiedJson(event);@Expect(codecV2StreamAccepts(raw),codecV2OriginalAccepts(raw))
            }
        }
        let raw=stringifyUnifiedJson(codecProjectionValidFixture());let owner=reservePurePolicyRawData()
        try{let projection=codecV2StreamProject(raw,owner);let text=canonicalAgentValue(projection)
            for(secret in ["private-other-thread-id","private-thread","private payload","private context","private origin","private-other-id"]){@Expect(text.contains(secret),false)}
            for(index in 0..MEMORY_CODEC_PROJECTION_PATHS.size){let field=projection.field("fields").getOrThrow().items[index]
                @Expect(field.field("ascii_trimmed_bytes").isSome(),index==6)
                if(!memoryCodecProjectionClassification(MEMORY_CODEC_PROJECTION_PATHS[index])){
                    @Expect(field.field("prefix").isNone(),true);@Expect(field.field("sha256").isNone(),true)}}
        }finally{owner.close()}
    }
    @TestCase
    func UnknownDuplicateInvalidUtf8AndDeepHistoricalSyntaxCannotBeHidden():Unit{
        let valid=stringifyUnifiedJson(codecProjectionValidFixture())
        for(raw in [valid.replace("\"version\":3","\"version\":2"),
            valid.replace("\"version\":3","\"version\":3,\"version\":3"),
            valid.replace("\"private payload\"","\"\\uD800x\""),
            valid.replace("\"private payload\"","\"\\uDC00\""),
            valid.replace("\"private payload\"","\"\\x00\""),valid[..valid.size-1],valid+" true"]){
            @Expect(codecV2StreamAccepts(raw),codecV2OriginalAccepts(raw))
            @Expect(codecV2StreamAccepts(raw),false)
        }
    }
}
