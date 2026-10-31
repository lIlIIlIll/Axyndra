package memory_plugin

import yjson.*
import yjson_support.*
import agent_domain.*
import pure_provider_runtime.*
import std.collection.*

// Only the operator-approved scopeKey path may expose trimmed length. No
// private bytes, prefixes or hashes are added to the unreadable projection.
func memoryCodecProjectionValueV2(field:AgentValue,path:Array<String>):?AgentValue{
    if(path.size!=2 || path[0]!="record" || path[1]!="scopeKey"){return memoryCodecProjectionValue(field,path)}
    memoryDocumentFields(field,["path","type","bytes","ascii_trimmed_bytes"])
    let size=memoryDocumentInteger(field,"bytes");let trimmed=memoryDocumentInteger(field,"ascii_trimmed_bytes")
    let kind=memoryDocumentText(field,"type")
    if(trimmed<0 || trimmed>size || (kind!="string" && trimmed!=0)){
        throw PureProviderError("memory.codec_projection_shape","scope structural trim length changed")}
    let ordinary=objectValue([ValueField("path",field.field("path").getOrThrow()),
        ValueField("type",field.field("type").getOrThrow()),ValueField("bytes",field.field("bytes").getOrThrow())])
    let value=memoryCodecProjectionValue(ordinary,path)
    if(kind=="string" && size>0 && trimmed==0){return Some(textValue(" "))};value
}
func memoryV3ValidateProjectedEventV2(projection:AgentValue):Result<Unit>{
    memoryDocumentFields(projection,["schema","fields"])
    if(httpIntentText(projection,"schema")!="axyndra.json-field-projection/v2"){
        throw PureProviderError("memory.codec_projection_shape","unknown generic structural projection")}
    let fields=projection.field("fields").getOrThrow()
    if(fields.unifiedKind!=ValueKind.List || fields.items.size!=MEMORY_CODEC_PROJECTION_PATHS.size){
        throw PureProviderError("memory.codec_projection_shape","every fixed structural field is required")}
    let values=ArrayList<?AgentValue>()
    for(index in 0..fields.items.size){values.add(memoryCodecProjectionValueV2(fields.items[index],MEMORY_CODEC_PROJECTION_PATHS[index]))}
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
