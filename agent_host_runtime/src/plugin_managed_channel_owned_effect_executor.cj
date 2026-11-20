package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// This callback is installed only by the actual lifecycle/catalog factory.
// It lends that installation's real generation/publication fence; binding
// metadata used to select its resource never supplies execution authority.
type HostManagedChannelEffectHandoff = (ToolInvocationContext,PreparedToolInvocation)->Result<ToolExecutionHandoffLease>

// A failed dispatch has no output to acknowledge and cannot become Known.
// It does not counterfeit an allocation, resource, Source or cleanup ACK.
class HostManagedChannelMissingOutputOwner <: AcknowledgedOperationTerminalDataOwner {
    public func withRetainedOutput(_:ToolResultPayloadLease,
        _:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        managedChannelDriverError("managed_channel.child_output_missing")
    }
}

// Registered once per exact generic effect family by the real Host factory.
// Ordinary entry and the historical ID-only effect seam remain closed. Only
// the new Kernel opt-in can lend actual parent plus SAME original custody.
class HostManagedChannelRetainedEffectExecutor <: ToolExecutor & ManagedChannelOwnedEffectExecutor & RetainedOwnedToolEffectExecutor {
    private let tool:String
    private let handoff:HostManagedChannelEffectHandoff
    init(tool:String,handoff:HostManagedChannelEffectHandoff){
        if(![HOST_MANAGED_CHANNEL_WRITE_TOOL,HOST_MANAGED_CHANNEL_SPAWN_TOOL,HOST_MANAGED_CHANNEL_CLOSE_TOOL].contains(tool)){
            throw IllegalArgumentException("actual managed effect family is invalid")}
        this.tool=tool;this.handoff=handoff
    }
    func descriptor():ToolDescriptor{
        ToolDescriptor(ModelToolDefinition(tool,"Execute one exact approved operation for an existing managed channel invocation.",
            objectValue([ValueField("type",textValue("object"))])),
            Capability(CapabilityKind.ProcessSpawn),sideEffecting:true,hostServiceOnly:true,neverReplay:true,
            implementationVersion:HOST_MANAGED_CHANNEL_EFFECT_FINGERPRINT,
            implementationFingerprint:HOST_MANAGED_CHANNEL_EFFECT_FINGERPRINT,
            additionalCapabilityResolver:Some({ call =>
                if (call.kind([ToolResolverStep.Field("binding")]).isNone()) { return [] }
                match (resolverChannelCapabilities(call, managed: true)) {
                    case Result.Err(_) => []; case Result.Ok(required) => required[1..] }
            }),
            networkPolicyResolver:Some({ call =>
                if (call.kind([ToolResolverStep.Field("binding")]).isNone()) {
                    return managedChannelDriverError<NetworkPolicy>("managed_channel.child_binding_missing") }
                resolverNetworkPolicy(call, [ToolResolverStep.Field("binding"), ToolResolverStep.Field("network")])
            }),
            canonicalArgumentsResolver:Some({_,call=>
                if(!managedChannelRuntimeChildValueValid(call.arguments)){
                    return managedChannelDriverError<AgentValue>("managed_channel.child_plan_invalid")}
                let kind=httpIntentText(call.arguments.field("operation").getOrThrow(),"kind")
                let expected=if(kind=="write"){HOST_MANAGED_CHANNEL_WRITE_TOOL}
                    else if(kind=="spawn"){HOST_MANAGED_CHANNEL_SPAWN_TOOL}else{HOST_MANAGED_CHANNEL_CLOSE_TOOL}
                if(expected!=tool){return managedChannelDriverError<AgentValue>("managed_channel.child_family_changed")}
                Result.Ok(call.arguments)
            }))
    }
    public func acquireHandoffLease(context:ToolInvocationContext,child:PreparedToolInvocation):Result<ToolExecutionHandoffLease>{
        if(child.call.name!=tool || !isManagedChannelOwnedChildPlan(child.operationPlan)){
            return managedChannelDriverError("managed_channel.child_family_changed")}
        handoff(context,child)
    }
    public func execute(_:ToolInvocationContext,_:PreparedToolInvocation):Result<ToolResult>{
        managedChannelDriverError("managed_channel.retained_child_entry_required")
    }
    public func executeManagedChannelEffect(_:ToolInvocationContext,_:PreparedToolInvocation):ToolExecutionOutcome{
        ToolExecutionOutcome(managedChannelDriverError<ToolResult>("managed_channel.retained_child_entry_required"))
    }
    public func executeRetainedEffect(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,custody:LiveToolExecutionCustody):OwnedRetainedToolEffectOutcome{
        if(child.call.name!=tool || !isManagedChannelOwnedParentPlan(parent.operationPlan) ||
            !managedChannelOwnedChildAllowed(parent.operationPlan,child.operationPlan) || !hostManagedChannelSameRoot(parent,child)){
            return missing("managed_channel.actual_child_changed")}
        let session=match(custody as HostManagedChannelOwnedSession){case Some(value)=>value
            case None=>return missing("managed_channel.actual_custody_missing")}
        // Session checks original object identity and private physical lease.
        // IDs/DTOs never find a Root or substitute a current physical owner.
        session.executeRetainedEffect(context,parent,child)
    }
    private func missing(code:String):OwnedRetainedToolEffectOutcome{
        OwnedRetainedToolEffectOutcome(ToolExecutionOutcome(managedChannelDriverError<ToolResult>(code)),
            HostManagedChannelMissingOutputOwner())
    }
    public func cancel(_:RunId):Result<Unit>{Result.Ok(())}
}
