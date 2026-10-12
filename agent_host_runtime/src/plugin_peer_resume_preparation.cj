package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

func hostCanonicalizePeerResume111(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    configuration:HostPrimitiveConfiguration111,generation:UInt64,local:String,
    context:ToolInvocationContext,call:ToolCall,binding:AgentValue,options:AgentValue):Result<AgentValue> {
    match(hostChildPreparationCurrent111(host,configuration,generation,local,context,binding,service:"peer.send")) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>() }
    if(!configuration.permitsService(local,"peer.send")) {
        return hostPluginResourceError("peer.resume_profile_missing","actual contribution cannot consume peer messaging") }
    let observed=match(hostLoadPeerReadFact111(operations,configuration,context,call,binding)) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    let provider=configuration.preparationProvider(local)
    let current:()->Result<Unit>={=>hostChildPreparationCurrent111(host,configuration,generation,local,context,binding,service:"peer.send")}
    let captured=match(hostCapturePeerPreparedInput111(host,configuration,ToolCall(call.callId,call.name,observed.original),current)) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    captured.consume(current,{business=>
    var queryBytes:Int64=8192;var queryNodes:Int64=128
    for(value in [observed.request,observed.data,business]) {
        let bytes=logicalJsonWriteReservationBytes(value,8388608);let nodes=logicalJsonValueNodeCount(value)
        if(queryBytes>Int64.Max-bytes || queryNodes>Int64.Max-nodes) {
            return hostPluginResourceError<AgentValue>("peer.resume_size_invalid","resume input invoice overflow") }
        queryBytes+=bytes;queryNodes+=nodes
    }
    let query=configuration.retainObservation(queryBytes,queryNodes,{=>objectValue([
        ValueField("schema",textValue("axyndra.peer-resume-preparation/v1")),ValueField("request",observed.request),
        ValueField("fact",observed.data),ValueField("input",business)])})
    let response=match(hostQueryPluginPolicy(host,configuration.namespace,provider,configuration.packageDigest,
        objectValue([ValueField("schema",textValue("axyndra.peer-resume-intents/v1")),ValueField("query",query)]),
        ThreadId(context.sessionId.value),context.cancellation,call.callId+":resume-freeze")) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    try {
        if(response.binding.namespace!=configuration.namespace || response.binding.generation!=generation ||
            response.binding.digest!=configuration.packageDigest || response.binding.contribution!=provider ||
            !httpIntentExactFields(response.value,["intents"])) {
            return hostPluginResourceError("peer.resume_provider_changed","resume plan lost its exact installed Provider") }
        let intents=response.value.field("intents").getOrThrow()
        if(intents.unifiedKind!=ValueKind.List || intents.items.size!=1 || httpIntentText(intents.items[0],"service")!="peer.send") {
            return hostPluginResourceError("peer.resume_plan_invalid","resume must remain the sole actual frozen peer message") }
        let input=intents.items[0].field("input").getOrThrow()
        if(!pluginPeerResumeInputValid111(input,binding) ||
            canonicalAgentValue(input.field("resume").getOrThrow().field("read_request").getOrThrow())!=canonicalAgentValue(observed.request) ||
            canonicalAgentValue(input.field("resume").getOrThrow().field("read_fact").getOrThrow())!=canonicalAgentValue(observed.data) ||
            httpIntentText(input.field("resume").getOrThrow().field("proposal").getOrThrow().field("completion").getOrThrow(),"provider")!=provider) {
            return hostPluginResourceError("peer.resume_plan_invalid","resume changed the actual read, member or frozen completion") }
        let hostPlan=objectValue([ValueField("version",textValue(PLUGIN_PRIMITIVE_PARENT111)),
            ValueField("binding",binding),ValueField("intents",intents)])
        let selected=configuration.invocationName(local,service:"peer.send")
        if(selected!="extension.invoke"){hostPlan.put("invocation_capability",textValue(selected))}
        let arguments=objectValue([ValueField("input",call.arguments),ValueField("configuration",options),ValueField("host_plan",hostPlan)])
        if(pluginChildStartArguments111(arguments,httpIntentText(intents.items[0],"id")).isError()) {
            return hostPluginResourceError("peer.resume_plan_invalid","resume plan does not bind its exact original parent data") }
        let frozen=configuration.copyPreparedPlan(arguments)
        match(hostChildPreparationCurrent111(host,configuration,generation,local,context,binding,service:"peer.send")) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>() }
        Result<AgentValue>.Ok(frozen)
    }finally{response.close()}
    })
}
