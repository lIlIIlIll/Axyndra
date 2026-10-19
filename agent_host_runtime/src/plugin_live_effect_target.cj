package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// Mechanical target selection from the operator's frozen ceiling. This
// returns a path, never a capability, Source, approval or execution witness.
// It performs no mkdir/write/delete, including while resolving a missing
// target through its actually existing ancestor.
func hostPluginLiveFilesystemTarget(ceiling:AgentValue,effect:AgentValue):Result<String>{
    try{
        let kind=httpIntentText(effect,"kind")
        if(!pluginLivePolicyCeilingValid(ceiling) ||
            !["directory.create","file.atomic_write","directory.delete_tree"].contains(kind) ||
            !httpIntentExactFields(effect,["kind","root","relative_path","canonical_path"])){
            return hostPluginResourceError("plugin.live_target_invalid","strict frozen filesystem effect required")}
        let relative=httpIntentText(effect,"relative_path")
        if(relative=="" || relative.startsWith("/") || relative.contains("\\") || relative.contains(":") || relative.contains("\u{0000}")){
            return hostPluginResourceError("plugin.live_target_invalid","effect path must be a strict relative path")}
        for(part in relative.split("/")){if(part=="" || part=="." || part==".."){
            return hostPluginResourceError("plugin.live_target_invalid","effect path contains an unselected component")}}
        for(row in ceiling.field("filesystem").getOrThrow().items where
            httpIntentText(row,"root")==httpIntentText(effect,"root")){
            var permitted=false
            for(operation in row.field("operations").getOrThrow().items where operation.text==kind){permitted=true}
            if(!permitted){return hostPluginResourceError("plugin.live_target_denied","operator did not select this filesystem primitive")}
            let anchor=httpIntentText(row,"canonical_root")
            // The root must still be the exact selected physical root. A
            // changed symlink cannot redefine this ceiling at preparation.
            let actualAnchor=hostResolveThroughExistingAncestor(Path(anchor)).toString()
            if(actualAnchor!=anchor){return hostPluginResourceError("plugin.live_target_changed","selected filesystem root changed its physical identity")}
            let actual=hostResolveThroughExistingAncestor(Path(anchor).join(relative)).toString()
            if(actual==anchor || !hostPathComponentsContain(anchor,actual)){
                return hostPluginResourceError("plugin.live_target_escape","filesystem target resolves outside its selected root")}
            if(actual!=httpIntentText(effect,"canonical_path")){
                return hostPluginResourceError("plugin.live_target_changed","effect path differs from its current physical target")}
            return Result<String>.Ok(actual)
        }
        hostPluginResourceError("plugin.live_target_denied","operator did not select this filesystem root")
    }catch(_:Exception){hostPluginResourceError("plugin.live_target_invalid","filesystem target could not be resolved")}
}

// Resolving a proposal never executes it. The strict typed Pipeline still
// prepares an independent child, proves the original parent and full paid
// read/Receipt prefix, and independently asks current policy for approval.
func hostPreparePluginLiveEffect(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    context:ToolInvocationContext,call:ToolCall):Result<AgentValue>{
    try{
        if(call.name!=HOST_PLUGIN_LIVE_EFFECT_TOOL || !pluginLivePolicyStreamingChildValueValid(call.arguments) ||
            context.trustedControl || context.cancellation.isCancelled()){
            return hostPluginResourceError("plugin.live_effect_scope","strict live child proposal and current caller required")}
        let args=call.arguments;let binding=args.field("binding").getOrThrow()
        let namespace=httpIntentText(binding,"namespace");let digest=httpIntentText(binding,"package_digest")
        let generation=UInt64.parse(httpIntentText(binding,"generation"))
        if(generation.toString()!=httpIntentText(binding,"generation") ||
            context.sessionId.value!=httpIntentText(binding,"thread_id") || context.runId.value!=httpIntentText(binding,"run_id") ||
            context.epoch.toString()!=binding.field("epoch").getOrThrow().asNumberText() ||
            call.callId!=httpIntentText(binding,"parent_call_id")+":live:"+args.field("sequence").getOrThrow().asNumberText()){
            return hostPluginResourceError("plugin.live_effect_scope","live child changed its original caller or exact call identity")}
        let configuration=match(host.livePolicyConfiguration(namespace,digest,httpIntentText(binding,"contribution"))){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(Some(value))=>value
            case Result.Ok(None)=>return hostPluginResourceError("plugin.live_effect_disabled","operator did not enable this exact live family")}
        if(configuration.read.digest!=httpIntentText(binding,"configuration_digest")){
            return hostPluginResourceError("plugin.live_effect_changed","child changed the actual frozen read configuration")}
        match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let lane=match(operations.pluginDocumentLane(ThreadId(context.sessionId.value),context.runId,context.epoch)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(lane.value!=httpIntentText(binding,"lane_id")){
            return hostPluginResourceError("plugin.live_effect_scope","live child belongs to another actual lane")}
        for(provider in [configuration.readProvider,configuration.policyProvider]){
            let actual=match(host.policyProviderBinding(namespace,provider)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(actual.generation!=generation || actual.digest!=digest || actual.contribution!=provider){
                return hostPluginResourceError("plugin.live_effect_owner_changed","actual typed policy provider changed")}}
        let packageDescriptor=match(host.servicePackageData81(namespace,generation)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(packageDescriptor.contentDigest!=digest || !packageDescriptor.requestedCapabilities.contains("document.store")){
            return hostPluginResourceError("plugin.live_effect_owner_changed","actual package no longer owns its selected journal contribution")}
        let effect=args.field("effect").getOrThrow();let kind=httpIntentText(effect,"kind")
        if(kind=="row_journal.append"){
            var selected=false
            for(row in configuration.ceiling().field("documents").getOrThrow().items where
                httpIntentText(row,"key")==httpIntentText(effect,"key")){
                for(operation in row.field("operations").getOrThrow().items where operation.text==kind){selected=true}}
            if(!selected || httpIntentText(effect,"key")!=configuration.key){
                return hostPluginResourceError("plugin.live_effect_denied","operator did not select this exact journal append")}
        }else{
            match(hostPluginLiveFilesystemTarget(configuration.ceiling(),effect)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
        match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(context.cancellation.isCancelled()){
            return hostPluginResourceError("plugin.live_effect_cancelled","live child preparation was cancelled")}
        // No decoded body or new mutable snapshot escapes a temporary charge.
        // These are the original caller-owned, fixed-reference arguments.
        Result<AgentValue>.Ok(args)
    }catch(_:Exception){hostPluginResourceError("plugin.live_effect_invalid","live child could not retain its exact operator selection")}
}
