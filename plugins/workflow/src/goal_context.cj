package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

// Pure content only. The Host supplies its completed canonical document fact
// and observed usage; this worker owns no Source, repository or user control.
func workflowGoalContext(input: AgentValue): AgentValue {
    workflowFields(input,["schema",CONTEXT_READ_INPUT_FIELD,"_axyndra_context_provider"])
    if(workflowText(input,"schema")!="axyndra.goal-context-query/v1"){
        throw PureProviderError("workflow.context_query_invalid","unsupported goal content query")}
    let identity=input.field("_axyndra_context_provider").getOrThrow()
    workflowFields(identity,["namespace","package_digest","generation","provider"])
    let namespace=workflowText(identity,"namespace")
    // Accept the real tagged PluginPackageDescriptor identity the Host supplies
    // (sha256:<64hex>) as well as the existing raw SHA pure-data dialect, the
    // same convention the Memory context provider uses. This is a descriptive
    // input check only: actual package ownership is verified by Host/Store from
    // the frozen provider and the canonical fact, so no allowance is created.
    if(!httpServicePluginNamespace(namespace) ||
        !(httpIntentDigest(workflowText(identity,"package_digest")) ||
          httpServicePackageDigest(workflowText(identity,"package_digest"))) ||
        workflowText(identity,"provider")!="goal_context"){
        throw PureProviderError("workflow.context_identity_invalid","content requires the supplied current package description")}
    let generation=workflowText(identity,"generation")
    try { if(UInt64.parse(generation)<1 || UInt64.parse(generation).toString()!=generation){
        throw PureProviderError("workflow.context_identity_invalid","unsupported package generation")}
    } catch(_:Exception){throw PureProviderError("workflow.context_identity_invalid","unsupported package generation")}
    let snapshot=workflowDocumentSnapshot(input,"goal")
    workflowFields(snapshot,["key","revision","json","sha256"])
    let raw=workflowText(snapshot,"json")
    if(raw=="" || raw.size>8388608 || !httpIntentDigest(workflowText(snapshot,"sha256")) ||
        modelPolicySha256Text(raw)!=workflowText(snapshot,"sha256")){
        throw PureProviderError("workflow.document_fact_invalid","goal content bytes differ from their observation")}
    let revision=workflowNonnegative(snapshot,"revision")
    if(revision.toString()!=snapshot.field("revision").getOrThrow().asNumberText()){
        throw PureProviderError("workflow.document_fact_invalid","unsupported document revision")}
    let data=input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow().field("data").getOrThrow()
    let observation=data.field("observation").getOrThrow()
    workflowFields(observation,["schema","thread_id","run_id","observed_at_millis","input_tokens","output_tokens"])
    if(workflowText(observation,"schema")!="axyndra.document-observation/v1" ||
        workflowText(observation,"thread_id")=="" || workflowText(observation,"run_id")=="" ||
        !httpIntentDigest(workflowText(data,"request_digest"))){
        throw PureProviderError("workflow.goal_observation_invalid","canonical current usage observation required")}
    let now=workflowNonnegative(observation,"observed_at_millis")
    let inbound=workflowNonnegative(observation,"input_tokens");let outbound=workflowNonnegative(observation,"output_tokens")
    if(inbound>9223372036854775807-outbound){
        throw PureProviderError("workflow.goal_observation_invalid","usage cannot be represented")}
    let document=parseUnifiedJson(raw,maxBytes:8388608,maxDepth:32)
    if(document.unifiedKind!=ValueKind.Null){
        // Reuse the actual strict cold-format decoder solely to validate all
        // eleven original typed fields. Its proposal is discarded here.
        let _=workflowGoalLegacyMigration(objectValue([ValueField("op",textValue("migrate_legacy")),
            ValueField("legacy_document",textValue(raw)),ValueField("legacy_sha256",textValue(modelPolicySha256Text(raw))),
            ValueField(CONTEXT_READ_INPUT_FIELD,input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow())]),"null")
    }
    let policy=WorkflowGoalPolicy(document,now,inbound+outbound,"context-description")
    match(policy.finalizeRun(SessionId(workflowText(observation,"thread_id")))){
        case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(_)=>()}
    let prompt=match(policy.activePrompt(SessionId(workflowText(observation,"thread_id")))){
        case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value}
    // Actual publication name is descriptive content, never a call or grant.
    let content=prompt.replace("Call goal with op=complete","Call plugin."+namespace+".goal with op=complete")
    objectValue([ValueField("schema",textValue("axyndra.context-result/v1")),ValueField("contributions",
        if(content==""){listValue([])}else{listValue([objectValue([ValueField("id",textValue("goal")),
            ValueField("content",textValue(content)),ValueField("references",listValue([]))])])})])
}
