package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

let HOST_LIVE_POLICY_READ_QUERY_SCHEMA="axyndra.plugin-live-policy-read-query/v1"

// This validates a data-only logical selector. Neither the plugin's answer
// nor the operator profile is a Root, read allowance or execution grant.
func hostLivePolicyReadSelectionValid(value:AgentValue,key:String):Bool{
    if(!httpIntentExactFields(value,["document_read"])) {return false}
    let selection=value.field("document_read").getOrThrow()
    if(!httpIntentExactFields(selection,["key","kind"])) {return false}
    for(name in ["key","kind"]){if(selection.field(name).getOrThrow().unifiedKind!=ValueKind.Text){return false}}
    httpIntentText(selection,"kind")=="latest" && httpIntentText(selection,"key")==key
}

func hostLivePolicyReadBinding(configuration:HostPluginLivePolicyConfiguration,generation:UInt64,
    implementation:String,schemaDigest:String,context:ToolInvocationContext,call:ToolCall,lane:LaneId):AgentValue{
    objectValue([ValueField("namespace",textValue(configuration.namespace)),ValueField("package_digest",textValue(configuration.packageDigest)),
        ValueField("generation",textValue(generation.toString())),ValueField("configuration_digest",textValue(configuration.read.digest)),
        ValueField("thread_id",textValue(context.sessionId.value)),ValueField("lane_id",textValue(lane.value)),
        ValueField("run_id",textValue(context.runId.value)),ValueField("epoch",integerValue(context.epoch)),
        ValueField("parent_call_id",textValue(call.callId)),ValueField("contribution",textValue(call.name)),
        ValueField("implementation_fingerprint",textValue(implementation)),ValueField("schema_digest",textValue(schemaDigest))])
}

func hostPreparePluginLivePolicyRead(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    configuration:HostPluginLivePolicyConfiguration,localTool:String,generation:UInt64,implementation:String,schemaDigest:String,
    context:ToolInvocationContext,call:ToolCall):Result<?ToolPreparationRead>{
    if(call.arguments.field(CONTEXT_READ_INPUT_FIELD).isSome() || context.trustedControl || call.name!=configuration.contribution ||
        call.name!="plugin."+configuration.namespace+"."+localTool){
        return hostPluginResourceError("plugin.live_read_reentered","live preread requires its actual original published Tool call")}
    let lane=match(operations.pluginDocumentLane(ThreadId(context.sessionId.value),context.runId,context.epoch)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let binding=hostLivePolicyReadBinding(configuration,generation,implementation,schemaDigest,context,call,lane)
    match(hostLivePolicyInputCurrent(host,configuration,generation,context,call,binding)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let access=match(configuration.read.access(configuration.key)){case Some(value)=>value
        case None=>return hostPluginResourceError("plugin.live_read_access_missing","the exact read profile omitted this logical key")}
    let view=match(configuration.read.view(configuration.key)){case Some(value)=>value
        case None=>return hostPluginResourceError("plugin.live_read_view_missing","the exact read profile omitted this latest-view purpose")}
    // No complete business parameters enter the small pure policy query. The
    // Native policy gets only its real local contribution and picks a key.
    let response=match(hostQueryPluginPolicy(host,configuration.namespace,configuration.readProvider,configuration.packageDigest,
        objectValue([ValueField("schema",textValue(HOST_LIVE_POLICY_READ_QUERY_SCHEMA)),ValueField("tool",textValue(localTool))]),
        ThreadId(context.sessionId.value),context.cancellation,"live-read-"+call.callId)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    try{
        if(!hostLivePolicyReadSelectionValid(response.value,configuration.key) || response.binding.generation!=generation ||
            response.binding.digest!=configuration.packageDigest || response.binding.contribution!=configuration.readProvider){
            return hostPluginResourceError("plugin.live_read_selection_changed","the actual pure provider changed its frozen logical read selection")}
        let request=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA)),
            ValueField("binding",binding),ValueField("projection_digest",textValue(contextReadProjectionDigest(context.contextProjection))),
            ValueField("key",textValue(configuration.key)),ValueField("access_policy_digest",textValue(access.digest)),
            ValueField("view_policy_digest",textValue(view.digest))])
        if(!pluginDocumentLatestJournalStreamReadRequestValid(request)){
            return hostPluginResourceError("plugin.live_read_request_invalid","the frozen actual Tool read request is invalid")}
        match(hostLatestJournalPreparationCurrent(host,configuration.read,generation,context,request)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        // Only the fixed <=16KiB descriptor is encoded here. Its complete
        // caller input stays under the original Core preparation owner and
        // is frozen by the unchanged ToolPreparationRead.complete path.
        let frozenRequest=encodeAgentValue(request)
        let frozenBinding=encodeAgentValue(binding)
        Result<?ToolPreparationRead>.Ok(Some(ToolPreparationRead(configuration.namespace,configuration.packageDigest,configuration.read.digest,
            request,{actual,facts=>
                let expected=parseUnifiedJson(frozenRequest,maxBytes:16384)
                match(hostLivePolicyInputCurrent(host,configuration,generation,actual,call,parseUnifiedJson(frozenBinding,maxBytes:16384))){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(hostLatestJournalPreparationCurrent(host,configuration.read,generation,actual,expected)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                if(facts.size!=1 || facts[0].runId.value!=actual.runId.value ||
                    facts[0].origin.ownerNamespace!=configuration.namespace || facts[0].origin.packageDigest!=configuration.packageDigest ||
                    facts[0].origin.configurationDigest!=configuration.read.digest || facts[0].projectionDigest!=httpIntentText(expected,"projection_digest") ||
                    facts[0].origin.parentCallItemId=="" ||
                    !pluginDocumentLatestJournalStreamReadResultValid(facts[0].output(),expected)){
                    return hostPluginResourceError("plugin.live_read_fact_changed","live continuation requires its sole completed canonical Tool read")}
                let fields=ArrayList<ValueField>(call.arguments.fields.toArray())
                fields.add(ValueField(CONTEXT_READ_INPUT_FIELD,objectValue([ValueField("schema",textValue("axyndra.context-read-input/v1")),
                    ValueField("data",facts[0].output()),ValueField("facts",contextReadFactLinksValue([facts[0].link()]))])))
                Result<AgentValue>.Ok(objectValue(fields.toArray()))
            },boundary:Some({actual,arguments=>
                let expected=parseUnifiedJson(frozenRequest,maxBytes:16384)
                if(canonicalAgentValue(arguments)!=canonicalAgentValue(expected)){
                    return hostPluginResourceError("plugin.live_read_request_changed","live preread differs from its exact retained request")}
                match(hostLivePolicyInputCurrent(host,configuration,generation,actual,call,parseUnifiedJson(frozenBinding,maxBytes:16384))){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                hostLatestJournalPreparationCurrent(host,configuration.read,generation,actual,arguments)
            }))))
    }finally{response.close()}
}
