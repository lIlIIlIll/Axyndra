package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Pure projection fixture only. It contains no Source/grant/Host callback.
// Real generic streaming parser and actual Root/fact provenance gates remain
// required before this shape may be emitted for an unreadable event.
func codecProjectionFixture(event:AgentValue):AgentValue{
    let fields=ArrayList<AgentValue>()
    for(path in MEMORY_CODEC_PROJECTION_PATHS){
        var value:?AgentValue=Some(event)
        for(component in path){value=match(value){case Some(current)=>current.field(component);case None=>None}}
        let kind=match(value){case None=>"missing";case Some(node)=>match(node.unifiedKind){
            case ValueKind.Null=>"null";case ValueKind.Boolean=>"boolean";case ValueKind.Number=>"number"
            case ValueKind.Text=>"string";case ValueKind.List=>"array";case ValueKind.Object=>"object"}}
        let text=match(value){case Some(node)=>if(node.unifiedKind==ValueKind.Text){node.text}
            else if(node.unifiedKind==ValueKind.Number){node.asNumberText()}else{""};case None=>""}
        let entries=ArrayList<ValueField>();entries.add(ValueField("path",listValue(path.map{name=>textValue(name)})))
        entries.add(ValueField("type",textValue(kind)));entries.add(ValueField("bytes",integerValue(text.size)))
        if(memoryCodecProjectionClassification(path)){
            entries.add(ValueField("prefix",textValue(memoryPolicyUtf8Prefix(text,64))))}
        fields.add(objectValue(entries.toArray()))
    }
    objectValue([ValueField("schema",textValue("axyndra.json-field-projection/v1")),ValueField("fields",listValue(fields.toArray()))])
}
func codecProjectionValidFixture():AgentValue{
    parseUnifiedJson("{\"version\":3,\"operation\":\"retain\",\"record\":{\"id\":\"private-other-thread-id\","+
        "\"kind\":\"project_fact\",\"scopeKind\":\"session\",\"scopeKey\":\"private-thread\","+
        "\"content\":\"private payload\",\"context\":\"private context\",\"source\":\"private origin\","+
        "\"status\":\"active\",\"revision\":10,\"conflictIds\":[\"private-other-id\"]}}")
}
func codecProjectionSameAcceptance(event:AgentValue):Unit{
    let original=memoryV3DecodeEvent(event)
    let projected=memoryV3ValidateProjectedEvent(codecProjectionFixture(event))
    @Expect(original.isOk(),projected.isOk())
    if(original.isError()){@Expect(original.error().getOrThrow().code,projected.error().getOrThrow().code)}
}
@Test
class NativeMemoryCodecProjectionTests {
    @TestCase
    func everyRequiredFieldTypeEnumVersionAndScopeMatchesOriginalDecoder():Unit{
        let values=[nullValue(),boolValue(true),integerValue(0),integerValue(3),textValue(""),textValue("active"),
            listValue([]),objectValue([])]
        for(name in ["version","operation","record"]){for(value in values){
            let event=codecProjectionValidFixture();event.put(name,value);codecProjectionSameAcceptance(event)}}
        for(name in ["id","content","kind","scopeKind","scopeKey","status"]){for(value in values){
            let event=codecProjectionValidFixture();event.field("record").getOrThrow().put(name,value);codecProjectionSameAcceptance(event)}}
        for(kind in ["global","user","workspace","session","unknown"]){for(key in ["","x"]){
            let event=codecProjectionValidFixture();let record=event.field("record").getOrThrow()
            record.put("scopeKind",textValue(kind));record.put("scopeKey",textValue(key));codecProjectionSameAcceptance(event)}}
        for(kind in ["preference","project_fact","decision","constraint","observation","unknown"]){
            let event=codecProjectionValidFixture();event.field("record").getOrThrow().put("kind",textValue(kind));codecProjectionSameAcceptance(event)}
        for(status in ["active","corrected","deleted","conflicted","expired","unknown"]){
            let event=codecProjectionValidFixture();event.field("record").getOrThrow().put("status",textValue(status));codecProjectionSameAcceptance(event)}
        for(raw in ["0","2","3","4","3e0","3.0","9223372036854775808"]){
            let event=codecProjectionValidFixture();event.put("version",parseUnifiedJson(raw));codecProjectionSameAcceptance(event)}
    }
    @TestCase
    func optionalFallbackAndUnknownFieldsNeverRequireUnreadablePayload():Unit{
        for(name in ["context","source","importancePermille","expiresAt","correctionOf","replacementId","conflictIds",
            "conflictReason","deletionReason","createdAt","updatedAt","deletedAt","revision","unknown"]){
            for(value in [nullValue(),boolValue(false),integerValue(-123),textValue("private"),listValue([integerValue(1),textValue("secret")]),objectValue([])]){
                let event=codecProjectionValidFixture();event.field("record").getOrThrow().put(name,value);codecProjectionSameAcceptance(event)}}
        let projected=codecProjectionFixture(codecProjectionValidFixture());let raw=stringifyUnifiedJson(projected)
        for(secret in ["private-other-thread-id","private-thread","private payload","private context","private origin","private-other-id"]){
            @Expect(raw.contains(secret),false)}
        for(field in projected.field("fields").getOrThrow().items){
            if(!["version","kind","scopeKind","status"].contains(field.field("path").getOrThrow().items[field.field("path").getOrThrow().items.size-1].text)){
                @Expect(field.field("prefix").isNone(),true);@Expect(field.field("sha256").isNone(),true)}}
    }
    @TestCase
    func longClassificationCannotMasqueradeAsEnumAndOpaquePrefixInjectionFails():Unit{
        let event=codecProjectionValidFixture();event.field("record").getOrThrow().put("kind",textValue("project_fact"+
            String.fromUtf8(Array<Byte>(65536,repeat:b'x'))));codecProjectionSameAcceptance(event)
        let projection=codecProjectionFixture(codecProjectionValidFixture())
        projection.field("fields").getOrThrow().items[7].put("prefix",textValue("private payload"))
        var refused=false;try{let _=memoryV3ValidateProjectedEvent(projection)}catch(_:PureProviderError){refused=true};@Expect(refused,true)
    }
}
