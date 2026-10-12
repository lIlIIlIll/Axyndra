package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Generic observed-document content selection. The only read happens after
// actual Core admission/approval/Source/handoff, through canonical ContextRead.
func productDocumentContextProviderRead(host:ProductJavaScriptPluginHost,operations:OperationRuntimePort,
    namespace:String,provider:String,before:ActiveRunSnapshot,context:ToolInvocationContext,
    keys:AgentValue,query:AgentValue,invocationId:String,sourceValidity:()->Result<Unit>):Result<ProductContextProviderRead>{
    let binding=match(host.contentProviderBinding(namespace,provider,false)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let configuration=match(host.documentContextConfiguration(namespace,binding.digest,provider)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let lane=match(operations.pluginDocumentLane(before.threadId,before.runId,before.epoch)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let frozen=try{FrozenPluginContentQuery(query,[])}catch(_:Exception){
        return pluginProcessError("context.document_query_invalid","document content query must be bounded immutable data")}
    if(frozen.query.field(CONTEXT_READ_INPUT_FIELD).isSome() || frozen.query.field("_axyndra_context_provider").isSome()){
        return pluginProcessError("context.document_query_invalid","document content caller cannot supply an observed fact")}
    let expectedProjection=contextReadProjectionDigest(before.contextSnapshot)
    let identity=objectValue([ValueField("namespace",textValue(namespace)),ValueField("package_digest",textValue(binding.digest)),
        ValueField("generation",textValue(binding.generation.toString())),ValueField("configuration_digest",textValue(configuration.digest)),
        ValueField("thread_id",textValue(before.threadId.value)),ValueField("lane_id",textValue(lane.value)),
        ValueField("run_id",textValue(before.runId.value)),ValueField("epoch",integerValue(before.epoch)),ValueField("provider",textValue(provider))])
    let request=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_CONTEXT_READ_SCHEMA)),
        ValueField("binding",identity),ValueField("projection_digest",textValue(expectedProjection)),ValueField("keys",keys)])
    if(!pluginDocumentContextReadRequestValid(request)){
        return pluginProcessError("context.document_request_invalid","document content requires exact unique bounded logical keys")}
    for(key in keys.items where !configuration.permits(key.text)){
        return pluginProcessError("context.document_rights_denied","operator did not grant this logical context document")}
    let encoded=stringifyUnifiedJson(request);let frozenQuery=stringifyUnifiedJson(frozen.query)
    let valid={=>
        match(sourceValidity()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        match(configuration.validateCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        if(context.cancellation.isCancelled()){
            return pluginProcessError<Unit>("context.document_selection_withdrawn","document content selection was cancelled")}
        let current=match(host.contentProviderBinding(namespace,provider,false)){
            case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
        if(current.generation!=binding.generation || current.digest!=binding.digest){
            return pluginProcessError<Unit>("context.document_provider_changed","document content provider was revoked or replaced")}
        Result.Ok(())}
    let read=ToolPreparationRead(namespace,binding.digest,configuration.digest,parseUnifiedJson(encoded,maxBytes:16384),
        {actual,facts=>
            match(valid()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            let expected=parseUnifiedJson(encoded,maxBytes:16384)
            if(facts.size!=1 || facts[0].runId.value!=before.runId.value || facts[0].origin.parentCallItemId!="" ||
                facts[0].origin.parentKind!="" || facts[0].origin.parentOperationId!="" ||
                facts[0].origin.ownerNamespace!=namespace || facts[0].origin.packageDigest!=binding.digest ||
                facts[0].origin.configurationDigest!=configuration.digest || facts[0].origin.projectionDigest!=expectedProjection ||
                !pluginDocumentReadResultValid(facts[0].output(),expected)){
                return pluginProcessError<AgentValue>("context.document_fact_invalid","document content requires its exact canonical readonly fact")}
            let fields=ArrayList<ValueField>();for(field in parseUnifiedJson(frozenQuery,maxBytes:65536).fields){fields.add(field)}
            fields.add(ValueField("_axyndra_context_provider",objectValue([
                ValueField("namespace",textValue(namespace)),ValueField("package_digest",textValue(binding.digest)),
                ValueField("generation",textValue(binding.generation.toString())),ValueField("provider",textValue(provider))])))
            fields.add(ValueField(CONTEXT_READ_INPUT_FIELD,objectValue([ValueField("schema",textValue("axyndra.context-read-input/v1")),
                ValueField("data",facts[0].output()),ValueField("facts",contextReadFactLinksValue([facts[0].link()]))])))
            let selected=match(resolveObservedProductPluginContext(host,namespace,provider,objectValue(fields.toArray()),
                before.threadId,[],actual.cancellation,invocationId)){
                case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
            match(valid()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            let owner=namespace+"/context/"+provider;let items=ArrayList<InvocationContextContribution>()
            for(item in before.contextSnapshot.contributions() where item.owner!=owner){items.add(item)}
            for(item in selected.contributions()){
                if(item.owner!=owner){return pluginProcessError<AgentValue>("context.document_owner_invalid","document provider returned a foreign owner")}
                items.add(item)}
            let projection=InvocationContextProjection(contributions:items.toArray())
            Result.Ok(contextSnapshotValue(InvocationContextProjection(contributions:items.toArray(),sourceDigest:
                modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("context",contextSnapshotValue(projection)),
                    ValueField("facts",contextReadFactLinksValue([facts[0].link()]))]))))))
        },boundary:Some({actual,arguments=>
            if(actual.sessionId.value!=before.threadId.value || actual.runId.value!=before.runId.value || actual.epoch!=before.epoch ||
                contextReadProjectionDigest(actual.contextProjection)!=expectedProjection || canonicalAgentValue(arguments)!=canonicalAgentValue(parseUnifiedJson(encoded,maxBytes:16384))){
                return pluginProcessError<Unit>("context.document_binding_invalid","document content lost its original Run or exact request")}
            valid()}))
    match(valid()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    Result.Ok(ProductContextProviderRead(read,valid))
}
