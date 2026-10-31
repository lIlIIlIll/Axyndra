package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

public func hostPrepareDocumentRead(host: HostJavaScriptPluginHost, context: ToolInvocationContext,
    args: AgentValue): Result<AgentValue> {
    if(httpIntentText(args,"schema")==PLUGIN_DOCUMENT_ROW_JOURNAL_READ_SCHEMA){
        return hostPrepareWindowDocumentRead(host,context,args)}
    if(pluginDocumentContextReadRequestValid(args)){return hostPrepareDocumentContextRead(host,context,args)}
    if (!pluginDocumentReadRequestValid(args) || httpIntentText(args, "projection_digest") != contextReadProjectionDigest(context.contextProjection)) {
        return hostPluginResourceError("plugin.document_read_request", "document read requires the exact current context projection") }
    let binding = args.field("binding").getOrThrow()
    let configuration = match (host.documentConfiguration(httpIntentText(binding, "namespace"), httpIntentText(binding, "package_digest"))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    match (hostDocumentPreparationCurrent(host, configuration, UInt64.parse(httpIntentText(binding, "generation")), context, binding)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let prefix = "plugin." + configuration.namespace + "."
    let name = httpIntentText(binding, "contribution")
    if (!name.startsWith(prefix)) { return hostPluginResourceError("plugin.document_read_scope", "document contribution has another namespace") }
    if ((httpIntentText(args, "schema") == PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA) != configuration.payloadReferences(name[prefix.size..])) {
        return hostPluginResourceError("plugin.document_payload_profile_changed", "document representation differs from its exact operator profile") }
    for (key in args.field("keys").getOrThrow().items where !configuration.permits(name[prefix.size..], key.text, false)) {
        return hostPluginResourceError("plugin.document_rights_denied", "operator did not grant this document read") }
    Result.Ok(parseUnifiedJson(stringifyUnifiedJson(args), maxBytes: 16384))
}

public func hostDocumentPreparationCurrent(host: HostJavaScriptPluginHost, configuration: HostPluginDocumentConfiguration,
    generation: UInt64, context: ToolInvocationContext, binding: AgentValue): Result<Unit> {
    if (context.cancellation.isCancelled()) { return Result.Err(AgentError(AgentErrorKind.Cancelled,
        "plugin.document_cancelled", "document preparation was cancelled")) }
    if (validatePluginDocumentBinding(binding).isError() || context.sessionId.value != httpIntentText(binding, "thread_id") ||
        context.runId.value != httpIntentText(binding, "run_id") || context.epoch.toString() != binding.field("epoch").getOrThrow().asNumberText() ||
        configuration.namespace != httpIntentText(binding, "namespace") || configuration.packageDigest != httpIntentText(binding, "package_digest") ||
        configuration.digest != httpIntentText(binding, "configuration_digest") || generation.toString() != httpIntentText(binding, "generation") ||
        !context.capabilities.allows(CapabilityKind.ExtensionInvoke, resource: configuration.namespace)) {
        return hostPluginResourceError("plugin.document_preparation_scope", "document preparation lost its original caller or capability ceiling") }
    match (configuration.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let current = match (host.servicePackageData81(configuration.namespace, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (current.contentDigest != configuration.packageDigest || !current.requestedCapabilities.contains("document.store")) {
        return hostPluginResourceError("plugin.document_owner_stale", "document package no longer owns the selected contribution") }
    Result.Ok(())
}

public func hostDocumentBinding(configuration: HostPluginDocumentConfiguration, generation: UInt64,
    implementation: String, schemaDigest: String, context: ToolInvocationContext, call: ToolCall, lane: LaneId): AgentValue {
    objectValue([ValueField("namespace", textValue(configuration.namespace)), ValueField("package_digest", textValue(configuration.packageDigest)),
        ValueField("generation", textValue(generation.toString())), ValueField("configuration_digest", textValue(configuration.digest)),
        ValueField("thread_id", textValue(context.sessionId.value)), ValueField("lane_id", textValue(lane.value)),
        ValueField("run_id", textValue(context.runId.value)), ValueField("epoch", integerValue(context.epoch)),
        ValueField("parent_call_id", textValue(call.callId)), ValueField("contribution", textValue(call.name)),
        ValueField("implementation_fingerprint", textValue(implementation)), ValueField("schema_digest", textValue(schemaDigest))])
}

public func hostQueryDocumentPreparation(host: HostJavaScriptPluginHost, namespace: String, localTool: String, generation: UInt64,
    configuration: HostPluginDocumentConfiguration, context: ToolInvocationContext, call: ToolCall): Result<HostJavaScriptPluginInvocationResult> {
    match (configuration.preparationProvider(localTool)) {
        case Some(provider) => return hostQueryDocumentPreparationProvider(host, namespace, localTool, provider,
            generation, configuration, context, call)
        case None => () }
    host.invoke(namespace, localTool, stringifyUnifiedJson(objectValue([ValueField("input", call.arguments)])),
        identity: JavaScriptHostInvocationIdentity(threadId: context.sessionId.value, runId: context.runId.value,
            epoch: context.epoch, operationId: "", callId: call.callId, kind: "prepare"),
        cancellation: context.cancellation, processLimits: context.budget.processLimits, timeoutMillis: 5000,
        expectedInstanceGeneration: generation, authorityScope: "pure-document:" + configuration.digest)
}

public func hostPreparePluginDocumentRead(host: HostJavaScriptPluginHost, operations: OperationRuntimePort,
    namespace: String, localTool: String, generation: UInt64, implementation: String, schemaDigest: String,
    context: ToolInvocationContext, call: ToolCall): Result<?ToolPreparationRead> {
    if (call.arguments.field(CONTEXT_READ_INPUT_FIELD).isSome()) {
        return hostPluginResourceError("plugin.document_preparation_reentered", "document preread cannot accept a supplied fact envelope") }
    let packageDescriptor = match (host.servicePackageData81(namespace, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let configuration = match (host.documentConfiguration(namespace, packageDescriptor.contentDigest)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let lane = match (operations.pluginDocumentLane(ThreadId(context.sessionId.value), context.runId, context.epoch)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let binding = hostDocumentBinding(configuration, generation, implementation, schemaDigest, context, call, lane)
    match (hostDocumentPreparationCurrent(host, configuration, generation, context, binding)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let response = match (hostQueryDocumentPreparation(host, namespace, localTool, generation, configuration, context, call)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        if(configuration.readWindows(localTool)){
            return hostCreateWindowDocumentRead(host,operations,configuration,namespace,localTool,generation,implementation,schemaDigest,
                context,call,binding,response)}
        if (response.isError || !httpIntentExactFields(response.value, ["document_read"]) ||
            !httpIntentExactFields(response.value.field("document_read").getOrThrow(), ["keys"])) {
            return hostPluginResourceError("plugin.document_read_request", "document tool must first request its logical document keys") }
        let request = objectValue([ValueField("schema", textValue(if (configuration.payloadReferences(localTool)) {
            PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA } else { PLUGIN_DOCUMENT_READ_SCHEMA })), ValueField("binding", binding),
            ValueField("projection_digest", textValue(contextReadProjectionDigest(context.contextProjection))),
            ValueField("keys", response.value.field("document_read").getOrThrow().field("keys").getOrThrow())])
        if (!pluginDocumentReadRequestValid(request)) { return hostPluginResourceError("plugin.document_read_request", "document preread has invalid keys") }
        for (key in request.field("keys").getOrThrow().items where !configuration.permits(localTool, key.text, false)) {
            return hostPluginResourceError("plugin.document_rights_denied", "operator did not grant the requested document read") }
        let frozenRequest = stringifyUnifiedJson(request)
        let original = stringifyUnifiedJson(call.arguments)
        let frozenBinding = stringifyUnifiedJson(binding)
        match (hostDocumentPreparationCurrent(host, configuration, generation, context, binding)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(Some(ToolPreparationRead(namespace, configuration.packageDigest, configuration.digest,
            parseUnifiedJson(frozenRequest, maxBytes: 16384), { actual, facts =>
                let expected = parseUnifiedJson(frozenRequest, maxBytes: 16384)
                match (hostDocumentPreparationCurrent(host, configuration, generation, actual, parseUnifiedJson(frozenBinding, maxBytes: 16384))) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                if (facts.size != 1 || facts[0].runId.value != actual.runId.value || facts[0].origin.ownerNamespace != namespace ||
                    facts[0].origin.packageDigest != configuration.packageDigest || facts[0].origin.configurationDigest != configuration.digest ||
                    facts[0].projectionDigest != httpIntentText(expected, "projection_digest")) {
                    return hostPluginResourceError("plugin.document_fact_changed", "document continuation requires its actual canonical read fact") }
                let data = facts[0].output()
                if (!pluginDocumentReadResultValid(data, expected)) { return hostPluginResourceError("plugin.document_fact_changed", "document fact differs from its frozen logical request") }
                let input = parseUnifiedJson(original, maxBytes: 8388608)
                let fields = ArrayList<ValueField>(input.fields.toArray())
                fields.add(ValueField(CONTEXT_READ_INPUT_FIELD, objectValue([ValueField("schema", textValue("axyndra.context-read-input/v1")),
                    ValueField("data", data), ValueField("facts", contextReadFactLinksValue([facts[0].link()]))])))
                Result.Ok(objectValue(fields.toArray()))
            }, boundary: Some({ actual, arguments =>
                if (canonicalAgentValue(arguments) != canonicalAgentValue(parseUnifiedJson(frozenRequest, maxBytes: 16384)) ||
                    contextReadProjectionDigest(actual.contextProjection) != httpIntentText(arguments, "projection_digest")) {
                    return hostPluginResourceError("plugin.document_read_changed", "document read lost its retained preparation") }
                hostDocumentPreparationCurrent(host, configuration, generation, actual, parseUnifiedJson(frozenBinding, maxBytes: 16384))
            }))))
    } finally { response.releasePayload() }
}

public func hostCanonicalizePluginDocument(host: HostJavaScriptPluginHost, operations: OperationRuntimePort,
    namespace: String, localTool: String, generation: UInt64, implementation: String, schemaDigest: String,
    context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
    let originalStarted=MonoTime.now()
    let packageDescriptor = match (host.servicePackageData81(namespace, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let configuration = match (host.documentConfiguration(namespace, packageDescriptor.contentDigest)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let lane = match (operations.pluginDocumentLane(ThreadId(context.sessionId.value), context.runId, context.epoch)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let binding = hostDocumentBinding(configuration, generation, implementation, schemaDigest, context, call, lane)
    match (hostDocumentPreparationCurrent(host, configuration, generation, context, binding)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if(configuration.readWindows(localTool)){
        return hostCanonicalizeWindowDocument(host,operations,configuration,namespace,localTool,generation,context,call,binding,originalStarted)}
    // ToolPipeline verifies this private envelope against canonical fact links
    // before this callback; the Store repeats the same parent/source checks.
    let envelope = call.arguments.field(CONTEXT_READ_INPUT_FIELD) ?? nullValue()
    if (!httpIntentExactFields(envelope, ["schema", "data", "facts"])) {
        return hostPluginResourceError("plugin.document_fact_missing", "document preparation requires its completed canonical preread") }
    let data = envelope.field("data").getOrThrow()
    match (hostReusePreparedPluginDocument(operations, configuration, localTool, context, call, binding, envelope)) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(Some(arguments)) =>
            match (hostDocumentPreparationCurrent(host, configuration, generation, context, binding)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            return Result.Ok(arguments)
        case Result.Ok(None) => () }
    if(configuration.payloadReferences(localTool)){
        if(httpIntentText(data,"schema")!=PLUGIN_DOCUMENT_PAYLOAD_READ_RESULT_SCHEMA || data.field("documents").isNone()){
            return hostPluginResourceError("plugin.document_fact_missing","public payload preparation requires its exact compact canonical observation")}
        let provider=match(configuration.preparationProvider(localTool)){case Some(value)=>value
            case None=>return hostPluginResourceError("plugin.document_preparation_provider_missing","public payloads require a pure preparation Provider")}
        let owner=match(host.documentDataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let sequence=match(host.allocateDocumentDataSequence()){case Result.Err(error)=>let _=owner.close();return Result.Err(error);case Result.Ok(value)=>value}
        let query=HostDocumentDataPreparation(host,namespace,localTool,provider,generation,configuration,context,call,binding,sequence,originalStarted)
        return owner.run({session=>query.prepare(session)})
    }
    if (httpIntentText(data, "schema") != PLUGIN_DOCUMENT_READ_RESULT_SCHEMA || data.field("documents").isNone()) {
        return hostPluginResourceError("plugin.document_fact_missing", "document preparation has no document snapshot") }
    let response = match (hostQueryDocumentPreparation(host, namespace, localTool, generation, configuration, context, call)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        if (response.isError || !hostApplicationPlanObjectShape(response.value, ["intents", "user_control"], ["intents"])) {
            return hostPluginResourceError("plugin.document_prepare_rejected", "document tool did not return a pure mutation proposal") }
        let proposals = response.value.field("intents").getOrThrow()
        if (proposals.unifiedKind != ValueKind.List || proposals.items.isEmpty() || proposals.items.size > 8) {
            return hostPluginResourceError("plugin.document_prepare_rejected", "document proposal count is invalid") }
        let intents = ArrayList<AgentValue>()
        for (proposal in proposals.items) {
            if (!httpIntentExactFields(proposal, ["id", "key", "mode", "next_json"])) {
                return hostPluginResourceError("plugin.document_prepare_rejected", "worker cannot provide expected data or scope bindings") }
            let key = httpIntentText(proposal, "key")
            let write = httpIntentText(proposal, "mode") == "compare_exchange"
            if (!configuration.permits(localTool, key, write)) { return hostPluginResourceError("plugin.document_rights_denied", "operator did not grant this exact document action") }
            var expected: ?AgentValue = None
            for (item in data.field("documents").getOrThrow().items where httpIntentText(item, "key") == key) { expected = Some(item) }
            if (expected.isNone()) { return hostPluginResourceError("plugin.document_unobserved", "document intent must use a key read by this exact parent") }
            let prior = expected.getOrThrow()
            intents.add(objectValue([ValueField("id", proposal.field("id").getOrThrow()), ValueField("key", textValue(key)),
                ValueField("mode", proposal.field("mode").getOrThrow()), ValueField("expected_revision", prior.field("revision").getOrThrow()),
                ValueField("expected_json", prior.field("json").getOrThrow()), ValueField("expected_sha256", prior.field("sha256").getOrThrow()),
                ValueField("next_json", proposal.field("next_json").getOrThrow())]))
        }
        let hostFields = ArrayList<ValueField>([ValueField("version", textValue(PLUGIN_DOCUMENT_PARENT_SCHEMA)),
            ValueField("binding", binding), ValueField("intents", listValue(intents.toArray()))])
        match (configuration.toolPayloadLimits(localTool)) {
            case Some(profile) => hostFields.add(ValueField("tool_payload_limits", profile.value()))
            case None => () }
        let result = objectValue([ValueField("input", call.arguments), ValueField("configuration", objectValue([])),
            ValueField("host_plan", objectValue(hostFields.toArray()))])
        for (item in intents) { match (pluginDocumentChildArguments(result, httpIntentText(item, "id"))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () } }
        match (hostDocumentPreparationCurrent(host, configuration, generation, context, binding)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (freezeHostDocumentPreparation(context, call, result, response.value.field("user_control"))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(result)
    } finally { response.releasePayload() }
}


// Revalidation uses the one durable proposal that was actually prepared. It
// cannot rerun a Provider, stage another payload or select another user control.
// Pipeline compares the complete normalized plan; Store independently repeats
// source/fact/current-document/pin checks before execution and handoff.
public func hostReusePreparedPluginDocument(operations: OperationRuntimePort,
    configuration: HostPluginDocumentConfiguration, localTool: String,
    context: ToolInvocationContext, call: ToolCall, binding: AgentValue,
    envelope: AgentValue): Result<?AgentValue> {
    try {
        let links = contextReadFactLinksFromValue(envelope.field("facts").getOrThrow())
        if (links.size != 1 || validateContextReadInputProjection(call.arguments, links).isError()) {
            return hostPluginResourceError("plugin.document_fact_changed", "document preparation requires one exact canonical fact") }
        let fact = match (operations.loadContextReadFact(links[0].operationId, context.runId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (links[0].runId.value != context.runId.value ||
            canonicalAgentValue(fact.reference()) != canonicalAgentValue(links[0].toValue()) ||
            canonicalAgentValue(fact.output()) != canonicalAgentValue(envelope.field("data").getOrThrow()) ||
            fact.origin.ownerNamespace != configuration.namespace || fact.origin.packageDigest != configuration.packageDigest ||
            fact.origin.configurationDigest != configuration.digest ||
            fact.origin.projectionDigest != contextReadProjectionDigest(context.contextProjection)) {
            return hostPluginResourceError("plugin.document_fact_changed", "document fact differs from the actual caller and configuration") }
        let read = match (operations.loadPlan(fact.operationId, context.runId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (!isContextReadPlan(read) || !pluginDocumentReadAuthority(read) ||
            canonicalAgentValue(read.canonicalArguments.field("binding").getOrThrow()) != canonicalAgentValue(binding) ||
            !pluginDocumentReadResultValid(fact.output(), read.canonicalArguments)) {
            return hostPluginResourceError("plugin.document_fact_changed", "document fact belongs to another original read binding") }
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
        if (!isFrozenPluginDocumentParentPlan(frozen) ||
            canonicalAgentValue(frozen.canonicalArguments.field("input").getOrThrow()) != canonicalAgentValue(call.arguments) ||
            canonicalAgentValue(frozen.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()) != canonicalAgentValue(binding) ||
            canonicalAgentValue(contextReadFactLinksValue(frozen.contextReadFacts)) != canonicalAgentValue(contextReadFactLinksValue(links))) {
            return hostPluginResourceError("plugin.document_preparation_changed", "prepared document plan differs from the exact original call and fact") }
        for (item in frozen.canonicalArguments.field("host_plan").getOrThrow().field("intents").getOrThrow().items) {
            match (pluginDocumentChildArguments(frozen.canonicalArguments, httpIntentText(item, "id"))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (!configuration.permits(localTool, httpIntentText(item, "key"), httpIntentText(item, "mode") == "compare_exchange")) {
                return hostPluginResourceError("plugin.document_rights_denied", "operator no longer grants the frozen document action") }
        }
        Result.Ok(Some(frozen.canonicalArguments))
    } catch (_: Exception) {
        hostPluginResourceError("plugin.document_preparation_changed", "prepared document metadata is invalid") }
}

public func hostExecuteDocumentRead(host: HostJavaScriptPluginHost, operations: OperationRuntimePort,
    context: ToolInvocationContext, prepared: PreparedToolInvocation,
    observer: ?PluginDocumentReadObserver, payloadArtifacts!: ?HostArtifactStore = None,
    retainPayload!: ?(HostDocumentPayloadReader) -> Unit = None): Result<ToolResult> {
    if(pluginDocumentContextReadRequestValid(prepared.operationPlan.canonicalArguments)){return hostExecuteDocumentContextRead(host,operations,context,prepared,observer)}
    if (!isContextReadPlan(prepared.operationPlan) || !pluginDocumentReadAuthority(prepared.operationPlan) ||
        prepared.source.contextReadPreparation.isNone()) { return hostPluginResourceError("plugin.document_read_source", "document read requires retained host preparation") }
    let source = match (prepared.source.operationRoot) { case Some(OperationRootSource.Direct(value)) => value
        case _ => return hostPluginResourceError("plugin.document_read_source", "document read requires canonical ContextRead provenance") }
    let binding = prepared.operationPlan.canonicalArguments.field("binding").getOrThrow()
    let read = prepared.source.contextReadPreparation.getOrThrow()
    match (read.validateBoundary(context, prepared.operationPlan.canonicalArguments)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let configuration = match (host.documentConfiguration(httpIntentText(binding, "namespace"), httpIntentText(binding, "package_digest"))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let generation = UInt64.parse(httpIntentText(binding, "generation"))
    match (hostDocumentPreparationCurrent(host, configuration, generation, context, binding)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let revoked = AtomicBool(false)
    let registration = match (host.observeServiceRevocation(configuration.namespace, generation, { => revoked.store(true) })) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        let prefix = "plugin." + configuration.namespace + "."
        let name = httpIntentText(binding, "contribution")
        if (!name.startsWith(prefix)) { return hostPluginResourceError("plugin.document_read_scope", "document contribution has another namespace") }
        for (key in prepared.operationPlan.canonicalArguments.field("keys").getOrThrow().items where !configuration.permits(name[prefix.size..], key.text, false)) {
            return hostPluginResourceError("plugin.document_rights_denied", "operator denied document read") }
        let guard = { =>
            // This callback runs under canonical DB. It must not acquire host
            // or Runtime locks. Revocation is an atomic signal from the owner.
            if (revoked.load() || context.cancellation.isCancelled()) { return hostPluginResourceError<Unit>("plugin.document_read_revoked", "document read owner was revoked") }
            configuration.validateCurrent()
        }
        let referenced = httpIntentText(prepared.operationPlan.canonicalArguments, "schema") == PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA
        if (referenced != configuration.payloadReferences(name[prefix.size..])) {
            return hostPluginResourceError("plugin.document_payload_profile_changed", "document representation changed after approval") }
        let result: Result<AgentValue>
        if (referenced) {
            if (payloadArtifacts.isNone() || retainPayload.isNone()) {
                return hostPluginResourceError("plugin.document_payload_owner_missing", "reference reads require their retained artifact cleanup owner") }
            let owner = payloadArtifacts.getOrThrow().documentPayloadReader(operations, source, prepared.operationPlan, guard, observer)
            result = try { owner.read() } finally {
                if (owner.close().isError()) { retainPayload.getOrThrow()(owner) }
            }
        } else { result = operations.readPluginDocuments(source, prepared.operationPlan, guard, observer) }
        let value = match (result) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (read.validateBoundary(context, prepared.operationPlan.canonicalArguments)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (revoked.load() || context.cancellation.isCancelled()) { return hostPluginResourceError("plugin.document_read_revoked", "document read revoked before its result was consumed") }
        Result.Ok(ToolResult(prepared.call.callId, value))
    } finally { registration.dispose() }
}

public func hostQueryDocumentPreparationProvider(host: HostJavaScriptPluginHost, namespace: String, localTool: String,
    provider: String, generation: UInt64, configuration: HostPluginDocumentConfiguration,
    context: ToolInvocationContext, call: ToolCall): Result<HostJavaScriptPluginInvocationResult> {
    match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    match (configuration.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    // Pin the actual already-mounted Tool generation before invoking a Provider.
    // A disable/re-enable of the same digest cannot be adopted by this request.
    let binding = match (host.policyProviderBinding(namespace, provider)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (binding.namespace != namespace || binding.contribution != provider ||
        binding.digest != configuration.packageDigest || binding.generation != generation) {
        return hostPluginResourceError("plugin.document_preparation_provider_changed", "preparation Provider differs from the original Tool package and generation") }
    let mounted = match (host.servicePackage(namespace, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    // Derive DATA custody before constructing the query and its carriers.
    // This is the same installed metadata root, not execution authority.
    let payment = try {
        if (!mounted.textEquals(PluginDescriptorText.Namespace, namespace) ||
            !mounted.textEquals(PluginDescriptorText.ContentDigest, configuration.packageDigest)) {
            return hostPluginResourceError("plugin.document_preparation_provider_changed", "preparation Provider package differs from its data custody") }
        mounted.deriveCopiedDataPayment(65536)
    } finally { mounted.close() }
    let response = try {
        match (hostQueryPluginPolicyPaidInput(host, namespace, provider, configuration.packageDigest,
            objectValue([ValueField("schema", textValue("axyndra.tool-preparation-query/v1")),
                ValueField("tool", textValue(localTool)), ValueField("input", call.arguments)]), payment,
            ThreadId(context.sessionId.value), context.cancellation, call.callId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    } finally { payment.close() }
    var transferred = false
    try {
        if (response.binding.generation != generation || response.binding.digest != configuration.packageDigest ||
            response.binding.namespace != namespace || response.binding.contribution != provider) {
            return hostPluginResourceError("plugin.document_preparation_provider_changed", "preparation Provider changed during its pure query") }
        match (configuration.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let current = match (host.policyProviderBinding(namespace, provider)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (current.generation != generation || current.digest != binding.digest) {
            return hostPluginResourceError("plugin.document_preparation_provider_changed", "preparation Provider was revoked before result consumption") }
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let result = HostJavaScriptPluginInvocationResult(response.value, false, releasePayload: { => response.close() })
        transferred = true
        Result.Ok(result)
    } finally { if (!transferred) { response.close() } }
}
