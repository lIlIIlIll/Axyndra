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
    generation:UInt64,contribution:String,implementation:String,schemaDigest:String,call:ToolResolverInput):Bool{
    try{
        if(!call.textEquals(ToolResolverText.Name,"plugin."+namespace+"."+contribution) || host.instanceGeneration(namespace)!=generation){return true}
        let packageDescriptor=match(host.servicePackageData81(namespace,generation)){
            case Result.Err(_)=>return true;case Result.Ok(value)=>value}
        if(packageDescriptor.contentDigest!=packageDigest || !packageDescriptor.requestedCapabilities.contains("document.store")){return true}
        let configuration=match(host.documentConfiguration(namespace,packageDigest)){
            case Result.Err(_)=>return true;case Result.Ok(value)=>value}
        if(!configuration.effectFromIntents(contribution) || configuration.validateCurrent().isError()){return true}
        let keys = match (resolverDocumentReadKeys(call, namespace, packageDigest, generation,
            configuration.digest, implementation, schemaDigest)) { case None => return true; case Some(value) => value }
        for (key in keys where !configuration.permits(contribution, key, false)) { return true }
        false
    }catch(_:Exception){true}
}
