package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import yjson.*
import yjson_support.*

// Explicitly opted-in generic effect classification runs after the normal
// canonicalizer froze every intent. Old configurations retain their original
// conservative descriptor and snapshot. A changed/invalid profile is always
// side-effecting; this callback does not approve or execute any action.
func hostDocumentIntentEffectEnabled(host:HostJavaScriptPluginHost,namespace:String,
    packageDigest:String,contribution:String):Bool{
    match(host.documentConfiguration(namespace,packageDigest)){
        case Result.Err(_)=>false;case Result.Ok(value)=>value.effectFromIntents(contribution)}
}
func hostPluginDocumentSideEffect(host:HostJavaScriptPluginHost,namespace:String,packageDigest:String,
    generation:UInt64,contribution:String,implementation:String,schemaDigest:String,call:ToolCall):Bool{
    try{
        if(call.name!="plugin."+namespace+"."+contribution || host.instanceGeneration(namespace)!=generation){return true}
        let packageDescriptor=match(host.servicePackageData81(namespace,generation)){
            case Result.Err(_)=>return true;case Result.Ok(value)=>value}
        if(packageDescriptor.contentDigest!=packageDigest || !packageDescriptor.requestedCapabilities.contains("document.store")){return true}
        let configuration=match(host.documentConfiguration(namespace,packageDigest)){
            case Result.Err(_)=>return true;case Result.Ok(value)=>value}
        if(!configuration.effectFromIntents(contribution) || configuration.validateCurrent().isError()){return true}
        let frozen=call.arguments.field("host_plan").getOrThrow()
        let intents=frozen.field("intents").getOrThrow()
        if(intents.unifiedKind!=ValueKind.List || intents.items.isEmpty() || intents.items.size>8){return true}
        let selected=match(pluginDocumentChildArguments(call.arguments,httpIntentText(intents.items[0],"id"))){
            case Result.Err(_)=>return true;case Result.Ok(value)=>value}
        let binding=selected.field("binding").getOrThrow()
        if(httpIntentText(binding,"namespace")!=namespace || httpIntentText(binding,"package_digest")!=packageDigest ||
            httpIntentText(binding,"generation")!=generation.toString() || httpIntentText(binding,"configuration_digest")!=configuration.digest ||
            httpIntentText(binding,"contribution")!=call.name || httpIntentText(binding,"implementation_fingerprint")!=implementation ||
            httpIntentText(binding,"schema_digest")!=schemaDigest){return true}
        for(intent in intents.items){
            if(httpIntentText(intent,"mode")!="read" || !configuration.permits(contribution,httpIntentText(intent,"key"),false)){return true}}
        false
    }catch(_:Exception){true}
}
