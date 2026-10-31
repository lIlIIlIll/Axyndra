package agent_host_runtime
import agent_domain.*
import agent_runtime.*
import agent_ports.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

public func hostCanonicalizeWindowDocument(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    configuration:HostPluginDocumentConfiguration,namespace:String,tool:String,generation:UInt64,
    context:ToolInvocationContext,call:ToolCall,binding:AgentValue,started:MonoTime):Result<AgentValue>{
    let envelope=call.arguments.field(CONTEXT_READ_INPUT_FIELD)??nullValue()
    if(!httpIntentExactFields(envelope,["schema","data","facts"]) || httpIntentText(envelope,"schema")!=CONTEXT_READ_SEQUENCE_INPUT_SCHEMA){
        return hostPluginResourceError("plugin.document_window_fact_missing","window preparation requires its complete canonical sequence")}
    match(hostReusePreparedWindowDocument(operations,configuration,tool,context,call,binding,envelope)){
        case Result.Err(error)=>return Result.Err(error)
        case Result.Ok(Some(value))=>
            match(hostDocumentPreparationCurrent(host,configuration,generation,context,binding)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()};return Result.Ok(value)
        case Result.Ok(None)=>()}
    let provider=match(configuration.preparationProvider(tool)){case Some(value)=>value
        case None=>return hostPluginResourceError("plugin.document_preparation_provider_missing","window preparation requires its explicitly configured fixed provider")}
    let owner=match(host.documentDataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let sequence=match(host.allocateDocumentDataSequence()){case Result.Err(error)=>let _=owner.close();return Result.Err(error);case Result.Ok(value)=>value}
    let query=HostDocumentWindowDataPreparation(host,namespace,tool,provider,generation,configuration,context,call,binding,sequence,started)
    owner.run({session=>query.prepare(session)})
}

public func hostReusePreparedWindowDocument(operations: OperationRuntimePort,
    configuration: HostPluginDocumentConfiguration, localTool: String,
    context: ToolInvocationContext, call: ToolCall, binding: AgentValue,
    envelope: AgentValue): Result<?AgentValue> {
    try {
        let links = contextReadFactLinksFromValue(envelope.field("facts").getOrThrow())
        if (links.isEmpty() || links.size>8 || validateContextReadInputProjection(call.arguments, links).isError()) {
            return hostPluginResourceError("plugin.document_fact_changed", "document preparation requires one exact canonical fact") }
        let dataList=envelope.field("data").getOrThrow()
        if(httpIntentText(envelope,"schema")!=CONTEXT_READ_SEQUENCE_INPUT_SCHEMA || dataList.items.size!=links.size){
            return hostPluginResourceError("plugin.document_window_fact_changed","window preparation requires all original outputs")}
        for(index in 0..links.size){
        let fact = match (operations.loadContextReadFact(links[index].operationId, context.runId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (links[index].runId.value != context.runId.value ||
            canonicalAgentValue(fact.reference()) != canonicalAgentValue(links[index].toValue()) ||
            canonicalAgentValue(fact.output()) != canonicalAgentValue(dataList.items[index]) ||
            fact.origin.ownerNamespace != configuration.namespace || fact.origin.packageDigest != configuration.packageDigest ||
            fact.origin.configurationDigest != configuration.digest ||
            fact.origin.projectionDigest != contextReadProjectionDigest(context.contextProjection)) {
            return hostPluginResourceError("plugin.document_fact_changed", "document fact differs from the actual caller and configuration") }
        let read = match (operations.loadPlan(fact.operationId, context.runId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (!isContextReadPlan(read) || !pluginDocumentRowJournalReadAuthority(read) ||
            canonicalAgentValue(read.canonicalArguments.field("binding").getOrThrow()) != canonicalAgentValue(binding) ||
            !pluginDocumentRowJournalReadResultValid(fact.output(), read.canonicalArguments)) {
            return hostPluginResourceError("plugin.document_fact_changed", "document fact belongs to another original read binding") }
        }
        let fact=match(operations.loadContextReadFact(links[0].operationId,context.runId)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let parent: OperationId
        if (fact.origin.parentKind == "direct" && fact.origin.parentOperationId != "") {
            parent = OperationId(fact.origin.parentOperationId)
        } else if (fact.origin.parentKind == "committed" && fact.origin.parentDecisionId != "" && fact.origin.parentScopedCallId != "") {
            parent = OperationId("operation-" + fact.origin.parentDecisionId + "-" + fact.origin.parentScopedCallId)
        } else {
            return hostPluginResourceError("plugin.document_fact_changed", "document fact has no canonical pending parent") }
        let frozen = match (operations.loadPlan(parent, context.runId)) {
            case Result.Err(error) => if (error.code == "operation.not_found") { return Result.Ok(Option<AgentValue>.None) }
                else { return Result.Err(error) }
            case Result.Ok(value) => value }
        if (!isFrozenPluginDocumentRowJournalParentPlan(frozen) ||
            canonicalAgentValue(frozen.canonicalArguments.field("input").getOrThrow()) != canonicalAgentValue(call.arguments) ||
            canonicalAgentValue(frozen.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()) != canonicalAgentValue(binding) ||
            canonicalAgentValue(contextReadFactLinksValue(frozen.contextReadFacts)) != canonicalAgentValue(contextReadFactLinksValue(links))) {
            return hostPluginResourceError("plugin.document_preparation_changed", "prepared document plan differs from the exact original call and fact") }
        for (item in frozen.canonicalArguments.field("host_plan").getOrThrow().field("intents").getOrThrow().items) {
            match (pluginDocumentRowJournalChildArguments(frozen.canonicalArguments, httpIntentText(item, "id"))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (!configuration.permits(localTool, httpIntentText(item, "key"), httpIntentText(item, "mode") == "append")) {
                return hostPluginResourceError("plugin.document_rights_denied", "operator no longer grants the frozen document action") }
        }
        Result.Ok(Some(frozen.canonicalArguments))
    } catch (_: Exception) {
        hostPluginResourceError("plugin.document_preparation_changed", "prepared document metadata is invalid") }
}

public func hostExecuteWindowDocumentRead(host: HostJavaScriptPluginHost, operations: OperationRuntimePort,
    context: ToolInvocationContext, prepared: PreparedToolInvocation,
    observer: ?PluginDocumentReadObserver, payloadArtifacts!: ?HostArtifactStore = None,
    retainPayload!: ?(HostDocumentPayloadReader) -> Unit = None): Result<ToolResult> {
    if (prepared.source.kind!=PreparedInvocationSourceKind.Direct || !isContextReadPlan(prepared.operationPlan) ||
        !pluginDocumentRowJournalReadAuthority(prepared.operationPlan) || prepared.source.contextReadPreparation.isNone()) { return hostPluginResourceError("plugin.document_read_source", "document read requires retained host preparation") }
    let source = match (prepared.source.operationRoot) { case Some(OperationRootSource.Direct(value)) => value
        case _ => return hostPluginResourceError("plugin.document_read_source", "document read requires canonical ContextRead provenance") }
    let origin=match(source.origin){case DirectCallOrigin.ContextRead(value)=>value
        case _=>return hostPluginResourceError("plugin.document_window_source","window read requires its original actual ContextRead Source")}
    if(origin.parentCallItemId=="" || source.threadId.value!=context.sessionId.value ||
        source.runId.value!=context.runId.value || source.epoch!=context.epoch ||
        source.operationId.value!=prepared.operationId.value){
        return hostPluginResourceError("plugin.document_window_source","window read lost its exact canonical parent, Run and operation")}
    let binding = prepared.operationPlan.canonicalArguments.field("binding").getOrThrow()
    let read = prepared.source.contextReadPreparation.getOrThrow()
    match (read.validateBoundary(context, prepared.operationPlan.canonicalArguments)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let configuration = match (host.documentConfiguration(httpIntentText(binding, "namespace"), httpIntentText(binding, "package_digest"))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let generation = UInt64.parse(httpIntentText(binding, "generation"))
    match (hostDocumentPreparationCurrent(host, configuration, generation, context, binding)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    match(operations.verifyContextReadExecuting(source,prepared.operationPlan)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let revoked = AtomicBool(false)
    let registration = match (host.observeServiceRevocation(configuration.namespace, generation, { => revoked.store(true) })) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        let prefix = "plugin." + configuration.namespace + "."
        let name = httpIntentText(binding, "contribution")
        if (!name.startsWith(prefix)) { return hostPluginResourceError("plugin.document_read_scope", "document contribution has another namespace") }
        if(!configuration.readWindows(name[prefix.size..]) || !configuration.payloadReferences(name[prefix.size..]) ||
            !configuration.permits(name[prefix.size..],httpIntentText(prepared.operationPlan.canonicalArguments,"key"),false)){
            return hostPluginResourceError("plugin.document_window_profile_changed","operator did not select this exact journal window")}
        let guard = { =>
            // This callback runs under canonical DB. It must not acquire host
            // or Runtime locks. Revocation is an atomic signal from the owner.
            if (revoked.load() || context.cancellation.isCancelled()) { return hostPluginResourceError<Unit>("plugin.document_read_revoked", "document read owner was revoked") }
            configuration.validateCurrent()
        }
        if(payloadArtifacts.isNone() || retainPayload.isNone()){
            return hostPluginResourceError("plugin.document_payload_owner_missing","window reads require their retained artifact cleanup owner")}
        let owner=payloadArtifacts.getOrThrow().documentWindowPayloadReader(operations,source,prepared.operationPlan,guard,observer)
        // Inert construction is retained by the original executor owner
        // before any writer, file or raw payload can become live.
        retainPayload.getOrThrow()(owner)
        let result=owner.read()
        let cleanup=owner.close()
        match(cleanup){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let value = match (result) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (read.validateBoundary(context, prepared.operationPlan.canonicalArguments)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (revoked.load() || context.cancellation.isCancelled()) { return hostPluginResourceError("plugin.document_read_revoked", "document read revoked before its result was consumed") }
        match(hostDocumentPreparationCurrent(host,configuration,generation,context,binding)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(!pluginDocumentRowJournalReadResultValid(value,prepared.operationPlan.canonicalArguments)){
            return hostPluginResourceError("plugin.document_window_result_changed","window result differs from its exact original request")}
        Result.Ok(ToolResult(prepared.call.callId, value))
    } finally { registration.dispose() }
}

