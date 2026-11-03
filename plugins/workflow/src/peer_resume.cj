package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import yjson.*
import yjson_support.*

// Pure continuation planning consumes a completed ContextRead fact. It does
// not choose a Root, start a Run, or manufacture a completed delivery Receipt.
// The generic Host must still freeze this data in the original parent plan.
func workflowPeerResumeProposal111(input:AgentValue):AgentValue {
    workflowFields(input,["schema","request","fact","input"])
    if(workflowText(input,"schema")!="axyndra.peer-resume-preparation/v1") {
        throw PureProviderError("workflow.peer_resume_query_invalid","unknown resume preparation") }
    let request=input.field("request").getOrThrow()
    let fact=input.field("fact").getOrThrow()
    let business=input.field("input").getOrThrow()
    if(!pluginPeerReadInputMatches111(business,request) || !pluginPeerReadResultValid111(fact,request)) {
        throw PureProviderError("workflow.peer_resume_fact_invalid","resume needs its exact observed member and message") }
    let observed=fact.field("observation").getOrThrow()
    let target=observed.field("target").getOrThrow()
    let identity=observed.field("message").getOrThrow()
    let route=match(workflowHubRoute111(ToolCall("resume-data","hub",business))) {
        case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value }
    let sending=route.field("arguments").getOrThrow()
    if(workflowText(route,"service")!="peer.send" ||
        workflowText(sending,"target")!=workflowText(request,"recipient")) {
        throw PureProviderError("workflow.peer_resume_input_changed","original business input names another observed member") }
    let message=objectValue([ValueField("id",identity.field("id").getOrThrow()),
        ValueField("body",sending.field("body").getOrThrow()),ValueField("reply_to",sending.field("reply_to").getOrThrow()),
        ValueField("created_at",identity.field("created_at").getOrThrow())])
    if(workflowText(observed,"sender")==workflowText(target,"id") ||
        !["completed","failed","cancelled"].contains(workflowText(target,"status"))) {
        throw PureProviderError("workflow.peer_resume_target_invalid","only a settled different member can resume") }
    let definition=target.field("definition").getOrThrow()
    workflowFields(definition,["request","completion"])
    let completion=definition.field("completion").getOrThrow()
    workflowFields(completion,["provider","input","input_sha256"])
    let recipe=completion.field("input").getOrThrow()
    workflowFields(recipe,["schema","arguments","batch"])
    if(workflowText(completion,"provider")!="prepare_child" ||
        workflowText(completion,"input_sha256")!=modelPolicySha256Text(canonicalAgentValue(recipe)) ||
        workflowText(recipe,"schema")!="axyndra.workflow-child-completion/v1" ||
        recipe.field("batch").getOrThrow().unifiedKind!=ValueKind.Boolean) {
        throw PureProviderError("workflow.peer_resume_definition_invalid","prior role description is not the original frozen recipe") }
    let spec=match(parseWorkflowTask(ToolCall("resume-data","task",recipe.field("arguments").getOrThrow()))) {
        case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value }
    // Names are presentation, not role authority: a custom Task name still
    // selects its original exact role before the Host intersects ceilings.
    let role=workflowRoleValue(spec.agent)
    let builder=PromptBuilder()
    builder.add(PromptSection(PromptSectionKind.Base,PromptTrust.System,PromptStability.Stable,
        workflowText(role,"source"),workflowText(role,"version"),workflowText(role,"prompt")))
    let system=builder.build()
    let prompt="<hub-message from=\""+workflowText(observed,"sender")+"\" id=\""+
        workflowText(message,"id")+"\">"+workflowText(message,"body")+"</hub-message>"
    // Model/thinking are deliberately absent: the original revival uses the
    // actual current Root defaults. Native cannot reset those live settings.
    objectValue([ValueField("schema",textValue("axyndra.peer-resume-proposal/v1")),
        ValueField("fact_sha256",textValue(modelPolicySha256Text(canonicalAgentValue(fact)))),
        ValueField("target",target),ValueField("message",message),
        ValueField("request",objectValue([ValueField("prompt",textValue(prompt)),
            ValueField("system_prompt",textValue(system.text)),ValueField("cache_key",textValue(system.stablePrefixHash)),
            ValueField("capability_ceiling",role.field("capability_ceiling").getOrThrow()),
            ValueField("requested_limits",role.field("requested_limits").getOrThrow())])),
        ValueField("completion",completion)])
}

// Pure selection only. The Host supplies original input from its paid private
// file; this result requests an ordinary member ContextRead, never a Source.
func workflowPeerPreparationRead111(input:AgentValue):AgentValue {
    workflowFields(input,["schema","tool","input"])
    if(workflowText(input,"schema")!="axyndra.primitive-read-query/v1") {
        throw PureProviderError("workflow.peer_read_query_invalid","unknown member preparation query") }
    if(workflowText(input,"tool")!="hub"){return objectValue([ValueField("peer_read",nullValue())])}
    let route=match(workflowHubRoute111(ToolCall("read-data","hub",input.field("input").getOrThrow()))) {
        case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value }
    if(httpIntentText(route,"service")!="peer.send"){return objectValue([ValueField("peer_read",nullValue())])}
    let target=workflowText(route.field("arguments").getOrThrow(),"target")
    if(target=="Main" || target=="all"){return objectValue([ValueField("peer_read",nullValue())])}
    objectValue([ValueField("peer_read",objectValue([ValueField("recipient",textValue(target))]))])
}

// The Host supplies actual Task metadata, not a policy Boolean. Returning
// null preserves ordinary running/approval-wait delivery without adding a
// canonical read. A terminal choice only requests more verification.
func workflowPeerReadSelection111(input:AgentValue):AgentValue {
    workflowFields(input,["schema","selector","snapshot"])
    if(workflowText(input,"schema")!="axyndra.peer-read-selection/v1") {
        throw PureProviderError("workflow.peer_read_selection_invalid","unknown member selection") }
    let selector=input.field("selector").getOrThrow();workflowFields(selector,["recipient"])
    let snapshot=input.field("snapshot").getOrThrow()
    if(!pluginPeerMemberSnapshotValid111(snapshot) ||
        workflowText(snapshot,"id")!=workflowText(selector,"recipient")) {
        throw PureProviderError("workflow.peer_read_snapshot_invalid","member snapshot differs from the original selector") }
    let status=workflowText(snapshot,"status")
    if(status=="running" || status=="blocked") {return objectValue([ValueField("peer_read",nullValue())])}
    if(!["completed","failed","cancelled"].contains(status) ||
        snapshot.field("execution_in_progress").getOrThrow().asBool() ||
        snapshot.field("launch_in_progress").getOrThrow().asBool() || snapshot.field("finishing").getOrThrow().asBool() ||
        snapshot.field("budget_held").getOrThrow().asBool() || !snapshot.field("completion_done").getOrThrow().asBool()) {
        throw PureProviderError("workflow.peer_member_unsettled","member still has unsettled execution, completion or budget") }
    objectValue([ValueField("peer_read",selector)])
}

func workflowPeerMemberPrepare111(input:AgentValue):AgentValue {
    workflowFields(input,["schema","input","snapshot"])
    if(workflowText(input,"schema")!="axyndra.peer-member-preparation/v1") {
        throw PureProviderError("workflow.peer_member_query_invalid","unknown member preparation") }
    let route=match(workflowHubRoute111(ToolCall("member-data","hub",input.field("input").getOrThrow()))) {
        case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value }
    let snapshot=input.field("snapshot").getOrThrow()
    if(workflowText(route,"service")!="peer.send" || !pluginPeerMemberSnapshotValid111(snapshot) ||
        workflowText(route.field("arguments").getOrThrow(),"target")!=workflowText(snapshot,"id") ||
        (workflowText(snapshot,"status")!="running" && workflowText(snapshot,"status")!="blocked")) {
        throw PureProviderError("workflow.peer_read_required","member changed or requires its completed canonical read") }
    let intents=workflowPeerSendIntent111(route)
    intents.items[0].field("input").getOrThrow().put("member_snapshot",snapshot)
    objectValue([ValueField("intents",intents)])
}

func workflowPeerResumeIntents111(query:AgentValue):AgentValue {
    let proposal=workflowPeerResumeProposal111(query)
    let route=match(workflowHubRoute111(ToolCall("resume-data","hub",query.field("input").getOrThrow()))) {
        case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value }
    let intents=workflowPeerSendIntent111(route)
    intents.items[0].field("input").getOrThrow().put("resume",objectValue([
        ValueField("read_request",query.field("request").getOrThrow()),ValueField("read_fact",query.field("fact").getOrThrow()),
        ValueField("proposal",proposal)]))
    objectValue([ValueField("intents",intents)])
}
