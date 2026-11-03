package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// The Native contribution owns Task parsing, role/prompt selection and the
// original four-wide batch schedule. The Host only consumes frozen primitives.
func workflowChildIntentAt111(arguments: AgentValue, index: Int64, background: Bool,
    admissionOnly: Bool): AgentValue {
    let batch = match (parseWorkflowTaskBatch(ToolCall("frozen-data", "task", arguments))) {
        case Result.Err(error) => throw PureProviderError(error.code,error.message);case Result.Ok(value) => value }
    let spec=batch.specs[index];let role=workflowRoleValue(spec.agent)
    let builder=PromptBuilder()
    builder.add(PromptSection(PromptSectionKind.Base,PromptTrust.System,PromptStability.Stable,
        workflowText(role,"source"),workflowText(role,"version"),workflowText(role,"prompt")))
    if(batch.context.trimAscii()!=""){builder.add(PromptSection(PromptSectionKind.DynamicContext,PromptTrust.External,
        PromptStability.Turn,"delegated-task-context","1",batch.context.trimAscii()))}
    let prompt=builder.build()
    let originalSpec=if(batch.batch){arguments.field("tasks").getOrThrow().items[index]}else{arguments}
    let recipe=objectValue([ValueField("schema",textValue("axyndra.workflow-child-completion/v1")),
        ValueField("arguments",originalSpec),ValueField("batch",boolValue(batch.batch))])
    objectValue([ValueField("id",textValue("task-"+(index+1).toString())),ValueField("service",textValue("child.start")),
        ValueField("input",objectValue([ValueField("request",objectValue([
            ValueField("label",textValue(spec.name)),ValueField("description",role.field("description").getOrThrow()),
            ValueField("prompt",textValue(spec.task)),ValueField("system_prompt",textValue(prompt.text)),
            ValueField("cache_key",textValue(prompt.stablePrefixHash)),ValueField("model_alias",role.field("model_alias").getOrThrow()),
            ValueField("thinking",textValue(if(spec.effort=="lo"){ "low" }else if(spec.effort=="hi"){ "high" }else{ "medium" })),
            ValueField("capability_ceiling",role.field("capability_ceiling").getOrThrow()),
            ValueField("requested_limits",role.field("requested_limits").getOrThrow()),ValueField("background",boolValue(background)),
            ValueField("admission_only",boolValue(admissionOnly))])),
            ValueField("completion",objectValue([ValueField("provider",textValue("prepare_child")),ValueField("input",recipe),
                ValueField("input_sha256",textValue(modelPolicySha256Text(canonicalAgentValue(recipe))))]))]))])
}
func workflowChildRouting111(arguments:AgentValue,options:AgentValue):AgentValue {
    workflowFields(options,["background_enabled"])
    if(options.field("background_enabled").getOrThrow().unifiedKind!=ValueKind.Boolean){
        throw PureProviderError("workflow.child_options_invalid","expected actual background configuration")}
    workflowTaskRouting111(objectValue([ValueField("schema",textValue("axyndra.workflow-policy/v1")),
        ValueField("action",textValue("task_route")),ValueField("source_digest",textValue(modelPolicySha256Text(canonicalAgentValue(arguments)))),
        ValueField("arguments",arguments),ValueField("async_enabled",options.field("background_enabled").getOrThrow())]))
}
func workflowChildIntents111(arguments:AgentValue,options:AgentValue):AgentValue {
    let batch=match(parseWorkflowTaskBatch(ToolCall("frozen-data","task",arguments))){
        case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value}
    let routing=workflowChildRouting111(arguments,options)
    let intents=ArrayList<AgentValue>()
    for(index in routing.field("background").getOrThrow().items){
        intents.add(workflowChildIntentAt111(arguments,Int64.parse(index.asNumberText()),true,true))}
    for(wave in routing.field("inline_waves").getOrThrow().items){
        for(index in wave.items){intents.add(workflowChildIntentAt111(arguments,Int64.parse(index.asNumberText()),false,batch.batch))}
        if(batch.batch){for(index in wave.items){
            let id="task-"+(Int64.parse(index.asNumberText())+1).toString()
            intents.add(objectValue([ValueField("id",textValue(id+"-wait")),ValueField("service",textValue("child.wait")),
                ValueField("input",objectValue([ValueField("start_intent_id",textValue(id))]))]))}}
    }
    listValue(intents.toArray())
}
func workflowChildPrepare111(name:String,arguments:AgentValue):AgentValue {
    workflowChildPrepare111(name,arguments,objectValue([ValueField("background_enabled",boolValue(true))]))
}
func workflowChildPrepare111(name:String,arguments:AgentValue,options:AgentValue):AgentValue {
    workflowFields(arguments,["input"])
    if(workflowHubContribution196(name)){
        workflowRequireHubFamily196(name,arguments.field("input").getOrThrow())
        if(name=="hub_process_read"){
            return objectValue([ValueField("intents",workflowHubProcessObservationIntents196(arguments.field("input").getOrThrow(),options))])}
        if(workflowHubProcessOperation180(arguments.field("input").getOrThrow())){
            return objectValue([ValueField("intents",workflowHubProcessIntents180(arguments.field("input").getOrThrow(),options))])}
        return workflowPeerPrepare111(arguments.field("input").getOrThrow())}
    if(name=="yield"){return workflowYieldPrepare150(arguments,options)}
    if(name!="task"){throw PureProviderError("workflow.child_tool_unknown","unknown primitive Tool")}
    let raw = arguments.field("input").getOrThrow()
    match (parseWorkflowTaskBatch(ToolCall("preparation-data", "task", raw))) {
        case Result.Err(error) => return objectValue([ValueField("completion", workflowTaskParameterCompletion152(error))])
        case Result.Ok(_) => ()
    }
    objectValue([ValueField("intents",workflowChildIntents111(raw,options))])
}
func workflowTaskParameterCompletion152(error: AgentError): AgentValue {
    objectValue([ValueField("output", objectValue([ValueField("results", listValue([])),
        ValueField("error", textValue(error.message))])), ValueField("is_error", boolValue(true))])
}
func workflowChildCompletion111(input: AgentValue): AgentValue {
    workflowFields(input,["schema","recipe","observation"])
    let recipe=input.field("recipe").getOrThrow()
    workflowFields(recipe,["schema","arguments","batch"])
    if(workflowText(recipe,"schema")!="axyndra.workflow-child-completion/v1"){
        throw PureProviderError("workflow.child_recipe_invalid","unknown frozen completion recipe")}
    let observation=input.field("observation").getOrThrow()
    if(observation.field("state").isSome()){
        workflowFields(observation,["run_id","thread_id","status","error","messages","result_state","state"])
    }else{workflowFields(observation,["run_id","thread_id","status","error","messages","result_state"])}
    var lastText=""
    let messages=observation.field("messages").getOrThrow()
    if(messages.unifiedKind!=ValueKind.List){throw PureProviderError("workflow.child_observation_invalid","messages must be data")}
    for(message in messages.items where httpIntentText(message,"role")=="assistant"){
        var text=""
        let blocks=message.field("content").getOrThrow()
        if(blocks.unifiedKind!=ValueKind.List){throw PureProviderError("workflow.child_observation_invalid","blocks must be data")}
        for(block in blocks.items where httpIntentText(block,"type")=="text"){text+=workflowText(block,"text")}
        if(text!=""){lastText=text}
    }
    // The pilot still observes the existing result store. Its Native writer
    // migration is a later primitive; preserve all actually accepted sections
    // and terminal values instead of pretending that store was empty.
    let observed=observation.field("result_state").getOrThrow()
    workflowFields(observed,["sections","terminal","has_terminal","error","use_last_turn"])
    let state=WorkflowYieldState111()
    for(section in observed.field("sections").getOrThrow().items){
        workflowFields(section,["labels","data"])
        let labels=ArrayList<String>()
        for(label in section.field("labels").getOrThrow().items){
            if(label.unifiedKind!=ValueKind.Text){throw PureProviderError("workflow.child_observation_invalid","invalid result labels")}
            labels.add(label.text)}
        state.sections.add(WorkflowYieldSection111(labels.toArray(),section.field("data").getOrThrow()))}
    if(observed.field("has_terminal").getOrThrow().asBool()){state.terminal=Some(observed.field("terminal").getOrThrow())}
    state.error=workflowText(observed,"error");state.useLastTurn=observed.field("use_last_turn").getOrThrow().asBool()
    let spec=match(parseWorkflowTask(ToolCall("policy-data","task",recipe.field("arguments").getOrThrow()))){
        case Result.Ok(value)=>value;case Result.Err(error)=>throw PureProviderError(error.code,error.message)}
    let output=workflowTaskOutputState111(objectValue([ValueField("source_digest",
        textValue(modelPolicySha256Text(canonicalAgentValue(recipe))))]),spec,state,lastText)
    let actualSuccess=workflowText(observation,"status")=="completed"
    let accepted=actualSuccess && httpIntentText(output,"application_status")=="completed"
    let completedOutput=if(observation.field("state").isSome()){
        workflowChildResultRow111(observation,output)
    }else{output}
    objectValue([ValueField("accepted",boolValue(accepted)),ValueField("output",completedOutput),
        ValueField("diagnostic",textValue(if(!actualSuccess){workflowText(observation,"error")}else{httpIntentText(output,"stderr")}))])
}
func workflowChildPolicy111(name: String, input: AgentValue): AgentValue {
    if(name!="prepare_child"){throw PureProviderError("workflow.child_provider_unknown","unknown primitive Provider")}
    if(httpIntentText(input,"schema")=="axyndra.primitive-read-query/v1"){return workflowPeerPreparationRead111(input)}
    if(httpIntentText(input,"schema")=="axyndra.peer-resume-intents/v1") {
        workflowFields(input,["schema","query"]);return workflowPeerResumeIntents111(input.field("query").getOrThrow()) }
    if(httpIntentText(input,"schema")=="axyndra.peer-member-preparation/v1"){return workflowPeerMemberPrepare111(input)}
    if(httpIntentText(input,"schema")=="axyndra.peer-read-selection/v1"){return workflowPeerReadSelection111(input)}
    if(httpIntentText(input,"schema")=="axyndra.peer-resume-preparation/v1"){return workflowPeerResumeProposal111(input)}
    if(httpIntentText(input,"schema")=="axyndra.child-completion-query/v1"){return workflowChildCompletion111(input)}
    if(httpIntentText(input,"schema")=="axyndra.child-projection-query/v1"){return workflowChildProjection151(input)}
    if(httpIntentText(input,"schema")=="axyndra.frozen-message-query/v1"){return workflowPeerDelivery111(input)}
    if(input.field("options").isSome()){workflowFields(input,["schema","tool","input","options"])}
    else{workflowFields(input,["schema","tool","input"])}
    if(workflowText(input,"schema")!="axyndra.primitive-preparation-query/v1"){
        throw PureProviderError("workflow.child_query_invalid","expected frozen primitive preparation data")}
    workflowChildPrepare111(workflowText(input,"tool"),objectValue([ValueField("input",input.field("input").getOrThrow())]),
        input.field("options")??objectValue([ValueField("background_enabled",boolValue(true))]))
}
func workflowChildResultRow111(observation:AgentValue,business:AgentValue):AgentValue {
    let state=observation.field("state").getOrThrow()
    let status=workflowText(observation,"status")
    let completed=status=="completed"
    let output=if(completed){business.field("output").getOrThrow()}else{textValue("")}
    let code=if(completed){business.field("exitCode").getOrThrow()}else{integerValue(1)}
    let diagnostic=if(completed){httpIntentText(business,"stderr")}
        else if(status=="blocked"){"subagent is awaiting approval"}
        else if(status=="cancelled"){"subagent was cancelled"}else{workflowText(observation,"error")}
    let fields=ArrayList<ValueField>([
        ValueField("index",state.field("index").getOrThrow()),ValueField("id",textValue(workflowText(state,"id"))),
        ValueField("agent",state.field("label").getOrThrow()),ValueField("agentSource",state.field("source").getOrThrow()),
        ValueField("task",state.field("prompt").getOrThrow()),ValueField("assignment",state.field("assignment").getOrThrow()),
        ValueField("exitCode",code),ValueField("output",textValue(if(output.unifiedKind==ValueKind.Text){output.text}else{encodeAgentValue(output)})),
        ValueField("stderr",textValue(diagnostic)),ValueField("truncated",boolValue(false)),
        ValueField("tokens",state.field("tokens").getOrThrow()),ValueField("requests",state.field("requests").getOrThrow()),
        ValueField("sessionRef",state.field("reference").getOrThrow()),ValueField("runId",observation.field("run_id").getOrThrow()),
        ValueField("status",textValue(if(completed && httpIntentText(business,"application_status")=="failed"){"failed"}else{status}))])
    if(completed && httpIntentText(business,"schema_status")!="unavailable"){
        fields.add(ValueField("structuredOutput",objectValue([ValueField("source",textValue("caller")),
            ValueField("mode",business.field("schema_mode").getOrThrow()),ValueField("status",business.field("schema_status").getOrThrow()),
            ValueField("data",output),ValueField("error",business.field("schema_error").getOrThrow())])))}
    objectValue(fields.toArray())
}
func workflowChildObservedRow111(output:AgentValue):AgentValue {
    match(output.field("completion")){case Some(value)=>if(value.unifiedKind!=ValueKind.Null){return value};case None=>()}
    workflowChildResultRow111(objectValue([ValueField("run_id",output.field("run_id").getOrThrow()),
        ValueField("status",output.field("status").getOrThrow()),ValueField("error",output.field("state").getOrThrow().field("error").getOrThrow()),
        ValueField("state",output.field("state").getOrThrow())]),objectValue([]))
}
func workflowChildProgress111(output:AgentValue):AgentValue {
    let state=output.field("state").getOrThrow()
    let fields=ArrayList<ValueField>([ValueField("id",output.field("child_id").getOrThrow()),
        ValueField("agentId",output.field("child_id").getOrThrow()),ValueField("type",textValue("task")),
        ValueField("status",output.field("status").getOrThrow()),ValueField("label",state.field("prompt").getOrThrow()),
        ValueField("durationMs",state.field("duration_millis").getOrThrow())])
    let completion=output.field("completion").getOrThrow()
    if(completion.unifiedKind!=ValueKind.Null){fields.add(ValueField("result",completion))}
    if(httpIntentText(state,"error")!=""){fields.add(ValueField("error",state.field("error").getOrThrow()))}
    objectValue(fields.toArray())
}
func workflowChildExecute111(name:String,arguments:AgentValue,broker:FrozenPrimitiveBroker111):DocumentPolicyToolResult {
    workflowFields(arguments,["input","configuration","host_plan"])
    if(workflowHubContribution196(name)){
        workflowRequireHubFamily196(name,arguments.field("input").getOrThrow())
        if(name=="hub_process_read"){return workflowExecuteHubProcessObservation196(arguments,broker)}
        if(workflowHubProcessOperation180(arguments.field("input").getOrThrow())){return workflowExecuteHubProcess180(arguments,broker)}
        return workflowPeerExecute111(arguments,broker)}
    if(name=="yield"){return workflowYieldExecute150(arguments,broker)}
    if(name!="task"){throw PureProviderError("workflow.child_tool_unknown","unknown primitive Tool")}
    let raw=arguments.field("input").getOrThrow();let options=arguments.field("configuration").getOrThrow()
    let batch=match(parseWorkflowTaskBatch(ToolCall("execution-data","task",raw))){
        case Result.Err(error)=>
            if (!pluginPreparedCompletionArgumentsValid152(arguments) ||
                canonicalAgentValue(arguments.field("host_plan").getOrThrow().field("completion").getOrThrow()) !=
                    canonicalAgentValue(workflowTaskParameterCompletion152(error))) {
                throw PureProviderError("workflow.task_failure_changed", "complete original parameter failure differs from its frozen result") }
            return DocumentPolicyToolResult(arguments.field("host_plan").getOrThrow().field("completion").getOrThrow().field("output").getOrThrow(), isError: true)
        case Result.Ok(value)=>value}
    let expected=workflowChildIntents111(raw,options)
    let plan=arguments.field("host_plan").getOrThrow();let intents=plan.field("intents").getOrThrow()
    if(httpIntentText(plan,"version")!=PLUGIN_PRIMITIVE_PARENT111 || canonicalAgentValue(expected)!=canonicalAgentValue(intents)){
        throw PureProviderError("workflow.child_plan_changed","frozen child sequence changed after approval")}
    let started=agentUtcMillis();let results=ArrayList<AgentValue>();let progress=ArrayList<AgentValue>();let ids=ArrayList<AgentValue>()
    var failed=false
    for(intent in intents.items){
        let response=broker.consume(workflowText(intent,"id"));let output=response.field("output").getOrThrow()
        if(httpIntentText(output,"schema")!="axyndra.child-launch-result/v1" ||
            httpIntentText(output,"run_id")=="" || httpIntentText(output,"thread_id")==""){
            throw PureProviderError("workflow.child_result_invalid","actual launch acknowledgement is missing")}
        let waiting=workflowText(intent,"service")=="child.wait"
        if(!waiting && output.field("background").getOrThrow().asBool()){
            progress.add(workflowChildProgress111(output));ids.add(output.field("child_id").getOrThrow())
        }else if(waiting || !batch.batch){
            let value=workflowChildObservedRow111(output);results.add(value)
            if(value.field("exitCode").getOrThrow().asNumberText()!="0"){failed=true}
        }
    }
    let fields=ArrayList<ValueField>([ValueField("results",listValue(results.toArray())),
        ValueField("totalDurationMs",integerValue(if(!batch.batch && !ids.isEmpty()){0}else{max(0,agentUtcMillis()-started)}))])
    if(batch.batch || !ids.isEmpty()){fields.add(ValueField("progress",listValue(progress.toArray())))}
    if(!ids.isEmpty()){
        let asynchronous=ArrayList<ValueField>([ValueField("state",textValue("running")),ValueField("jobId",ids[0]),ValueField("type",textValue("task"))])
        if(batch.batch){asynchronous.add(ValueField("jobIds",listValue(ids.toArray())))}
        fields.add(ValueField("async",objectValue(asynchronous.toArray())))
    }
    DocumentPolicyToolResult(objectValue(fields.toArray()),isError:failed)
}
func workflowPrimitiveTools111(): AgentValue {
    let definition=workflowProductTaskToolDefinition111()
    let peerDefinition=workflowProductHubToolDefinition111()
    let values=ArrayList<AgentValue>(workflowDocumentTools().items.toArray())
    values.add(objectValue([ValueField("name",textValue(definition.name)),ValueField("description",textValue(definition.description)),
        ValueField("input_schema",definition.inputSchema)]))
    values.add(objectValue([ValueField("name",textValue(peerDefinition.name)),ValueField("description",textValue(peerDefinition.description)),
        ValueField("input_schema",peerDefinition.inputSchema)]))
    let yieldDefinition=workflowYieldToolDefinition111()
    values.add(objectValue([ValueField("name",textValue(yieldDefinition.name)),
        ValueField("description",textValue(yieldDefinition.description)),ValueField("input_schema",yieldDefinition.inputSchema)]))
    for(name in workflowHubFamilyNames196()){
        let family=workflowHubFamilyDefinition196(name)
        values.add(objectValue([ValueField("name",textValue(family.name)),
            ValueField("description",textValue(family.description)),ValueField("input_schema",family.inputSchema)]))}
    listValue(values.toArray())
}
