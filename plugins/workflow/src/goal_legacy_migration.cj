package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import yjson.*
import yjson_support.*

// Explicit cold-format migration only. The proposal is consumed by the same
// actual document ContextRead/Root/CAS path as other Native document tools.
// Legacy metadata is neither an active fact store nor continuation authority.
func workflowGoalLegacyMigration(input: AgentValue, currentDocument: String): AgentValue {
    workflowFields(input,["op","legacy_document","legacy_sha256",CONTEXT_READ_INPUT_FIELD])
    if(workflowText(input,"op")!="migrate_legacy" || currentDocument!="null"){
        throw PureProviderError("workflow.goal_migration_conflict","Goal migration requires an empty canonical goal document")}
    let encoded=workflowText(input,"legacy_document")
    let digest=workflowText(input,"legacy_sha256")
    if(encoded=="" || encoded.size>8388608 || !httpIntentDigest(digest) || modelPolicySha256Text(encoded)!=digest){
        throw PureProviderError("workflow.goal_legacy_invalid","Legacy goal bytes or digest are unsupported; the original data remains unchanged")}
    let legacy=parseUnifiedJson(encoded,maxBytes:8388608,maxDepth:32)
    if(!httpIntentExactFields(legacy,["id","objective","status","tokenBudget","tokensUsed","timeUsedSeconds",
        "createdAt","updatedAt","enabled","baselineTokens","accountedAt"])){
        throw PureProviderError("workflow.goal_legacy_version","Unsupported legacy goal format; the original data remains unchanged")}
    for(name in ["id","objective","status"]){
        if(legacy.field(name).getOrThrow().unifiedKind!=ValueKind.Text){
            throw PureProviderError("workflow.goal_legacy_version","Unsupported legacy goal text field")}}
    for(name in ["tokensUsed","timeUsedSeconds","createdAt","updatedAt","baselineTokens","accountedAt"]){
        let amount=workflowNonnegative(legacy,name)
        if(amount.toString()!=legacy.field(name).getOrThrow().asNumberText()){
            throw PureProviderError("workflow.goal_legacy_version","Unsupported legacy goal integer field")}}
    let budget=legacy.field("tokenBudget").getOrThrow()
    if(budget.unifiedKind!=ValueKind.Null){
        let amount=workflowNonnegative(legacy,"tokenBudget")
        if(amount<=0 || amount.toString()!=budget.asNumberText()){
            throw PureProviderError("workflow.goal_legacy_version","Unsupported legacy goal budget field")}}
    if(legacy.field("enabled").getOrThrow().unifiedKind!=ValueKind.Boolean){
        throw PureProviderError("workflow.goal_legacy_version","Unsupported legacy goal boolean field")}
    let goal=match(decodeGoalState(legacy)){
        case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value}
    let document=encodeGoalState(goal)
    if(canonicalAgentValue(document)!=canonicalAgentValue(legacy)){
        throw PureProviderError("workflow.goal_legacy_version","Unsupported legacy goal representation")}
    // No user_control is returned. An enabled display value cannot create or
    // restore the actual Host user-continuation owner or its next Run admission.
    objectValue([ValueField("changed",boolValue(true)),ValueField("document",document),
        ValueField("is_error",boolValue(false)),
        ValueField("output",textValue("Legacy goal imported. Use /goal resume to approve continuation."))])
}
