package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.convert.*
import std.sync.*
import agent_extension_runtime.*
import yjson.*
import yjson_support.*

// Full Host checks are outside Artifact/SQL locks. The SQL guard below uses
// only cancellation, the frozen caller and actual immutable profile files.
func hostLivePolicyInputCurrent(host:HostJavaScriptPluginHost,configuration:HostPluginLivePolicyConfiguration,
    generation:UInt64,context:ToolInvocationContext,call:ToolCall,binding:AgentValue):Result<Unit>{
    if(validatePluginDocumentBinding(binding).isError() || context.trustedControl || context.cancellation.isCancelled() ||
        configuration.read.contextRead || configuration.contribution!=call.name ||
        configuration.namespace!=httpIntentText(binding,"namespace") || configuration.packageDigest!=httpIntentText(binding,"package_digest") ||
        configuration.read.digest!=httpIntentText(binding,"configuration_digest") || generation.toString()!=httpIntentText(binding,"generation") ||
        context.sessionId.value!=httpIntentText(binding,"thread_id") || context.runId.value!=httpIntentText(binding,"run_id") ||
        context.epoch.toString()!=binding.field("epoch").getOrThrow().asNumberText() || call.callId!=httpIntentText(binding,"parent_call_id") ||
        call.name!=httpIntentText(binding,"contribution") || !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:configuration.namespace)){
        return hostPluginResourceError("plugin.live_input_scope","live input lost its exact actual caller and read profile")}
    match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    for(provider in [configuration.readProvider,configuration.policyProvider]){
        let actual=match(host.policyProviderBinding(configuration.namespace,provider)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(actual.generation!=generation || actual.digest!=configuration.packageDigest || actual.contribution!=provider){
            return hostPluginResourceError("plugin.live_input_owner_changed","actual typed live input provider changed")}}
    let packageDescriptor=match(host.servicePackageData81(configuration.namespace,generation)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    if(packageDescriptor.contentDigest!=configuration.packageDigest || !packageDescriptor.requestedCapabilities.contains("document.store")){
        return hostPluginResourceError("plugin.live_input_owner_changed","actual package changed its exact document ownership")}
    Result<Unit>.Ok(())
}

// The installed canonicalizer derives bounded binding data from the sole
// actual completed Tool read. While approval is pending, the Store's new
// data-only path requires its existing prepared plan and exact original pin.
// Source and effect admission still require the original full running chain.
func hostCanonicalizePluginLivePolicy(host:HostJavaScriptPluginHost,configuration:HostPluginLivePolicyConfiguration,
    generation:UInt64,implementation:String,schemaDigest:String,context:ToolInvocationContext,call:ToolCall):Result<AgentValue>{
    if(call.arguments.unifiedKind!=ValueKind.Object || context.trustedControl || context.cancellation.isCancelled() ||
        call.name!=configuration.contribution || !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:configuration.namespace)){
        return hostPluginResourceError("plugin.live_input_scope","live input requires its actual current original Tool caller")}
    match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let revoked=AtomicBool(false)
    let registration=match(host.observeServiceRevocation(configuration.namespace,generation,{=>revoked.store(true)})){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    try{
        let guard:()->Result<Unit>={=>
            if(revoked.load() || context.cancellation.isCancelled() ||
                !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:configuration.namespace)){
                return hostPluginResourceError<Unit>("plugin.live_input_cancelled","same live input caller was cancelled or revoked")}
            configuration.validateTransferWitness()}
        let session=match(host.documentDataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let prepared=session.run({owner=>
            let request=match(owner.livePolicyInputReadRequest(call.name,call.arguments,guard)){
                case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
            if(!pluginDocumentLatestJournalStreamReadRequestValid(request) ||
                httpIntentText(request,"key")!=configuration.key ||
                httpIntentText(request,"projection_digest")!=contextReadProjectionDigest(context.contextProjection)){
                return hostPluginResourceError<AgentValue>("plugin.live_input_read_changed","live input lost its exact actual read request")}
            let binding=request.field("binding").getOrThrow()
            if(httpIntentText(binding,"implementation_fingerprint")!=implementation || httpIntentText(binding,"schema_digest")!=schemaDigest){
                return hostPluginResourceError<AgentValue>("plugin.live_input_binding_changed","original Tool implementation or schema changed")}
            match(hostLivePolicyInputCurrent(host,configuration,generation,context,call,binding)){
                case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            match(hostLatestJournalPreparationCurrent(host,configuration.read,generation,context,request)){
                case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            hostFreezePluginLivePolicyInputOwned(owner,configuration,call,binding,guard)})
        match(prepared){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>
            match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            match(hostLivePolicyInputCurrent(host,configuration,generation,context,call,value.field("host_plan").getOrThrow().field("binding").getOrThrow())){
                case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            Result<AgentValue>.Ok(value)}
    }finally{registration.dispose()}
}

private func hostFreezePluginLivePolicyInputOwned(owner:HostDocumentDataSession,configuration:HostPluginLivePolicyConfiguration,
    call:ToolCall,binding:AgentValue,guard:()->Result<Unit>):Result<AgentValue>{
    let envelope=call.arguments.field(CONTEXT_READ_INPUT_FIELD)??nullValue()
    if(!httpIntentExactFields(envelope,["schema","data","facts"]) ||
        !["axyndra.context-read-input/v1",CONTEXT_READ_SEQUENCE_INPUT_SCHEMA].contains(httpIntentText(envelope,"schema"))){
        return hostPluginResourceError("plugin.live_input_fact","live input requires its complete private canonical fact envelope")}
    let links=try{contextReadFactLinksFromValue(envelope.field("facts").getOrThrow())}catch(_:Exception){
        return hostPluginResourceError<AgentValue>("plugin.live_input_fact","live input fact links are malformed")}
    if(links.size!=1 || validateContextReadInputProjection(call.arguments,links).isError()){
        return hostPluginResourceError("plugin.live_input_fact","live input requires its sole complete actual Tool read")}
    match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
    let reference=match(owner.describeLivePolicyInput(call.arguments,guard)){
        case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
    let parent=objectValue([ValueField("input",call.arguments),
        ValueField("configuration",objectValue([ValueField("digest",textValue(configuration.digest))])),
        ValueField("host_plan",objectValue([ValueField("version",textValue(PLUGIN_LIVE_POLICY_PARENT_SCHEMA)),
            ValueField("binding",binding),ValueField("input_payload",reference),
            ValueField("effect_ceiling",configuration.ceiling()),ValueField("initial_read_facts",contextReadFactLinksValue(links)),
            ValueField("policy_provider",textValue(configuration.policyProvider)),ValueField("data_schema",textValue(configuration.dataSchema))]))])
    if(!pluginLivePolicyParentValueValid(parent)){return hostPluginResourceError<AgentValue>("plugin.live_input_parent","fixed live parent shape is invalid")}
    let reused=match(owner.reuseLivePolicyInput(parent,guard)){
        case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
    if(!reused){
        let writer=match(owner.writeLivePolicyInput(call.arguments,guard)){
            case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
        let actual=writer.completedArtifact()
        if(actual.bytes!=Int64.parse(reference.field("bytes").getOrThrow().asNumberText()) || actual.sha256!=httpIntentText(reference,"sha256")){
            return hostPluginResourceError<AgentValue>("plugin.live_input_changed","original complete input changed during its paid serialization")}
        match(owner.retainLivePolicyInput(parent,writer,guard)){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}}
    match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
    Result<AgentValue>.Ok(parent)
}
