package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

public let HOST_MANAGED_CHANNEL_OWNED_VERSION = "managed-channel-owned-v1"
public let HOST_MANAGED_CHANNEL_WRITE_TOOL = "host.process.channel.owned.write"
public let HOST_MANAGED_CHANNEL_SPAWN_TOOL = "host.process.channel.owned.spawn"
public let HOST_MANAGED_CHANNEL_CLOSE_TOOL = "host.process.channel.owned.close"
public let HOST_MANAGED_CHANNEL_EFFECT_FINGERPRINT = "host-managed-channel-owned-v1"

// These are descriptive complete plans, never lease, Source or approval
// factories. The registered typed Host executor selects its actual owner;
// Store separately proves Source, ordinary decision and durable handoff.
public func validateManagedChannelRuntimeBinding(binding:AgentValue):Result<Unit>{
    try{
        let common=["plugin","package_digest","configuration_digest","instance_identity","endpoint_identity",
            "directory_revision","directory_digest","implementation_version","implementation_fingerprint","schema_digest",
            "target_thread_id","permission_domain","workspace_root","workspace_mode","network","launch_digest",
            "lane_id","run_id","epoch","resource_state"]
        let active=httpIntentText(binding,"resource_state")=="active"
        let fields=ArrayList<String>(common)
        if(active){fields.add("lease_id");fields.add("startup_operation_id")}
        if(!httpIntentExactFields(binding,fields.toArray()) ||
            (!active && httpIntentText(binding,"resource_state")!="planned") ||
            !httpServicePluginNamespace(httpIntentText(binding,"plugin")) ||
            !httpServicePackageDigest(httpIntentText(binding,"package_digest"))){
            return managedChannelPlanError("managed_channel.binding_invalid")}
        for(key in ["configuration_digest","endpoint_identity","directory_digest","schema_digest","permission_domain","launch_digest"]){
            if(!httpIntentDigest(httpIntentText(binding,key))){return managedChannelPlanError("managed_channel.binding_digest")}}
        for(key in ["instance_identity","implementation_version","target_thread_id","lane_id","run_id"]){
            if(!channelIntentIdentifier(httpIntentText(binding,key))){return managedChannelPlanError("managed_channel.binding_identity")}}
        if(active && (!channelIntentIdentifier(httpIntentText(binding,"lease_id")) ||
            !channelIntentIdentifier(httpIntentText(binding,"startup_operation_id")))){
            return managedChannelPlanError("managed_channel.resource_identity")}
        let fingerprint=httpIntentText(binding,"implementation_fingerprint")
        if(!fingerprint.startsWith("owned-v1:") || !httpIntentDigest(fingerprint[9..])){
            return managedChannelPlanError("managed_channel.catalog_identity")}
        for(key in ["directory_revision","epoch"]){
            let value=binding.field(key).getOrThrow();let number=Int64.parse(value.asNumberText())
            if(value.unifiedKind!=ValueKind.Number || number.toString()!=value.asNumberText() ||
                number<(if(key=="directory_revision"){1}else{0})){return managedChannelPlanError("managed_channel.binding_ordinal")}}
        let workspace=httpIntentText(binding,"workspace_root")
        if(workspace.size<1 || workspace.size>4096 || workspace.contains("\u{0}") ||
            !["isolated_readonly","workspace_readonly","workspace_readwrite"].contains(httpIntentText(binding,"workspace_mode"))){
            return managedChannelPlanError("managed_channel.workspace")}
        match(parseNetworkPolicy(binding.field("network").getOrThrow())){
            case Result.Err(error)=>return Result.Err(error)
            case Result.Ok(value)=>if(!value.publish.isEmpty()){return managedChannelPlanError("managed_channel.network")}}
        Result.Ok(())
    }catch(_:Exception){managedChannelPlanError("managed_channel.binding_invalid")}
}

public func managedChannelRuntimeRequiredCapabilities(binding:AgentValue):Result<Array<Capability>>{
    match(validateManagedChannelRuntimeBinding(binding)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    // Preserve the actual Host lifecycle convention: both resources are empty.
    // Launch/configuration/resource equality is independently checked, and
    // cannot be substituted for ordinary ProcessSpawn/ExtensionInvoke policy.
    let values=ArrayList<Capability>([Capability(CapabilityKind.ProcessSpawn),Capability(CapabilityKind.ExtensionInvoke)])
    let root=httpIntentText(binding,"workspace_root");let mode=httpIntentText(binding,"workspace_mode")
    if(mode=="workspace_readonly" || mode=="workspace_readwrite"){values.add(Capability(CapabilityKind.WorkspaceRead,resource:root))}
    if(mode=="workspace_readwrite"){values.add(Capability(CapabilityKind.WorkspaceWrite,resource:root))}
    let network=match(parseNetworkPolicy(binding.field("network").getOrThrow())){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    for(resource in networkPolicyCapabilityResources(network)){values.add(Capability(CapabilityKind.NetworkAccess,resource:resource))}
    Result.Ok(values.toArray())
}

public func managedChannelRuntimeChildValueValid(value:AgentValue):Bool{
    try{
        if(!httpIntentExactFields(value,["binding","sequence","request_key","operation"]) ||
            validateManagedChannelRuntimeBinding(value.field("binding").getOrThrow()).isError()){return false}
        let ordinal=value.field("sequence").getOrThrow();let sequence=Int64.parse(ordinal.asNumberText())
        if(ordinal.unifiedKind!=ValueKind.Number || sequence<1 || sequence.toString()!=ordinal.asNumberText() ||
            !channelIntentIdentifier(httpIntentText(value,"request_key"))){return false}
        let binding=value.field("binding").getOrThrow();let operation=value.field("operation").getOrThrow()
        let kind=httpIntentText(operation,"kind")
        if(kind=="write"){
            if(!httpIntentExactFields(operation,["kind","lease_id","id","bytes_hex"]) ||
                httpIntentText(binding,"resource_state")!="active" ||
                httpIntentText(operation,"lease_id")!=httpIntentText(binding,"lease_id") ||
                !channelIntentIdentifier(httpIntentText(operation,"id"))){return false}
            let encoded=httpIntentText(operation,"bytes_hex")
            if(encoded.size<2 || encoded.size%2!=0){return false}
            for(byte in encoded.toArray()){
                if(!((byte>=b'0' && byte<=b'9') || (byte>=b'a' && byte<=b'f'))){return false}}
            return true
        }
        if(kind=="close"){
            return httpIntentExactFields(operation,["kind","lease_id"]) &&
                httpIntentText(binding,"resource_state")=="active" &&
                httpIntentText(operation,"lease_id")==httpIntentText(binding,"lease_id")}
        let configured=operation.field("configured_process")
        let spawnFields=ArrayList<String>(["kind","role","executable","args","cwd","environment","workspace_mode","network"])
        if(configured.isSome()){
            if(httpIntentText(operation,"role")!="adapter" || configured.getOrThrow().unifiedKind!=ValueKind.Text ||
                !channelIntentIdentifier(configured.getOrThrow().text) || configured.getOrThrow().text.size>128){return false}
            spawnFields.add("configured_process")}
        if(kind!="spawn" || !httpIntentExactFields(operation,spawnFields.toArray()) ||
            !["adapter","auxiliary"].contains(httpIntentText(operation,"role"))){return false}
        for(key in ["executable","cwd"]){let text=httpIntentText(operation,key);if(text=="" || text.contains("\u{0}")){return false}}
        let args=operation.field("args").getOrThrow();let environment=operation.field("environment").getOrThrow()
        if(args.unifiedKind!=ValueKind.List || environment.unifiedKind!=ValueKind.Object ||
            httpIntentText(operation,"workspace_mode")!=httpIntentText(binding,"workspace_mode")){return false}
        for(arg in args.items){if(arg.unifiedKind!=ValueKind.Text || arg.text.contains("\u{0}")){return false}}
        let object=environment.asObject()
        for(index in 0..object.size()){
            if(object.nameAt(index)=="" || object.nameAt(index).contains("\u{0}") || object.nameAt(index).contains("=") ||
                object.valueAt(index).unifiedKind!=ValueKind.Text || object.valueAt(index).text.contains("\u{0}")){return false}}
        let proposed=match(parseNetworkPolicy(operation.field("network").getOrThrow())){case Result.Err(_)=>return false;case Result.Ok(network)=>network}
        let actual=match(parseNetworkPolicy(binding.field("network").getOrThrow())){case Result.Err(_)=>return false;case Result.Ok(network)=>network}
        networkPoliciesEqual(proposed,actual)
    }catch(_:Exception){false}
}

func managedChannelPlanNever(plan:NormalizedOperationPlan):Bool{
    plan.effectClass==OperationEffectClass.ExternalMutation && plan.retryDisposition==OperationRetryDisposition.Never &&
        plan.idempotencyKey=="" &&
        match(plan.replayDisposition){case ReplayDisposition.NeverReplay=>true;case _=>false}
}
func managedChannelPlanCapabilities(plan:NormalizedOperationPlan,binding:AgentValue):Bool{
    let expected=match(managedChannelRuntimeRequiredCapabilities(binding)){case Result.Err(_)=>return false;case Result.Ok(value)=>value}
    if(expected.size!=plan.requiredCapabilities.size){return false}
    for(index in 0..expected.size){if(expected[index].kind!=plan.requiredCapabilities[index].kind ||
        expected[index].resource!=plan.requiredCapabilities[index].resource){return false}}
    let network=match(parseNetworkPolicy(binding.field("network").getOrThrow())){case Result.Err(_)=>return false;case Result.Ok(value)=>value}
    networkPoliciesEqual(plan.networkPolicy,network)
}
public func isManagedChannelOwnedParentPlan(plan:NormalizedOperationPlan):Bool{
    try{
        if(!managedChannelPlanNever(plan) || !httpIntentExactFields(plan.canonicalArguments,["input","configuration","host_plan"])){return false}
        let host=plan.canonicalArguments.field("host_plan").getOrThrow()
        if(!httpIntentExactFields(host,["version","binding"]) || httpIntentText(host,"version")!=HOST_MANAGED_CHANNEL_OWNED_VERSION){return false}
        let binding=host.field("binding").getOrThrow()
        !validateManagedChannelRuntimeBinding(binding).isError() &&
            plan.toolName.startsWith("plugin."+httpIntentText(binding,"plugin")+".") &&
            plan.implementation.toolVersion==httpIntentText(binding,"implementation_version") &&
            plan.implementation.implementationFingerprint==httpIntentText(binding,"implementation_fingerprint") &&
            plan.implementation.schemaDigest==httpIntentText(binding,"schema_digest") && managedChannelPlanCapabilities(plan,binding)
    }catch(_:Exception){false}
}
public func isManagedChannelOwnedChildPlan(plan:NormalizedOperationPlan):Bool{
    try{
        if(!managedChannelPlanNever(plan) || !plan.contextReadFacts.isEmpty() || !managedChannelRuntimeChildValueValid(plan.canonicalArguments) ||
            plan.implementation.implementationFingerprint!=HOST_MANAGED_CHANNEL_EFFECT_FINGERPRINT){return false}
        let kind=httpIntentText(plan.canonicalArguments.field("operation").getOrThrow(),"kind")
        let name=if(kind=="write"){HOST_MANAGED_CHANNEL_WRITE_TOOL}else if(kind=="spawn"){HOST_MANAGED_CHANNEL_SPAWN_TOOL}else{HOST_MANAGED_CHANNEL_CLOSE_TOOL}
        plan.toolName==name && managedChannelPlanCapabilities(plan,plan.canonicalArguments.field("binding").getOrThrow())
    }catch(_:Exception){false}
}
public func managedChannelOwnedChildAllowed(parent:NormalizedOperationPlan,child:NormalizedOperationPlan):Bool{
    try{
        if(!isManagedChannelOwnedParentPlan(parent) || !isManagedChannelOwnedChildPlan(child)){return false}
        let left=parent.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        let right=child.canonicalArguments.field("binding").getOrThrow()
        for(key in ["plugin","package_digest","configuration_digest","instance_identity","endpoint_identity","directory_revision",
            "directory_digest","implementation_version","implementation_fingerprint","schema_digest","target_thread_id","permission_domain",
            "workspace_root","workspace_mode","network","launch_digest","lane_id","run_id","epoch"]){
            if(canonicalAgentValue(left.field(key).getOrThrow())!=canonicalAgentValue(right.field(key).getOrThrow())){return false}}
        // Each resource, including an auxiliary process, needs its own actual
        // startup receipt/audit and Host inventory entry. The initial parent
        // lease never grants authority for a different physical child.
        true
    }catch(_:Exception){false}
}
public func managedChannelOwnedRequestKey(parentCall:String,child:NormalizedOperationPlan):String{
    if(!channelIntentIdentifier(parentCall) || !isManagedChannelOwnedChildPlan(child)){return ""}
    "managed-channel:"+parentCall+":"+child.canonicalArguments.field("sequence").getOrThrow().asNumberText()
}
func managedChannelPlanError<T>(code:String):Result<T>{
    Result.Err(AgentError(AgentErrorKind.PermissionDenied,code,"managed channel lost its complete current endpoint or precise operation plan"))
}
