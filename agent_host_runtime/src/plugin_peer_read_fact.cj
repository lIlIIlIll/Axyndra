package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// Private observed data, not a grant or a reconstructible live owner. The
// actual canonicalizer must repeat its current profile checks and Store still
// consumes the exact links in the ordinary parent admission transaction.
class HostPeerReadFact111 {
    let request:AgentValue
    let data:AgentValue
    let link:ContextReadFactLink
    let original:AgentValue
    init(request:AgentValue,data:AgentValue,link:ContextReadFactLink,original:AgentValue) {
        this.request=request;this.data=data;this.link=link;this.original=original
    }
}

func hostLoadPeerReadFact111(operations:OperationRuntimePort,configuration:HostPrimitiveConfiguration111,
    context:ToolInvocationContext,call:ToolCall,binding:AgentValue):Result<HostPeerReadFact111> {
    try {
        let envelope=call.arguments.field(CONTEXT_READ_INPUT_FIELD) ?? nullValue()
        if(!httpIntentExactFields(envelope,["schema","data","facts"]) ||
            httpIntentText(envelope,"schema")!="axyndra.context-read-input/v1") {
            return hostPluginResourceError("peer.read_fact_missing","parent has no original completed member read") }
        let links=contextReadFactLinksFromValue(envelope.field("facts").getOrThrow())
        if(links.size!=1 || links[0].runId.value!=context.runId.value ||
            validateContextReadInputProjection(call.arguments,links).isError()) {
            return hostPluginResourceError("peer.read_fact_changed","parent must consume its sole actual same-Run read") }
        let fact=match(operations.loadContextReadFact(links[0].operationId,context.runId)) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
        if(canonicalAgentValue(fact.reference())!=canonicalAgentValue(links[0].toValue()) ||
            fact.origin.ownerNamespace!=configuration.namespace || fact.origin.packageDigest!=configuration.packageDigest ||
            fact.origin.configurationDigest!=configuration.digest ||
            fact.projectionDigest!=contextReadProjectionDigest(context.contextProjection)) {
            return hostPluginResourceError("peer.read_fact_changed","canonical read belongs to another caller or package") }
        let read=match(operations.loadPlan(fact.operationId,context.runId)) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
        if(!isContextReadPlan(read) || !pluginPeerReadAuthority111(read) ||
            canonicalAgentValue(read.canonicalArguments.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
            httpIntentText(binding,"parent_call_id")!=call.callId || httpIntentText(binding,"contribution")!=call.name) {
            return hostPluginResourceError("peer.read_fact_changed","canonical read names another actual original parent") }
        let request=configuration.copyPreparedPlan(read.canonicalArguments)
        let data=configuration.retainObservation(max(1,fact.outputBytes),max(1,fact.outputBytes),{=>fact.output()})
        if(!pluginPeerReadResultValid111(data,request) ||
            canonicalAgentValue(data)!=canonicalAgentValue(envelope.field("data").getOrThrow())) {
            return hostPluginResourceError("peer.read_fact_changed","supplied observation differs from the canonical Receipt") }
        // Fund the full original input before the plain business projection
        // creates even its wrapper. A payload descriptor is not that custody.
        let original=configuration.copyPreparedPlan(call.arguments)
        if(!pluginPeerReadInputMatches111(contextReadBusinessInput(original),request)) {
            return hostPluginResourceError("peer.read_input_changed","original parent input differs from its completed read") }
        let _=configuration.retainObservation(4096,64,{=>nullValue()})
        Result.Ok(HostPeerReadFact111(request,data,links[0],contextReadBusinessInput(original)))
    }catch(_:Exception){hostPluginResourceError("peer.read_fact_changed","original completed member fact could not be verified")}
}
