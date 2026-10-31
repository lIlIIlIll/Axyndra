package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Optional Native contributions split the original Hub business by the
// existing exact operator-selected service boundary. They do not widen the
// Host's two-service ceiling or the process-service exclusive selection.
func workflowHubFamilyNames196(): Array<String> {
    ["hub_peers", "hub_messages", "hub_jobs", "hub_cancel", "hub_process", "hub_process_read"]
}
func workflowHubContribution196(name: String): Bool {
    name == "hub" || workflowHubFamilyNames196().contains(name)
}
func workflowRequireHubFamily196(name: String, input: AgentValue): Unit {
    if (name == "hub") { return }
    let route = match (workflowHubRoute111(ToolCall("frozen-data", "hub", input))) {
        case Result.Err(error) => throw PureProviderError(error.code, error.message)
        case Result.Ok(value) => value
    }
    let service = if (httpIntentText(route, "route") == "process") { "process.service" }
        else { httpIntentText(route, "service") }
    let selected = match (name) {
        case "hub_peers" => service == "peer.list" || service == "peer.receive"
        case "hub_messages" => service == "peer.send" || service == "peer.wait"
        case "hub_jobs" => service == "job.list" || service == "job.wait"
        case "hub_cancel" => service == "job.cancel"
        case "hub_process" => service == "process.service"
        case "hub_process_read" => service == "process.service" &&
            ["ps", "logs", "describe", "wait"].contains(httpIntentText(route, "op"))
        case _ => false
    }
    if (!selected) {
        throw PureProviderError("workflow.hub_service_unselected", "operation is outside this Native contribution's selected service family")
    }
}
func workflowHubFamilyDefinition196(name: String): ModelToolDefinition {
    let original = workflowProductHubToolDefinition111()
    let description = match (name) {
        case "hub_peers" => "List peers or consume/peek at the caller's inbox (op: list, inbox)."
        case "hub_messages" => "Send a peer message or wait for a peer (op: send; wait with from)."
        case "hub_jobs" => "List background jobs or wait for them (op: jobs; wait with ids)."
        case "hub_cancel" => "Cancel the selected background jobs (op: cancel with ids)."
        case "hub_process_read" => "Observe selected project processes without mutation (op: ps, logs, describe, wait)."
        case "hub_process" => "Supervise selected project processes (op: start, ps, logs, stop, restart, describe, send, wait; process name selects send/wait)."
        case _ => throw PureProviderError("workflow.child_tool_unknown", "unknown primitive Tool")
    }
    // The complete original field schema is retained; the Native parser and
    // family gate validate the operation before any frozen primitive is used.
    ModelToolDefinition(name, description, original.inputSchema)
}

// Business normalization/rendering remains Native. Host independently validates
// the normalized read-only operation and the actual frozen authority in 197.
func workflowHubProcessObservationIntents196(arguments:AgentValue,options:AgentValue):AgentValue{
    if(options.field("process_facts").isNone()){
        workflowFields(options,["background_enabled"])
        throw PureProviderError("workflow.peer_primitive_unavailable","this peer primitive is not installed")}
    workflowFields(options,["background_enabled","process_facts"])
    let facts=options.field("process_facts").getOrThrow()
    workflowFields(facts,["shell_mode","broker_available"])
    if(facts.field("broker_available").getOrThrow().unifiedKind!=ValueKind.Boolean){
        throw PureProviderError("workflow.process_configuration_invalid","expected actual broker availability")}
    let request=workflowHubProcessRequest(arguments,workflowText(facts,"shell_mode"))
    request.put("actual_target",nullValue())
    if(!["ps","logs","describe","wait"].contains(workflowText(request,"op"))){
        throw PureProviderError("workflow.hub_service_unselected","write operation is outside the process observation contribution")}
    if(workflowText(request,"op")=="start" && request.field("spec").getOrThrow().field("persist").getOrThrow().asBool() &&
        !facts.field("broker_available").getOrThrow().asBool()){
        throw PureProviderError("hub.process_broker_required","persistent process services require the process broker")}
    listValue([objectValue([ValueField("id",textValue("hub-process-"+workflowText(request,"op"))),
        ValueField("service",textValue("process.observe")),ValueField("input",objectValue([
            ValueField("schema",textValue("axyndra.hub-process-request/v1")),ValueField("request",request),ValueField("facts",facts)]))])])
}

func workflowExecuteHubProcessObservation196(arguments:AgentValue,broker:FrozenPrimitiveBroker111):DocumentPolicyToolResult{
    let plan=arguments.field("host_plan").getOrThrow();let supplied=plan.field("intents").getOrThrow()
    if(supplied.unifiedKind!=ValueKind.List || supplied.items.size!=1 || workflowText(supplied.items[0],"service")!="process.observe"){
        throw PureProviderError("workflow.process_plan_changed","expected one exact admitted process service")}
    let expected=workflowHubProcessObservationIntents196(arguments.field("input").getOrThrow(),arguments.field("configuration").getOrThrow())
    let actualInput=supplied.items[0].field("input").getOrThrow();let frozen=actualInput.field("request").getOrThrow()
    // This is immutable DATA inserted by the actual resource preparation, not
    // a PID/name or plugin-authored Source claim. Host validates it again at
    // the effect boundary against its actual private incarnation record.
    expected.items[0].field("input").getOrThrow().field("request").getOrThrow().put("actual_target",frozen.field("actual_target").getOrThrow())
    if(workflowText(plan,"version")!=PLUGIN_PRIMITIVE_PARENT111 || canonicalAgentValue(expected)!=canonicalAgentValue(supplied)){
        throw PureProviderError("workflow.process_plan_changed","complete process input differs from canonical preparation")}
    let response=broker.consume(workflowText(expected.items[0],"id"))
    let request=expected.items[0].field("input").getOrThrow().field("request").getOrThrow()
    let output=workflowHubProcessOutput(request,response.field("output").getOrThrow())
    DocumentPolicyToolResult(output,isError:workflowText(request,"op")=="start" && workflowText(output.field("daemon").getOrThrow(),"state")=="failed")
}
