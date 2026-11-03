package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// The original Hub parser and renderer run only in this installed package.
// Other business routes remain closed until their true primitives are wired.
func workflowPeerIntents111(arguments: AgentValue): AgentValue {
    let route=match(workflowHubRoute111(ToolCall("frozen-data","hub",arguments))){
        case Result.Err(error)=>throw PureProviderError(error.code,error.message)
        case Result.Ok(value)=>value}
    if(httpIntentText(route,"service")=="peer.send"){return workflowPeerSendIntent111(route)}
    if(httpIntentText(route,"service")=="job.list" || httpIntentText(route,"service")=="job.wait" || httpIntentText(route,"service")=="peer.wait" || httpIntentText(route,"service")=="job.cancel") {
        return listValue([objectValue([ValueField("id",route.field("id").getOrThrow()),
            ValueField("service",route.field("service").getOrThrow()),ValueField("input",route.field("arguments").getOrThrow())])]) }
    if(httpIntentText(route,"service")!="peer.list" && httpIntentText(route,"service")!="peer.receive"){
        throw PureProviderError("workflow.peer_primitive_unavailable","this peer primitive is not installed")}
    listValue([objectValue([ValueField("id",route.field("id").getOrThrow()),
        ValueField("service",route.field("service").getOrThrow()),ValueField("input",route.field("arguments").getOrThrow())])])
}
func workflowPeerPrepare111(arguments: AgentValue): AgentValue {
    objectValue([ValueField("intents",workflowPeerIntents111(arguments))])
}
func workflowPeerExecute111(arguments: AgentValue,broker: FrozenPrimitiveBroker111): DocumentPolicyToolResult {
    let plan=arguments.field("host_plan").getOrThrow()
    let supplied=plan.field("intents").getOrThrow()
    let snapshot=if(supplied.unifiedKind==ValueKind.List && supplied.items.size==1) {
        supplied.items[0].field("input").getOrThrow().field("member_snapshot")
    }else{Option<AgentValue>.None}
    let resume=if(supplied.unifiedKind==ValueKind.List && supplied.items.size==1) {
        supplied.items[0].field("input").getOrThrow().field("resume")
    }else{Option<AgentValue>.None}
    let expected=if(resume.isSome()) {
        let data=resume.getOrThrow()
        workflowPeerResumeIntents111(objectValue([ValueField("schema",textValue("axyndra.peer-resume-preparation/v1")),
            ValueField("request",data.field("read_request").getOrThrow()),ValueField("fact",data.field("read_fact").getOrThrow()),
            ValueField("input",contextReadBusinessInput(arguments.field("input").getOrThrow()))])).field("intents").getOrThrow()
    }else if(snapshot.isSome()) {
        workflowPeerMemberPrepare111(objectValue([ValueField("schema",textValue("axyndra.peer-member-preparation/v1")),
            ValueField("input",arguments.field("input").getOrThrow()),ValueField("snapshot",snapshot.getOrThrow())]))
            .field("intents").getOrThrow()
    }else{workflowPeerIntents111(arguments.field("input").getOrThrow())}
    if(httpIntentText(plan,"version")!=PLUGIN_PRIMITIVE_PARENT111 ||
        canonicalAgentValue(expected)!=canonicalAgentValue(plan.field("intents").getOrThrow())){
        throw PureProviderError("workflow.peer_plan_changed","peer observation changed after approval")}
    let response=broker.consume(httpIntentText(expected.items[0],"id"))
    let output=response.field("output").getOrThrow()
    DocumentPolicyToolResult(if(httpIntentText(expected.items[0],"service")=="peer.list"){
        workflowPeerListOutput111(output)
    }else if(httpIntentText(expected.items[0],"service")=="job.list"){workflowHubJobListOutput165(output)}
    else if(httpIntentText(expected.items[0],"service")=="job.wait"){
        let value=workflowHubJobListOutput165(output); value.put("op",textValue("wait")); value}
    else if(httpIntentText(expected.items[0],"service")=="job.cancel"){
        let value=workflowHubJobListOutput165(output); value.put("op",textValue("cancel")); value}
    else if(httpIntentText(expected.items[0],"service")=="peer.wait"){workflowPeerWaitOutput171(output)}
    else if(httpIntentText(expected.items[0],"service")=="peer.send"){workflowPeerSendOutput111(output,awaitReply178:expected.items[0].field("input").getOrThrow().field("await_reply").isSome())}
    else{workflowPeerInboxOutput111(output,expected.items[0].field("input").getOrThrow().field("peek").getOrThrow().asBool())})
}
func workflowPeerListOutput111(observation: AgentValue): AgentValue {
    workflowFields(observation,["schema","caller_is_root","members"])
    if(httpIntentText(observation,"schema")!="axyndra.peer-observation/v1" ||
        observation.field("caller_is_root").getOrThrow().unifiedKind!=ValueKind.Boolean ||
        observation.field("members").getOrThrow().unifiedKind!=ValueKind.List){
        throw PureProviderError("workflow.peer_observation_invalid","expected actual peer membership facts")}
    let peers=ArrayList<AgentValue>([objectValue([ValueField("id",textValue("Main")),ValueField("kind",textValue("main")),
        ValueField("status",textValue(if(observation.field("caller_is_root").getOrThrow().asBool()){"running"}else{"idle"}))])])
    for(member in observation.field("members").getOrThrow().items){
        workflowFields(member,["id","label","status","activity"])
        peers.add(objectValue([ValueField("id",textValue(workflowText(member,"id"))),ValueField("kind",textValue("sub")),
            ValueField("agent",textValue(workflowText(member,"label"))),ValueField("status",textValue(workflowText(member,"status"))),
            ValueField("activity",textValue(workflowText(member,"activity")))]))
    }
    objectValue([ValueField("op",textValue("list")),ValueField("peers",listValue(peers.toArray()))])
}

func workflowPeerInboxOutput111(observation: AgentValue,peek: Bool): AgentValue {
    workflowFields(observation,["schema","messages"])
    if(httpIntentText(observation,"schema")!="axyndra.peer-messages/v1" ||
        observation.field("messages").getOrThrow().unifiedKind!=ValueKind.List){
        throw PureProviderError("workflow.peer_observation_invalid","expected actual mailbox observation")}
    let messages=ArrayList<AgentValue>()
    for(m in observation.field("messages").getOrThrow().items){
        workflowFields(m,["id","sender","recipient","body","reply_to","created_at"])
        let time=m.field("created_at").getOrThrow()
        if(time.unifiedKind!=ValueKind.Number){throw PureProviderError("workflow.peer_observation_invalid","message time must be an integer")}
        let stamp=try{Int64.parse(time.asNumberText())}catch(_:Exception){throw PureProviderError("workflow.peer_observation_invalid","message time must be an integer")}
        let fields=ArrayList<ValueField>([ValueField("id",textValue(workflowText(m,"id"))),ValueField("from",textValue(workflowText(m,"sender"))),
            ValueField("to",textValue(workflowText(m,"recipient"))),ValueField("message",textValue(workflowText(m,"body")))])
        let reply=workflowText(m,"reply_to")
        if(reply!=""){fields.add(ValueField("replyTo",textValue(reply)))}
        fields.add(ValueField("createdAt",integerValue(stamp)))
        messages.add(objectValue(fields.toArray()))
    }
    objectValue([ValueField("op",textValue("inbox")),ValueField("inbox",listValue(messages.toArray())),ValueField("peek",boolValue(peek))])
}

func workflowPeerSendIntent111(route: AgentValue): AgentValue {
    let input=route.field("arguments").getOrThrow()
    let target=workflowText(input,"target")
    let recipient=objectValue([ValueField("kind",textValue(if(target=="Main"){"root"}else if(target=="all"){"others"}else{"member"})),
        ValueField("id",textValue(if(target=="Main" || target=="all"){""}else{target}))])
    let recipe=objectValue([ValueField("schema",textValue("axyndra.workflow-peer-message/v1"))])
    let intents=listValue([objectValue([ValueField("id",route.field("id").getOrThrow()),ValueField("service",textValue("peer.send")),
        ValueField("input",objectValue([ValueField("recipient",recipient),ValueField("body",input.field("body").getOrThrow()),
            ValueField("reply_to",input.field("reply_to").getOrThrow()),ValueField("format",objectValue([
                ValueField("provider",textValue("prepare_child")),ValueField("input",recipe),
                ValueField("input_sha256",textValue(modelPolicySha256Text(canonicalAgentValue(recipe))))]))]))])])
    if(input.field("wait_for_reply").getOrThrow().asBool()) {
        intents.items[0].field("input").getOrThrow().put("await_reply",objectValue([
            ValueField("sender",textValue(target)),ValueField("timeout_ms",input.field("timeout_ms").getOrThrow())])) }
    intents
}
func workflowPeerDelivery111(input: AgentValue): AgentValue {
    workflowFields(input,["schema","recipe","observation"])
    workflowFields(input.field("recipe").getOrThrow(),["schema"])
    if(workflowText(input,"schema")!="axyndra.frozen-message-query/v1" ||
        httpIntentText(input.field("recipe").getOrThrow(),"schema")!="axyndra.workflow-peer-message/v1") {
        throw PureProviderError("workflow.peer_recipe_invalid","unknown frozen message formatter") }
    let observed=input.field("observation").getOrThrow()
    workflowFields(observed,["schema","sender","sender_session","root_thread","counter","messages"])
    if(httpIntentText(observed,"schema")!="axyndra.peer-delivery-observation/v1" ||
        observed.field("messages").getOrThrow().unifiedKind!=ValueKind.List) {
        throw PureProviderError("workflow.peer_observation_invalid","expected actual recipient data") }
    let sender=workflowText(observed,"sender")
    let values=ArrayList<AgentValue>()
    for(message in observed.field("messages").getOrThrow().items) {
        workflowFields(message,["id","recipient","recipient_session","recipient_run","recipient_status","body","reply_to","created_at","wait_call_id"])
        let id=workflowText(message,"id")
        values.add(objectValue([ValueField("id",textValue(id)),ValueField("content",textValue(
            "<hub-message from=\""+sender+"\" id=\""+id+"\">"+workflowText(message,"body")+"</hub-message>"))]))
    }
    objectValue([ValueField("messages",listValue(values.toArray()))])
}
func workflowPeerSendOutput111(observation: AgentValue, awaitReply178!: Bool = false): AgentValue {
    if(awaitReply178){workflowFields(observation,["schema","sender","deliveries","waited"])}
    else{workflowFields(observation,["schema","sender","deliveries"])}
    if(httpIntentText(observation,"schema")!="axyndra.peer-delivery-result/v1" ||
        observation.field("deliveries").getOrThrow().unifiedKind!=ValueKind.List) {
        throw PureProviderError("workflow.peer_observation_invalid","expected actual durable deliveries") }
    let receipts=ArrayList<AgentValue>()
    for(delivery in observation.field("deliveries").getOrThrow().items) {
        workflowFields(delivery,["id","recipient","delivered"])
        if(delivery.field("delivered").getOrThrow().unifiedKind!=ValueKind.Boolean ||
            !delivery.field("delivered").getOrThrow().asBool()) {
            throw PureProviderError("workflow.peer_delivery_incomplete","message was not durably delivered") }
        receipts.add(objectValue([ValueField("id",textValue(workflowText(delivery,"id"))),
            ValueField("to",textValue(workflowText(delivery,"recipient"))),ValueField("delivered",boolValue(true))]))
    }
    let output=objectValue([ValueField("op",textValue("send")),ValueField("from",textValue(workflowText(observation,"sender"))),
        ValueField("receipts",listValue(receipts.toArray()))])
    if(awaitReply178) {
        let waited=workflowPeerWaitOutput171(objectValue([ValueField("schema",textValue("axyndra.peer-wait-observation/v1")),
            ValueField("waited",observation.field("waited").getOrThrow())]))
        output.put("waited",waited.field("waited").getOrThrow()) }
    output
}

// Native owns the old jobs/error/warning presentation. The observation never
// authorizes a cancellation, admits a child or supplies physical ACK evidence.
func workflowHubJobListOutput165(observation: AgentValue): AgentValue {
    workflowFields(observation,["schema","jobs","recovery_warnings"])
    let source = observation.field("jobs").getOrThrow()
    let warnings = observation.field("recovery_warnings").getOrThrow()
    if (httpIntentText(observation,"schema") != "axyndra.job-observation/v1" ||
        source.unifiedKind != ValueKind.List || warnings.unifiedKind != ValueKind.List) {
        throw PureProviderError("workflow.job_observation_invalid","expected actual retained job snapshot") }
    let jobs = ArrayList<AgentValue>()
    for (job in source.items) {
        workflowFields(job,["id","agent_id","type","status","label","duration_ms","has_result","result","error"])
        let duration = job.field("duration_ms").getOrThrow()
        let present = job.field("has_result").getOrThrow()
        if (duration.unifiedKind != ValueKind.Number || present.unifiedKind != ValueKind.Boolean ||
            (!present.asBool() && job.field("result").getOrThrow().unifiedKind != ValueKind.Null)) {
            throw PureProviderError("workflow.job_observation_invalid","invalid original job result shape") }
        let millis = try { Int64.parse(duration.asNumberText()) }
            catch (_: Exception) { throw PureProviderError("workflow.job_observation_invalid","duration must be an integer") }
        if (millis < 0) { throw PureProviderError("workflow.job_observation_invalid","duration must be nonnegative") }
        let fields = ArrayList<ValueField>([ValueField("id",textValue(workflowText(job,"id"))),
            ValueField("agentId",textValue(workflowText(job,"agent_id"))),ValueField("type",textValue(workflowText(job,"type"))),
            ValueField("status",textValue(workflowText(job,"status"))),ValueField("label",textValue(workflowText(job,"label"))),
            ValueField("durationMs",integerValue(millis))])
        if (present.asBool()) { fields.add(ValueField("result",job.field("result").getOrThrow())) }
        let error = workflowText(job,"error")
        if (error != "") { fields.add(ValueField("error",textValue(error))) }
        jobs.add(objectValue(fields.toArray()))
    }
    for (warning in warnings.items) {
        if (warning.unifiedKind != ValueKind.Text) {
            throw PureProviderError("workflow.job_observation_invalid","warning must preserve complete text") } }
    let fields = ArrayList<ValueField>([ValueField("op",textValue("jobs")),ValueField("jobs",listValue(jobs.toArray()))])
    if (!warnings.items.isEmpty()) { fields.add(ValueField("recoveryWarnings",warnings)) }
    objectValue(fields.toArray())
}

// Restore the complete original public Hub wait shape from neutral facts.
// No Source, child launch, message delivery or consumption occurs in Native.
func workflowPeerWaitOutput171(observation: AgentValue): AgentValue {
    workflowFields(observation, ["schema", "waited"])
    if (httpIntentText(observation, "schema") != "axyndra.peer-wait-observation/v1") {
        throw PureProviderError("workflow.peer_observation_invalid", "expected actual mailbox wait facts") }
    let value = observation.field("waited").getOrThrow()
    let waited = if (value.unifiedKind == ValueKind.Null) { nullValue() } else {
        workflowFields(value, ["id", "sender", "recipient", "body", "reply_to", "created_at"])
        let time = value.field("created_at").getOrThrow()
        if (time.unifiedKind != ValueKind.Number) {
            throw PureProviderError("workflow.peer_observation_invalid", "message time must be an integer") }
        let stamp = try { Int64.parse(time.asNumberText()) }
            catch (_: Exception) { throw PureProviderError("workflow.peer_observation_invalid", "message time must be an integer") }
        let fields = ArrayList<ValueField>([ValueField("id", textValue(workflowText(value, "id"))),
            ValueField("from", textValue(workflowText(value, "sender"))),
            ValueField("to", textValue(workflowText(value, "recipient"))),
            ValueField("message", textValue(workflowText(value, "body")))])
        let reply = workflowText(value, "reply_to")
        if (reply != "") { fields.add(ValueField("replyTo", textValue(reply))) }
        fields.add(ValueField("createdAt", integerValue(stamp)))
        objectValue(fields.toArray())
    }
    objectValue([ValueField("op", textValue("wait")), ValueField("waited", waited)])
}
