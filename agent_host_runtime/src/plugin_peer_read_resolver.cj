package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import yjson.*
import yjson_support.*

// Mounted only for an explicit current per-contribution primitive selection.
// This resolver uses the ordinary canonical ContextRead and actual same-Run
// fact continuation. It creates no pending Operation, Source or extra grant.
func hostPreparePluginPeerRead111(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    namespace:String,local:String,generation:UInt64,implementation:String,schemaDigest:String,
    context:ToolInvocationContext,call:ToolCall):Result<?ToolPreparationRead> {
    if(call.name!="plugin."+namespace+"."+local || call.arguments.unifiedKind!=ValueKind.Object ||
        call.arguments.field(CONTEXT_READ_INPUT_FIELD).isSome() || call.arguments.field("host_plan").isSome()) {
        return hostPluginResourceError("peer.read_input_invalid","member preparation requires the original caller input") }
    let configuration=match(host.primitiveConfiguration111(namespace,local,generation)) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(Some(value))=>value
        case Result.Ok(None)=>return hostPluginResourceError("peer.read_profile_missing","no exact installed primitive selection") }
    if(!configuration.permitsService(local,"peer.send")){return Result<?ToolPreparationRead>.Ok(Option<ToolPreparationRead>.None)}
    let lane=match(operations.pluginDocumentLane(ThreadId(context.sessionId.value),context.runId,context.epoch)) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    let binding=configuration.retainObservation(16384,128,{=>objectValue([
        ValueField("namespace",textValue(namespace)),ValueField("package_digest",textValue(configuration.packageDigest)),
        ValueField("generation",textValue(generation.toString())),ValueField("configuration_digest",textValue(configuration.digest)),
        ValueField("thread_id",textValue(context.sessionId.value)),ValueField("lane_id",textValue(lane.value)),
        ValueField("run_id",textValue(context.runId.value)),ValueField("epoch",integerValue(context.epoch)),
        ValueField("parent_call_id",textValue(call.callId)),ValueField("contribution",textValue(call.name)),
        ValueField("implementation_fingerprint",textValue(implementation)),ValueField("schema_digest",textValue(schemaDigest))])})
    let current:()->Result<Unit>={=>hostChildPreparationCurrent111(host,configuration,generation,local,context,binding)}
    match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let phaseDeadline=MonoTime.now()+Duration.second*5
    let preparing:()->Result<Unit>={=>
        if(MonoTime.now()>=phaseDeadline){return hostPluginResourceError<Unit>("policy.deadline_exceeded","original preparation phase expired")}
        current()}
    let input=match(hostCapturePeerPreparedInput111(host,configuration,call,preparing)) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    let provider=configuration.preparationProvider(local)
    let proposal=match(input.consume(preparing,{original=>
        let response=match(hostQueryPluginPolicy(host,namespace,provider,configuration.packageDigest,
            objectValue([ValueField("schema",textValue("axyndra.primitive-read-query/v1")),
                ValueField("tool",textValue(local)),ValueField("input",original)]),ThreadId(context.sessionId.value),
            context.cancellation,call.callId,deadline:Some(phaseDeadline))) {
            case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value }
        try {
            if(response.binding.generation!=generation || response.binding.digest!=configuration.packageDigest ||
                response.binding.namespace!=namespace || response.binding.contribution!=provider ||
                !httpIntentExactFields(response.value,["peer_read"])) {
                return hostPluginResourceError<AgentValue>("peer.read_proposal_changed","member preparation changed its selected pure Provider") }
            Result<AgentValue>.Ok(configuration.copyPreparedPlan(response.value))
        }finally{response.close()}})) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    let selector=proposal.field("peer_read").getOrThrow()
    if(selector.unifiedKind==ValueKind.Null){return Result<?ToolPreparationRead>.Ok(Option<ToolPreparationRead>.None)}
    if(!httpIntentExactFields(selector,["recipient"]) || selector.field("recipient").getOrThrow().unifiedKind!=ValueKind.Text ||
        httpIntentText(selector,"recipient")=="") {
        return hostPluginResourceError("peer.read_proposal_invalid","pure member selector has an invalid shape") }
    match(hostChildPreparationCurrent111(host,configuration,generation,local,context,binding,service:"peer.send")) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>() }
    let member=match(hostObservePeerPreparation111(host,operations,context,httpIntentText(selector,"recipient"),binding,
        configuration,{=>
            match(preparing()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            hostChildPreparationCurrent111(host,configuration,generation,local,context,binding,service:"peer.send")})) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    let selection=match(hostQueryPluginPolicy(host,namespace,provider,configuration.packageDigest,
        objectValue([ValueField("schema",textValue("axyndra.peer-read-selection/v1")),ValueField("selector",selector),
            ValueField("snapshot",member)]),ThreadId(context.sessionId.value),context.cancellation,
        call.callId+":member-read-selection",deadline:Some(phaseDeadline))) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    try {
        if(selection.binding.generation!=generation || selection.binding.digest!=configuration.packageDigest ||
            selection.binding.namespace!=namespace || selection.binding.contribution!=provider ||
            !httpIntentExactFields(selection.value,["peer_read"])) {
            return hostPluginResourceError("peer.read_selection_changed","read selection lost its exact installed Provider") }
        let chosen=selection.value.field("peer_read").getOrThrow()
        match(preparing()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(chosen.unifiedKind==ValueKind.Null){return Result<?ToolPreparationRead>.Ok(Option<ToolPreparationRead>.None)}
        if(canonicalAgentValue(chosen)!=canonicalAgentValue(selector)) {
            return hostPluginResourceError("peer.read_selection_changed","read selection changed its original actual member") }
    }finally{selection.close()}
    let request=configuration.retainObservation(65536,512,{=>objectValue([
        ValueField("schema",textValue(PLUGIN_PEER_READ111)),ValueField("binding",binding),
        ValueField("projection_digest",textValue(contextReadProjectionDigest(context.contextProjection))),
        ValueField("recipient",selector.field("recipient").getOrThrow()),ValueField("input_payload",input.reference()),
        ValueField("member_snapshot",member),
        ValueField("invocation_capability",textValue(configuration.invocationName(local,service:"peer.send")))])})
    if(!pluginPeerReadRequestValid111(request)) {
        return hostPluginResourceError("peer.read_proposal_invalid","member read could not freeze its complete input identity") }
    let _=configuration.retainObservation(8192,128,{=>nullValue()})
    Result.Ok(Some(ToolPreparationRead(namespace,configuration.packageDigest,configuration.digest,request,
        {actual,facts=>
            match(hostChildPreparationCurrent111(host,configuration,generation,local,actual,binding,service:"peer.send")) {
                case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>() }
            if(facts.size!=1){return hostPluginResourceError<AgentValue>("peer.read_fact_changed","resume requires one actual member read")}
            // outputBytes is an immutable fact field; one JSON node consumes
            // at least one encoded byte. Pay this conservative complete copy
            // before the DTO's private JSON is decoded. No temporary output
            // escapes its original installed-bank retained observation.
            let data=configuration.retainObservation(max(1,facts[0].outputBytes),max(1,facts[0].outputBytes),{=>facts[0].output()})
            if(facts[0].runId.value!=actual.runId.value || facts[0].origin.ownerNamespace!=namespace ||
                facts[0].origin.packageDigest!=configuration.packageDigest || facts[0].origin.configurationDigest!=configuration.digest ||
                facts[0].projectionDigest!=httpIntentText(request,"projection_digest") ||
                !pluginPeerReadResultValid111(data,request)) {
                return hostPluginResourceError<AgentValue>("peer.read_fact_changed","resume requires this original completed member read") }
            input.consume({=>hostChildPreparationCurrent111(host,configuration,generation,local,actual,binding,service:"peer.send")},
                {original=>
                    if(!pluginPeerReadInputMatches111(original,request)) {
                        return hostPluginResourceError<AgentValue>("peer.read_input_changed","verified input differs from the original read") }
                    let fields=ArrayList<ValueField>(original.fields.toArray())
                    fields.add(ValueField(CONTEXT_READ_INPUT_FIELD,objectValue([
                        ValueField("schema",textValue("axyndra.context-read-input/v1")),ValueField("data",data),
                        ValueField("facts",contextReadFactLinksValue([facts[0].link()]))])))
                    Result<AgentValue>.Ok(objectValue(fields.toArray()))})
        },boundary:Some({actual,arguments=>
            if(canonicalAgentValue(arguments)!=canonicalAgentValue(request) ||
                contextReadProjectionDigest(actual.contextProjection)!=httpIntentText(request,"projection_digest")) {
                return hostPluginResourceError<Unit>("peer.read_boundary_changed","member read lost its exact original request") }
            hostChildPreparationCurrent111(host,configuration,generation,local,actual,binding,service:"peer.send")
        }))))
}
