package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// A paid private preparation reader, not an Operation or execution Source.
// The only public consumer returns existing same-root Task metadata. Neither
// this scope nor its serialized result can acquire a start/publication lease.
public class HostPluginPeerPreparationSnapshot111 {
    private let context:ToolInvocationContext
    private let recipient:String
    private let current:()->Result<Unit>
    private let configuration:HostPrimitiveConfiguration111
    init(context:ToolInvocationContext,recipient:String,current:()->Result<Unit>,
        configuration:HostPrimitiveConfiguration111) {
        this.context=context;this.recipient=recipient;this.current=current;this.configuration=configuration
    }
    public func check(actual:ToolInvocationContext,id:String):Result<Unit> {
        if(!refEq(actual,context) || id!=recipient) {
            return hostPluginResourceError("peer.preparation_scope_changed","member metadata belongs to another actual preparation") }
        current()
    }
    public func retainObservation(bytes:Int64,nodes:Int64,build:()->AgentValue):AgentValue {
        configuration.retainObservation(bytes,nodes,build)
    }
}

func hostObservePeerPreparation111(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    context:ToolInvocationContext,recipient:String,binding:AgentValue,
    configuration:HostPrimitiveConfiguration111,current:()->Result<Unit>):Result<AgentValue> {
    let _=configuration.retainObservation(8192,128,{=>nullValue()})
    let checked:()->Result<Unit>={=>
        match(current()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        let lane=match(operations.pluginDocumentLane(ThreadId(context.sessionId.value),context.runId,context.epoch)) {
            case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value }
        if(lane.value!=httpIntentText(binding,"lane_id")) {
            return hostPluginResourceError<Unit>("peer.preparation_run_changed","member metadata lost the original actual Run lane") }
        Result<Unit>.Ok(())}
    match(checked()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let scope=HostPluginPeerPreparationSnapshot111(context,recipient,checked,configuration)
    let result=match(host.observePeerPreparation111(context,recipient,scope)) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    if(!pluginPeerMemberSnapshotValid111(result) || httpIntentText(result,"id")!=recipient) {
        return hostPluginResourceError("peer.preparation_snapshot_invalid","member metadata has another identity or shape") }
    match(checked()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    Result<AgentValue>.Ok(result)
}

func hostFreezePeerMemberIntents111(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    context:ToolInvocationContext,call:ToolCall,configuration:HostPrimitiveConfiguration111,generation:UInt64,
    local:String,binding:AgentValue,intents:AgentValue):Result<AgentValue> {
    if(intents.unifiedKind!=ValueKind.List || intents.items.size!=1 ||
        httpIntentText(intents.items[0],"service")!="peer.send") {return Result<AgentValue>.Ok(intents)}
    let input=intents.items[0].field("input").getOrThrow()
    let recipient=input.field("recipient").getOrThrow()
    if(httpIntentText(recipient,"kind")!="member"){return Result<AgentValue>.Ok(intents)}
    let current:()->Result<Unit>={=>hostChildPreparationCurrent111(host,configuration,generation,local,context,binding,service:"peer.send")}
    let member=match(hostObservePeerPreparation111(host,operations,context,httpIntentText(recipient,"id"),binding,configuration,current)) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    let provider=configuration.preparationProvider(local)
    let response=match(hostQueryPluginPolicy(host,configuration.namespace,provider,configuration.packageDigest,
        objectValue([ValueField("schema",textValue("axyndra.peer-member-preparation/v1")),
            ValueField("input",call.arguments),ValueField("snapshot",member)]),ThreadId(context.sessionId.value),
        context.cancellation,call.callId+":member-freeze")) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    try {
        if(response.binding.namespace!=configuration.namespace || response.binding.generation!=generation ||
            response.binding.digest!=configuration.packageDigest || response.binding.contribution!=provider ||
            !httpIntentExactFields(response.value,["intents"])) {
            return hostPluginResourceError("peer.member_plan_changed","member plan lost the actual installed preparation") }
        let next=response.value.field("intents").getOrThrow()
        if(next.unifiedKind!=ValueKind.List || next.items.size!=1 ||
            httpIntentText(next.items[0],"id")!=httpIntentText(intents.items[0],"id") ||
            httpIntentText(next.items[0],"service")!="peer.send") {
            return hostPluginResourceError("peer.member_plan_changed","member plan changed its exact primitive") }
        let frozen=next.items[0].field("input").getOrThrow()
        if(!httpIntentExactFields(frozen,["recipient","body","reply_to","format","member_snapshot"]) ||
            canonicalAgentValue(frozen.field("member_snapshot").getOrThrow())!=canonicalAgentValue(member)) {
            return hostPluginResourceError("peer.member_plan_changed","member plan changed its actual metadata") }
        for(field in ["recipient","body","reply_to","format"]) {
            if(canonicalAgentValue(frozen.field(field).getOrThrow())!=canonicalAgentValue(input.field(field).getOrThrow())) {
                return hostPluginResourceError("peer.member_plan_changed","member plan changed its original complete message") }
        }
        let copied=configuration.copyPreparedPlan(next)
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result<AgentValue>.Ok(copied)
    }finally{response.close()}
}
