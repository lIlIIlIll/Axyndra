package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Native business validation over a generic actual structural projection.
// The producer must have mechanically parsed EVERY original JSON byte with
// duplicate-key rejection/depth32/UTF8 validation. This descriptive DTO is
// never a ReadGrant, Source or proof: real Host/Store pins remain mandatory.
let MEMORY_CODEC_PROJECTION_PATHS:Array<Array<String>>=[
    ["version"],["operation"],["record"],["record","id"],["record","kind"],
    ["record","scopeKind"],["record","scopeKey"],["record","content"],["record","status"],
    ["record","context"],["record","source"],["record","revision"],["record","conflictIds"]]
let MEMORY_CODEC_CLASSIFICATION_PATHS:Array<Array<String>>=[
    ["version"],["record","kind"],["record","scopeKind"],["record","status"]]

func memoryCodecProjectionPath(value:AgentValue,path:Array<String>):Bool{
    if(value.unifiedKind!=ValueKind.List || value.items.size!=path.size){return false}
    for(index in 0..path.size){if(value.items[index].unifiedKind!=ValueKind.Text || value.items[index].text!=path[index]){return false}}
    true
}
func memoryCodecProjectionClassification(path:Array<String>):Bool{
    for(candidate in MEMORY_CODEC_CLASSIFICATION_PATHS){
        if(candidate.size!=path.size){continue}
        var same=true;for(index in 0..path.size){if(candidate[index]!=path[index]){same=false}}
        if(same){return true}}
    false
}
func memoryCodecProjectionValue(field:AgentValue,path:Array<String>):?AgentValue{
    let classified=memoryCodecProjectionClassification(path)
    memoryDocumentFields(field,if(classified){["path","type","bytes","prefix"]}else{["path","type","bytes"]})
    if(!memoryCodecProjectionPath(field.field("path").getOrThrow(),path)){
        throw PureProviderError("memory.codec_projection_shape","projection path/order changed")}
    let kind=memoryDocumentText(field,"type");let bytes=memoryDocumentInteger(field,"bytes")
    if(bytes<0 || bytes>67108864 || !["missing","null","boolean","number","string","array","object"].contains(kind)){
        throw PureProviderError("memory.codec_projection_shape","projection type/length changed")}
    if(!["string","number"].contains(kind) && bytes!=0){
        throw PureProviderError("memory.codec_projection_shape","only scalar text has a projected byte length")}
    var prefix=""
    if(classified){
        prefix=memoryDocumentText(field,"prefix")
        if(prefix.size>64 || prefix.size>bytes || (bytes<=64 && prefix.size!=bytes) ||
            (!["string","number"].contains(kind) && prefix!="")){
            throw PureProviderError("memory.codec_projection_shape","classification prefix is not its bounded complete extent")}}
    // No opaque id/content/context/source/revision/conflictIds bytes, hashes
    // or prefixes are accepted for an unreadable historical event. The old
    // decoder's acceptance checks need only their true type/empty state.
    match(kind){
        case "missing"=>None
        case "null"=>Some(nullValue())
        case "boolean"=>Some(boolValue(false))
        case "array"=>Some(listValue([]))
        case "object"=>Some(objectValue([]))
        case "number"=>
            if(classified && bytes<=64){Some(numberValue(prefix))}else{Some(integerValue(0))}
        case "string"=>
            let value=if(classified){if(bytes==prefix.size){prefix}else{"unrecognized-stream-classification"}}
                else{if(bytes==0){""}else{"opaque-nonempty"}}
            Some(textValue(value))
        case _=>throw PureProviderError("memory.codec_projection_shape","unsupported projected scalar")}
}
func memoryV3ValidateProjectedEvent(projection:AgentValue):Result<Unit>{
    memoryDocumentFields(projection,["schema","fields"])
    if(httpIntentText(projection,"schema")!="axyndra.json-field-projection/v1"){
        throw PureProviderError("memory.codec_projection_shape","unknown generic structural projection")}
    let fields=projection.field("fields").getOrThrow()
    if(fields.unifiedKind!=ValueKind.List || fields.items.size!=MEMORY_CODEC_PROJECTION_PATHS.size){
        throw PureProviderError("memory.codec_projection_shape","every fixed structural field is required")}
    let values=ArrayList<?AgentValue>()
    for(index in 0..fields.items.size){values.add(memoryCodecProjectionValue(fields.items[index],MEMORY_CODEC_PROJECTION_PATHS[index]))}
    let event=ArrayList<ValueField>()
    match(values[0]){case Some(value)=>event.add(ValueField("version",value));case None=>()}
    match(values[1]){case Some(value)=>event.add(ValueField("operation",value));case None=>()}
    match(values[2]){
        case Some(record)=>
            if(record.unifiedKind==ValueKind.Object){
                let entries=ArrayList<ValueField>()
                for(index in 3..values.size){match(values[index]){
                    case Some(value)=>entries.add(ValueField(MEMORY_CODEC_PROJECTION_PATHS[index][1],value))
                    case None=>()}}
                event.add(ValueField("record",objectValue(entries.toArray())))
            }else{event.add(ValueField("record",record))}
        case None=>()}
    match(memoryV3DecodeEvent(objectValue(event.toArray()))){
        case Result.Err(error)=>Result<Unit>.Err(error)
        case Result.Ok(_)=>Result<Unit>.Ok(())}
}
