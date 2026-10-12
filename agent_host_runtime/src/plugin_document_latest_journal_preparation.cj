package agent_host_runtime

import agent_ports.*
import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// Selection is from the current operator profile and actual typed provider.
// These descriptive configuration bytes are never a ReadGrant or Source.
func hostLatestJournalReadConfiguration(host:HostJavaScriptPluginHost,args:AgentValue):Result<HostPluginDocumentJournalReadConfiguration>{
    let contextRead=pluginDocumentContextLatestJournalStreamReadRequestValid(args)
    if(!contextRead && !pluginDocumentLatestJournalStreamReadRequestValid(args)){
        return hostPluginResourceError<HostPluginDocumentJournalReadConfiguration>("plugin.journal_read_request","exact v3 journal read dialect required")}
    let binding=args.field("binding").getOrThrow();let namespace=httpIntentText(binding,"namespace")
    let packageDigest=httpIntentText(binding,"package_digest")
    let contribution=if(contextRead){""}else{httpIntentText(binding,"contribution")}
    let provider:String
    if(contextRead){provider=httpIntentText(binding,"provider")}
    else{
        let prefix="plugin."+namespace+"."
        if(!contribution.startsWith(prefix) || !hostDocumentLogicalName(contribution[prefix.size..])){
            return hostPluginResourceError<HostPluginDocumentJournalReadConfiguration>("plugin.journal_read_contribution","actual published Tool belongs to another namespace")}
        let original=match(host.documentConfiguration(namespace,packageDigest)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        provider=match(original.preparationProvider(contribution[prefix.size..])){case Some(value)=>value
            case None=>return hostPluginResourceError<HostPluginDocumentJournalReadConfiguration>("plugin.journal_read_provider","explicit original preparation provider required")}
    }
    host.documentJournalReadConfiguration(namespace,packageDigest,provider,contribution,contextRead)
}

public func hostLatestJournalPreparationCurrent(host:HostJavaScriptPluginHost,
    configuration:HostPluginDocumentJournalReadConfiguration,generation:UInt64,
    context:ToolInvocationContext,args:AgentValue):Result<Unit>{
    let binding=args.field("binding").getOrThrow()
    let shape=if(configuration.contextRead){pluginDocumentContextLatestJournalStreamReadRequestValid(args)}
        else{pluginDocumentLatestJournalStreamReadRequestValid(args)}
    if(!shape || context.cancellation.isCancelled() ||
        context.sessionId.value!=httpIntentText(binding,"thread_id") || context.runId.value!=httpIntentText(binding,"run_id") ||
        context.epoch.toString()!=binding.field("epoch").getOrThrow().asNumberText() ||
        configuration.namespace!=httpIntentText(binding,"namespace") || configuration.packageDigest!=httpIntentText(binding,"package_digest") ||
        configuration.digest!=httpIntentText(binding,"configuration_digest") || generation.toString()!=httpIntentText(binding,"generation") ||
        contextReadProjectionDigest(context.contextProjection)!=httpIntentText(args,"projection_digest") ||
        !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:configuration.namespace)){
        return hostPluginResourceError<Unit>("plugin.journal_read_scope","journal read lost its exact caller, projection, configuration or capability ceiling")}
    if((configuration.contextRead && configuration.provider!=httpIntentText(binding,"provider")) ||
        (!configuration.contextRead && configuration.contribution!=httpIntentText(binding,"contribution"))){
        return hostPluginResourceError<Unit>("plugin.journal_read_scope","journal read changed its actual selected contribution")}
    let key=httpIntentText(args,"key")
    let access=match(configuration.access(key)){case Some(value)=>value
        case None=>return hostPluginResourceError<Unit>("plugin.journal_read_rights","operator denied this exact logical journal")}
    let view=match(configuration.view(key)){case Some(value)=>value
        case None=>return hostPluginResourceError<Unit>("plugin.journal_read_rights","operator denied this exact latest-view purpose")}
    if(access.digest!=httpIntentText(args,"access_policy_digest") || view.digest!=httpIntentText(args,"view_policy_digest")){
        return hostPluginResourceError<Unit>("plugin.journal_read_policy_changed","strict structural and latest policies differ from the frozen actual operator mapping")}
    match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    if(configuration.contextRead){
        let actual=match(host.contentProviderBinding(configuration.namespace,configuration.provider,false)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(actual.generation!=generation || actual.digest!=configuration.packageDigest || actual.contribution!=configuration.provider){
            return hostPluginResourceError<Unit>("plugin.journal_read_owner_changed","actual typed context provider changed")}
    }else{
        let actual=match(host.policyProviderBinding(configuration.namespace,configuration.provider)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(actual.generation!=generation || actual.digest!=configuration.packageDigest || actual.contribution!=configuration.provider){
            return hostPluginResourceError<Unit>("plugin.journal_read_owner_changed","actual typed preparation provider changed")}
    }
    let actualPackage=match(host.servicePackageData81(configuration.namespace,generation)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    if(actualPackage.contentDigest!=configuration.packageDigest || !actualPackage.requestedCapabilities.contains("document.store")){
        return hostPluginResourceError<Unit>("plugin.journal_read_owner_changed","actual package no longer owns this fixed document capability")}
    Result<Unit>.Ok(())
}

public func hostPrepareLatestJournalRead(host:HostJavaScriptPluginHost,context:ToolInvocationContext,args:AgentValue):Result<AgentValue>{
    let configuration=match(hostLatestJournalReadConfiguration(host,args)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let generation=UInt64.parse(httpIntentText(args.field("binding").getOrThrow(),"generation"))
    match(hostLatestJournalPreparationCurrent(host,configuration,generation,context,args)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    Result<AgentValue>.Ok(parseUnifiedJson(stringifyUnifiedJson(args),maxBytes:16384))
}

public func hostExecuteLatestJournalRead(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    context:ToolInvocationContext,prepared:PreparedToolInvocation,payloadArtifacts:?HostArtifactStore,
    retainPayload:(HostLatestJournalStreamPayloadReader)->Unit):Result<ToolResult>{
    let args=prepared.operationPlan.canonicalArguments
    let contextRead=pluginDocumentContextLatestJournalStreamReadRequestValid(args)
    let authority=if(contextRead){pluginDocumentContextLatestJournalStreamReadAuthority(prepared.operationPlan)}
        else{pluginDocumentLatestJournalStreamReadAuthority(prepared.operationPlan)}
    if(prepared.source.kind!=PreparedInvocationSourceKind.Direct || !isContextReadPlan(prepared.operationPlan) ||
        !authority || prepared.source.contextReadPreparation.isNone() || payloadArtifacts.isNone()){
        return hostPluginResourceError<ToolResult>("plugin.journal_read_source","journal stream requires its actual executing ContextRead and retained payload owner")}
    let source=match(prepared.source.operationRoot){case Some(OperationRootSource.Direct(value))=>value
        case _=>return hostPluginResourceError<ToolResult>("plugin.journal_read_source","canonical direct ContextRead Source required")}
    let origin=match(source.origin){case DirectCallOrigin.ContextRead(value)=>value
        case _=>return hostPluginResourceError<ToolResult>("plugin.journal_read_source","journal stream cannot borrow another direct Source")}
    if((contextRead && (origin.parentCallItemId!="" || origin.parentKind!="" || origin.parentOperationId!="" ||
        origin.parentDecisionId!="" || origin.parentScopedCallId!="")) || (!contextRead && origin.parentCallItemId=="") ||
        source.threadId.value!=context.sessionId.value || source.runId.value!=context.runId.value || source.epoch!=context.epoch ||
        source.operationId.value!=prepared.operationId.value){
        return hostPluginResourceError<ToolResult>("plugin.journal_read_source","strict Tool-parent and parentless Context sources cannot be interchanged")}
    let read=prepared.source.contextReadPreparation.getOrThrow()
    match(read.validateBoundary(context,args)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let configuration=match(hostLatestJournalReadConfiguration(host,args)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let binding=args.field("binding").getOrThrow();let generation=UInt64.parse(httpIntentText(binding,"generation"))
    if(origin.ownerNamespace!=configuration.namespace || origin.packageDigest!=configuration.packageDigest ||
        origin.configurationDigest!=configuration.digest || origin.projectionDigest!=httpIntentText(args,"projection_digest")){
        return hostPluginResourceError<ToolResult>("plugin.journal_read_source","actual Source origin differs from this exact frozen journal request")}
    match(hostLatestJournalPreparationCurrent(host,configuration,generation,context,args)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    match(operations.verifyContextReadExecuting(source,prepared.operationPlan)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let revoked=AtomicBool(false)
    let registration=match(host.observeServiceRevocation(configuration.namespace,generation,{=>revoked.store(true)})){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    try{
        let guard={=>
            // The actual artifact mutex/SQL TX is held: no Host generation or
            // Runtime locks here. Only atomic cancellation, captured caller,
            // and the same actual immutable operator/base-file witnesses.
            if(revoked.load() || context.cancellation.isCancelled() ||
                context.sessionId.value!=httpIntentText(binding,"thread_id") || context.runId.value!=httpIntentText(binding,"run_id") ||
                context.epoch.toString()!=binding.field("epoch").getOrThrow().asNumberText() ||
                !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:configuration.namespace)){
                return hostPluginResourceError<Unit>("plugin.journal_read_revoked","journal stream lost its actual caller or was revoked")}
            configuration.validateTransferWitness()}
        let owner=payloadArtifacts.getOrThrow().latestJournalStreamPayloadReader(operations,source,prepared.operationPlan,guard)
        // Inert reader is registered before any buffer, file or SQL cursor.
        // Failed close stays in the original executor capacity/cleanup owner.
        retainPayload(owner)
        let outcome=owner.read();let cleanup=owner.close()
        match(cleanup){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let value=match(outcome){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(read.validateBoundary(context,args)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(hostLatestJournalPreparationCurrent(host,configuration,generation,context,args)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(operations.verifyContextReadExecuting(source,prepared.operationPlan)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let valid=if(contextRead){pluginDocumentContextLatestJournalStreamReadResultValid(value,args)}
            else{pluginDocumentLatestJournalStreamReadResultValid(value,args)}
        if(!valid){return hostPluginResourceError<ToolResult>("plugin.journal_read_result_changed","exact public stream differs from its actual frozen request")}
        Result<ToolResult>.Ok(ToolResult(prepared.call.callId,value))
    }finally{registration.dispose()}
}
