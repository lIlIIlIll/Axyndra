package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// An actual Host registration: the catalog receives the original executor
// object, preserving its OwnedToolEffectExecutor interface. No lambda wraps
// it and no Native result can manufacture this interface.
public func hostRegisterPluginLiveEffect(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    catalog:ToolCatalog,executor:ToolExecutor):Result<Unit>{
    match(executor as OwnedToolEffectExecutor){case None=>
        return hostPluginResourceError("plugin.live_effect_executor_invalid","live effect requires its actual typed Host executor")
        case Some(_)=>()}
    catalog.register(hostPluginLiveEffectDescriptor(host,operations),executor)
}

public func hostPluginLiveEffectDescriptor(host:HostJavaScriptPluginHost,operations:OperationRuntimePort):ToolDescriptor{
    ToolDescriptor(ModelToolDefinition(HOST_PLUGIN_LIVE_EFFECT_TOOL,"Execute one precisely prepared operator-selected effect",
        objectValue([ValueField("type",textValue("object"))])),
        Capability(CapabilityKind.ExtensionInvoke),sideEffecting:true,hostServiceOnly:true,neverReplay:true,
        implementationVersion:HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT,implementationFingerprint:HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT,
        canonicalArgumentsResolver:Some({context,call=>hostPreparePluginLiveEffect(host,operations,context,call)}),
        capabilityResolver:Some({call=>
            // The canonicalizer has independently revalidated the physical
            // path and current profile. This exact requirement is evaluated
            // by the original policy engine; it is not a permission grant.
            if(!pluginLivePolicyStreamingChildValueValid(call.arguments)){
                throw IllegalArgumentException("strict live child arguments required")}
            let effect=call.arguments.field("effect").getOrThrow()
            if(httpIntentText(effect,"kind")=="row_journal.append"){
                Capability(CapabilityKind.ExtensionInvoke,resource:httpIntentText(call.arguments.field("binding").getOrThrow(),"namespace"))
            }else{Capability(CapabilityKind.WorkspaceWrite,resource:httpIntentText(effect,"canonical_path"))}}),
        networkPolicyResolver:Some({_=>Result<NetworkPolicy>.Ok(NetworkPolicy(NetworkPolicyMode.Denied))}))
}
