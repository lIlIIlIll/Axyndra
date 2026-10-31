package agent_domain

import yjson.*
import yjson_support.*

// A distinct v2 shape view only. The original v1 validators, old frozen
// service dispatch and Source/admission paths remain byte-for-byte unchanged.
// This fixed-size view never embeds an ordinal-sized receipt array and is
// never passed to Store, authorization, admission or an effect executor.
func pluginLivePolicyStreamingShapeView(plan:NormalizedOperationPlan):NormalizedOperationPlan{
    let raw=plan.canonicalArguments
    let arguments=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_CHILD_SCHEMA)),
        ValueField("binding",raw.field("binding").getOrThrow()),ValueField("sequence",integerValue(1)),
        ValueField("effect",raw.field("effect").getOrThrow()),ValueField("proposal_payload",raw.field("proposal_payload").getOrThrow()),
        ValueField("read_facts",raw.field("read_facts").getOrThrow()),ValueField("prior_receipts",listValue([]))])
    NormalizedOperationPlan(plan.toolName,arguments,plan.requiredCapabilities,OperationEffectClass.ExternalMutation,plan.retryDisposition,plan.bindingDigest,
        resolvedPaths:plan.resolvedPaths,resolvedHosts:plan.resolvedHosts,networkPolicy:Some(plan.networkPolicy),cwd:plan.cwd,
        relevantEnvironment:plan.relevantEnvironment,approvalMetadata:Some(plan.approvalMetadata),idempotencyKey:plan.idempotencyKey,
        replayDisposition:Some(plan.replayDisposition),toolVersion:plan.implementation.toolVersion,
        implementationFingerprint:plan.implementation.implementationFingerprint,schemaDigest:plan.implementation.schemaDigest,
        effectiveArgumentsDigest:plan.implementation.effectiveArgumentsDigest,replayContractVersion:plan.implementation.replayContractVersion,
        contextReadFacts:plan.contextReadFacts)
}
public func isPluginLivePolicyStreamingChildPlan(plan:NormalizedOperationPlan):Bool{
    try{
        if(!pluginLivePolicyStreamingChildValueValid(plan.canonicalArguments)){return false}
        let kind=httpIntentText(plan.canonicalArguments.field("effect").getOrThrow(),"kind")
        let expected=if(kind=="row_journal.append"){OperationEffectClass.ExternalMutation}else{OperationEffectClass.WorkspaceMutation}
        // This matches the unchanged real ToolDescriptor normalizer. The v1
        // external-class view above is descriptive only and never executed.
        plan.effectClass==expected && isPluginLivePolicyChildPlan(pluginLivePolicyStreamingShapeView(plan))
    }catch(_:Exception){false}
}
public func pluginLivePolicyStreamingChildWithinCeiling(parent:NormalizedOperationPlan,child:NormalizedOperationPlan):Bool{
    try{isPluginLivePolicyParentPlan(parent) && isPluginLivePolicyStreamingChildPlan(child) &&
        pluginLivePolicyChildWithinCeiling(parent,pluginLivePolicyStreamingShapeView(child))}catch(_:Exception){false}
}
public func pluginLivePolicyStreamingRequestKey(parentCallId:String,child:NormalizedOperationPlan):String{
    if(!documentContractIdentifier(parentCallId) || !isPluginLivePolicyStreamingChildPlan(child)){return ""}
    "live-policy:"+parentCallId+":"+child.canonicalArguments.field("sequence").getOrThrow().asNumberText()
}
