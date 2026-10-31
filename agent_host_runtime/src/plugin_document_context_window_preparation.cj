package agent_host_runtime

import agent_ports.*
import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

public func hostDocumentContextWindowPreparationCurrent(host:HostJavaScriptPluginHost,
    configuration:HostPluginDocumentContextWindowConfiguration,generation:UInt64,
    context:ToolInvocationContext,binding:AgentValue):Result<Unit>{
    if(context.cancellation.isCancelled() || !pluginDocumentContextBindingValid(binding) ||
        context.sessionId.value!=httpIntentText(binding,"thread_id") || context.runId.value!=httpIntentText(binding,"run_id") ||
        binding.field("epoch").getOrThrow().asNumberText()!=context.epoch.toString() ||
        configuration.namespace!=httpIntentText(binding,"namespace") || configuration.packageDigest!=httpIntentText(binding,"package_digest") ||
        configuration.digest!=httpIntentText(binding,"configuration_digest") || configuration.provider!=httpIntentText(binding,"provider") ||
        generation.toString()!=httpIntentText(binding,"generation") ||
        !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:configuration.namespace)){
        return hostPluginResourceError("plugin.document_context_window_scope","document window lost its actual Run, configuration or capability ceiling")}
    match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let actual=match(host.contentProviderBinding(configuration.namespace,configuration.provider,false)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let actualPackage=match(host.servicePackageData81(configuration.namespace,generation)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    if(actual.generation!=generation || actual.digest!=configuration.packageDigest ||
        actualPackage.contentDigest!=configuration.packageDigest || !actualPackage.requestedCapabilities.contains("document.store")){
        return hostPluginResourceError("plugin.document_context_window_owner_stale","document window provider generation or package changed")}
    Result.Ok(())
}

public func hostPrepareDocumentContextWindowRead(host:HostJavaScriptPluginHost,
    context:ToolInvocationContext,args:AgentValue):Result<AgentValue>{
    if(!pluginDocumentContextWindowReadRequestValid(args) ||
        httpIntentText(args,"projection_digest")!=contextReadProjectionDigest(context.contextProjection)){
        return hostPluginResourceError("plugin.document_context_window_request","document window requires its exact current projection")}
    let binding=args.field("binding").getOrThrow()
    let configuration=match(host.documentContextWindowConfiguration(httpIntentText(binding,"namespace"),
        httpIntentText(binding,"package_digest"),httpIntentText(binding,"provider"))){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(hostDocumentContextWindowPreparationCurrent(host,configuration,UInt64.parse(httpIntentText(binding,"generation")),context,binding)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    if(!configuration.permits(httpIntentText(args,"key"))){
        return hostPluginResourceError("plugin.document_context_window_rights_denied","operator denied this logical context window")}
    Result.Ok(parseUnifiedJson(stringifyUnifiedJson(args),maxBytes:16384))
}

public func hostExecuteDocumentContextWindowRead(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    context:ToolInvocationContext,prepared:PreparedToolInvocation,
    payloadArtifacts!:?HostArtifactStore=None,
    retainPayload!:?((HostDocumentPayloadReader)->Unit)=None):Result<ToolResult>{
    let args=prepared.operationPlan.canonicalArguments
    if(prepared.source.kind!=PreparedInvocationSourceKind.Direct || !isContextReadPlan(prepared.operationPlan) ||
        !pluginDocumentContextWindowReadAuthority(prepared.operationPlan) ||
        prepared.source.contextReadPreparation.isNone() || payloadArtifacts.isNone() || retainPayload.isNone()){
        return hostPluginResourceError("plugin.document_context_window_source","document window requires its actual ContextRead and retained paid payload owner")}
    let source=match(prepared.source.operationRoot){case Some(OperationRootSource.Direct(value))=>value
        case _=>return hostPluginResourceError("plugin.document_context_window_source","document window requires its actual canonical direct Source")}
    let origin=match(source.origin){case DirectCallOrigin.ContextRead(value)=>value
        case _=>return hostPluginResourceError("plugin.document_context_window_source","document window cannot borrow another direct Source")}
    if(origin.parentCallItemId!="" || origin.parentKind!="" || origin.parentOperationId!="" ||
        origin.parentDecisionId!="" || origin.parentScopedCallId!="" ||
        source.threadId.value!=context.sessionId.value || source.runId.value!=context.runId.value ||
        source.epoch!=context.epoch || source.operationId.value!=prepared.operationId.value){
        return hostPluginResourceError("plugin.document_context_window_source","document window lost its exact parentless Run and operation")}
    let read=prepared.source.contextReadPreparation.getOrThrow()
    match(read.validateBoundary(context,args)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let binding=args.field("binding").getOrThrow();let generation=UInt64.parse(httpIntentText(binding,"generation"))
    let configuration=match(host.documentContextWindowConfiguration(httpIntentText(binding,"namespace"),
        httpIntentText(binding,"package_digest"),httpIntentText(binding,"provider"))){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(hostDocumentContextWindowPreparationCurrent(host,configuration,generation,context,binding)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    if(!configuration.permits(httpIntentText(args,"key"))){
        return hostPluginResourceError("plugin.document_context_window_rights_denied","operator denied this logical context window")}
    match(operations.verifyContextReadExecuting(source,prepared.operationPlan)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let revoked=AtomicBool(false)
    let registration=match(host.observeServiceRevocation(configuration.namespace,generation,{=>revoked.store(true)})){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    try{
        let guard={=>if(revoked.load() || context.cancellation.isCancelled()){
                return hostPluginResourceError<Unit>("plugin.document_context_window_revoked","document window was revoked before consumption")}
            if(context.sessionId.value!=httpIntentText(binding,"thread_id") || context.runId.value!=httpIntentText(binding,"run_id") ||
                context.epoch.toString()!=binding.field("epoch").getOrThrow().asNumberText() ||
                !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:configuration.namespace)){
                return hostPluginResourceError<Unit>("plugin.document_context_window_scope","document window lost its captured caller scope")}
            // The artifact and SQL gates are already held here. This pure
            // file-witness check acquires neither Host generation nor Runtime
            // locks. Full actual Source/provider checks surround the reader.
            configuration.validateCurrent()}
        let reader=payloadArtifacts.getOrThrow().documentWindowPayloadReader(operations,source,prepared.operationPlan,guard,Option<PluginDocumentReadObserver>.None)
        // Inert construction precedes retention; every file/buffer read follows
        // retention by the existing executor cleanup owner and its capacity.
        retainPayload.getOrThrow()(reader)
        let outcome=reader.read()
        let cleanup=reader.close()
        match(cleanup){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let value=match(outcome){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(read.validateBoundary(context,args)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(hostDocumentContextWindowPreparationCurrent(host,configuration,generation,context,binding)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(!pluginDocumentContextWindowReadResultValid(value,args)){
            return hostPluginResourceError("plugin.document_context_window_result","document window result differs from its exact original request")}
        Result.Ok(ToolResult(prepared.call.callId,value))
    }finally{registration.dispose()}
}
