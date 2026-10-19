package tool_runtime

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Actual catalog executor selection, not a Native DTO flag. The same existing
// OwnedToolExecutionControl and continuation own every execute/resume/reject.
public interface ManagedChannelOwnedExecutor <: OwnedToolExecutor {}
public interface ManagedChannelOwnedEffectExecutor {
    func executeManagedChannelEffect(context:ToolInvocationContext,child:PreparedToolInvocation):ToolExecutionOutcome
}

func ownedRuntimeParentPlan(plan:NormalizedOperationPlan):Bool{
    isPluginLivePolicyParentPlan(plan) || isManagedChannelOwnedParentPlan(plan)
}
func ownedRuntimeChildPlan(plan:NormalizedOperationPlan):Bool{
    isPluginLivePolicyStreamingChildPlan(plan) || isManagedChannelOwnedChildPlan(plan)
}
func ownedRuntimeChildAllowed(parent:NormalizedOperationPlan,child:NormalizedOperationPlan):Bool{
    if(isManagedChannelOwnedParentPlan(parent)){managedChannelOwnedChildAllowed(parent,child)}
    else{pluginLivePolicyStreamingChildWithinCeiling(parent,child)}
}
func ownedRuntimeRequestKey(parentCall:String,child:NormalizedOperationPlan):String{
    if(isManagedChannelOwnedChildPlan(child)){managedChannelOwnedRequestKey(parentCall,child)}
    else{pluginLivePolicyStreamingRequestKey(parentCall,child)}
}
func ownedRuntimeChildCallId(parentCall:String,child:NormalizedOperationPlan):String{
    parentCall+(if(isManagedChannelOwnedChildPlan(child)){":managed:"}else{":live:"})+
        child.canonicalArguments.field("sequence").getOrThrow().asNumberText()
}
