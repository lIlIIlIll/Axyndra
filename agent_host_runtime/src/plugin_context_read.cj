package agent_host_runtime

import agent_ports.*

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import yjson.*
import yjson_support.*

public func hostPrepareContextRead(host: HostJavaScriptPluginHost, context: ToolInvocationContext,
    call: ToolCall): Result<AgentValue> {
    if (httpIntentText(call.arguments,"schema")==PLUGIN_PEER_READ111) {
        return hostPreparePeerRead111(host,context,call.arguments) }
    let args = call.arguments
    if(httpIntentText(args,"schema")==PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA ||
        httpIntentText(args,"schema")==PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA){
        return hostPrepareLatestJournalRead(host,context,args)}
    if(httpIntentText(args,"schema")==PLUGIN_DOCUMENT_CONTEXT_WINDOW_READ_SCHEMA){
        return hostPrepareDocumentContextWindowRead(host,context,args)}
    if(httpIntentText(args,"schema")==PLUGIN_DOCUMENT_ROW_JOURNAL_READ_SCHEMA){
        return hostPrepareWindowDocumentRead(host,context,args)}
    if (pluginDocumentReadRequestValid(args)) {
        return hostPrepareDocumentRead(host, context, args)
    }
    if (!httpIntentExactFields(args, ["schema", "binding", "resources"]) ||
        httpIntentText(args, "schema") != CONTEXT_READ_RESOURCE_SCHEMA ||
        args.field("binding").getOrThrow().unifiedKind != ValueKind.Object) {
        return hostPluginResourceError("context.read_request_invalid", "resource requests cannot supply classification or approval fields")
    }
    // Only metadata is examined before policy and approval. The collector uses
    // the same verified-handle identity and host exclusions as read views.
    let binding = args.field("binding").getOrThrow()
    let referenceRead = httpIntentText(binding, "schema") == "axyndra.context-reference-read/v1"
    let contextSelection = referenceRead || httpIntentText(binding, "schema") == "axyndra.context-provider-read/v1"
    let bindingFields = if (referenceRead) { ["schema", "thread_id", "run_id", "epoch", "projection_digest", "configuration_digest"] }
        else { ["schema", "plugin", "provider", "package_digest", "generation", "thread_id", "run_id", "epoch", "projection_digest", "configuration_digest"] }
    if (contextSelection && (!httpIntentExactFields(binding, bindingFields) ||
        httpIntentText(binding, "thread_id") != context.sessionId.value || httpIntentText(binding, "run_id") != context.runId.value ||
        binding.field("epoch").getOrThrow().unifiedKind != ValueKind.Number ||
        binding.field("epoch").getOrThrow().asNumberText() != context.epoch.toString() ||
        httpIntentText(binding, "projection_digest") != contextReadProjectionDigest(context.contextProjection))) {
        return hostPluginResourceError("context.read_binding_invalid", "host-selected context directories lost their actual Run") }
    let scopes = match (host.captureContextReadScopes()) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let collector = HostReadViewCollector(context, host, contextSelection: contextSelection,
        scopes: if (contextSelection) { Some(scopes) } else { None }, pathIdentityAllowed: true)
    let resources = match (collector.collect(args.field("resources").getOrThrow())) {
        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
    // Classification comes from the host's existing workspace policy. A pure
    // plugin request cannot opt out of review for sensitive or external data.
    let canonical = objectValue([ValueField("schema", textValue(CONTEXT_READ_RESOURCE_SCHEMA)),
        ValueField("binding", args.field("binding").getOrThrow()), ValueField("resources", resources),
        ValueField("requires_approval", boolValue(collector.requiresApproval)), ValueField("read_scope_digest", textValue(scopes.digest))])
    if (!contextReadResourcePlanValid(canonical)) {
        return hostPluginResourceError("context.read_resource_limit", "resource metadata or total content exceeds the bounded context snapshot")
    }
    match (scopes.validate(host)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    Result.Ok(canonical)
}

public func hostContextReadCapabilities(call: ToolCall): Array<Capability> {
    if (httpIntentText(call.arguments,"schema")==PLUGIN_PEER_READ111) {
        let peer=Capability(CapabilityKind.PeerMessage)
        if (httpIntentText(call.arguments,"invocation_capability")=="peer.message") { return [peer] }
        return [peer,Capability(CapabilityKind.ExtensionInvoke,
            resource:httpIntentText(call.arguments.field("binding").getOrThrow(),"namespace"))] }
    let values = ArrayList<Capability>()
    if(httpIntentText(call.arguments,"schema")==PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA ||
        httpIntentText(call.arguments,"schema")==PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA){
        return [Capability(CapabilityKind.ExtensionInvoke,resource:httpIntentText(call.arguments.field("binding").getOrThrow(),"namespace"))]}
    if(pluginDocumentContextWindowReadRequestValid(call.arguments)){
        return [Capability(CapabilityKind.ExtensionInvoke,resource:httpIntentText(call.arguments.field("binding").getOrThrow(),"namespace"))]}
    if(pluginDocumentRowJournalReadRequestValid(call.arguments)){
        return [Capability(CapabilityKind.ExtensionInvoke,resource:httpIntentText(call.arguments.field("binding").getOrThrow(),"namespace"))]}
    if (pluginDocumentReadRequestValid(call.arguments)) {
        return [Capability(CapabilityKind.ExtensionInvoke,
            resource: httpIntentText(call.arguments.field("binding").getOrThrow(), "namespace"))]
    }
    if (contextReadResourcePlanValid(call.arguments)) {
        for (resource in call.arguments.field("resources").getOrThrow().items) {
            values.add(Capability(CapabilityKind.WorkspaceRead, resource: httpIntentText(resource, "source")))
            if (httpIntentText(resource, "kind") == "index") {
                for (entry in resource.field("entries").getOrThrow().items) {
                    let relative = httpIntentText(entry, "relative")
                    values.add(Capability(CapabilityKind.WorkspaceRead, resource: if (relative == "") { httpIntentText(resource, "source") }
                        else { Path(httpIntentText(resource, "source")).join(relative).toString() })) }
            }
            if (httpIntentText(resource, "kind") == "metadata") {
                for (entry in resource.field("entries").getOrThrow().items) {
                    values.add(Capability(CapabilityKind.WorkspaceRead,
                        resource: Path(httpIntentText(resource, "source")).join(httpIntentText(entry, "name")).toString())) }
            }
            if (httpIntentText(resource, "kind") == "absence") {
                values.add(Capability(CapabilityKind.WorkspaceRead, resource: httpIntentText(resource, "absence_parent"))) }
        }
    }
    if (values.isEmpty()) { values.add(Capability(CapabilityKind.WorkspaceRead)) }
    values.toArray()
}

public func hostContextReadApproval(call: ToolCall): ToolApprovalMetadata {
    if(httpIntentText(call.arguments,"schema")==PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA ||
        httpIntentText(call.arguments,"schema")==PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA){
        return ToolApprovalMetadata("extension.invoke",RiskAssessment(ApprovalRiskLevel.Medium,
            flags:["exact_context_read"],reasons:["Read this explicitly configured structural journal through the actual typed Provider"]),
            ApprovalGrantScope("extension.invoke",toolName:HOST_CONTEXT_READ_TOOL),sessionApprovalAllowed:false)}
    if(pluginDocumentContextWindowReadRequestValid(call.arguments)){
        return ToolApprovalMetadata("extension.invoke",RiskAssessment(ApprovalRiskLevel.Medium,
            flags:["exact_context_read"],reasons:["Read this explicitly configured window for the actual context Provider"]),
            ApprovalGrantScope("extension.invoke",toolName:HOST_CONTEXT_READ_TOOL),sessionApprovalAllowed:false)}
    if(pluginDocumentRowJournalReadRequestValid(call.arguments)){
        return ToolApprovalMetadata("extension.invoke",RiskAssessment(ApprovalRiskLevel.Medium,
            flags:["exact_context_read"],reasons:["Read this explicitly configured journal window before preparing the pending Tool"]),
            ApprovalGrantScope("extension.invoke",toolName:HOST_CONTEXT_READ_TOOL),sessionApprovalAllowed:false)}
    if (pluginDocumentReadRequestValid(call.arguments)) {
        return ToolApprovalMetadata("extension.invoke", RiskAssessment(ApprovalRiskLevel.Medium,
            flags: ["exact_context_read"], reasons: ["Read these operator-authorized logical documents before preparing this Tool"]),
            ApprovalGrantScope("extension.invoke", toolName: HOST_CONTEXT_READ_TOOL), sessionApprovalAllowed: false)
    }
    if (httpIntentText(call.arguments,"schema")==PLUGIN_PEER_READ111) {
        return ToolApprovalMetadata("peer.message",RiskAssessment(ApprovalRiskLevel.Medium,
            flags:["exact_context_read"],reasons:["Observe this actual same-root member before freezing its new invocation"]),
            ApprovalGrantScope("peer.message",toolName:HOST_CONTEXT_READ_TOOL),sessionApprovalAllowed:false) }
    var label = "workspace.read"; var risk = ApprovalRiskLevel.Medium
    let reasons = ArrayList<String>(["Read these frozen resources into this Run before preparing the pending tool"])
    if (contextReadResourcePlanValid(call.arguments)) {
        for (resource in call.arguments.field("resources").getOrThrow().items) {
            let permission = httpIntentText(resource, "permission")
            if (risk != ApprovalRiskLevel.Critical && permission != "workspace.read") { label = permission }
            if (permission == "sensitive-path.read") { label = permission; risk = ApprovalRiskLevel.Critical }
            if (reasons.size < 10) { reasons.add(permission + ": " + httpIntentText(resource, "source")) }
            if (["metadata", "index"].contains(httpIntentText(resource, "kind"))) {
                for (entry in resource.field("entries").getOrThrow().items) {
                    let classified = httpIntentText(entry, "permission")
                    if (risk != ApprovalRiskLevel.Critical && classified != "workspace.read") { label = classified }
                    if (classified == "sensitive-path.read") { label = classified; risk = ApprovalRiskLevel.Critical }
                    if (classified != "workspace.read" && reasons.size < 10) {
                        reasons.add(classified + ": " + Path(httpIntentText(resource, "source")).join((if (httpIntentText(resource, "kind") == "index") { httpIntentText(entry, "relative") } else { httpIntentText(entry, "name") })).toString()) }
                }
            }
        }
    }
    ToolApprovalMetadata(label, RiskAssessment(risk, flags: ["exact_context_read"], reasons: reasons.toArray()),
        ApprovalGrantScope(label, toolName: HOST_CONTEXT_READ_TOOL), sessionApprovalAllowed: false)
}

public func hostRegisterContextRead(catalog: ToolCatalog, host: HostJavaScriptPluginHost,
    operations: OperationRuntimePort, documentObserver!: ?PluginDocumentReadObserver = None,
    payloadArtifacts!: ?HostArtifactStore = None): Result<Unit> {
    let executor = HostContextReadExecutor(host, operations, documentObserver, payloadArtifacts)
    match (host.ownContextReadCleanup({ => executor.closeReads() })) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if(payloadArtifacts.isSome()) {
        match (host.ownToolInputAttachments(payloadArtifacts.getOrThrow())) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match(host.ownDocumentPayloadFactory({ run,parent,operation,guard => executor.payloadCommitReader(run,parent,operation,guard) })) {
            case Result.Err(error) => return Result.Err(error);case Result.Ok(_) => () }
        match(host.ownDocumentDataFactory({=>executor.dataSession()})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    }
    catalog.register(ToolDescriptor(ModelToolDefinition(HOST_CONTEXT_READ_TOOL,
        "Read authorized resources into the current Run's canonical context facts.",
        hostObjectSchema([hostSchemaProperty("schema", "string"), hostSchemaProperty("binding", "object"),
            hostSchemaProperty("resources", "array"), hostSchemaProperty("keys", "array"),
            hostSchemaProperty("projection_digest", "string"),hostSchemaProperty("key","string"),
            hostSchemaProperty("access_policy_digest","string"),hostSchemaProperty("view_policy_digest","string"),
            hostSchemaProperty("window","object"),hostSchemaProperty("prior_facts","array")], ["schema", "binding"])),
        Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true, neverReplay: true,
        implementationVersion: HOST_CONTEXT_READ_IMPLEMENTATION, implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION,
        canonicalArgumentsResolver: Some({ context, call => hostPrepareContextRead(host, context, call) }),
        capabilityResolver: Some({ call => hostContextReadCapabilities(call)[0] }),
        additionalCapabilityResolver: Some({ call => hostContextReadCapabilities(call)[1..] }),
        approvalMetadataResolver: Some({ call => hostContextReadApproval(call) }),
        networkPolicyResolver: Some({ _ => Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied)) })), executor)
}

// Own only private temporary copies. Cleanup failure retains its capacity
// until a later close actually removes it; no separate execution registry.
class HostContextReadExecutor <: ToolExecutor {
    private let host: HostJavaScriptPluginHost
    private let operations: OperationRuntimePort
    private let documentObserver: ?PluginDocumentReadObserver
    private let payloadArtifacts: ?HostArtifactStore
    private let retainedPayloads = ArrayList<HostDocumentPayloadReader>()
    private let retainedLatestJournalStreams=ArrayList<HostLatestJournalStreamPayloadReader>()
    private let retainedPayloadCommits = ArrayList<HostDocumentPayloadCommitReader>()
    private let retainedDataSessions=ArrayList<HostDocumentDataSession>()
    private let lock = Mutex()
    private let retained = ArrayList<String>()
    private var active: Int64 = 0
    private var closed = false
    init(host: HostJavaScriptPluginHost, operations: OperationRuntimePort, observer: ?PluginDocumentReadObserver,
        artifacts: ?HostArtifactStore) {
        this.host = host; this.operations = operations; this.documentObserver = observer; this.payloadArtifacts = artifacts }
    private func clean(path: String): Bool {
        try { if (exists(Path(path))) { remove(path, recursive: true) }; true }
        catch (_: Exception) { false }
    }
    private func collect(): Unit {
        var index: Int64 = 0
        while (index < retained.size) { if (clean(retained[index])) { retained.remove(at: index) } else { index++ } }
        index = 0
        while (index < retainedPayloads.size) {
            if (retainedPayloads[index].close().isOk()) { retainedPayloads.remove(at: index) } else { index++ }
        }
        index=0
        while(index<retainedLatestJournalStreams.size){
            if(retainedLatestJournalStreams[index].close().isOk()){retainedLatestJournalStreams.remove(at:index)}else{index++}}
        index=0
        while(index<retainedPayloadCommits.size) {
            if(retainedPayloadCommits[index].collect()) { retainedPayloadCommits.remove(at:index) } else { index++ }
        }
        index=0
        while(index<retainedDataSessions.size){
            if(retainedDataSessions[index].collect()){retainedDataSessions.remove(at:index)}else{index++}}
    }
    func payloadCommitReader(run: RunId,parent: OperationId,operation: OperationId,
        guard: () -> Result<Unit>): Result<HostDocumentPayloadCommitReader> {
        lock.lock()
        var selected: ?HostDocumentPayloadCommitReader=None
        try {
            collect()
            if(closed || payloadArtifacts.isNone() || active+retained.size+retainedPayloads.size+retainedPayloadCommits.size+retainedDataSessions.size + retainedLatestJournalStreams.size>=8) {
                return hostPluginResourceError("context.read_capacity", "document payload reader is closed or at its bounded capacity") }
            let reader=payloadArtifacts.getOrThrow().documentPayloadCommitReader(run,parent,operation,guard)
            selected=Some(reader)
            retainedPayloadCommits.add(reader);Result.Ok(reader)
        } catch(_: Exception) {
            // No File can exist until runCommit; construction failure can
            // release this inert fixed reservation without losing an OS owner.
            match(selected) { case Some(reader) => let _=reader.close();case None => () }
            hostPluginResourceError("plugin.document_payload_capacity", "document payload allocation budget is exhausted") }
        finally { lock.unlock() }
    }
    func dataSession():Result<HostDocumentDataSession>{
        lock.lock()
        try{
            collect()
            if(closed || payloadArtifacts.isNone() || active+retained.size+retainedPayloads.size+retainedPayloadCommits.size+retainedDataSessions.size + retainedLatestJournalStreams.size>=8){
                return hostPluginResourceError("context.read_capacity","document data owner is closed or at its bounded capacity")}
            let session=payloadArtifacts.getOrThrow().documentDataSession()
            session.ownDerivedDataSessionCollector336({value=>retainDerivedDataSession336(value)})
            retainedDataSessions.add(session);Result.Ok(session)
        }catch(_:Exception){hostPluginResourceError("plugin.document_query_capacity","document query allocation budget is exhausted")}
        finally{lock.unlock()}
    }
    // Resource-only adoption into the ORIGINAL bounded collector. The
    // successor is already fully prepaid on its original parent's bank.
    func retainDerivedDataSession336(session:HostDocumentDataSession):Result<Unit>{
        lock.lock();try{
            collect()
            if(closed || payloadArtifacts.isNone() || active+retained.size+retainedPayloads.size+retainedPayloadCommits.size+retainedDataSessions.size + retainedLatestJournalStreams.size>=8){
                return hostPluginResourceError("context.read_capacity","same document data collector remains closed or at its original capacity")}
            retainedDataSessions.add(session);Result<Unit>.Ok(())
        }finally{lock.unlock()}
    }
    // The actual same collector adopts the Session before any live input,
    // worker, file, or custody can be constructed. This returns no authority.
    func executionDataSession():Result<(HostDocumentDataSession,HostLiveExecutionCustody)>{
        let session=match(dataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(session.retainExecutionCustody()){
            case Result.Ok(custody)=>Result.Ok((session,custody))
            case Result.Err(error)=>let _=session.close();Result.Err(error)}
    }
    func closeReads(): Result<Unit> {
        lock.lock()
        try {
            closed = true
            for(reader in retainedLatestJournalStreams){let _=reader.close()}
            for(reader in retainedPayloadCommits) { let _=reader.close() }
            for(session in retainedDataSessions){let _=session.closeExecutionDataOwner()}
            collect()
            if (active != 0 || !retained.isEmpty() || !retainedPayloads.isEmpty() || !retainedPayloadCommits.isEmpty() || !retainedDataSessions.isEmpty() || !retainedLatestJournalStreams.isEmpty()) { return hostPluginResourceError("context.read_cleanup_pending", "private read copy is still owned") }
            Result.Ok(())
        } finally { lock.unlock() }
    }
    private func reserve(): Result<Unit> {
        lock.lock()
        try {
            collect()
            if (closed || active + retained.size + retainedPayloads.size + retainedPayloadCommits.size + retainedDataSessions.size + retainedLatestJournalStreams.size >= 8) { return hostPluginResourceError("context.read_capacity", "resource reader is closed or at its bounded capacity") }
            active++; Result.Ok(())
        } finally { lock.unlock() }
    }
    private func validate(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<Unit> {
        lock.lock(); let unavailable = try { closed } finally { lock.unlock() }
        if (unavailable || prepared.source.kind != PreparedInvocationSourceKind.Direct ||
            prepared.source.contextReadPreparation.isNone() || !isContextReadPlan(prepared.operationPlan) ||
            !contextReadResourcePlanValid(prepared.operationPlan.canonicalArguments)) {
            return hostPluginResourceError("context.read_source_invalid", "resource executor requires its retained host preparation and exact read plan")
        }
        let source = match (prepared.source.operationRoot) {
            case Some(OperationRootSource.Direct(value)) => value
            case _ => return hostPluginResourceError("context.read_source_invalid", "resource executor requires its canonical direct read source") }
        let origin = match (source.origin) {
            case DirectCallOrigin.ContextRead(value) => value
            case _ => return hostPluginResourceError("context.read_source_invalid", "resource executor cannot borrow another direct source") }
        let read = prepared.source.contextReadPreparation.getOrThrow()
        if (origin.ownerNamespace != read.ownerNamespace || origin.packageDigest != read.packageDigest ||
            origin.configurationDigest != read.configurationDigest || source.runId.value != context.runId.value ||
            source.threadId.value != context.sessionId.value || source.epoch != context.epoch ||
            source.operationId.value != prepared.operationId.value) {
            return hostPluginResourceError("context.read_source_invalid", "resource executor lost its exact Run, origin or operation")
        }
        match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (read.validateBoundary(context, prepared.operationPlan.canonicalArguments)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let scopes = match (host.captureContextReadScopes()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (httpIntentText(prepared.operationPlan.canonicalArguments, "read_scope_digest") != scopes.digest) {
            return hostPluginResourceError("context.read_scopes_changed", "read classification no longer matches its approved plan") }
        operations.verifyContextReadExecuting(source, prepared.operationPlan)
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (httpIntentText(prepared.operationPlan.canonicalArguments,"schema")==PLUGIN_PEER_READ111) {
            match(reserve()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            try {return hostExecutePeerRead111(host,operations,context,prepared)}
            finally {lock.lock();active--;lock.unlock()} }

        if(httpIntentText(prepared.operationPlan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA ||
            httpIntentText(prepared.operationPlan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA){
            match(reserve()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            try{return hostExecuteLatestJournalRead(host,operations,context,prepared,payloadArtifacts,{owner=>
                lock.lock();try{retainedLatestJournalStreams.add(owner)}finally{lock.unlock()}})}
            finally{lock.lock();try{active--;collect()}finally{lock.unlock()}}
        }
        if(pluginDocumentContextWindowReadRequestValid(prepared.operationPlan.canonicalArguments)){
            match(reserve()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            try{return hostExecuteDocumentContextWindowRead(host,operations,context,prepared,
                payloadArtifacts:payloadArtifacts,retainPayload:Some({owner=>
                    lock.lock();try{retainedPayloads.add(owner)}finally{lock.unlock()}}))}
            finally{lock.lock();active--;lock.unlock()}
        }
        if(pluginDocumentRowJournalReadRequestValid(prepared.operationPlan.canonicalArguments)){
            match(reserve()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            try{return hostExecuteWindowDocumentRead(host,operations,context,prepared,documentObserver,
                payloadArtifacts:payloadArtifacts,retainPayload:Some({owner=>
                    lock.lock();try{retainedPayloads.add(owner)}finally{lock.unlock()}}))}
            finally{lock.lock();active--;lock.unlock()}
        }
        if (pluginDocumentReadRequestValid(prepared.operationPlan.canonicalArguments)) {
            match (reserve()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            try { return hostExecuteDocumentRead(host, operations, context, prepared, documentObserver,
                payloadArtifacts: payloadArtifacts, retainPayload: Some({ owner =>
                    lock.lock(); try { retainedPayloads.add(owner) } finally { lock.unlock() }
                })) }
            finally { lock.lock(); active--; lock.unlock() }
        }
        match (validate(context, prepared)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (reserve()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let directory = try { Directory.createTemp("/tmp").toString() }
            catch (_: Exception) {
                lock.lock(); active--; lock.unlock()
                return hostPluginResourceError("context.read_snapshot_unavailable", "private resource snapshot cannot be created") }
        let outcome = try { read(context, prepared, directory) }
            catch (_: Exception) { Result<ToolResult>.Err(AgentError(AgentErrorKind.InvalidInput,
                "context.read_failed", "resource could not be copied or decoded within its approved bound")) }
        let cleaned = clean(directory)
        lock.lock(); active--; if (!cleaned) { retained.add(directory) }; lock.unlock()
        if (!cleaned) { return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "context.read_cleanup_pending", "private resource cleanup has not acknowledged release", retryable: false, fallbackAllowed: false)) }
        outcome
    }
    private func read(context: ToolInvocationContext, prepared: PreparedToolInvocation, directory: String): Result<ToolResult> {
        let scopes = match (host.captureContextReadScopes()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (httpIntentText(prepared.operationPlan.canonicalArguments, "read_scope_digest") != scopes.digest) {
            return hostPluginResourceError("context.read_scopes_changed", "read classification no longer matches its approved plan") }
        let selected = ["axyndra.context-provider-read/v1", "axyndra.context-reference-read/v1"].contains(
            httpIntentText(prepared.operationPlan.canonicalArguments.field("binding").getOrThrow(), "schema"))
        let readScopes: ?HostContextReadScopes = if (selected) { Some(scopes) } else { None }
        let values = ArrayList<AgentValue>(); let workspace = host.readTargetInspector(context.workspaceRoot)
        var index: Int64 = 0; var observed: Int64 = 0
        for (resource in prepared.operationPlan.canonicalArguments.field("resources").getOrThrow().items) {
            match (validate(context, prepared)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let source = httpIntentText(resource, "source"); let witness = httpIntentText(resource, "witness")
            let info = match (workspace.inspectReadTarget(source)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            let permission = hostContextReadPermission(host, readScopes, source, info.permissionClass)
            let absent = httpIntentText(resource, "kind") == "absence"
            if (info.exists == absent || info.normalizedPath != source || permission != httpIntentText(resource, "permission") ||
                !context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: source)) {
                return hostPluginResourceError("context.read_resource_changed", "resource classification changed after approval") }
            if (absent) {
                let parent = httpIntentText(resource, "absence_parent")
                if (!context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: parent)) {
                    return hostPluginResourceError("context.read_capability_denied", "absence metadata exceeds the current capability ceiling") }
                let current = match (hostReadResourceWitness(parent)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (current != witness) { return hostPluginResourceError("context.read_absence_changed", "absence ancestor changed after approval") }
                let names = match (hostReadViewDirectory(parent, witness)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (names.contains(httpIntentText(resource, "absence_name"))) {
                    return hostPluginResourceError("context.read_absence_changed", "the previously absent entry now exists") }
                let after = match (hostReadResourceWitness(parent)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (after != witness) { return hostPluginResourceError("context.read_absence_changed", "absence directory changed while observed") }
            }
            let actual = if (absent) { witness } else { match (hostReadResourceWitness(source)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) } }
            if (actual != witness) { return hostPluginResourceError("context.read_resource_changed", "resource identity changed after approval") }
            if (httpIntentText(resource, "kind") == CONTEXT_READ_PATH_IDENTITY_KIND) {
                match (hostValidateContextReadPathIdentity(host, context, resource, readScopes)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            }
            if (httpIntentText(resource, "kind") == "index") {
                let current = match (HostContextIndex(host, context, source, resource, scopes: readScopes).collect(resource.field("starts").getOrThrow())) {
                    case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (canonicalAgentValue(current.field("entries").getOrThrow()) != canonicalAgentValue(resource.field("entries").getOrThrow()) ||
                    current.field("truncated").getOrThrow().asBool() != resource.field("truncated").getOrThrow().asBool() ||
                    current.field("depth_limited").getOrThrow().asBool() != resource.field("depth_limited").getOrThrow().asBool()) {
                    return hostPluginResourceError("context.index_changed", "directory index changed after metadata approval") }
            }
            var metadataEntries: ?AgentValue = None
            if (httpIntentText(resource, "kind") == "metadata") {
                let entries = match (hostContextReadMetadataEntries(host, context, source, witness,
                    Int64.parse(resource.field("max_files").getOrThrow().asNumberText()),
                    Int64.parse(resource.field("max_file_bytes").getOrThrow().asNumberText()), scopes: readScopes)) {
                    case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (canonicalAgentValue(entries) != canonicalAgentValue(resource.field("entries").getOrThrow())) {
                    return hostPluginResourceError("context.metadata_changed", "directory members changed after metadata approval") }
                metadataEntries = Some(entries)
            }
            var content = ""
            var bodyError = ""; var rawDigest = ""
            let header = httpIntentText(resource, "kind") == "header"
            let textObservation = httpIntentText(resource, "kind") == "text"
            if (header || textObservation || httpIntentText(resource, "kind") == "file") {
                let size = Int64.parse(resource.field("bytes").getOrThrow().asNumberText())
                let target = Path(directory).join(index.toString()).toString()
                let count = match (if (header) { hostReadViewHeader(source, witness, target,
                    Int64.parse(resource.field("max_bytes").getOrThrow().asNumberText()), httpIntentText(resource, "start_marker"),
                    httpIntentText(resource, "end_marker"), resource.field("trim_ascii").getOrThrow().asBool()) }
                    else { hostReadResourceCopy(source, witness, target, size) }) {
                    case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if ((!header && count != size) || count > size) { return hostPluginResourceError("context.read_resource_changed", "resource length changed after approval") }
                match (validate(context, prepared)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let raw = File.readFrom(target)
                if (textObservation) { rawDigest = modelPolicySha256(raw) }
                content = if (header) {
                    // Invalid UTF-8 in a bounded header is not a valid document
                    // frame. The unread body is never decoded or copied.
                    try { String.fromUtf8(raw) } catch (_: Exception) { "" }
                } else if (textObservation) {
                    try { String.fromUtf8(raw) } catch (_: Exception) { bodyError = "invalid_utf8"; "" }
                } else { String.fromUtf8(raw) }
            }
            let fields = ArrayList<ValueField>([ValueField("kind", if (textObservation) { textValue("file") } else { resource.field("kind").getOrThrow() }),
                ValueField("source", textValue(source)), ValueField("path", resource.field("path").getOrThrow()),
                ValueField("witness", textValue(witness)), ValueField("text", textValue(content)),
                ValueField("sha256", textValue(if (textObservation) { rawDigest } else { modelPolicySha256Text(content) }))])
            if (httpIntentText(resource, "kind") == CONTEXT_READ_PATH_IDENTITY_KIND) {
                fields.add(ValueField("is_directory", resource.field("is_directory").getOrThrow()))
            }
            if (textObservation) { fields.add(ValueField("error", if (bodyError == "") { nullValue() } else { textValue(bodyError) })) }
            match (metadataEntries) { case Some(entries) => fields.add(ValueField("entries", entries)); case None => () }
            if (httpIntentText(resource, "kind") == "index") {
                fields.add(ValueField("entries", resource.field("entries").getOrThrow()))
                fields.add(ValueField("truncated", resource.field("truncated").getOrThrow()))
                fields.add(ValueField("depth_limited", resource.field("depth_limited").getOrThrow()))
            }
            let item = objectValue(fields.toArray())
            let encoded = stringifyUnifiedJson(item)
            // Keep room for the result wrapper, separators, and durable fact.
            if (encoded.size > RUN_CONTEXT_SNAPSHOT_MAX_BYTES - 1024 - observed) {
                return hostPluginResourceError("context.read_output_limit", "encoded resource data exceeds the canonical context snapshot") }
            observed += encoded.size + 1; values.add(item); index++
        }
        match (validate(context, prepared)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(ToolResult(prepared.call.callId, objectValue([ValueField("schema", textValue("axyndra.context-read-result/v1")),
            ValueField("resources", listValue(values.toArray()))])))
    }
}
