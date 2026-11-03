package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

public func hostDocumentContextPreparationCurrent(host:HostJavaScriptPluginHost,
    configuration:HostPluginDocumentContextConfiguration,generation:UInt64,
    context:ToolInvocationContext,binding:AgentValue):Result<Unit>{
    if(context.cancellation.isCancelled() || !pluginDocumentContextBindingValid(binding) ||
        context.sessionId.value!=httpIntentText(binding,"thread_id") || context.runId.value!=httpIntentText(binding,"run_id") ||
        context.epoch!=Int64.parse(binding.field("epoch").getOrThrow().asNumberText()) ||
        configuration.namespace!=httpIntentText(binding,"namespace") || configuration.packageDigest!=httpIntentText(binding,"package_digest") ||
        configuration.digest!=httpIntentText(binding,"configuration_digest") || configuration.provider!=httpIntentText(binding,"provider") ||
        generation.toString()!=httpIntentText(binding,"generation") ||
        !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:configuration.namespace)){
        return hostPluginResourceError("plugin.document_context_scope","document context read lost its actual Run, configuration or capability ceiling")}
    match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let actual=match(host.contentProviderBinding(configuration.namespace,configuration.provider,false)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let actualPackage=match(host.servicePackageData81(configuration.namespace,generation)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    if(actual.generation!=generation || actual.digest!=configuration.packageDigest ||
        actualPackage.contentDigest!=configuration.packageDigest || !actualPackage.requestedCapabilities.contains("document.store")){
        return hostPluginResourceError("plugin.document_context_owner_stale","actual context provider generation or document package changed")}
    Result.Ok(())
}

public func hostPrepareDocumentContextRead(host:HostJavaScriptPluginHost,context:ToolInvocationContext,
    args:AgentValue):Result<AgentValue>{
    if(!pluginDocumentContextReadRequestValid(args) ||
        httpIntentText(args,"projection_digest")!=contextReadProjectionDigest(context.contextProjection)){
        return hostPluginResourceError("plugin.document_context_request","document context requires its exact current projection")}
    let binding=args.field("binding").getOrThrow()
    let configuration=match(host.documentContextConfiguration(httpIntentText(binding,"namespace"),httpIntentText(binding,"package_digest"),httpIntentText(binding,"provider"))){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(hostDocumentContextPreparationCurrent(host,configuration,UInt64.parse(httpIntentText(binding,"generation")),context,binding)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    for(key in args.field("keys").getOrThrow().items where !configuration.permits(key.text)){
        return hostPluginResourceError("plugin.document_context_rights_denied","operator denied this logical context document")}
    Result.Ok(parseUnifiedJson(stringifyUnifiedJson(args),maxBytes:16384))
}

public func hostExecuteDocumentContextRead(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    context:ToolInvocationContext,prepared:PreparedToolInvocation,observer:?PluginDocumentReadObserver):Result<ToolResult>{
    if(!isContextReadPlan(prepared.operationPlan) || !pluginDocumentReadAuthority(prepared.operationPlan) ||
        !pluginDocumentContextReadRequestValid(prepared.operationPlan.canonicalArguments) || prepared.source.contextReadPreparation.isNone()){
        return hostPluginResourceError("plugin.document_context_source","document context requires its retained actual ContextRead preparation")}
    let source=match(prepared.source.operationRoot){case Some(OperationRootSource.Direct(value))=>value
        case _=>return hostPluginResourceError("plugin.document_context_source","document context requires the actual canonical direct Source")}
    let origin=match(source.origin){case DirectCallOrigin.ContextRead(value)=>value
        case _=>return hostPluginResourceError("plugin.document_context_source","document context cannot borrow a different direct Source")}
    if(origin.parentCallItemId!="" || origin.parentKind!="" || origin.parentOperationId!=""){
        return hostPluginResourceError("plugin.document_context_source","initial document context cannot borrow a Tool or Derived parent")}
    let read=prepared.source.contextReadPreparation.getOrThrow();let args=prepared.operationPlan.canonicalArguments
    match(read.validateBoundary(context,args)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let binding=args.field("binding").getOrThrow();let generation=UInt64.parse(httpIntentText(binding,"generation"))
    let configuration=match(host.documentContextConfiguration(httpIntentText(binding,"namespace"),httpIntentText(binding,"package_digest"),httpIntentText(binding,"provider"))){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(hostDocumentContextPreparationCurrent(host,configuration,generation,context,binding)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    for(key in args.field("keys").getOrThrow().items where !configuration.permits(key.text)){
        return hostPluginResourceError("plugin.document_context_rights_denied","operator denied this logical context document")}
    let revoked=AtomicBool(false)
    let registration=match(host.observeServiceRevocation(configuration.namespace,generation,{=>revoked.store(true)})){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    try{
        let guard={=>if(revoked.load() || context.cancellation.isCancelled()){
                return hostPluginResourceError<Unit>("plugin.document_context_revoked","document context was revoked before consumption")}
            configuration.validateCurrent()}
        let value=match(operations.readPluginDocuments(source,prepared.operationPlan,guard,observer)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(read.validateBoundary(context,args)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(hostDocumentContextPreparationCurrent(host,configuration,generation,context,binding)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(revoked.load() || context.cancellation.isCancelled()){
            return hostPluginResourceError("plugin.document_context_revoked","document context was revoked before its result was returned")}
        Result.Ok(ToolResult(prepared.call.callId,value))
    }finally{registration.dispose()}
}
