package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*


import agent_domain.*
import agent_extension_runtime.*
import agent_sdk.{PluginContributionKind, PluginToolExecutionProfile}
import yjson.*
import yjson_support.*
import tool_runtime.*
import agent_runtime.*
import process4cj as process
import std.collection.*
import std.fs.Path
import sandbox4cj.*
import std.sync.*
import std.time.*
// Shared lifecycle owner for the process-backed JavaScript host. The
// extension runtime owns the wire protocol; this layer owns activation,
// cancellation bridging, tool registration, and canonical host error semantics.
public class HostJavaScriptPluginInvocationResult {
    public let value: AgentValue
    public let isError: Bool
    private let payloadRelease: () -> Unit

    public init(value: AgentValue, isError: Bool, releasePayload!: () -> Unit = { => () }) {
        this.value = value
        this.isError = isError
        this.payloadRelease = releasePayload
    }
    public func releasePayload(): Unit { payloadRelease() }
}
// A published view identity. The host decides how (and whether) to render it;
// a plugin never receives terminal control or an approval surface through it.
public class HostJavaScriptPluginView {
    public let extensionId: String
    public let name: String
    public let description: String
    public let instanceGeneration: UInt64

    public init(extensionId: String, name: String, description: String,
        instanceGeneration!: UInt64 = 0u64) {
        this.extensionId = extensionId
        this.name = name
        this.description = description
        this.instanceGeneration = instanceGeneration
    }

    public prop routeName: String {
        get() { "plugin." + extensionId + "." + name }
    }
}
public class HostJavaScriptPluginCommand {
    public let extensionId: String
    public let name: String
    public let description: String
    public let instanceGeneration: UInt64

    public init(extensionId: String, name: String, description: String,
        instanceGeneration!: UInt64 = 0u64) {
        this.extensionId = extensionId
        this.name = name
        this.description = description
        this.instanceGeneration = instanceGeneration
    }

    public prop routeName: String {
        get() { "plugin." + extensionId + "." + name }
    }
}

public class HostJavaScriptPluginHook {
    public let extensionId: String
    public let descriptor: JavaScriptHookDescriptor

    public init(extensionId: String, descriptor: JavaScriptHookDescriptor) {
        this.extensionId = extensionId
        this.descriptor = descriptor
    }
}
// Freeze the actual protected directory, not portable components of a relative
// spelling. In particular, ../home must never become the absolute /home prefix.
private func hostCanonicalReadProtectionRoot217(root: String): String {
    if (root == "") { return "" }
    hostResolveThroughExistingAncestor(Path(root)).toString()
}

public open class HostJavaScriptPluginHost {
    // Same-bank payment remains in the actual Host even if reservation or
    // constructor/list registration throws after canonical handoff.
    private var pendingProcessPayment180: ?HostPaidValueProjection151 = None
    private let retainedProcessServices180 = ArrayList<HostHubDerivedProcessLease180>()
    func holdProcessPaymentBeforeAllocation180(value:HostPaidValueProjection151):Unit{
        lock.lock();try{
            if(pendingProcessPayment180.isSome()){
                throw IllegalStateException("unknown process lease allocation remains held")}
            pendingProcessPayment180=Some(value)
        }finally{lock.unlock()}
    }
    func registerActualProcessLease180(value:HostHubDerivedProcessLease180):Unit{
        lock.lock();try{
            if(pendingProcessPayment180.isNone()){
                throw IllegalStateException("actual process lease has no retained original payment")}
            retainedProcessServices180.add(value)
            pendingProcessPayment180=None<HostPaidValueProjection151>
        }finally{lock.unlock()}
    }
    private let childBackendLock111 = Mutex()
    private var childBackend111: ?HostPluginChildBackend111 = None
    func bindChildBackend111(value: HostPluginChildBackend111): Result<Unit> {
        childBackendLock111.lock()
        try {
            if (childBackend111.isSome()) { return hostPluginResourceError("child.backend_already_bound", "child backend is already installed") }
            childBackend111 = Some(value)
            Result.Ok(())
        } finally { childBackendLock111.unlock() }
    }
    func childOptions111(): Result<AgentValue> {
        childBackendLock111.lock()
        try { match (childBackend111) {
            case Some(value) => Result.Ok(objectValue([ValueField("background_enabled", boolValue(value.backgroundEnabled()))]))
            case None => hostPluginResourceError("child.backend_missing", "actual controlled child backend is unavailable") }
        } finally { childBackendLock111.unlock() }
    }
    func processOptions180(context:ToolInvocationContext,meter:HostPaidValueProjection151):Result<AgentValue>{
        let backend:?HostPluginChildBackend111
        childBackendLock111.lock();try{backend=childBackend111}finally{childBackendLock111.unlock()}
        let actual=match(backend){case Some(value)=>value;case None=>return hostPluginResourceError<AgentValue>(
            "child.backend_missing","actual process resource owner is unavailable")}
        let facts=match(actual.processFacts180(context,meter)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        meter.fundAdditional151(65536,16)
        Result.Ok(objectValue([ValueField("background_enabled",boolValue(actual.backgroundEnabled())),ValueField("process_facts",facts)]))
    }
    func observeProcessPreparation180(context:ToolInvocationContext,request:AgentValue,
        meter:HostPaidValueProjection151):Result<AgentValue>{
        let backend:?HostPluginChildBackend111
        childBackendLock111.lock();try{backend=childBackend111}finally{childBackendLock111.unlock()}
        match(backend){case Some(value)=>value.observeProcessPreparation180(context,request,meter)
            case None=>hostPluginResourceError("child.backend_missing","actual process resource owner is unavailable")}
    }
    func observeResultSlot150(context: ToolInvocationContext, consume: (Bool, Int64, Bool) -> Unit): Result<Unit> {
        let backend: ?HostPluginChildBackend111
        childBackendLock111.lock()
        try { backend = childBackend111 } finally { childBackendLock111.unlock() }
        match (backend) {
            case Some(value) => value.observeResultSlot150(context, consume)
            case None => hostPluginResourceError("child.backend_missing", "actual controlled child backend is unavailable") }
    }
    func observePeerPreparation111(context:ToolInvocationContext,recipient:String,
        scope:HostPluginPeerPreparationSnapshot111):Result<AgentValue> {
        let backend:?HostPluginChildBackend111
        childBackendLock111.lock()
        try {backend=childBackend111}finally{childBackendLock111.unlock()}
        match(backend){case Some(value)=>value.observeMember(context,recipient,scope)
            case None=>hostPluginResourceError("peer.backend_missing","the actual member owner is unavailable")}
    }
    func readPeerMember111(context:ToolInvocationContext,request:AgentValue,
        read:HostPluginPeerReadCustody111):Result<AgentValue> {
        let backend:?HostPluginChildBackend111
        childBackendLock111.lock()
        try {backend=childBackend111}finally{childBackendLock111.unlock()}
        match(backend){case Some(value)=>value.readMember(context,request,read)
            case None=>hostPluginResourceError("peer.backend_missing","the actual member owner is unavailable")}
    }
    func primitiveParentResultPersisted111(context:ToolInvocationContext,result:ToolResult):Result<Unit> {
        let backend:?HostPluginChildBackend111
        childBackendLock111.lock()
        try {backend=childBackend111}finally{childBackendLock111.unlock()}
        match(backend){case Some(value)=>value.parentResultPersisted(context,result);case None=>Result<Unit>.Ok(())}
    }
    private let lock = Mutex()
    private let serviceEndpointSeal = HostServiceEndpointSeal()
    private let generations = ArrayList<HostJavaScriptPluginGeneration>()
    // Cleanup-only owners, never dispatch candidates. This also accounts for
    // failed bootstrap processes that never acquired an active generation.
    private let retainedCleanup = ArrayList<JavaScriptExtensionHost>()
    private let primitiveConfigurations111 = HostPrimitiveConfigurationCache111()
    private let canonicalProjectionConfigurations173 = HostCanonicalProjectionConfigurationCache173()
    private var closed = false
    private var nextInstanceGeneration: UInt64 = 1u64

    private let launcher: JavaScriptHostProcessLauncher
    private let settingsRoot: String
    private var installedRegistry: ?PluginRegistry = None
    private let configureDocumentBackends: (HostPluginDocumentConfiguration)->Result<Unit>
    private let readViewStateRoot: String
    private let readTargetInspectors: HostReadTargetInspectorFactory
    private var contextReadComponents: ?() -> RegistryContextComponentSnapshot = None
    private var readViewCleanup: ?() -> Result<Unit> = None
    private var contextReadCleanup: ?() -> Result<Unit> = None
    private var documentPayloadFactory: ?(RunId,OperationId,OperationId,() -> Result<Unit>) -> Result<HostDocumentPayloadCommitReader> = None
    private var documentDataFactory: ?() -> Result<HostDocumentDataSession> = None
    private var nextDocumentQuerySequence:Int64=1
    private var toolInputAttachmentOwner: ?HostToolInputAttachmentOwner = None
    public init(readTargetInspectors: HostReadTargetInspectorFactory,
        settingsRoot!: String = "", readViewStateRoot!: String = "",
        documentBackends!: (HostPluginDocumentConfiguration)->Result<Unit> = {_=>Result.Ok(())}) {
        this.settingsRoot = hostCanonicalReadProtectionRoot217(settingsRoot)
        this.configureDocumentBackends=documentBackends
        this.readViewStateRoot = hostCanonicalReadProtectionRoot217(readViewStateRoot)
        this.readTargetInspectors = readTargetInspectors
        launcher = HostSandboxedJavaScriptHostLauncher()
    }
    public func ownRegistry(registry: PluginRegistry): Result<Unit> {
        lock.lock(); try {
            if (closed || installedRegistry.isSome() || !generations.isEmpty() ||
                hostCanonicalReadProtectionRoot217(registry.settingsRoot) != settingsRoot) {
                return hostPluginResourceError("plugin.registry_owner_conflict", "host must bind its actual installed registry before activation")
            }
            installedRegistry = Some(registry); Result.Ok(())
        } finally { lock.unlock() }
    }
    public func bindLifecycleService(configuration: HostPluginLifecycleConfiguration, serviceId: String,
        targetThread: ThreadId, workspaceRoot: String, hostLimits: ExecutionResourceLimits,
        permissionDomain: String, expectedGeneration: UInt64): Result<HostPluginLifecycleLaunchGrant> {
        let identity = match (serviceInstanceIdentity(configuration.namespace, expectedGeneration)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        configuration.bindService(serviceId, targetThread, identity, workspaceRoot, hostLimits, permissionDomain,
            registryAdmission: Some({ => enterRegistryEffect(configuration.namespace, expectedGeneration) }))
    }
    func ownToolInputAttachments(artifacts: HostArtifactStore): Result<Unit> {
        lock.lock(); try {
            if (closed || toolInputAttachmentOwner.isSome()) { return hostPluginResourceError("input_attachment.owner_conflict", "input owner is already bound or closed") }
            toolInputAttachmentOwner = Some(HostToolInputAttachmentOwner(artifacts)); Result.Ok(())
        } finally { lock.unlock() }
    }
    func prepareToolInputAttachment(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        namespace: String, contribution: String, generation: UInt64): Result<?HostToolInputAttachmentSession> {
        if (!isFrozenReadonlyDelegationParentPlan(prepared.operationPlan) ||
            prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("input_attachment").isNone()) { return Result.Ok(Option<HostToolInputAttachmentSession>.None) }
        lock.lock()
        let actual: ?HostToolInputAttachmentOwner = try { if (closed) { None } else { toolInputAttachmentOwner } } finally { lock.unlock() }
        let owner = match (actual) { case Some(value) => value
            case None => return hostPluginResourceError("input_attachment.owner_missing", "input owner is not available") }
        let session = match (owner.acquire(this, context, prepared, namespace, contribution, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (session.stage()) {
            case Result.Err(error) => session.abort(); Result.Err(error)
            case Result.Ok(_) => Result.Ok(Some(session)) }
    }
    public func toolInputAttachmentDeclaration(namespace: String, tool: String, generation: UInt64): Result<AgentValue> {
        let descriptor = match (servicePackageData81(namespace, generation)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (descriptor.entryKind != PluginEntryKind.NativeExecutable) { return hostPluginResourceError("input_attachment.native_required", "input attachment requires an actual native Tool") }
        lock.lock(); try {
            let active = match (findLocked(namespace)) { case Some(value) => value
                case None => return hostPluginResourceError("input_attachment.instance_stale", "input contribution is no longer active") }
            if (generation == 0u64 || active.isClosing() || active.instanceGeneration != generation || active.descriptor.contentDigest != descriptor.contentDigest) {
                return hostPluginResourceError("input_attachment.instance_stale", "input contribution changed generation or package") }
            for (declared in descriptor.contributions where declared.kind == PluginContributionKind.Tool && declared.name == tool &&
                declared.executionProfile == PluginToolExecutionProfile.Brokered && declared.inputAttachmentField != "") {
                for (ready in active.tools where ready.name == tool && ready.executionProfile == declared.executionProfile &&
                    ready.inputAttachmentField == declared.inputAttachmentField && ready.inputAttachmentMaxBytes == declared.inputAttachmentMaxBytes) {
                    return Result.Ok(objectValue([ValueField("field", textValue(declared.inputAttachmentField)), ValueField("max_bytes", integerValue(declared.inputAttachmentMaxBytes))])) }
            }
            hostPluginResourceError("input_attachment.declaration_missing", "actual manifest and ready Tool have no matching input declaration")
        } finally { lock.unlock() }
    }
    public func readTargetInspector(workspaceRoot: String): HostReadTargetInspector {
        readTargetInspectors(workspaceRoot)
    }
    public func ownReadViewCleanup(cleanup: () -> Result<Unit>): Result<Unit> {
        lock.lock()
        try {
            if (closed || readViewCleanup.isSome()) { return hostPluginResourceError("read_view.owner_conflict", "read-view cleanup owner is already bound or closed") }
            readViewCleanup = Some(cleanup); Result.Ok(())
        } finally { lock.unlock() }
    }
    public func ownContextReadCleanup(cleanup: () -> Result<Unit>): Result<Unit> {
        lock.lock()
        try {
            if (closed || contextReadCleanup.isSome()) {
                return hostPluginResourceError("context.read_owner_conflict", "context read cleanup owner is already bound or closed")
            }
            contextReadCleanup = Some(cleanup); Result.Ok(())
        } finally { lock.unlock() }
    }
    public func ownDocumentPayloadFactory(factory: (RunId,OperationId,OperationId,() -> Result<Unit>) -> Result<HostDocumentPayloadCommitReader>): Result<Unit> {
        lock.lock();try {
            if(closed || documentPayloadFactory.isSome()) { return hostPluginResourceError("plugin.document_payload_owner_conflict", "document payload factory is already bound or closed") }
            documentPayloadFactory=Some(factory);Result.Ok(())
        } finally { lock.unlock() }
    }
    public func documentPayloadCommitReader(run: RunId,parent: OperationId,operation: OperationId,
        guard: () -> Result<Unit>): Result<HostDocumentPayloadCommitReader> {
        lock.lock()
        let selected: ?(RunId,OperationId,OperationId,() -> Result<Unit>) -> Result<HostDocumentPayloadCommitReader> =
            try { if(closed) { None } else { documentPayloadFactory } } finally { lock.unlock() }
        match(selected) { case Some(factory) => factory(run,parent,operation,guard)
            case None => hostPluginResourceError("plugin.document_payload_owner_missing", "document payload owner is unavailable") }
    }
    public func ownDocumentDataFactory(factory:()->Result<HostDocumentDataSession>):Result<Unit>{
        lock.lock();try{
            if(closed || documentDataFactory.isSome()){return hostPluginResourceError("plugin.document_query_owner_conflict","document data owner is already bound or closed")}
            documentDataFactory=Some(factory);Result.Ok(())
        }finally{lock.unlock()}
    }
    public func documentDataSession():Result<HostDocumentDataSession>{
        lock.lock()
        let selected: ?() -> Result<HostDocumentDataSession> = try{if(closed){None}else{documentDataFactory}}finally{lock.unlock()}
        match(selected){case Some(factory)=>factory();case None=>hostPluginResourceError("plugin.document_query_owner_missing","document data owner is unavailable")}
    }
    public func documentDataWorker(namespace:String,generation:UInt64,thread:String,scope:String):Result<HostDocumentDataWorker>{
        let selected=match(find(namespace)){case Some(value)=>value;case None=>return hostPluginResourceError("plugin.document_query_owner_stale","document worker generation is unavailable")}
        if(selected.instanceGeneration!=generation){return hostPluginResourceError("plugin.document_query_owner_stale","document worker generation changed")}
        let key=stringifyUnifiedJson(objectValue([ValueField("thread",textValue(thread)),ValueField("authority",textValue(scope)),
            ValueField("provider_sequence",textValue("provider-invoke-i63-v1"))]))
        let entry=match(selected.threadHost(key,launcher,providerSequence:true)){
            case JavaScriptHostResult.Err(error)=>retainCleanupError(error);return Result.Err(hostJavascriptPluginAgentError(error))
            case JavaScriptHostResult.Ok(value)=>value}
        entry.dataTransferLock.lock()
        var transferred=false
        try{
            let current=match(selected.threadHost(key,launcher,providerSequence:true)){
                case JavaScriptHostResult.Err(error)=>retainCleanupError(error);return Result.Err(hostJavascriptPluginAgentError(error))
                case JavaScriptHostResult.Ok(value)=>value}
            if(!refEq(entry,current)){return hostPluginResourceError("plugin.document_query_worker_changed","pure data worker changed during selection")}
            let result=HostDocumentDataWorker(entry,entry.host);transferred=true;Result.Ok(result)
        }finally{if(!transferred){entry.dataTransferLock.unlock()}}
    }
    public func contextDataWorker(namespace:String,generation:UInt64,thread:String,scope:String):Result<HostDocumentDataWorker>{
        let selected=match(find(namespace)){case Some(value)=>value;case None=>return hostPluginResourceError("plugin.document_query_owner_stale","document worker generation is unavailable")}
        if(selected.instanceGeneration!=generation){return hostPluginResourceError("plugin.document_query_owner_stale","document worker generation changed")}
        if(thread=="" || !scope.startsWith("pure-context-data:")){
            return hostPluginResourceError("context.document_worker_scope","typed context data worker requires its private pure scope")}
        let key=stringifyUnifiedJson(objectValue([ValueField("thread",textValue(thread)),ValueField("authority",textValue(scope))]))
        let entry=match(selected.threadHost(key,launcher,providerSequence:false)){
            case JavaScriptHostResult.Err(error)=>retainCleanupError(error);return Result.Err(hostJavascriptPluginAgentError(error))
            case JavaScriptHostResult.Ok(value)=>value}
        entry.dataTransferLock.lock()
        var transferred=false
        try{
            let current=match(selected.threadHost(key,launcher,providerSequence:false)){
                case JavaScriptHostResult.Err(error)=>retainCleanupError(error);return Result.Err(hostJavascriptPluginAgentError(error))
                case JavaScriptHostResult.Ok(value)=>value}
            if(!refEq(entry,current)){return hostPluginResourceError("plugin.document_query_worker_changed","pure data worker changed during selection")}
            let result=HostDocumentDataWorker(entry,entry.host);transferred=true;Result.Ok(result)
        }finally{if(!transferred){entry.dataTransferLock.unlock()}}
    }
    // Only the distinct v3 operator journal purpose selects this worker.
    // The profile discriminator is part of its actual process address, not
    // an alias or a reset of an old4096 context connection's counter.
    public func contextJournalDataWorker(namespace:String,generation:UInt64,thread:String,scope:String):Result<HostDocumentDataWorker>{
        let selected=match(find(namespace)){case Some(value)=>value;case None=>return hostPluginResourceError("plugin.document_query_owner_stale","document worker generation is unavailable")}
        if(selected.instanceGeneration!=generation){return hostPluginResourceError("plugin.document_query_owner_stale","document worker generation changed")}
        if(thread=="" || !scope.startsWith("pure-context-journal-data:")){
            return hostPluginResourceError("context.document_worker_scope","typed journal context worker requires its separate private pure scope")}
        let key=stringifyUnifiedJson(objectValue([ValueField("thread",textValue(thread)),ValueField("authority",textValue(scope)),
            ValueField("context_sequence",textValue("context-invoke-i63-v1"))]))
        let entry=match(selected.threadHost(key,launcher,contextSequence:true)){
            case JavaScriptHostResult.Err(error)=>retainCleanupError(error);return Result.Err(hostJavascriptPluginAgentError(error))
            case JavaScriptHostResult.Ok(value)=>value}
        entry.dataTransferLock.lock();var transferred=false
        try{
            let current=match(selected.threadHost(key,launcher,contextSequence:true)){
                case JavaScriptHostResult.Err(error)=>retainCleanupError(error);return Result.Err(hostJavascriptPluginAgentError(error))
                case JavaScriptHostResult.Ok(value)=>value}
            if(!refEq(entry,current)){return hostPluginResourceError("plugin.document_query_worker_changed","pure context journal worker changed during selection")}
            let result=HostDocumentDataWorker(entry,entry.host);transferred=true;Result.Ok(result)
        }finally{if(!transferred){entry.dataTransferLock.unlock()}}
    }
    public func allocateDocumentDataSequence():Result<Int64>{
        lock.lock();try{
            if(closed || nextDocumentQuerySequence==9223372036854775807){return hostPluginResourceError("plugin.document_query_sequence_exhausted","document data sequence cannot wrap")}
            let value=nextDocumentQuerySequence;nextDocumentQuerySequence++;Result.Ok(value)
        }finally{lock.unlock()}
    }
    public func readViewSensitive(source: String): Bool {
        if (hostSensitiveReadPath(source)) { return true }
        for (root in [settingsRoot, readViewStateRoot] where root != "") {
            if (hostPathComponentsContain(Path(root).normalize().toString(), source)) { return true }
        }
        for (part in source.split("/") where
            [".axyndra", ".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".kube"].contains(part.toAsciiLower())) { return true }
        Path(source).fileName.toAsciiLower().startsWith(".env.")
    }
    public func ownContextReadComponents(capture: () -> RegistryContextComponentSnapshot): Result<Unit> {
        lock.lock()
        try {
            if (closed || contextReadComponents.isSome()) {
                return hostPluginResourceError("context.read_scope_owner_conflict", "data root projection is already bound or closed") }
            contextReadComponents = Some(capture); Result.Ok(())
        } finally { lock.unlock() }
    }
    public func contextReadHardSensitive(source: String): Bool {
        if (hostSensitiveReadPath(source) || (readViewStateRoot != "" &&
            hostPathComponentsContain(Path(readViewStateRoot).normalize().toString(), source))) { return true }
        for (part in source.split("/") where
            [".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".kube"].contains(part.toAsciiLower())) { return true }
        Path(source).fileName.toAsciiLower().startsWith(".env.")
    }
    public func captureContextReadScopes(): Result<HostContextReadScopes> {
        // Never hold the process-host lock while entering the existing registry.
        lock.lock(); let provider = try { contextReadComponents } finally { lock.unlock() }
        let components: ?RegistryContextComponentSnapshot = try {
            match (provider) { case Some(capture) => Some(capture()); case None => None }
        } catch (_: Exception) { return hostPluginResourceError("context.read_scopes_changed", "installed data roots are unavailable") }
        try { hostLoadContextReadScopes(this, settingsRoot, components) }
        finally { match (components) { case Some(value) => value.close(); case None => () } }
    }
    public func prepareHttp(context: ToolInvocationContext, call: ToolCall,
        namespace: String, tool: String, generation: UInt64): Result<AgentValue> {
        hostPreparePluginHttpInvocation(this, settingsRoot, namespace, tool, generation, context, call)
    }
    public func prepareReadView(context: ToolInvocationContext, call: ToolCall,
        namespace: String, tool: String, generation: UInt64): Result<AgentValue> {
        hostPreparePluginReadViewInvocation(this, settingsRoot, namespace, tool, generation, context, call)
    }
    public func readonlyDelegationTool(name: String): Bool {
        lock.lock()
        try {
            for (generation in generations where !generation.isClosing() &&
                generation.descriptor.requestedCapabilities.contains("tool.readonly")) {
                for (tool in generation.toolNames() where name == "plugin." + generation.extensionId + "." + tool) { return true }
            }
            false
        } finally { lock.unlock() }
    }
    public func prepareReadonlyDelegation(context: ToolInvocationContext, call: ToolCall,
        namespace: String, tool: String, generation: UInt64): Result<AgentValue> {
        hostPreparePluginReadonlyDelegation(this, settingsRoot, namespace, tool, generation, context, call)
    }
    public func delegationInput(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        namespace: String, tool: String, generation: UInt64): Result<AgentValue> {
        hostValidatePluginReadonlyDelegation(this, settingsRoot, namespace, tool, generation, context, prepared)
    }
    // Classifies an actual current inspected contribution; this is not a grant.
    public func toolExecutionProfile(namespace: String, tool: String,
        generation: UInt64): Result<PluginToolExecutionProfile> {
        let descriptor = match (servicePackageData81(namespace, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        // Pi registers its actual Tools in the ready handshake. Read that
        // same current generation; manifest absence never grants a native Tool.
        if (descriptor.ecosystem == PluginEcosystem.Pi && descriptor.entryKind == PluginEntryKind.JavaScript) {
            lock.lock()
            try {
                match (findLocked(namespace)) {
                    case Some(current) =>
                        if (generation == 0u64 || current.instanceGeneration != generation || current.isClosing() ||
                            current.descriptor.contentDigest != descriptor.contentDigest) {
                            return hostPluginResourceError("plugin.instance_stale", "plugin Tool instance was replaced or revoked")
                        }
                        for (entry in current.tools where entry.name == tool) {
                            if (entry.executionProfile != PluginToolExecutionProfile.Brokered) {
                                return hostPluginResourceError("plugin.tool_profile_changed", "Pi Tool cannot change its brokered execution profile")
                            }
                            return Result.Ok(entry.executionProfile)
                        }
                    case None => return hostPluginResourceError("plugin.instance_stale", "plugin Tool instance was replaced or revoked")
                }
                return hostPluginResourceError("plugin.tool_contribution_missing", "no current registered Pi Tool exists")
            } finally { lock.unlock() }
        }
        for (entry in descriptor.contributions where entry.kind == PluginContributionKind.Tool && entry.name == tool) {
            return Result.Ok(entry.executionProfile) }
        hostPluginResourceError("plugin.tool_contribution_missing", "no current inspected Tool contribution exists")
    }
    public func prepareDataOnlyTool(context: ToolInvocationContext, call: ToolCall,
        namespace: String, tool: String, generation: UInt64): Result<AgentValue> {
        match (toolExecutionProfile(namespace, tool, generation)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(profile) => if (profile != PluginToolExecutionProfile.DataOnly) {
                return hostPluginResourceError("plugin.tool_profile_changed", "Tool no longer has its frozen data-only restriction") }
        }
        if (context.epoch < 1 || call.name != "plugin." + namespace + "." + tool ||
            call.arguments.field(CONTEXT_READ_INPUT_FIELD).isSome() || call.arguments.field("host_plan").isSome()) {
            return hostPluginResourceError("plugin.data_tool_input_invalid", "data-only Tools cannot supply a context fact or Host plan") }
        Result.Ok(call.arguments)
    }
    public func ordinaryToolInput(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        namespace: String, tool: String, generation: UInt64): Result<AgentValue> {
        let descriptor = match (servicePackageData81(namespace, generation)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let profile = match (toolExecutionProfile(namespace, tool, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (profile == PluginToolExecutionProfile.DataOnly) {
            let plan = prepared.operationPlan
            let version = match (instanceExecutorVersion(namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (plan.toolName != "plugin." + namespace + "." + tool ||
                plan.implementation.toolVersion != version ||
                plan.implementation.implementationFingerprint != namespace + ":" + descriptor.contentDigest ||
                plan.requiredCapabilities.size != 1 || plan.requiredCapabilities[0].kind != CapabilityKind.WorkspaceRead ||
                plan.effectClass != OperationEffectClass.ReadOnly || !networkPolicyModeIsDenied(plan.networkPolicy.mode) ||
                !plan.networkPolicy.egress.isEmpty() || !plan.networkPolicy.publish.isEmpty() ||
                !plan.resolvedHosts.isEmpty() || !plan.contextReadFacts.isEmpty()) {
                return hostPluginResourceError("plugin.tool_profile_changed", "data-only Tool lost its exact current contribution and restricted plan") }
            return prepareDataOnlyTool(context, ToolCall(prepared.call.callId, prepared.call.name,
                plan.canonicalArguments), namespace, tool, generation)
        }
        let primitive = match (primitiveSelected191(namespace, tool, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (primitive || isFrozenPluginChildParent111(prepared.operationPlan)) {
            return hostChildInvocationInput111(this, context, prepared, namespace, tool, generation) }
        if (descriptor.requestedCapabilities.contains("tool.readonly")) { return delegationInput(context, prepared, namespace, tool, generation) }
        readViewInput(prepared, namespace, tool, generation)
    }
    func readViewInvocationWindow(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        namespace: String, tool: String, generation: UInt64): Result<?HostReadViewCallWindow> {
        let descriptor = match (servicePackageData81(namespace, generation)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (!descriptor.requestedCapabilities.contains("process.readview")) { return Result<?HostReadViewCallWindow>.Ok(Option<HostReadViewCallWindow>.None) }
        match (readViewInput(prepared, namespace, tool, generation)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let configuration = match (loadHostPluginHttpConfiguration(settingsRoot, namespace, descriptor.contentDigest)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let intent = prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("intents").getOrThrow().items[0]
        match (intent.field("deadline_profile")) { case None => Result<?HostReadViewCallWindow>.Ok(Option<HostReadViewCallWindow>.None)
            case Some(value) => Result<?HostReadViewCallWindow>.Ok(Some(HostReadViewCallWindow(this, context, prepared,
                namespace, tool, generation, configuration.digest, value))) }
    }
    func captureReadonlyReadViewTarget(catalog: ToolCatalog, context: ToolInvocationContext,
        call: ToolCall): Result<HostReadOnlyExecReadView> {
        let namespace = namespaceForQualifiedTool(call.name)
        let contribution = contributionForQualifiedTool(call.name)
        let generation = instanceGeneration(namespace)
        let descriptor = match (servicePackageData81(namespace, generation)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let profile = match (toolExecutionProfile(namespace, contribution, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (descriptor.entryKind != PluginEntryKind.NativeExecutable || !descriptor.requestedCapabilities.contains("process.readview") ||
            descriptor.requestedCapabilities.any({cap => cap != "process.readview" && cap != "workspace.read"}) ||
            profile != PluginToolExecutionProfile.Brokered) {
            return hostPluginResourceError("extension.exec_target_family", "readonly exec requires an actual native brokered read-view publication") }
        let configuration = match (loadHostPluginHttpConfiguration(settingsRoot, namespace, descriptor.contentDigest)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (!configuration.ordinaryReadTools.contains(contribution)) {
            return hostPluginResourceError("extension.exec_grant_missing", "actual operator has not granted this ordinary read-view contribution") }
        match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let version = match (instanceExecutorVersion(namespace, generation)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let schema = match (currentToolSchemaDigest(namespace, contribution, generation)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let published = match (catalog.publishedDescriptor(call.name, threadId: Some(ThreadId(context.sessionId.value)))) {
            case None => return hostPluginResourceError("extension.exec_target_missing", "readonly exec target is not published to the actual Thread"); case Some(value) => value }
        if (published.implementationVersion != version || published.implementationFingerprint != namespace + ":" + descriptor.contentDigest ||
            published.schemaDigest != schema || published.capability.kind != CapabilityKind.ExtensionInvoke || published.capability.resource != call.name ||
            published.controlOnly || published.hostServiceOnly) {
            return hostPluginResourceError("extension.exec_target_changed", "readonly exec target differs from actual ready package, schema and generation") }
        Result.Ok(HostReadOnlyExecReadView(this, namespace, contribution, generation, descriptor.contentDigest, configuration.digest))
    }
    public func readViewInput(prepared: PreparedToolInvocation, namespace: String, tool: String,
        generation: UInt64): Result<AgentValue> {
        hostValidatePluginReadViewParent(this, settingsRoot, prepared.operationPlan, namespace, tool, generation)
    }
    public func mount(record: ProductPluginRecord): Result<Array<JavaScriptToolDescriptor>> {
        // Registry locking/reload is outside the Host lock. The same object is
        // shared with management; the captured pin never calls back into it.
        let registry = synchronized(lock) { installedRegistry }
        let actualRegistry = match (registry) { case Some(value) => value; case None =>
            return hostPluginResourceError("plugin.registry_owner_missing", "activation requires the actual installed registry") }
        let pin = match (actualRegistry.captureExecutionPin(record)) {
            case PluginRegistryResult.Err(error) => return hostRegistryOwnedError81(error)
            case PluginRegistryResult.Ok(value) => value
        }
        var retained = false
        try {
            let actual = match (pin.capturedRecord()) {
                case PluginRegistryResult.Err(error) => return hostRegistryOwnedError81(error)
                case PluginRegistryResult.Ok(value) => value
            }
            let result = try { mountCaptured(actual, pin) } finally { actual.close() }
            match (result) { case Result.Ok(_) => retained = true; case Result.Err(_) => () }
            result
        } finally { if (!retained) { pin.close() } }
    }
    private func mountCaptured(record: ProductPluginRecord, pin: PluginRegistryExecutionPin): Result<Array<JavaScriptToolDescriptor>> {
        if (!cleanupCapacityAvailable()) {
            return hostPluginResourceError("plugin.cleanup_capacity", "failed native worker cleanup still occupies host capacity")
        }
        let owner = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let result = try { mountDescriptorFrame159(record, pin, owner) }
        catch (error: Exception) { owner.retainLegacy159(); throw error }
        owner.returnedMountFrame159()
        result
    }
    private func mountDescriptorFrame159(record: ProductPluginRecord, pin: PluginRegistryExecutionPin,
        owner: HostRegistryMountDescriptor159): Result<Array<JavaScriptToolDescriptor>> {
        let descriptor = owner.mountDescriptor159()
        let dependencies = match (captureComponentDependencies(descriptor)) {
            // This original branch constructs a dynamic dependency diagnostic.
            // Its raw error has no consumer retirement contract yet.
            case Result.Err(error) => owner.retainLegacy159(); return Result.Err(error)
            case Result.Ok(value) => value
        }
        if (descriptor.ecosystem != PluginEcosystem.Pi &&
            !(descriptor.ecosystem == PluginEcosystem.Axyndra &&
                descriptor.entryKind == PluginEntryKind.NativeExecutable)) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.ecosystem_unsupported",
                "plugin activation requires a supported process protocol or Pi adapter"
            ))
        }
        if (descriptor.entrypoint.trimAscii() == "") {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.entrypoint_missing",
                "JavaScript plugin activation requires an entrypoint"
            ))
        }
        for (capability in descriptor.requestedCapabilities) {
            if (capability != "workspace.read" && capability != "workspace.write" &&
                !((capability == "network.http" || capability == "process.channel" || capability == "process.readview" || capability == "tool.readonly" || capability == "document.store") && descriptor.entryKind == PluginEntryKind.NativeExecutable)) {
                return Result.Err(AgentError(
                    AgentErrorKind.PermissionDenied,
                    "plugin.capability_unsupported",
                    "process host supports workspace access; HTTP requests additionally require the native preparation protocol"
                ))
            }
        }
        // A process-local sequence is not an executor identity: it repeats after
        // restart. Mint fresh host entropy for every successful mount and never
        // derive it from package input or a plugin-provided generation.
        let instanceIdentity = match (hostNewPluginInstanceIdentity()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        // Request/command/catalog raw aliases remain conservative legacy escapes.
        // Retain before their first constructor or asynchronous process launch.
        owner.retainLegacy159()
        let bootstrap = match (hostStartRegistryJavaScriptHost159(descriptor, 1u64, launcher, pin)) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) =>
                retainCleanupError(error)
                return Result.Err(hostJavascriptPluginAgentError(error))
        }
        let tools = bootstrap.tools
        let commands = bootstrap.commands
        let views = bootstrap.views
        let hooks = bootstrap.hooks
        let services = bootstrap.services
        let modelProviders = bootstrap.modelProviders
        let contextProviders = bootstrap.contextProviders
        let resourceProviders = bootstrap.resourceProviders
        let policyProviders = bootstrap.policyProviders
        bootstrap.close()
        retainCleanupOwner(bootstrap)
        lock.lock()
        try {
            if (closed) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "plugin.host_closed",
                    "JavaScript plugin host is closed"
                ))
            }
            if (findLocked(descriptor.namespace).isSome()) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "plugin.already_active",
                    "the plugin already has an active JavaScript generation"
                ))
            }
            for (dependency in dependencies) {
                let current = findLocked(dependency.extensionId)
                if (dependency.isClosing() || current.isNone() ||
                    !refEq(current.getOrThrow(), dependency)) {
                    return hostPluginResourceError("plugin.component_dependency_changed", "dependency changed while the candidate instance initialized")
                }
            }
            match (pin.current()) { case PluginImportResult.Err(error) => return hostRegistryFenceError90(descriptor, error); case PluginImportResult.Ok(_) => () }
            generations.add(HostJavaScriptPluginGeneration(
                descriptor, pin, installedRegistry.getOrThrow(), tools, commands, views, hooks, 2u64, nextInstanceGeneration, instanceIdentity, services: services, modelProviders: modelProviders, contextProviders: contextProviders, resourceProviders: resourceProviders, policyProviders: policyProviders
            ))
            nextInstanceGeneration += 1u64
            Result.Ok(tools)
        } finally {
            lock.unlock()
        }
    }

    public func currentToolSchemaDigest(namespace: String, contribution: String,
        expectedGeneration: UInt64): Result<String> {
        lock.lock()
        try {
            match (findLocked(namespace)) {
                case Some(current) =>
                    if (expectedGeneration == 0u64 || current.instanceGeneration != expectedGeneration || current.isClosing()) {
                        return hostPluginResourceError("plugin.instance_stale", "actual ready Tool generation is no longer current")
                    }
                    for (tool in current.tools where tool.name == contribution) {
                        let schema = match (decodeAgentValue(tool.inputSchemaJson, maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES)) {
                            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                        return Result.Ok(modelPolicySha256Text(canonicalAgentValue(schema)))
                    }
                case None => ()
            }
            hostPluginResourceError("plugin.tool_contribution_missing", "actual ready Tool contribution is absent")
        } finally { lock.unlock() }
    }

    public func toolNames(extensionId: String): Array<String> {
        lock.lock()
        try {
            match (findLocked(extensionId.trimAscii())) {
                case Some(value) => value.toolNames()
                case None => []
            }
        } finally {
            lock.unlock()
        }
    }
    // Frozen executors and command routes bind the mounted instance, not just
    // its package name. Reinstalling identical bytes still creates a new scope.
    public func instanceGeneration(extensionId: String): UInt64 {
        lock.lock()
        try {
            match (findLocked(extensionId)) {
                case Some(value) => value.instanceGeneration
                case None => 0u64
            }
        } finally { lock.unlock() }
    }

    public func instanceGeneration(descriptor: OwnedPluginPackageDescriptor): UInt64 {
        lock.lock()
        try {
            for (current in generations) {
                if (descriptor.textEquals(PluginDescriptorText.Namespace, current.extensionId)) { return current.instanceGeneration }
            }
            0u64
        } finally { lock.unlock() }
    }
    public func instanceExecutorVersion(extensionId: String, expectedGeneration: UInt64): Result<String> {
        lock.lock()
        try {
            match (findLocked(extensionId)) {
                case Some(value) =>
                    if (expectedGeneration != 0u64 &&
                        value.instanceGeneration == expectedGeneration && !value.isClosing()) {
                        return Result.Ok("native-adapter-v1:" + value.descriptor.version + ":" + value.instanceIdentity)
                    }
                case None => ()
            }
            hostPluginResourceError("plugin.instance_stale", "plugin executor instance is no longer active")
        } finally { lock.unlock() }
    }

    // Same installed generation registry; querying content creates no new
    // catalog, Tool route, Run, Operation or permission grant.
    public func contentProviderBinding(namespace: String, contribution: String,
        resource: Bool): Result<HostPluginContentBinding> {
        let generation = match (find(namespace)) {
            case Some(value) => value
            case None => return hostPluginResourceError("context.provider_missing", "content provider package is not active")
        }
        if (generation.isClosing()) { return hostPluginResourceError("context.provider_revoked", "content provider was revoked") }
        let packageMatches = match (registryPackageMatches81(generation.descriptor.root, namespace: Some(namespace),
            digest: Some(generation.descriptor.contentDigest))) {
            case Result.Err(_) => return hostPluginResourceError("context.provider_changed", "content package can no longer be verified")
            case Result.Ok(value) => value }
        if (!packageMatches) {
            return hostPluginResourceError("context.provider_changed", "content package bytes differ from the enabled snapshot")
        }
        let providers = if (resource) { generation.resourceProviders } else { generation.contextProviders }
        for (item in providers where item.name == contribution) {
            return Result.Ok(HostPluginContentBinding(generation.descriptor.namespace, generation.descriptor.contentDigest,
                generation.descriptor.version, generation.instanceGeneration, contribution, resource))
        }
        hostPluginResourceError("context.provider_missing", "the installed package has no exact typed content contribution")
    }

    // A pure policy is selected from the same immutable installed generation.
    // It has no Tool, Run, service, state-write or model-dispatch authority.
    public func policyProviderBinding(namespace: String, contribution: String): Result<HostPluginPolicyBinding> {
        let diagnosticStarted = MonoTime.now()
        try {
        let generation = match (find(namespace)) {
            case Some(value) => value
            case None => return hostPluginResourceError("policy.provider_missing", "policy provider package is not active") }
        if (generation.isClosing()) { return hostPluginResourceError("policy.provider_revoked", "policy provider was revoked") }
        let packageMatches = match (registryPackageMatches81(generation.descriptor.root, namespace: Some(namespace),
            digest: Some(generation.descriptor.contentDigest))) {
            case Result.Err(error) =>
                // Registry inspection needs the same shared metadata bank as the
                // caller's own bounded query. When the bank is exhausted the
                // inspection fails with the capacity code, which is a bounded
                // resource limit, not evidence that the installed package
                // changed. Preserve that fact so a caller under pressure still
                // observes the limit it actually hit; every other inspection
                // failure keeps the existing changed-package classification.
                if (error.code == "plugin.registry_metadata_capacity") {
                    return hostPluginResourceError("policy.query_limit", "policy package cannot be inspected within the original aggregate")
                }
                return hostPluginResourceError("policy.provider_changed", "policy package cannot be verified")
            case Result.Ok(value) => value }
        if (!packageMatches) {
            return hostPluginResourceError("policy.provider_changed", "policy package differs from the installed snapshot") }
        for (item in generation.policyProviders where item.name == contribution) {
            return Result.Ok(HostPluginPolicyBinding(namespace, contribution, generation.descriptor.contentDigest, generation.instanceGeneration)) }
        hostPluginResourceError("policy.provider_missing", "installed package has no exact pure policy contribution")
        } finally { hostCompactionDiagnosticRecord("binding", diagnosticStarted) }
    }

    // Synchronous data consumption only; this fence grants no Source,
    // capability, operation or cut. The action may enter the canonical DB,
    // but must not reenter this Host, launch a worker or await another task.
    // Unmount uses the same mutex; Registry mutation uses the held SH fence.
    public func withCurrentPolicyData(namespace: String, contribution: String,
        expectedGeneration: UInt64, packageDigest: String, action: () -> Result<Unit>): Result<Unit> {
        let checked = match (policyProviderBinding(namespace, contribution)) {
            case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(value) => value }
        if (checked.generation != expectedGeneration || checked.digest != packageDigest) {
            return hostPluginResourceError<Unit>("policy.provider_changed", "policy package differs from its current data loan") }
        lock.lock()
        try {
            if (closed || expectedGeneration == 0u64) {
                return hostPluginResourceError<Unit>("policy.provider_revoked", "policy data owner is closed") }
            for (current in generations where current.extensionId == namespace) {
                var selected = false
                for (item in current.policyProviders where item.name == contribution) { selected = true }
                if (current.instanceGeneration != expectedGeneration || current.isClosing() ||
                    current.descriptor.contentDigest != packageDigest || !selected) {
                    return hostPluginResourceError<Unit>("policy.provider_changed", "actual policy generation differs from its data loan") }
                let fence = match (current.enterRegistryEffect()) {
                    case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(value) => value }
                try { return action() } finally { fence.close() }
            }
            hostPluginResourceError<Unit>("policy.provider_revoked", "policy data package is no longer mounted")
        } finally { lock.unlock() }
    }

    // Same installed generation registry, no model-specific mutable catalog.
    public func modelProviderDeclaration(namespace: String, expectedGeneration: UInt64,
        contribution: String): Result<PluginModelProviderDescriptor> {
        let generation = match (find(namespace)) {
            case Some(value) => value
            case None => return hostPluginResourceError("model.provider_plugin_missing", "ModelProvider package is not enabled")
        }
        if (expectedGeneration == 0u64 || generation.instanceGeneration != expectedGeneration || generation.isClosing()) {
            return hostPluginResourceError("model.provider_instance_stale", "ModelProvider instance was replaced or revoked")
        }
        for (item in generation.modelProviders where item.name == contribution) { return Result.Ok(item) }
        hostPluginResourceError("model.provider_contribution_missing", "installed package has no exact ModelProvider contribution")
    }

    func servicePackageData81(extensionId: String, expectedGeneration: UInt64): Result<PluginPackageDescriptor> {
        let generation = match (find(extensionId)) {
            case Some(value) => value
            case None => return hostPluginResourceError("plugin.not_active", "plugin service instance is no longer active")
        }
        if (expectedGeneration == 0u64 || generation.instanceGeneration != expectedGeneration || generation.isClosing()) {
            return hostPluginResourceError("plugin.instance_stale", "plugin service instance was replaced or revoked")
        }
        Result.Ok(generation.descriptor)
    }

    public func servicePackage(extensionId: String, expectedGeneration: UInt64): Result<OwnedPluginPackageDescriptor> {
        let generation = match (find(extensionId)) {
            case Some(value) => value
            case None => return hostPluginResourceError("plugin.not_active", "plugin service instance is no longer active")
        }
        if (expectedGeneration == 0u64 || generation.instanceGeneration != expectedGeneration || generation.isClosing()) {
            return hostPluginResourceError("plugin.instance_stale", "plugin service instance was replaced or revoked")
        }
        generation.ownedDescriptor81()
    }

    public func registryPackageMatches81(root: String, namespace!: ?String = None, version!: ?String = None,
        digest!: ?String = None, entrypoint!: ?String = None): Result<Bool> {
        let registry = synchronized(lock) { installedRegistry }
        match (registry) {
            case None => hostPluginResourceError("plugin.registry_owner_missing", "package inspection requires the actual installed registry")
            case Some(value) => hostRegistryPackageMatches81(value, root, namespace: namespace, version: version,
                digest: digest, entrypoint: entrypoint)
        }
    }

    // This fence proves installed-state freshness only. Actual source, intent,
    // Run, Operation and capability checks remain at each caller.
    func enterRegistryEffect(namespace: String, expectedGeneration: UInt64): Result<PluginRegistryExecutionFence> {
        lock.lock(); try {
            let current = match (findLocked(namespace)) { case Some(value) => value; case None =>
                return hostPluginResourceError("plugin.instance_stale", "plugin instance is not mounted") }
            if (closed || expectedGeneration == 0u64 || current.instanceGeneration != expectedGeneration) {
                return hostPluginResourceError("plugin.instance_stale", "plugin instance was replaced or closed")
            }
            current.enterRegistryEffect()
        } finally { lock.unlock() }
    }

    // Only package-private host code can enter this gate. Unmount/beginClose
    // uses this same mutex. Callback may acquire the canonical database, but
    // must not reenter this host or the Runtime lock.
    public func commitDocumentEffect(namespace: String, expectedGeneration: UInt64,
        packageDigest: String, commit: () -> Result<Unit>): Result<Unit> {
        lock.lock()
        try {
            if (closed || expectedGeneration == 0u64) {
                return hostPluginResourceError("plugin.document_owner_stale", "document invocation owner is closed") }
            for (current in generations where current.extensionId == namespace) {
                if (current.instanceGeneration != expectedGeneration || current.isClosing() ||
                    current.descriptor.contentDigest != packageDigest ||
                    !current.descriptor.requestedCapabilities.contains("document.store")) {
                    return hostPluginResourceError("plugin.document_owner_stale", "document invocation package was replaced or revoked") }
                let fence = match (current.enterRegistryEffect()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                try { return commit() } finally { fence.close() }
            }
            hostPluginResourceError("plugin.document_owner_stale", "document invocation package is no longer mounted")
        } finally { lock.unlock() }
    }

    public func documentJournalStorageConfiguration(namespace:String,packageDigest:String):Result<HostPluginDocumentJournalStorageConfiguration>{
        loadHostPluginDocumentJournalStorageConfiguration(settingsRoot,namespace,packageDigest)
    }
    public func documentJournalReadConfiguration(namespace:String,packageDigest:String,provider:String,
        contribution:String,contextRead:Bool):Result<HostPluginDocumentJournalReadConfiguration>{
        loadHostPluginDocumentJournalReadConfiguration(settingsRoot,namespace,packageDigest,provider,contribution,contextRead)
    }
    public func livePolicyConfiguration(namespace:String,packageDigest:String,contribution:String):Result<?HostPluginLivePolicyConfiguration>{
        loadHostPluginLivePolicyConfiguration(settingsRoot,namespace,packageDigest,contribution)
    }
    public func documentContextWindowConfiguration(namespace:String,packageDigest:String,provider:String):Result<HostPluginDocumentContextWindowConfiguration>{
        loadHostPluginDocumentContextWindowConfiguration(settingsRoot,namespace,packageDigest,provider)
    }
    public func documentContextConfiguration(namespace:String,packageDigest:String,provider:String):Result<HostPluginDocumentContextConfiguration>{
        loadHostPluginDocumentContextConfiguration(settingsRoot,namespace,packageDigest,provider)
    }
    func primitiveConfiguration111(namespace: String, localTool: String,
        generation: UInt64): Result<?HostPrimitiveConfiguration111> {
        let descriptor = match (servicePackageData81(namespace, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let selected = match (primitiveConfigurations111.loadCompatibility191(this, settingsRoot, namespace, descriptor.contentDigest, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (selected) {
            case Some(value) => if (value.permits(localTool)) {
                let profile = match (toolExecutionProfile(namespace, localTool, generation)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(actual) => actual }
                if (descriptor.entryKind != PluginEntryKind.NativeExecutable || profile != PluginToolExecutionProfile.Brokered) {
                    return hostPluginResourceError("child.profile_invalid", "primitive selection requires an actual Native brokered Tool") }
                return Result.Ok(Some(value)) }
            case None => () }
        Result<?HostPrimitiveConfiguration111>.Ok(Option<HostPrimitiveConfiguration111>.None)
    }
    func primitiveConfigurationOwned191(namespace: String, localTool: String,
        generation: UInt64): Result<?HostOwnedPrimitiveConfiguration191> {
        let descriptor = match (servicePackageData81(namespace, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let selected = match (primitiveConfigurations111.loadOwned191(this, settingsRoot, namespace, descriptor.contentDigest, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (selected) {
            case Some(value) =>
                let accepted = primitiveConfigurationValidationFrame191(namespace, localTool, generation, descriptor, value)
                match (accepted) {
                    case Result.Ok(true) => return Result.Ok(Some(value))
                    case Result.Ok(false) => value.returnOwnedPrimitive191()
                    case Result.Err(error) => value.returnOwnedPrimitive191(); return Result.Err(error)
                }
            case None => () }
        Result<?HostOwnedPrimitiveConfiguration191>.Ok(None<HostOwnedPrimitiveConfiguration191>)
    }
    private func primitiveConfigurationValidationFrame191(namespace: String, localTool: String,
        generation: UInt64, descriptor: PluginPackageDescriptor, selected: HostOwnedPrimitiveConfiguration191): Result<Bool> {
        if (!selected.permits(localTool)) { return Result<Bool>.Ok(false) }
        let profile = match (toolExecutionProfile(namespace, localTool, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(actual) => actual }
        if (descriptor.entryKind != PluginEntryKind.NativeExecutable || profile != PluginToolExecutionProfile.Brokered) {
            return hostPluginResourceError("child.profile_invalid", "primitive selection requires an actual Native brokered Tool") }
        Result<Bool>.Ok(true)
    }
    private func primitiveSelected191(namespace: String, localTool: String, generation: UInt64): Result<Bool> {
        let selected = match (primitiveConfigurationOwned191(namespace, localTool, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let result = primitiveSelectedFrame191(selected)
        match (selected) { case Some(value) => value.returnOwnedPrimitive191(); case None => () }
        Result<Bool>.Ok(result)
    }
    private func primitiveSelectedFrame191(selected: ?HostOwnedPrimitiveConfiguration191): Bool { selected.isSome() }
    // Readonly numeric observation of this Host's actual linked DATA cells.
    // It cannot fabricate a Source, response, physical ACK or retirement.
    public func canonicalProjectionPublicTextDebtCount193(): Int64 {
        // Read-only diagnostics: this grants no retirement, Source or permit.
        canonicalProjectionConfigurations173.publicTextDebtCount186()
    }
    public func canonicalProjectionExecutionCellCount173(): Int64 {
        canonicalProjectionConfigurations173.retainedExecutionCellCount173()
    }
    func canonicalProjectionConfiguration173(namespace: String, localTool: String,
        generation: UInt64): Result<?HostCanonicalProjectionSelection173> {
        let descriptor = match (servicePackageData81(namespace, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let profile = match (toolExecutionProfile(namespace, localTool, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (descriptor.entryKind != PluginEntryKind.NativeExecutable || profile != PluginToolExecutionProfile.DataOnly) {
            return hostPluginResourceError("plugin.canonical_projection_profile_invalid", "canonical-data projection requires its actual Native data-only contribution") }
        canonicalProjectionConfigurations173.load(this, settingsRoot, namespace, descriptor.contentDigest, localTool, generation)
    }
    func canonicalProjectionConfigurationOwned186(namespace: String, localTool: String,
        generation: UInt64): Result<?HostOwnedCanonicalProjectionSelection186> {
        let descriptor = match (servicePackageData81(namespace, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let profile = match (toolExecutionProfile(namespace, localTool, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (descriptor.entryKind != PluginEntryKind.NativeExecutable || profile != PluginToolExecutionProfile.DataOnly) {
            return hostPluginResourceError("plugin.canonical_projection_profile_invalid", "canonical-data projection requires its actual Native data-only contribution") }
        canonicalProjectionConfigurations173.loadOwned186(this, settingsRoot, namespace, descriptor.contentDigest, localTool, generation)
    }
    public func documentConfiguration(namespace: String, packageDigest: String): Result<HostPluginDocumentConfiguration> {
        let selected=match(loadHostPluginDocumentConfiguration(settingsRoot,namespace,packageDigest)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(configureDocumentBackends(selected)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(selected)
    }

    public func observeServiceRevocation(
        extensionId: String, expectedGeneration: UInt64, callback: () -> Unit
    ): Result<process.CancellationRegistration> {
        let generation = match (find(extensionId)) {
            case Some(value) => value
            case None => return hostPluginResourceError("plugin.not_active", "plugin service instance is no longer active")
        }
        if (expectedGeneration == 0u64 || generation.instanceGeneration != expectedGeneration) {
            return hostPluginResourceError("plugin.instance_stale", "plugin service instance was replaced")
        }
        generation.observeRevocation(callback)
    }

    // Paired with the actual Returning159 cancellation implementation. This
    // sibling preserves the original mounted generation lookup/current test.
    public func observeServiceRevocationReturning180(extensionId:String,
        expectedGeneration:UInt64,callback:()->Unit):Result<process.CancellationRegistration>{
        let generation=match(find(extensionId)){case Some(value)=>value;case None=>
            return hostPluginResourceError("plugin.not_active","plugin service instance is no longer active")}
        if(expectedGeneration==0u64 || generation.instanceGeneration!=expectedGeneration){
            return hostPluginResourceError("plugin.instance_stale","plugin service instance was replaced")}
        generation.observeRevocationReturning180(callback)
    }

    public func serviceInstanceIdentity(extensionId: String, expectedGeneration: UInt64): Result<String> {
        match (find(extensionId)) {
            case Some(value) =>
                if (expectedGeneration > 0u64 && value.instanceGeneration == expectedGeneration && !value.isClosing()) {
                    return Result.Ok(value.instanceIdentity)
                }
            case None => ()
        }
        hostPluginResourceError("plugin.instance_stale", "service instance is no longer mounted")
    }

    // Trusted composition only: creates the powerless package adapter, not the
    // configured backend. Selection/grant data never attests an Operation or
    // authorizes broker I/O. The lifecycle manager owns admission and quotas.
    public func pinServiceEndpoint(grant: HostNativeServiceEndpointGrant, targetContext: ToolInvocationContext, maintenanceThread: ThreadId,
        route: String, expectedGeneration: UInt64,
        startupContext!: ?ToolInvocationContext = None,
        leaseCancellation!: ?CancellationToken = None): HostServiceEndpointSelection {
        if (targetContext.cancellation.isCancelled()) {
            return hostServiceSelectionError("extension.cancelled", "endpoint selection was cancelled before spawn")
        }
        let plan = grant.endpointBinding()
        let namespace = hostLifecycleText(plan, "namespace")
        let generation = match (find(namespace)) {
            case Some(value) => value
            case None => return hostServiceSelectionError("plugin.instance_stale", "service instance is no longer mounted")
        }
        if (expectedGeneration == 0u64 || generation.instanceGeneration != expectedGeneration || generation.isClosing() ||
            generation.descriptor.entryKind != PluginEntryKind.NativeExecutable ||
            generation.descriptor.contentDigest != hostLifecycleText(plan, "package_digest") ||
            generation.instanceIdentity != grant.endpointInstanceIdentity() || maintenanceThread.value == grant.endpointTargetThread().value ||
            targetContext.sessionId.value != grant.endpointTargetThread().value ||
            targetContext.workspaceRoot != hostLifecycleText(plan, "workspace_root") ||
            hostPluginInvocationAuthorityScope(targetContext) != hostLifecycleText(plan, "permission_domain") ||
            !hostJavascriptPluginLimitsFitHost(targetContext.budget.processLimits) ||
            maintenanceThread.value.size > 256 || grant.endpointTargetThread().value.size > 256 ||
            maintenanceThread.value.contains("\u{0}")) {
            return hostServiceSelectionError("plugin.service_binding_invalid", "service endpoint requires an exact native instance and distinct host Threads")
        }
        var declared = false
        for (service in generation.services where service.name == route) { declared = true }
        if (!declared) { return hostServiceSelectionError("extension.service_not_registered", "service route is not declared by this instance") }
        match (grant.stillCurrent()) { case Result.Err(error) => return HostServiceEndpointSelection.Rejected(error); case Result.Ok(_) => () }
        let nonce = match (hostNewPluginInstanceIdentity()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return HostServiceEndpointSelection.Rejected(error)
        }
        // Package verification belongs to the real startup/lease window. The
        // much shorter endpoint handshake begins only after that verification.
        let now = agentUtcMillis()
        var launchDeadline = now + hostLifecycleInt(plan, "lifetime_ms", 3600000)
        for (deadline in [targetContext.cancellation.deadlineMillis, targetContext.budget.deadlineMillis] where deadline > 0) {
            launchDeadline = min(launchDeadline, deadline)
        }
        match (startupContext) {
            case Some(context) =>
                for (deadline in [context.cancellation.deadlineMillis, context.budget.deadlineMillis] where deadline > 0) {
                    launchDeadline = min(launchDeadline, deadline)
                }
            case None => ()
        }
        if (launchDeadline <= now) { return hostServiceSelectionError("extension.cancelled", "parent deadline expired before endpoint spawn") }
        let launchCancellation = process.CancellationSource(deadlineMillis: launchDeadline)
        let registrations = ArrayList<CancellationRegistration>()
        registrations.add(targetContext.cancellation.onCancel({ _ => let _ = launchCancellation.cancel() }))
        match (startupContext) {
            case Some(context) => registrations.add(context.cancellation.onCancel({ _ => let _ = launchCancellation.cancel() }))
            case None => ()
        }
        match (leaseCancellation) {
            case Some(token) => registrations.add(token.onCancel({ _ => let _ = launchCancellation.cancel() }))
            case None => ()
        }
        let started = try {
            generation.pinServiceHost("pinned-service:" + nonce, launcher, launchCancellation.token,
                serviceProtocolLimits(grant.endpointBinding()).value().getOrThrow(), servicePayloadLimits(grant.endpointBinding()).value().getOrThrow())
        } finally {
            for (registration in registrations) { registration.dispose() }
            launchCancellation.close()
        }
        let entry = match (started) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) =>
                match (error.cleanupHost) {
                    case Some(failedHost) =>
                        let retained = generation.retainFailedPinnedHost("pinned-service:" + nonce, failedHost)
                        let failed = HostPinnedNativeServiceEndpoint(serviceEndpointSeal, generation, retained, grant,
                            maintenanceThread, route, nonce)
                        return hostFailedServiceSelection(failed, hostJavascriptPluginAgentError(error))
                    case None => return HostServiceEndpointSelection.Rejected(hostJavascriptPluginAgentError(error))
                }
        }
        let endpoint = HostPinnedNativeServiceEndpoint(serviceEndpointSeal, generation, entry, grant,
            maintenanceThread, route, nonce)
        match (generation.observeRevocation({ => endpoint.revoke() })) {
            case Result.Ok(registration) => endpoint.attachRevocation(registration)
            case Result.Err(error) => return hostFailedServiceSelection(endpoint, error)
        }
        if (!endpoint.available()) {
            return hostFailedServiceSelection(endpoint, AgentError(AgentErrorKind.Cancelled,
                "plugin.service_endpoint_stale", "service instance was revoked while selecting its endpoint"))
        }
        HostServiceEndpointSelection.Ready(endpoint)
    }

    public func prepareService(endpoint: HostPinnedNativeServiceEndpoint, argumentsJson: String,
        identity: JavaScriptHostInvocationIdentity, context: ToolInvocationContext,
        timeoutMillis!: Int64 = 5000, decodedData180!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>): Result<HostJavaScriptPluginInvocationResult> {
        invokePinnedService(endpoint, argumentsJson, identity, context, "service_prepare", timeoutMillis, Option<JavaScriptHostObserver>.None, Option<PreparedToolInvocation>.None, decodedData180)
    }

    public func invokeService(endpoint: HostPinnedNativeServiceEndpoint, argumentsJson: String,
        identity: JavaScriptHostInvocationIdentity, context: ToolInvocationContext,
        timeoutMillis!: Int64 = 30000,
        observer!: ?JavaScriptHostObserver = None,
        prepared!: ?PreparedToolInvocation = None): Result<HostJavaScriptPluginInvocationResult> {
        invokePinnedService(endpoint, argumentsJson, identity, context, "service", timeoutMillis, observer, prepared, None<LogicalJsonOwnerReservation>)
    }

    private func invokePinnedService(endpoint: HostPinnedNativeServiceEndpoint, argumentsJson: String,
        identity: JavaScriptHostInvocationIdentity, context: ToolInvocationContext, kind: String,
        timeoutMillis: Int64,
        observer: ?JavaScriptHostObserver, prepared: ?PreparedToolInvocation, decodedData180: ?LogicalJsonOwnerReservation): Result<HostJavaScriptPluginInvocationResult> {
        if (!refEq(endpoint.seal, serviceEndpointSeal)) {
            return hostPluginResourceError("plugin.service_endpoint_foreign", "endpoint belongs to a different host owner")
        }
        match (find(endpoint.namespace)) {
            case Some(value) => if (!refEq(value, endpoint.generation)) {
                return hostPluginResourceError("plugin.service_endpoint_stale", "selected service instance was replaced")
            }
            case None => return hostPluginResourceError("plugin.service_endpoint_stale", "selected service instance was removed")
        }
        if (identity.kind != kind || !hostJavascriptPluginLimitsFitHost(context.budget.processLimits)) {
            return hostPluginResourceError("plugin.service_invocation_invalid", "service kind or adapter resource envelope does not match")
        }
        endpoint.invoke(argumentsJson, identity, context, timeoutMillis, observer, prepared: prepared, decodedData180: decodedData180)
    }

    public func closeServiceEndpoint(endpoint: HostPinnedNativeServiceEndpoint,
        timeoutMillis!: Int64 = 1000): Result<Unit> {
        if (!refEq(endpoint.seal, serviceEndpointSeal)) {
            return hostPluginResourceError("plugin.service_endpoint_foreign", "endpoint belongs to a different host owner")
        }
        endpoint.close(timeoutMillis: timeoutMillis)
    }
    public func views(): Array<HostJavaScriptPluginView> {
        lock.lock()
        try {
            let output = ArrayList<HostJavaScriptPluginView>()
            for (generation in generations) {
                for (view in generation.views) {
                    output.add(HostJavaScriptPluginView(
                        generation.extensionId, view.name, view.description,
                        instanceGeneration: generation.instanceGeneration
                    ))
                }
            }
            output.toArray()
        } finally {
            lock.unlock()
        }
    }

    public func commands(): Array<HostJavaScriptPluginCommand> {
        lock.lock()
        try {
            let output = ArrayList<HostJavaScriptPluginCommand>()
            for (generation in generations) {
                for (command in generation.commands) {
                    output.add(HostJavaScriptPluginCommand(
                        generation.extensionId, command.name, command.description,
                        instanceGeneration: generation.instanceGeneration
                    ))
                }
            }
            output.toArray()
        } finally {
            lock.unlock()
        }
    }

    // Private catalog DATA snapshot. The original public raw API stays
    // unchanged. Count/payment and copying share this exact generation lock.
    func hookDescriptorsPaid159(payment: HostRegistryCatalogIdentity159): Array<HostJavaScriptPluginHook> {
        lock.lock()
        try {
            payment.reserveCatalogData159(8192)
            for (generation in generations) {
                for (hook in generation.hooks) {
                    payment.reserveHook159(generation.extensionId, hook.event)
                }
            }
            let output = ArrayList<HostJavaScriptPluginHook>()
            for (generation in generations) {
                for (hook in generation.hooks) {
                    output.add(HostJavaScriptPluginHook(generation.extensionId, hook))
                }
            }
            output.toArray()
        } finally { lock.unlock() }
    }
    public func hookDescriptors(): Array<HostJavaScriptPluginHook> {
        lock.lock()
        try {
            let output = ArrayList<HostJavaScriptPluginHook>()
            for (generation in generations) {
                for (hook in generation.hooks) {
                    output.add(HostJavaScriptPluginHook(generation.extensionId, hook))
                }
            }
            output.toArray()
        } finally {
            lock.unlock()
        }
    }
    // The graph is derived from this same mounted instance registry. Native
    // requirements cannot create a separate activation or permission catalog.
    private func captureComponentDependencies(descriptor: PluginPackageDescriptor): Result<Array<HostJavaScriptPluginGeneration>> {
        lock.lock()
        try {
            let dependencies = ArrayList<HostJavaScriptPluginGeneration>()
            for (requirement in descriptor.componentDependencies) {
                let dependency = match (findLocked(requirement.namespace)) {
                    case Some(value) => value
                    case None => return hostPluginResourceError("plugin.component_dependency_not_active", "required component is not active: " + requirement.identity())
                }
                if (dependency.isClosing() || !requirement.matches(dependency.descriptor)) {
                    return hostPluginResourceError("plugin.component_dependency_incompatible", "active component does not satisfy " + requirement.identity())
                }
                dependencies.add(dependency)
            }
            Result.Ok(dependencies.toArray())
        } finally { lock.unlock() }
    }

    private func deactivationNamespacesLocked(extensionId: String): Array<String> {
        let names = ArrayList<String>(); names.add(extensionId.trimAscii())
        var changed = true
        while (changed) {
            changed = false
            for (generation in generations where !names.contains(generation.extensionId)) {
                for (dependency in generation.descriptor.componentDependencies where names.contains(dependency.namespace)) {
                    names.add(generation.extensionId); changed = true; break
                }
            }
        }
        names.toArray()
    }

    public func deactivationNamespaces(extensionId: String): Array<String> {
        lock.lock(); try { deactivationNamespacesLocked(extensionId) } finally { lock.unlock() }
    }

    public func unmount(extensionId: String): Result<Unit> {
        let removed = ArrayList<HostJavaScriptPluginGeneration>()
        lock.lock()
        try {
            let affected = deactivationNamespacesLocked(extensionId)
            var index = generations.size
            while (index > 0) {
                index--
                if (affected.contains(generations[index].extensionId)) {
                    let generation = generations.remove(at: index)
                    generation.beginClose()
                    removed.add(generation)
                }
            }
        } finally {
            lock.unlock()
        }
        for (value in removed) { for (host in value.closeHosts()) { retainCleanupOwner(host) } }
        Result.Ok(())
    }

    public func close(): Result<Unit> {
        let removed = ArrayList<HostJavaScriptPluginGeneration>()
        lock.lock()
        try {
            closed = true
            while (generations.size > 0) {
                removed.add(generations.remove(at: generations.size - 1))
            }
        } finally {
            lock.unlock()
        }
        for (generation in removed) {
            for (host in generation.closeHosts()) { retainCleanupOwner(host) }
        }
        let deadline = MonoTime.now() + Duration.second * 2
        while (pendingCleanupCount() > 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
        // Both fixed resource owners must receive close even if native cleanup
        // is pending. Their release may also let a retained worker terminate.
        let nativePending = pendingCleanupCount() > 0
        lock.lock()
        let callbacks = try { [readViewCleanup, contextReadCleanup] } finally { lock.unlock() }
        var failure: ?AgentError = if (nativePending) {
            Some(AgentError(AgentErrorKind.PermissionDenied, "plugin.cleanup_pending",
                "native worker cleanup remains retained by the host"))
        } else { None }
        for (callback in callbacks) {
            match (callback) {
                case Some(cleanup) =>
                    try {
                        match (cleanup()) {
                            case Result.Err(error) => if (failure.isNone()) { failure = Some(error) }
                            case Result.Ok(_) => ()
                        }
                    } catch (_: Exception) {
                        if (failure.isNone()) {
                            failure = Some(AgentError(AgentErrorKind.Configuration, "plugin.resource_cleanup_failed",
                                "a private resource cleanup owner has not acknowledged release"))
                        }
                    }
                case None => ()
            }
        }
        lock.lock()
        let attachmentOwner = try { toolInputAttachmentOwner } finally { lock.unlock() }
        match (attachmentOwner) { case Some(value) => match (value.close()) {
            case Result.Err(error) => if (failure.isNone()) { failure = Some(error) }; case Result.Ok(_) => () }; case None => () }
        // Keep the original callbacks, including failed owners, for retry.
        match (failure) { case Some(error) => Result.Err(error); case None => Result.Ok(()) }
    }
    // Trusted generic data transport only. Callers must run their actual
    // Store proof inside action; this loan itself grants no data or Source.
    // The SQL body receives only direct calls to the already captured worker.
    public func withPureDocumentDataLoan(configuration:HostPluginDocumentJournalReadConfiguration,
        expectedGeneration:UInt64,context:ToolInvocationContext,requestId:String,deadline:MonoTime,
        owner:HostDocumentDataSession,localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>,
        action:(HostPluginPureDataLoan)->Result<Unit>,callerUnbounded!:Bool=false):Result<Unit>{
        if(expectedGeneration==0u64 || requestId=="" || context.cancellation.isCancelled() ||
            (!callerUnbounded && MonoTime.now()>=deadline) || (callerUnbounded && (!configuration.contextRead ||
            context.cancellation.deadlineMillis!=0 || context.budget.deadlineMillis!=0)) || !hostJavascriptPluginLimitsFitHost(context.budget.processLimits) ||
            !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:configuration.namespace)){
            return hostPluginResourceError<Unit>("plugin.pure_loan_scope","pure data loan lost its actual caller or process ceiling")}
        match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(configuration.contextRead){
            let binding=match(contentProviderBinding(configuration.namespace,configuration.provider,false)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(binding.generation!=expectedGeneration || binding.digest!=configuration.packageDigest){
                return hostPluginResourceError<Unit>("plugin.pure_loan_owner","actual typed context provider changed")}
        }else{
            let binding=match(policyProviderBinding(configuration.namespace,configuration.provider)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(binding.generation!=expectedGeneration || binding.digest!=configuration.packageDigest){
                return hostPluginResourceError<Unit>("plugin.pure_loan_owner","actual typed policy provider changed")}
        }
        let generation=match(find(configuration.namespace)){case Some(value)=>value
            case None=>return hostPluginResourceError<Unit>("plugin.pure_loan_owner","actual package generation is no longer active")}
        if(generation.instanceGeneration!=expectedGeneration || generation.descriptor.contentDigest!=configuration.packageDigest ||
            !generation.descriptor.requestedCapabilities.contains("document.store") || generation.isClosing()){
            return hostPluginResourceError<Unit>("plugin.pure_loan_owner","actual package generation or document capability changed")}
        let authority=if(configuration.contextRead){"pure-context-journal-data:"+configuration.digest+":"+configuration.provider}
            else{"pure-document-data:"+configuration.digest}
        let selected=match(if(configuration.contextRead){contextJournalDataWorker(configuration.namespace,expectedGeneration,context.sessionId.value,authority)}
            else{documentDataWorker(configuration.namespace,expectedGeneration,context.sessionId.value,authority)}){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let debt=HostPluginPureWorkerDebt(owner)
        try{
            let execute:()->Result<Unit>={=>
            // Existing session owns process cleanup before begin can retain
            // any cache. Failed physical collection remains with that owner.
            match(debt.adopt({=>selected.abortAndCollect()})){
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            let sequence=!configuration.contextRead
            let contextSequence=configuration.contextRead
            let scopeKey=stringifyUnifiedJson(objectValue([ValueField("thread",textValue(context.sessionId.value)),
                ValueField("authority",textValue(authority))]))
            let actualScope=if(sequence){
                let scope=parseUnifiedJson(scopeKey,maxBytes:16384);scope.put("provider_sequence",textValue("provider-invoke-i63-v1"));stringifyUnifiedJson(scope)
            }else{
                let scope=parseUnifiedJson(scopeKey,maxBytes:16384);scope.put("context_sequence",textValue("context-invoke-i63-v1"));stringifyUnifiedJson(scope)
            }
            let entry=match(generation.threadHost(actualScope,launcher,providerSequence:sequence,contextSequence:contextSequence)){
                case JavaScriptHostResult.Err(error)=>return Result<Unit>.Err(hostJavascriptPluginAgentError(error));case JavaScriptHostResult.Ok(value)=>value}
            if(!refEq(entry.host,selected.actual)){
                return hostPluginResourceError<Unit>("plugin.pure_loan_worker","actual selected worker is not this frozen generation connection")}
            let processCancellation=match(generation.invocationCancellation(context.cancellation.deadlineMillis)){
                case Some(value)=>value;case None=>return hostPluginResourceError<Unit>("plugin.pure_loan_owner","actual generation was revoked")}
            try{
            entry.invokeLock.lock()
            try{
                // All registry/generation lookups end before the action may
                // take artifact/SQL locks. No replacement worker is adopted.
                let again=match(generation.threadHost(actualScope,launcher,providerSequence:sequence,contextSequence:contextSequence)){
                    case JavaScriptHostResult.Err(error)=>return Result<Unit>.Err(hostJavascriptPluginAgentError(error));case JavaScriptHostResult.Ok(value)=>value}
                if(!refEq(again.host,entry.host) || !refEq(entry.host,selected.actual)){
                    return hostPluginResourceError<Unit>("plugin.pure_loan_worker","actual worker changed before materialization")}
                match(fullCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                match(configuration.validateCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                let revoked=AtomicBool(false)
                let revocation=match(observeServiceRevocation(configuration.namespace,expectedGeneration,{=>revoked.store(true)})){
                    case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
                let registration=context.cancellation.onCancel({_=>let _=processCancellation.cancel();entry.host.close()})
                let identity=JavaScriptHostInvocationIdentity(threadId:context.sessionId.value,runId:"",epoch:0,
                    operationId:"",callId:requestId,kind:if(configuration.contextRead){"context_provider"}else{"provider"})
                let current={=>
                    if(revoked.load() || context.cancellation.isCancelled() || (!callerUnbounded && MonoTime.now()>=deadline)){
                        return hostPluginResourceError<Unit>("plugin.pure_loan_cancelled","pure loan was revoked, cancelled or expired")}
                    match(localCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                    configuration.validateTransferWitness()}
                let loan=HostPluginPureDataLoan({encoded,remaining=>
                    // Zero services and no observer: native packets can never
                    // callback into Host/Runtime/SQL while the proof owns TX.
                    entry.host.invoke(configuration.provider,encoded,identity:identity,
                        context:Some(JavaScriptHostInvocationContext(cwd:"",hasUI:false)),
                        cancellation:processCancellation.token,timeoutMillis:remaining,serviceRequestLimit:0,observer:Option<JavaScriptHostObserver>.None)
                },{bytes=>reserveNativeDocumentPayload(bytes)},current,deadline,if(sequence || contextSequence){Int64.Max}else{4096},callerUnbounded:callerUnbounded)
                try{
                    let outcome=action(loan)
                    // The actual SQL action must return only after full EOF,
                    // private fence and cursor/file ACK. Registry checks are
                    // now outside that closed transaction again.
                    match(fullCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                    match(configuration.validateCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                    match(current()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                    // No value, reply or private loan capability is returned.
                    // A final context value is read by the existing paid
                    // output owner only after this SQL/worker scope closes.
                    outcome
                }finally{loan.close();registration.dispose();revocation.dispose()}
            }finally{entry.invokeLock.unlock()}
            }finally{processCancellation.close()}
            }
            let outcome=execute()
            // The original session retains failed cleanup debt. A worker's
            // cache release is never substituted for physical collection.
            selected.actual.close()
            if(!selected.actual.cleanupComplete){
                return hostPluginResourceError<Unit>("plugin.pure_loan_cleanup","actual captured worker has not acknowledged physical collection")}
            debt.acknowledgeIfCollected(selected.actual.cleanupComplete)
            outcome
        }finally{
            // Cache ACK is insufficient: collect the same physical worker.
            // Its original connection counter is never reset while alive.
            selected.actual.close()
            if(selected.actual.cleanupComplete){debt.acknowledgeIfCollected(selected.actual.cleanupComplete)}
            selected.finishTransfer()
        }
    }

    // Opt-in live family transport. The actual operator mapping freezes both
    // this typed policy provider and the original read grant. No provider name,
    // Source, SQL, path or grant may be selected by the Native action. Every
    // data source still requires its own full paid Store proof in action.
    public func withPureLivePolicyDataLoan(configuration:HostPluginLivePolicyConfiguration,
        expectedGeneration:UInt64,context:ToolInvocationContext,requestId:String,deadline:MonoTime,
        owner:HostDocumentDataSession,localCurrent:()->Result<Unit>,fullCurrent:()->Result<Unit>,
        action:(HostPluginPureDataLoan)->Result<Unit>,callerUnbounded!:Bool=false):Result<Unit>{
        if(expectedGeneration==0u64 || requestId=="" || context.cancellation.isCancelled() ||
            (!callerUnbounded && MonoTime.now()>=deadline) || (callerUnbounded && (
            context.cancellation.deadlineMillis!=0 || context.budget.deadlineMillis!=0)) || !hostJavascriptPluginLimitsFitHost(context.budget.processLimits) ||
            !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:configuration.namespace)){
            return hostPluginResourceError<Unit>("plugin.pure_loan_scope","pure data loan lost its actual caller or process ceiling")}
        match(fullCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(false){
            let binding=match(contentProviderBinding(configuration.namespace,configuration.policyProvider,false)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(binding.generation!=expectedGeneration || binding.digest!=configuration.packageDigest){
                return hostPluginResourceError<Unit>("plugin.pure_loan_owner","actual typed context provider changed")}
        }else{
            let binding=match(policyProviderBinding(configuration.namespace,configuration.policyProvider)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(binding.generation!=expectedGeneration || binding.digest!=configuration.packageDigest){
                return hostPluginResourceError<Unit>("plugin.pure_loan_owner","actual typed policy provider changed")}
        }
        let generation=match(find(configuration.namespace)){case Some(value)=>value
            case None=>return hostPluginResourceError<Unit>("plugin.pure_loan_owner","actual package generation is no longer active")}
        if(generation.instanceGeneration!=expectedGeneration || generation.descriptor.contentDigest!=configuration.packageDigest ||
            !generation.descriptor.requestedCapabilities.contains("document.store") || generation.isClosing()){
            return hostPluginResourceError<Unit>("plugin.pure_loan_owner","actual package generation or document capability changed")}
        let authority=if(false){"pure-context-journal-data:"+configuration.digest+":"+configuration.policyProvider}
            else{"pure-live-policy-data:"+configuration.digest}
        let selected=match(if(false){contextJournalDataWorker(configuration.namespace,expectedGeneration,context.sessionId.value,authority)}
            else{documentDataWorker(configuration.namespace,expectedGeneration,context.sessionId.value,authority)}){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let debt=HostPluginPureWorkerDebt(owner)
        try{
            let execute:()->Result<Unit>={=>
            // Existing session owns process cleanup before begin can retain
            // any cache. Failed physical collection remains with that owner.
            match(debt.adopt({=>selected.abortAndCollect()})){
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            let sequence=!false
            let contextSequence=false
            let scopeKey=stringifyUnifiedJson(objectValue([ValueField("thread",textValue(context.sessionId.value)),
                ValueField("authority",textValue(authority))]))
            let actualScope=if(sequence){
                let scope=parseUnifiedJson(scopeKey,maxBytes:16384);scope.put("provider_sequence",textValue("provider-invoke-i63-v1"));stringifyUnifiedJson(scope)
            }else{
                let scope=parseUnifiedJson(scopeKey,maxBytes:16384);scope.put("context_sequence",textValue("context-invoke-i63-v1"));stringifyUnifiedJson(scope)
            }
            let entry=match(generation.threadHost(actualScope,launcher,providerSequence:sequence,contextSequence:contextSequence)){
                case JavaScriptHostResult.Err(error)=>return Result<Unit>.Err(hostJavascriptPluginAgentError(error));case JavaScriptHostResult.Ok(value)=>value}
            if(!refEq(entry.host,selected.actual)){
                return hostPluginResourceError<Unit>("plugin.pure_loan_worker","actual selected worker is not this frozen generation connection")}
            let processCancellation=match(generation.invocationCancellation(context.cancellation.deadlineMillis)){
                case Some(value)=>value;case None=>return hostPluginResourceError<Unit>("plugin.pure_loan_owner","actual generation was revoked")}
            try{
            entry.invokeLock.lock()
            try{
                // All registry/generation lookups end before the action may
                // take artifact/SQL locks. No replacement worker is adopted.
                let again=match(generation.threadHost(actualScope,launcher,providerSequence:sequence,contextSequence:contextSequence)){
                    case JavaScriptHostResult.Err(error)=>return Result<Unit>.Err(hostJavascriptPluginAgentError(error));case JavaScriptHostResult.Ok(value)=>value}
                if(!refEq(again.host,entry.host) || !refEq(entry.host,selected.actual)){
                    return hostPluginResourceError<Unit>("plugin.pure_loan_worker","actual worker changed before materialization")}
                match(fullCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                match(configuration.validateCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                let revoked=AtomicBool(false)
                let revocation=match(observeServiceRevocation(configuration.namespace,expectedGeneration,{=>revoked.store(true)})){
                    case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
                let registration=context.cancellation.onCancel({_=>let _=processCancellation.cancel();entry.host.close()})
                let identity=JavaScriptHostInvocationIdentity(threadId:context.sessionId.value,runId:"",epoch:0,
                    operationId:"",callId:requestId,kind:if(false){"context_provider"}else{"provider"})
                let current={=>
                    if(revoked.load() || context.cancellation.isCancelled() || (!callerUnbounded && MonoTime.now()>=deadline)){
                        return hostPluginResourceError<Unit>("plugin.pure_loan_cancelled","pure loan was revoked, cancelled or expired")}
                    match(localCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                    configuration.validateTransferWitness()}
                let loan=HostPluginPureDataLoan({encoded,remaining=>
                    // Zero services and no observer: native packets can never
                    // callback into Host/Runtime/SQL while the proof owns TX.
                    entry.host.invoke(configuration.policyProvider,encoded,identity:identity,
                        context:Some(JavaScriptHostInvocationContext(cwd:"",hasUI:false)),
                        cancellation:processCancellation.token,timeoutMillis:remaining,serviceRequestLimit:0,observer:Option<JavaScriptHostObserver>.None)
                },{bytes=>reserveNativeDocumentPayload(bytes)},current,deadline,if(sequence || contextSequence){Int64.Max}else{4096},callerUnbounded:callerUnbounded)
                try{
                    let outcome=action(loan)
                    // The actual SQL action must return only after full EOF,
                    // private fence and cursor/file ACK. Registry checks are
                    // now outside that closed transaction again.
                    match(fullCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                    match(configuration.validateCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                    match(current()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                    // No value, reply or private loan capability is returned.
                    // A final context value is read by the existing paid
                    // output owner only after this SQL/worker scope closes.
                    outcome
                }finally{loan.close();registration.dispose();revocation.dispose()}
            }finally{entry.invokeLock.unlock()}
            }finally{processCancellation.close()}
            }
            let outcome=execute()
            // The original session retains failed cleanup debt. A worker's
            // cache release is never substituted for physical collection.
            selected.actual.close()
            if(!selected.actual.cleanupComplete){
                return hostPluginResourceError<Unit>("plugin.pure_loan_cleanup","actual captured worker has not acknowledged physical collection")}
            debt.acknowledgeIfCollected(selected.actual.cleanupComplete)
            outcome
        }finally{
            // Cache ACK is insufficient: collect the same physical worker.
            // Its original connection counter is never reset while alive.
            selected.actual.close()
            if(selected.actual.cleanupComplete){debt.acknowledgeIfCollected(selected.actual.cleanupComplete)}
            selected.finishTransfer()
        }
    }

    public func invoke(
        extensionId: String,
        tool: String,
        argumentsJson: String,
        identity!: JavaScriptHostInvocationIdentity,
        cancellation!: CancellationToken,
        cwd!: String = "",
        hasUI!: Bool = false,
        processLimits!: ExecutionResourceLimits = ExecutionResourceLimits(),
        timeoutMillis!: Int64 = 0,
        expectedInstanceGeneration!: UInt64 = 0u64,
        authorityScope!: String = "",
        observer!: ?JavaScriptHostObserver = None,
        toolPayloadLimits!: ?OrdinaryToolPayloadLimits = None,
        documentToolPayload!: Bool = false, providerSequence!: Bool = false, expectedDataWorker!: ?JavaScriptExtensionHost = None, expectedContextDataWorker!: ?JavaScriptExtensionHost = None
    ): Result<HostJavaScriptPluginInvocationResult> {
        invokeObserved(extensionId, tool, argumentsJson, identity: identity, cancellation: cancellation,
            cwd: cwd, hasUI: hasUI, processLimits: processLimits, timeoutMillis: timeoutMillis,
            expectedInstanceGeneration: expectedInstanceGeneration, authorityScope: authorityScope,
            observer: observer, toolPayloadLimits: toolPayloadLimits, documentToolPayload: documentToolPayload,
            providerSequence: providerSequence, expectedDataWorker: expectedDataWorker, expectedContextDataWorker: expectedContextDataWorker)
    }

    func invokeObserved(
        extensionId: String,
        tool: String,
        argumentsJson: String,
        identity!: JavaScriptHostInvocationIdentity,
        cancellation!: CancellationToken,
        cwd!: String = "",
        hasUI!: Bool = false,
        processLimits!: ExecutionResourceLimits = ExecutionResourceLimits(),
        timeoutMillis!: Int64 = 0,
        expectedInstanceGeneration!: UInt64 = 0u64,
        authorityScope!: String = "",
        observer!: ?JavaScriptHostObserver = None,
        toolPayloadLimits!: ?OrdinaryToolPayloadLimits = None,
        documentToolPayload!: Bool = false, providerSequence!: Bool = false, expectedDataWorker!: ?JavaScriptExtensionHost = None, expectedContextDataWorker!: ?JavaScriptExtensionHost = None,
        executionObservation!: ?HostToolExecutionCancellationObservation = None,
        inputAttachment!: ?AgentValue = None, inputAttachmentCurrent!: ?() -> Result<Unit> = None,
        finiteReadViewWindow!: ?HostReadViewCallWindow = None
    ): Result<HostJavaScriptPluginInvocationResult> {
        if (expectedDataWorker.isSome() && !providerSequence) { return hostPluginResourceError("plugin.document_query_scope", "fixed data worker requires the pure Provider sequence connection") }
        if(expectedContextDataWorker.isSome() && (providerSequence || identity.kind!="context_provider" ||
            expectedDataWorker.isSome() || observer.isSome() || toolPayloadLimits.isSome() || documentToolPayload ||
            !authorityScope.startsWith("pure-context-data:"))){
            return hostPluginResourceError("context.document_worker_scope","fixed context worker requires its typed capability-free ContextProvider scope")}

        if (providerSequence && (identity.kind != "provider" || observer.isSome() || toolPayloadLimits.isSome() || documentToolPayload)) {
            return hostPluginResourceError("plugin.provider_sequence_scope", "explicit sequence workers are reserved for pure Provider data")
        }
        if (identity.kind == "service" || identity.kind == "service_prepare") {
            return hostPluginResourceError("plugin.service_endpoint_required", "native Service requires a sealed fixed endpoint")
        }
        if (cancellation.isCancelled()) {
            return hostJavascriptPluginError<HostJavaScriptPluginInvocationResult>(
                "extension.cancelled", "JavaScript plugin invocation was cancelled"
            )
        }
        if (!hostJavascriptPluginLimitsFitHost(processLimits)) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.resource_limit_unavailable",
                "persistent JavaScript plugin host cannot enforce stricter per-invocation process limits"
            ))
        }
        let generation = match (find(extensionId.trimAscii())) {
            case Some(value) => value
            case None => return hostJavascriptPluginError<HostJavaScriptPluginInvocationResult>(
                "plugin.not_active", "JavaScript plugin has no active generation"
            )
        }
        if (expectedInstanceGeneration != 0u64 &&
            generation.instanceGeneration != expectedInstanceGeneration) {
            return hostJavascriptPluginError<HostJavaScriptPluginInvocationResult>(
                "plugin.instance_stale",
                "the frozen plugin executor is no longer active; a newer instance cannot execute its calls"
            )
        }
        let payloadSelection = match (hostOrdinaryToolPayloadSelection(settingsRoot,
            generation.descriptor, generation.toolNames(), identity.kind, tool, toolPayloadLimits, document: documentToolPayload)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let finiteCallMillis: Int64 = match (finiteReadViewWindow) { case None => 30000
            case Some(window) => match (window.validate(this, identity, expectedInstanceGeneration)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value } }
        let scope = objectValue([
            ValueField("thread", textValue(identity.threadId)),
            ValueField("authority", textValue(authorityScope))
        ])
        if (payloadSelection != "") { scope.put("ordinary_tool_payload", textValue(payloadSelection)) }
        if (providerSequence) { scope.put("provider_sequence", textValue("provider-invoke-i63-v1")) }
        match (finiteReadViewWindow) { case Some(window) => scope.put("finite_read_view", textValue(window.scope())); case None => () }
        let scopeKey = stringifyUnifiedJson(scope)
        let entry = match (generation.threadHost(scopeKey, launcher, ordinaryToolPayload: payloadSelection != "", providerSequence: providerSequence, callTimeoutMillis: finiteCallMillis)) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) =>
                retainCleanupError(error)
                return Result.Err(hostJavascriptPluginAgentError(error))
        }
        let processCancellation = match (generation.invocationCancellation(cancellation.deadlineMillis)) {
            case Some(value) => value
            case None => return hostJavascriptPluginError<HostJavaScriptPluginInvocationResult>(
                "plugin.not_active", "JavaScript plugin generation was revoked"
            )
        }
        entry.invokeLock.lock()
        if (cancellation.isCancelled()) {
            entry.invokeLock.unlock()
            processCancellation.close()
            return hostJavascriptPluginError<HostJavaScriptPluginInvocationResult>(
                "extension.cancelled", "JavaScript plugin invocation was cancelled"
            )
        }
        match (generation.threadHost(scopeKey, launcher, ordinaryToolPayload: payloadSelection != "", providerSequence: providerSequence, callTimeoutMillis: finiteCallMillis)) {
            case JavaScriptHostResult.Ok(_) => ()
            case JavaScriptHostResult.Err(error) =>
                entry.invokeLock.unlock()
                processCancellation.close()
                retainCleanupError(error)
                return Result.Err(hostJavascriptPluginAgentError(error))
        }
        match(expectedDataWorker){case Some(actual)=>if(!refEq(actual,entry.host)){
            entry.invokeLock.unlock();processCancellation.close()
            return hostPluginResourceError("plugin.document_query_worker_changed","fixed data query cannot use a replacement process")}
            case None=>()}
        match(expectedContextDataWorker){case Some(actual)=>if(!refEq(actual,entry.host)){
            entry.invokeLock.unlock();processCancellation.close()
            return hostPluginResourceError("context.document_worker_changed","context query cannot borrow a replacement worker")}
            case None=>()}
        if (payloadSelection != "") {
            // Starting or waiting for the selected worker may outlive an
            // operator edit. Recheck before any invocation payload is sent.
            let current = hostOrdinaryToolPayloadSelection(settingsRoot, generation.descriptor,
                generation.toolNames(), identity.kind, tool, toolPayloadLimits, document: documentToolPayload)
            match (current) {
                case Result.Err(error) =>
                    entry.invokeLock.unlock(); processCancellation.close(); return Result.Err(error)
                case Result.Ok(value) => if (value != payloadSelection) {
                    entry.invokeLock.unlock(); processCancellation.close()
                    return hostPluginResourceError("plugin.tool_payload_selection_invalid", "ordinary Tool payload selection changed during worker startup") }
            }
        }
        match (finiteReadViewWindow) { case Some(window) => match (window.validate(this, identity, expectedInstanceGeneration)) {
            case Result.Err(error) => entry.invokeLock.unlock(); processCancellation.close(); return Result.Err(error); case Result.Ok(_) => () }; case None => () }
        match (inputAttachmentCurrent) { case Some(current) => match (current()) {
            case Result.Err(error) => entry.invokeLock.unlock(); processCancellation.close(); return Result.Err(error); case Result.Ok(_) => () }; case None => () }
        let registration = cancellation.onCancel({ _ =>
            let _ = processCancellation.cancel()
            entry.host.close()
        })
        try {
            let response = entry.host.invoke(
                tool,
                argumentsJson,
                identity: identity,
                context: Some(JavaScriptHostInvocationContext(cwd: cwd, hasUI: hasUI)),
                cancellation: processCancellation.token,
                timeoutMillis: if (finiteReadViewWindow.isSome()) { finiteCallMillis } else { timeoutMillis },
                toolPayloadLimits: toolPayloadLimits, inputAttachment: inputAttachment,
                serviceRequestLimit: if (identity.kind == "prepare" || identity.kind == "context_provider" || identity.kind == "resource_provider" || identity.kind == "provider") { 0 } else { JAVASCRIPT_HOST_MAX_SERVICE_CALLS },
                observer: observer
            )
            match (response) {
                case JavaScriptHostResult.Err(error) =>
                    match (generation.invocationRevocationCause(processCancellation.token)) {
                        case Some(cause) => if (error.code == "process.parent_cancelled" && error.message == cause.message) {
                            let actualError = AgentError(AgentErrorKind.Cancelled, cause.code, cause.message)
                            match (executionObservation) {
                                case Some(observation) => observation.record(identity, generation, processCancellation.token, actualError)
                                case None => ()
                            }
                            return Result.Err(actualError)
                        }
                        case None => ()
                    }
                    Result.Err(hostJavascriptPluginAgentError(error))
                case JavaScriptHostResult.Ok(value) =>
                    var retained = false
                    try {
                        if (generation.isClosing() || cancellation.isCancelled()) {
                            return hostJavascriptPluginError<HostJavaScriptPluginInvocationResult>(
                                "extension.cancelled", "plugin query was cancelled or its generation was revoked")
                        }
                        let maximum = if (toolPayloadLimits.isSome()) { toolPayloadLimits.getOrThrow().maxResultBytes }
                        else if (identity.kind == "context_provider" || identity.kind == "resource_provider" || identity.kind == "provider") {
                            CONTENT_PAYLOAD_RESULT_BYTES
                        } else { JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES }
                        match (hostJavascriptPluginDecodeValue(value.resultJson, maxBytes: maximum)) {
                            case Result.Ok(result) =>
                                let output = HostJavaScriptPluginInvocationResult(result, value.isError,
                                    releasePayload: { => value.releasePayload() })
                                retained = true
                                Result.Ok(output)
                            case Result.Err(error) => hostJavascriptPluginError<HostJavaScriptPluginInvocationResult>(
                                "extension.result_invalid", error.message)
                        }
                    } finally { if (!retained) { value.releasePayload() } }
            }
        } finally {
            entry.invokeLock.unlock()
            registration.dispose()
            processCancellation.close()
        }
    }

    private func find(extensionId: String): ?HostJavaScriptPluginGeneration {
        lock.lock()
        try { findLocked(extensionId) } finally { lock.unlock() }
    }

    private func retainCleanupError(error: JavaScriptHostError): Unit {
        match (error.cleanupHost) { case Some(value) => retainCleanupOwner(value); case None => () }
    }

    private func retainCleanupOwner(host: JavaScriptExtensionHost): Unit {
        if (host.cleanupComplete && host.collectCompletedDispatchData159()) { return }
        host.requestAbort()
        lock.lock()
        try {
            for (current in retainedCleanup where refEq(current, host)) { return }
            retainedCleanup.add(host)
        } finally { lock.unlock() }
    }

    private func pendingCleanupCount(): Int64 {
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < retainedCleanup.size) {
                if (retainedCleanup[index].cleanupComplete && retainedCleanup[index].collectCompletedDispatchData159()) { retainedCleanup.remove(at: index) }
                else {
                    // Also retries a cleanup Future construction failure. A
                    // running native cleanup task is never duplicated.
                    retainedCleanup[index].requestAbort()
                    index += 1
                }
            }
            retainedCleanup.size
        } finally { lock.unlock() }
    }

    private func cleanupCapacityAvailable(): Bool { pendingCleanupCount() < 64 }

    private func findLocked(extensionId: String): ?HostJavaScriptPluginGeneration {
        for (generation in generations) {
            if (generation.extensionId == extensionId) { return Some(generation) }
        }
        None
    }
}

public class HostSandboxedJavaScriptHostLauncher <: JavaScriptHostProcessLauncher {
    public init() {}
    public func launch(
        command: process.ProcessCommand
    ): JavaScriptHostResult<process.ManagedProcess> {
        let sandbox = try {
            WorkspaceSandbox(WorkspaceSandboxPolicy(
                command.workingDirectory,
                filesystem: FilesystemIsolationMode.WorkspaceReadOnly,
                process: ProcessIsolationMode.Isolated,
                network: NetworkIsolationMode.Denied,
                environment: EnvironmentFilter(),
                resources: hostJavaScriptHostResourceLimits(command.maxOutputBytes)
            ))
        } catch (error: Exception) {
            return JavaScriptHostResult.Err(JavaScriptHostError(
                "extension.sandbox_configuration", error.message
            ))
        }
        match (sandbox.availability()) {
            case SandboxResult.Ok(_) => ()
            case SandboxResult.Err(error) => return JavaScriptHostResult.Err(JavaScriptHostError(
                error.code, error.message
            ))
        }
        let plan = match (sandbox.plan(WorkspaceSandboxCommand(
            command.executable,
            arguments: command.arguments,
            workingDirectory: command.workingDirectory,
            timeoutMillis: 600000
        ))) {
            case SandboxResult.Ok(value) => value
            case SandboxResult.Err(error) => return JavaScriptHostResult.Err(JavaScriptHostError(
                error.code, error.message
            ))
        }
        try {
            JavaScriptHostResult.Ok(process.startProcess(process.ProcessCommand(
                plan.sandboxExecutable,
                arguments: plan.sandboxArguments,
                workingDirectory: plan.workingDirectory,
                environment: HashMap<String, String>(),
                maxOutputBytes: command.maxOutputBytes,
                terminateProcessTree: true
            )))
        } catch (error: Exception) {
            JavaScriptHostResult.Err(JavaScriptHostError(
                "extension.sandbox_process_spawn_failed", error.message
            ))
        }
    }
}

public func hostJavaScriptHostResourceLimits(maxOutputBytes: Int64): SandboxResourceLimits {
    SandboxResourceLimits(
        maxOutputBytes: maxOutputBytes,
        addressSpaceBytes: 4294967296,
        fileSizeBytes: 67108864,
        openFiles: 256,
        processes: 128,
        cpuSeconds: 3600
    )
}

public func hostJavascriptPluginLimitsFitHost(requested: ExecutionResourceLimits): Bool {
    let host = hostJavaScriptHostResourceLimits(
        JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES * 4
    )
    hostJavascriptPluginLimitFitsHost(requested.maxOutputBytes, host.maxOutputBytes) &&
    hostJavascriptPluginLimitFitsHost(requested.addressSpaceBytes, host.addressSpaceBytes) &&
    hostJavascriptPluginLimitFitsHost(requested.fileSizeBytes, host.fileSizeBytes) &&
    hostJavascriptPluginLimitFitsHost(requested.openFiles, host.openFiles) &&
    hostJavascriptPluginLimitFitsHost(requested.processes, host.processes) &&
    hostJavascriptPluginLimitFitsHost(requested.cpuSeconds, host.cpuSeconds)
}

public func hostJavascriptPluginLimitFitsHost(requested: Int64, host: Int64): Bool {
    requested == 0 || requested >= host
}

public class HostJavaScriptPluginThreadHost {
    let threadId: String
    var host: JavaScriptExtensionHost
    let invokeLock = Mutex()
    let dataTransferLock = Mutex()
    let pinned: Bool

    init(threadId: String, host: JavaScriptExtensionHost, pinned!: Bool = false) {
        this.threadId = threadId
        this.host = host
        this.pinned = pinned
    }
}

// A query holds this connection's data-transfer mutex across begin/chunks/
// compute/download/release. The ordinary per-RPC invocation mutex is separate.
public class HostDocumentDataWorker {
    private let entry:HostJavaScriptPluginThreadHost
    public let actual:JavaScriptExtensionHost
    private var finished=false
    init(entry:HostJavaScriptPluginThreadHost,actual:JavaScriptExtensionHost){this.entry=entry;this.actual=actual}
    public func abortAndCollect():Bool{actual.requestAbort();actual.cleanupComplete}
    public func finishTransfer():Unit{if(!finished){finished=true;entry.dataTransferLock.unlock()}}
}

public class HostJavaScriptPluginGeneration {
    let extensionId: String
    public let instanceIdentity: String
    public let instanceGeneration: UInt64
    let descriptor: PluginPackageDescriptor
    let tools: Array<JavaScriptToolDescriptor>
    let commands: Array<JavaScriptCommandDescriptor>
    let views: Array<JavaScriptViewDescriptor>
    let hooks: Array<JavaScriptHookDescriptor>
    let services: Array<PluginServiceDescriptor>
    let modelProviders: Array<PluginModelProviderDescriptor>
    let contextProviders: Array<PluginContentProviderDescriptor>
    let resourceProviders: Array<PluginContentProviderDescriptor>
    let policyProviders: Array<PluginContentProviderDescriptor>
    private let hostLock = Mutex()
    private let threadHosts = ArrayList<HostJavaScriptPluginThreadHost>()
    private var nextGeneration: UInt64
    private var closing = false
    private let revocation = process.CancellationSource()
    private let registryPin: PluginRegistryExecutionPin
    private let metadataRegistry81: PluginRegistry

    init(
        descriptor: PluginPackageDescriptor,
        registryPin: PluginRegistryExecutionPin,
        metadataRegistry81: PluginRegistry,
        tools: Array<JavaScriptToolDescriptor>,
        commands: Array<JavaScriptCommandDescriptor>,
        views: Array<JavaScriptViewDescriptor>,
        hooks: Array<JavaScriptHookDescriptor>,
        nextGeneration: UInt64,
        instanceGeneration: UInt64,
        instanceIdentity: String,
        services!: Array<PluginServiceDescriptor> = [],
        modelProviders!: Array<PluginModelProviderDescriptor> = [],
        contextProviders!: Array<PluginContentProviderDescriptor> = [],
        resourceProviders!: Array<PluginContentProviderDescriptor> = [],
        policyProviders!: Array<PluginContentProviderDescriptor> = []
    ) {
        this.extensionId = descriptor.namespace
        this.registryPin = registryPin
        this.metadataRegistry81 = metadataRegistry81
        this.descriptor = descriptor
        this.tools = tools
        this.commands = commands
        this.views = views
        this.hooks = hooks
        this.services = services.clone()
        this.modelProviders = modelProviders.clone()
        this.contextProviders = contextProviders.clone()
        this.resourceProviders = resourceProviders.clone()
        this.policyProviders = policyProviders.clone()
        this.nextGeneration = nextGeneration
        this.instanceGeneration = instanceGeneration
        this.instanceIdentity = instanceIdentity
    }

    func toolNames(): Array<String> {
        let names = ArrayList<String>()
        for (tool in tools) { names.add(tool.name) }
        names.toArray()
    }

    func matchesDeclarations(host: JavaScriptExtensionHost): Bool {
        let actualTools = host.tools
        let actualCommands = host.commands
        let actualViews = host.views
        let actualHooks = host.hooks
        let actualServices = host.services
        let actualProviders = host.modelProviders
        if (!samePluginContentProviders(contextProviders, host.contextProviders) ||
            !samePluginContentProviders(resourceProviders, host.resourceProviders) ||
            !samePluginContentProviders(policyProviders, host.policyProviders)) { return false }
        if (actualTools.size != tools.size || actualCommands.size != commands.size ||
            actualViews.size != views.size ||
            actualHooks.size != hooks.size || actualServices.size != services.size || actualProviders.size != modelProviders.size) { return false }
        for (index in 0..tools.size) {
            if (actualTools[index].name != tools[index].name ||
                actualTools[index].description != tools[index].description ||
                actualTools[index].inputSchemaJson != tools[index].inputSchemaJson ||
                actualTools[index].executionProfile != tools[index].executionProfile ||
                actualTools[index].inputAttachmentField != tools[index].inputAttachmentField ||
                actualTools[index].inputAttachmentMaxBytes != tools[index].inputAttachmentMaxBytes) { return false }
        }
        for (index in 0..commands.size) {
            if (actualCommands[index].name != commands[index].name ||
                actualCommands[index].description != commands[index].description) { return false }
        }
        for (index in 0..views.size) {
            if (actualViews[index].name != views[index].name ||
                actualViews[index].description != views[index].description) { return false }
        }
        for (index in 0..services.size) {
            if (actualServices[index].name != services[index].name ||
                actualServices[index].description != services[index].description ||
                actualServices[index].supportsPreparationReference != services[index].supportsPreparationReference) { return false }
        }
        for (index in 0..modelProviders.size) {
            if (actualProviders[index].name != modelProviders[index].name ||
                actualProviders[index].description != modelProviders[index].description ||
                actualProviders[index].protocol != modelProviders[index].protocol) { return false }
        }
        for (index in 0..hooks.size) {
            if (actualHooks[index].reference != hooks[index].reference) { return false }
        }
        true
    }

    func threadHost(
        threadId: String,
        launcher: JavaScriptHostProcessLauncher,
        ordinaryToolPayload!: Bool = false, providerSequence!: Bool = false, contextSequence!: Bool = false, callTimeoutMillis!: Int64 = 30000
    ): JavaScriptHostResult<HostJavaScriptPluginThreadHost> {
        hostLock.lock()
        try {
            if (closing) {
                return JavaScriptHostResult.Err(JavaScriptHostError(
                    "plugin.not_active", "JavaScript plugin is no longer active"
                ))
            }
            if (threadId.trimAscii() == "") {
                return JavaScriptHostResult.Err(JavaScriptHostError(
                    "extension.invocation_identity_invalid", "JavaScript plugin invocation requires a thread identity"
                ))
            }
            var selected: ?HostJavaScriptPluginThreadHost = None
            for (entry in threadHosts where entry.threadId == threadId) {
                selected = Some(entry)
                break
            }
            let entry = match (selected) {
                case Some(value) => value
                case None =>
                    if (threadHosts.size >= 64) {
                        return JavaScriptHostResult.Err(JavaScriptHostError(
                            "extension.pi_thread_limit", "Pi extension reached the 64-thread state limit"
                        ))
                    }
                    let started = startThreadHost(launcher, timeoutMillis: callTimeoutMillis, handshakeTimeoutMillis: if (callTimeoutMillis == 30000) { 0 } else { 5000 }, ordinaryToolPayload: ordinaryToolPayload, providerSequence: providerSequence, contextSequence: contextSequence)
                    match (started) {
                        case JavaScriptHostResult.Err(error) => return JavaScriptHostResult.Err(error)
                        case JavaScriptHostResult.Ok(value) =>
                            let added = HostJavaScriptPluginThreadHost(threadId, value)
                            threadHosts.add(added)
                            return JavaScriptHostResult.Ok(added)
                    }
            }
            if (entry.pinned) {
                return JavaScriptHostResult.Err(JavaScriptHostError("plugin.service_endpoint_required", "pinned worker requires its host selector"))
            }
            if (!entry.host.isClosed) { return JavaScriptHostResult.Ok(entry) }
            if (!entry.host.cleanupComplete) {
                entry.host.requestAbort()
                return JavaScriptHostResult.Err(JavaScriptHostError("plugin.worker_cleanup_pending",
                    "old worker cleanup must complete before replacement", cleanupHost: Some(entry.host)))
            }
            match (startThreadHost(launcher, timeoutMillis: callTimeoutMillis, handshakeTimeoutMillis: if (callTimeoutMillis == 30000) { 0 } else { 5000 }, ordinaryToolPayload: ordinaryToolPayload, providerSequence: providerSequence, contextSequence: contextSequence)) {
                case JavaScriptHostResult.Err(error) => JavaScriptHostResult.Err(error)
                case JavaScriptHostResult.Ok(value) =>
                    entry.host = value
                    JavaScriptHostResult.Ok(entry)
            }
        } finally {
            hostLock.unlock()
        }
    }

    private func startThreadHost(
        launcher: JavaScriptHostProcessLauncher,
        timeoutMillis!: Int64 = 30000,
        cancellation!: ?process.CancellationToken = None,
        handshakeTimeoutMillis!: Int64 = 0, serviceLimits!: ?ServiceProtocolLimits = None, payloadLimits!: ?ServicePayloadLimits = None,
        ordinaryToolPayload!: Bool = false, providerSequence!: Bool = false, contextSequence!: Bool = false
    ): JavaScriptHostResult<JavaScriptExtensionHost> {
        match (cancellation) {
            case Some(token) => if (token.isCancelled()) {
                return JavaScriptHostResult.Err(JavaScriptHostError("extension.cancelled", "endpoint validation was cancelled before inspection"))
            }
            case None => ()
        }
        if (descriptor.contentDigest.trimAscii() != "") {
            let packageMatches = match (registryPackageMatches81(descriptor.root, namespace: Some(descriptor.namespace),
                version: Some(descriptor.version), digest: Some(descriptor.contentDigest))) {
                case Result.Err(_) => return JavaScriptHostResult.Err(JavaScriptHostError(
                    "plugin.snapshot_stale", "Pi package no longer matches its mounted snapshot"))
                case Result.Ok(value) => value }
            if (!packageMatches) {
                return JavaScriptHostResult.Err(JavaScriptHostError(
                    "plugin.snapshot_stale", "Pi package no longer matches its mounted snapshot")) }
        }
        // This token is scoped to launch/ready only. It cannot become the
        // persistent worker's invocation ceiling or outlive the handshake.
        let handshake: ?process.CancellationSource = if (handshakeTimeoutMillis > 0) {
            Some(process.CancellationSource(parent: cancellation,
                deadlineMillis: agentUtcMillis() + handshakeTimeoutMillis))
        } else { None }
        // Native intent references name the immutable mounted generation.
        // Physical workers are isolated by their actual channels/host identity;
        // the Pi connection counter must not replace a Native binding token.
        let wireGeneration = if (descriptor.entryKind == PluginEntryKind.NativeExecutable) {
            instanceGeneration
        } else { nextGeneration }
        let result = try {
            hostStartRegistryJavaScriptHost159(descriptor, wireGeneration, launcher, registryPin,
                timeoutMillis: timeoutMillis, serviceLimits: serviceLimits, payloadLimits: payloadLimits, ordinaryToolPayload: ordinaryToolPayload, providerSequence: providerSequence, contextSequence: contextSequence, cancellation: match (handshake) {
                    case Some(source) => Some(source.token)
                    case None => cancellation
                })
        } finally { match (handshake) { case Some(source) => source.close(); case None => () } }
        let started = match (result) {
            case JavaScriptHostResult.Err(error) => return JavaScriptHostResult.Err(error)
            case JavaScriptHostResult.Ok(value) => value
        }
        if (!matchesDeclarations(started)) {
            started.close()
            return JavaScriptHostResult.Err(JavaScriptHostError(
                "plugin.registration_changed", "Pi package registrations changed after activation",
                cleanupHost: if (started.cleanupComplete && started.collectCompletedDispatchData159()) { Option<JavaScriptExtensionHost>.None } else { Some(started) }
            ))
        }
        if (descriptor.entryKind != PluginEntryKind.NativeExecutable) { nextGeneration += 1u64 }
        JavaScriptHostResult.Ok(started)
    }
    func ownedDescriptor81(): Result<OwnedPluginPackageDescriptor> {
        match (registryPin.capturedRecord()) {
            case PluginRegistryResult.Err(error) => hostRegistryOwnedError81(error)
            case PluginRegistryResult.Ok(record) => Result.Ok(record.descriptor)
        }
    }
    func registryPackageMatches81(root: String, namespace!: ?String = None, version!: ?String = None,
        digest!: ?String = None, entrypoint!: ?String = None): Result<Bool> {
        hostRegistryPackageMatches81(metadataRegistry81, root, namespace: namespace, version: version,
            digest: digest, entrypoint: entrypoint)
    }
    func isClosing(): Bool {
        let unavailable = synchronized(hostLock) { closing }
        if (unavailable) { return true }
        match (registryPin.current()) { case PluginImportResult.Err(_) => true; case PluginImportResult.Ok(_) => false }
    }
    func enterRegistryEffect(): Result<PluginRegistryExecutionFence> {
        if (synchronized(hostLock) { closing }) { return hostPluginResourceError("plugin.instance_stale", "plugin instance is closing") }
        match (registryPin.enter()) {
            case PluginImportResult.Err(error) => hostRegistryFenceError90(descriptor, error)
            case PluginImportResult.Ok(value) => Result.Ok(value)
        }
    }

    func pinServiceHost(key: String, launcher: JavaScriptHostProcessLauncher,
        cancellation: process.CancellationToken, limits: ServiceProtocolLimits, payloadLimits: ?ServicePayloadLimits): JavaScriptHostResult<HostJavaScriptPluginThreadHost> {
        hostLock.lock()
        try {
            if (closing) { return JavaScriptHostResult.Err(JavaScriptHostError("plugin.not_active", "plugin instance was revoked")) }
            if (threadHosts.size >= 64) {
                return JavaScriptHostResult.Err(JavaScriptHostError("extension.pi_thread_limit", "plugin reached its 64-worker limit"))
            }
            // No lookup/replacement: each explicit pin gets a fresh worker.
            // Explicit operator profiles can retain a finite long call window.
            // Startup, actual call, canonical root and lease deadlines still clamp it.
            match (startThreadHost(launcher, timeoutMillis: max(120000, limits.callTimeoutMillis), cancellation: Some(cancellation),
                handshakeTimeoutMillis: 5000, serviceLimits: if (limits.isExplicit) { Some(limits) } else { Option<ServiceProtocolLimits>.None }, payloadLimits: payloadLimits)) {
                case JavaScriptHostResult.Err(error) => JavaScriptHostResult.Err(error)
                case JavaScriptHostResult.Ok(host) =>
                    let entry = HostJavaScriptPluginThreadHost(key, host, pinned: true)
                    threadHosts.add(entry)
                    JavaScriptHostResult.Ok(entry)
            }
        } finally { hostLock.unlock() }
    }

    func releasePinnedHost(entry: HostJavaScriptPluginThreadHost): Unit {
        hostLock.lock()
        try {
            if (!entry.pinned || !entry.host.cleanupComplete) { return }
            for (index in 0..threadHosts.size where refEq(threadHosts[index], entry)) {
                threadHosts.remove(at: index)
                break
            }
        } finally { hostLock.unlock() }
    }

    // Launch has already consumed a worker reservation. Retain its failed
    // cleanup in the same owner collection even if disable won the race.
    func retainFailedPinnedHost(key: String, worker: JavaScriptExtensionHost): HostJavaScriptPluginThreadHost {
        let entry = HostJavaScriptPluginThreadHost(key, worker, pinned: true)
        hostLock.lock()
        try { threadHosts.add(entry) } finally { hostLock.unlock() }
        entry
    }

    func invocationCancellation(deadlineMillis: Int64): ?process.CancellationSource {
        hostLock.lock()
        try {
            if (closing) { return None }
            Some(revocation.child(deadlineMillis: deadlineMillis))
        } finally {
            hostLock.unlock()
        }
    }

    // process4cj deliberately changes a child cause to Parent. Recognize only
    // the captured invocation child of this actual closing generation, with
    // the exact original owner message and timestamp retained by that bridge.
    func invocationRevocationCause(child: process.CancellationToken): ?process.CancellationCause {
        if (!isClosing()) { return None }
        let original = match (revocation.token.cause()) {
            case Some(value) => value
            case None => return None
        }
        let propagated = match (child.cause()) {
            case Some(value) => value
            case None => return None
        }
        match (original.kind) {
            case process.CancellationKind.Explicit => ()
            case _ => return None
        }
        match (propagated.kind) {
            case process.CancellationKind.Parent => ()
            case _ => return None
        }
        if (original.code != "extension.cancelled" || propagated.code != "process.parent_cancelled" ||
            propagated.message != original.message || propagated.occurredAtMillis != original.occurredAtMillis) {
            return None
        }
        Some(original)
    }

    // Capture only the same original generation/child bridge used to classify
    // this actual process response. This is execution evidence, not authority.
    func executionCancellationEvidence(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        child: process.CancellationToken, error: AgentError): ?ToolExecutionCancellationEvidence {
        let cause = match (invocationRevocationCause(child)) { case Some(value) => value; case None => return None }
        if (error.kind != AgentErrorKind.Cancelled || error.code != cause.code || error.message != cause.message) { return None }
        observeToolExecutionCancellation(context, prepared, error, borrowProcessCancellationToken(revocation.token))
    }

    func observeRevocation(callback: () -> Unit): Result<process.CancellationRegistration> {
        hostLock.lock()
        let unavailable = try { closing } finally { hostLock.unlock() }
        if (unavailable) {
            return hostPluginResourceError("plugin.not_active", "plugin generation was revoked")
        }
        // Registration runs an already-cancelled callback immediately, closing
        // the race between the state check above and generation disposal.
        Result.Ok(revocation.token.onCancel({ _ => callback() }))
    }

    func observeRevocationReturning180(callback:()->Unit):Result<process.CancellationRegistration>{
        hostLock.lock();let unavailable=try{closing}finally{hostLock.unlock()}
        if(unavailable){return hostPluginResourceError("plugin.not_active","plugin generation was revoked")}
        Result.Ok(revocation.token.onCancelReturning159({_=>callback()}))
    }

    func beginClose(): Unit {
        hostLock.lock(); try { closing = true } finally { hostLock.unlock() }
    }

    func closeHosts(): Array<JavaScriptExtensionHost> {
        hostLock.lock()
        let activeHosts = try {
            closing = true
            threadHosts.toArray()
        } finally {
            hostLock.unlock()
        }
        // This source belongs to the actual closing plugin generation.
        let _ = revocation.cancel(cause: Some(process.CancellationCause(
            process.CancellationKind.Explicit, "extension.cancelled",
            "plugin generation was revoked", occurredAtMillis: agentUtcMillis()
        )))
        for (entry in activeHosts) {
            if (entry.pinned) { entry.host.requestAbort() }
            else { entry.host.close() }
        }
        revocation.close()
        registryPin.close()
        activeHosts.map { entry => entry.host }
    }
}

// One stack-local observation per executor invocation; no native/Run owner.
class HostToolExecutionCancellationObservation {
    private let context: ToolInvocationContext
    private let prepared: PreparedToolInvocation
    private var evidence: ?ToolExecutionCancellationEvidence = None

    init(context: ToolInvocationContext, prepared: PreparedToolInvocation) {
        this.context = context; this.prepared = prepared
    }
    func record(identity: JavaScriptHostInvocationIdentity, generation: HostJavaScriptPluginGeneration,
        child: process.CancellationToken, error: AgentError): Unit {
        if (identity.threadId != context.sessionId.value || identity.runId != context.runId.value ||
            identity.epoch != context.epoch || identity.operationId != prepared.operationId.value ||
            identity.callId != prepared.call.callId) { return }
        evidence = generation.executionCancellationEvidence(context, prepared, child, error)
    }
    func outcome(result: Result<ToolResult>): ToolExecutionOutcome {
        ToolExecutionOutcome(result, cancellationEvidence: evidence)
    }
}

public class HostJavaScriptPluginToolExecutor <: ToolExecutor & OwnedToolExecutor & OwnedPersistedToolResultObserver {
    private let host: HostJavaScriptPluginHost
    private let extensionId: String
    private let toolName: String
    private let instanceGeneration: UInt64
    private let serviceRuntime: ?HostJavaScriptPluginServiceRuntime

    public init(
        host: HostJavaScriptPluginHost,
        extensionId: String,
        toolName: String
    ) {
        this.host = host
        this.extensionId = extensionId.trimAscii()
        this.toolName = toolName.trimAscii()
        this.instanceGeneration = host.instanceGeneration(this.extensionId)
        this.serviceRuntime = None
    }

    public init(
        host: HostJavaScriptPluginHost,
        extensionId: String,
        toolName: String,
        serviceRuntime!: ?HostJavaScriptPluginServiceRuntime,
        expectedInstanceGeneration!: UInt64 = 0u64
    ) {
        this.host = host
        this.extensionId = extensionId.trimAscii()
        this.toolName = toolName.trimAscii()
        this.instanceGeneration = if (expectedInstanceGeneration == 0u64) {
            host.instanceGeneration(this.extensionId)
        } else { expectedInstanceGeneration }
        this.serviceRuntime = serviceRuntime
    }

    public func acquireHandoffLease(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolExecutionHandoffLease> {
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (host.enterRegistryEffect(extensionId, instanceGeneration)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => Result<ToolExecutionHandoffLease>.Ok(HostRegistryToolHandoffLease(value))
        }
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        executeActual(context, prepared)
    }

    // The mounted Catalog retains this exact executor object. Pipeline
    // independently owns original Source/admission and terminal SQL proof;
    // no Native completion, descriptor or output lease supplies authority.
    // This executor has no persisted-result observer side effect. The real
    // canonical consumer owns held; this explicit NOP retains no item/alias.
    // Old ordinary afterPersisted and owned factory selections stay exact.
    public func afterOwnedResultPersisted(context:ToolInvocationContext,
        held:OwnedCanonicalThreadItemAliasCustody):Result<Unit>{
        let _=context;let _=held;Result<Unit>.Ok(())
    }

    // Ordinary canonical results only. The separate owned Memory observer
    // keeps its original contract; this callback never borrows owned payloads.
    public func afterResultPersisted(context:ToolInvocationContext,result:ToolResult):Result<Unit> {
        host.primitiveParentResultPersisted111(context,result)
    }

    public func executeOwned(context:ToolInvocationContext,parent:PreparedToolInvocation,
        control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        if(serviceRuntime.isNone() || instanceGeneration==0u64){
            return hostPluginResourceError("plugin.live_executor_unbound","actual mounted document broker and generation are required")}
        hostExecutePluginLivePolicyParent(host,extensionId,toolName,instanceGeneration,context,parent,control)
    }
    // Unused migration forwarders. Actual canonical carrier/oracles must
    // authorize switching the old owned methods to these explicit entries.
    // Unused creator only. Registering this distinct typed executor still
    // requires the original descriptor/Source/Host registry path; no current
    // factory is switched and the old methods below remain byte exact.
    func preparedLiveMemoryExecutor332():Result<ToolExecutor>{
        if(serviceRuntime.isNone() || instanceGeneration==0u64){
            return hostPluginResourceError("plugin.live_executor_unbound","actual mounted broker and generation are required")}
        Result<ToolExecutor>.Ok(HostLivePreparedPhaseExecutor332(this,host,extensionId,toolName,instanceGeneration))
    }
    public func executeOwnedLiveMemory312(context:ToolInvocationContext,parent:PreparedToolInvocation,
        control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        if(serviceRuntime.isNone() || instanceGeneration==0u64){
            return hostPluginResourceError("plugin.live_executor_unbound","actual mounted broker and generation are required")}
        hostExecutePluginLivePolicyParent312(host,extensionId,toolName,instanceGeneration,context,parent,control)
    }
    public func resumeOwnedLiveMemory312(context:ToolInvocationContext,pending:OwnedToolExecutionContinuation,
        decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        if(serviceRuntime.isNone() || instanceGeneration==0u64){
            return hostPluginResourceError("plugin.live_executor_unbound","actual mounted broker and generation are required")}
        hostResumePluginLivePolicyParent312(host,extensionId,toolName,instanceGeneration,context,pending,decision,control)
    }

    public func rejectOwned(context:ToolInvocationContext,parent:PreparedToolInvocation,
        decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        if(serviceRuntime.isNone() || instanceGeneration==0u64){
            return hostPluginResourceError("plugin.live_executor_unbound","actual mounted document broker and generation are required")}
        hostRejectPluginLivePolicyParent(host,extensionId,toolName,instanceGeneration,context,parent,decision,control)
    }
    public func resumeOwned(context:ToolInvocationContext,pending:OwnedToolExecutionContinuation,
        decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>{
        // This initial entry successor creates no pending mutation custody.
        // A subsequent child driver must recover its actual private retained
        // object through pending.withClaimedCustody, never reconstruct it
        // from history or execute the original Parent again.
        let _=context;let _=pending;let _=decision;let _=control
        hostPluginResourceError("plugin.live_parent_driver_unavailable","this executor has no retained child-driver owner for the claimed continuation")
    }

    public func executeObserved(context: ToolInvocationContext, prepared: PreparedToolInvocation): ToolExecutionOutcome {
        let observation = HostToolExecutionCancellationObservation(context, prepared)
        let result = executeActual(context, prepared, executionObservation: Some(observation))
        observation.outcome(result)
    }

    private func executeActual(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        executionObservation!: ?HostToolExecutionCancellationObservation = None
    ): Result<ToolResult> {
        if(isPluginLivePolicyParentPlan(prepared.operationPlan)){
            return hostPluginResourceError("plugin.live_owned_entry_required","live Parent requires the actual typed owned Pipeline entry")}
        if (instanceGeneration == 0u64) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "plugin.instance_unbound",
                "plugin executor was not bound to an active instance"
            ))
        }
        if (context.cancellation.isCancelled()) {
            return Result.Err(AgentError(
                AgentErrorKind.Cancelled,
                "extension.cancelled",
                "JavaScript plugin invocation was cancelled"
            ))
        }
        if (context.epoch < 1) {
            return Result.Err(AgentError(
                AgentErrorKind.Protocol,
                "extension.invocation_identity_invalid",
                "JavaScript plugin invocation requires the active run epoch"
            ))
        }
        let invocationArguments = match (host.ordinaryToolInput(context, prepared, extensionId, toolName, instanceGeneration)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        let toolPayload: ?OrdinaryToolPayloadLimits = if (isFrozenReadonlyDelegationParentPlan(prepared.operationPlan)) {
            ordinaryToolPayloadLimitsFromValue(prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("tool_payload_limits") ?? nullValue())
        } else if (isFrozenPluginDocumentParentPlan(prepared.operationPlan) || isFrozenReadViewParentPlan(prepared.operationPlan)) {
            ordinaryToolPayloadLimitsFromValue(prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("tool_payload_limits") ?? nullValue())
        } else { None }
        let identity = JavaScriptHostInvocationIdentity(
            threadId: context.sessionId.value,
            runId: context.runId.value,
            epoch: context.epoch,
            operationId: prepared.operationId.value,
            callId: prepared.call.callId
        )
        let profile = match (host.toolExecutionProfile(extensionId, toolName, instanceGeneration)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let dataOnly = profile == PluginToolExecutionProfile.DataOnly
        let preparedCompletion152 = isFrozenPluginPreparedCompletion152(prepared.operationPlan)
        let observer: HostJavaScriptPluginInvocationObserver = if (dataOnly || preparedCompletion152) {
            // Denies every service request. No raw or ordinary broker fallback.
            HostJavaScriptPluginInvocationObserver(context, prepared, Option<HostJavaScriptPluginServiceBroker>.None)
        } else { match (serviceRuntime) {
            case Some(runtime) => runtime.observer(context, prepared,
                identity: Some(HostPluginServiceIdentity(host, extensionId, instanceGeneration)))
            case None => HostJavaScriptPluginInvocationObserver(context, prepared, Option<HostJavaScriptPluginServiceBroker>.None)
        } }
        let result = executeObservedInvocationFrame159(context, prepared, executionObservation,
            invocationArguments, toolPayload, identity, dataOnly, preparedCompletion152, observer)
        // The entire actual Native/service callback/timer/output/Future helper
        // has returned. Failed Future retirement keeps the broker paid.
        let _ = observer.returnOwnedInvocationFrame159()
        result
    }
    private func executeObservedInvocationFrame159(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, executionObservation: ?HostToolExecutionCancellationObservation,
        invocationArguments: AgentValue, toolPayload: ?OrdinaryToolPayloadLimits,
        identity: JavaScriptHostInvocationIdentity, dataOnly: Bool, preparedCompletion152: Bool,
        observer: HostJavaScriptPluginInvocationObserver): Result<ToolResult> {
        if(httpIntentText(prepared.operationPlan.canonicalArguments.field("host_plan") ?? nullValue(),"version")==PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA ||
            httpIntentText(prepared.operationPlan.canonicalArguments.field("host_plan")??nullValue(),"version")==PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA){
            return hostExecuteFrozenDocument(host,extensionId,toolName,instanceGeneration,context,prepared,observer)
        }
        try {
            match(observer.prepareOwnedAwait166()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let hasUI = if (dataOnly || preparedCompletion152) { false } else { match (serviceRuntime) {
            case Some(runtime) => runtime.hasUI(context.sessionId)
            case None => false
        } }
        let workingDirectory = if (context.cwd.trimAscii() == "") {
            context.workspaceRoot
        } else {
            context.cwd
        }
        let readViewWindow = match (host.readViewInvocationWindow(context, prepared, extensionId, toolName, instanceGeneration)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let attachment: ?HostToolInputAttachmentSession = match (host.prepareToolInputAttachment(context, prepared, extensionId, toolName, instanceGeneration)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let outcome = try { host.invokeObserved(
            extensionId,
            toolName,
            stringifyUnifiedJson(invocationArguments),
            identity: identity,
            cancellation: context.cancellation,
            cwd: workingDirectory,
            hasUI: hasUI,
            processLimits: context.budget.processLimits,
            finiteReadViewWindow: readViewWindow,
            observer: Some(observer),
            expectedInstanceGeneration: instanceGeneration,
            authorityScope: if (dataOnly) { "data-only:" + extensionId + ":" +
                prepared.operationPlan.implementation.toolVersion + ":" +
                prepared.operationPlan.implementation.implementationFingerprint } else {
                hostPluginInvocationAuthorityScope(context) },
            toolPayloadLimits: toolPayload,
            documentToolPayload: toolPayload.isSome() && isFrozenPluginDocumentParentPlan(prepared.operationPlan),
            executionObservation: executionObservation,
            inputAttachment: match (attachment) { case Some(value) => value.descriptor(); case None => Option<AgentValue>.None },
            inputAttachmentCurrent: match (attachment) { case Some(value) => Some({ => value.validate() }); case None => Option<() -> Result<Unit>>.None }
        ) } catch (error: Exception) {
            match (attachment) { case Some(owner) => owner.abort(); case None => () }; throw error
        }
        var transferred = false
        try {
            match (observer.finishReadonly()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (observer.finishChild111()) { case Result.Err(error) =>
                return Result.Err(error); case Result.Ok(_) => () }
        match (observer.finishDocument()) { case Result.Err(error) =>
            match (outcome) {
                case Result.Ok(_) => ()
                case Result.Err(original) => if (original.kind == AgentErrorKind.Cancelled && context.cancellation.isCancelled()) {
                    return Result.Err(original) }
            }
            return Result.Err(error)
            case Result.Ok(_) => () }
            match (outcome) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(value) =>
                    match (host.ordinaryToolInput(context, prepared, extensionId, toolName, instanceGeneration)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
                    }
                    match (attachment) { case Some(owner) => match (owner.validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; case None => () }
                    if (preparedCompletion152) {
                        match (hostVerifyPreparedCompletion152(host, extensionId, toolName, instanceGeneration,
                            context, prepared, value.value, value.isError)) {
                            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    }
                    let owned=match(observer.retainOwnedAwaitResult166(prepared.call.callId,value.value,value.isError)){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(item)=>item}
                    match(owned){case Some(copy)=>
                        var copyReturned=false
                        try{
                            // The independent copy and this encoded output
                            // helper are prepaid before real emission. No raw
                            // ordinary Native result is relabeled as a lease.
                            match(context.outputSink.emit(ToolOutputChunk(prepared.call.callId,
                                if(copy.isError){ToolOutputChannel.Stderr}else{ToolOutputChannel.Stdout},stringifyUnifiedJson(copy.output)))){
                                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                            let result=if(toolPayload.isSome() || attachment.isSome()){
                                ToolResult(prepared.call.callId,copy.output,isError:copy.isError,payloadLease:Some(ToolResultPayloadLease({=>
                                    copy.releasePayload();value.releasePayload()
                                    match(attachment){case Some(owner)=>owner.acknowledge();case None=>()}})))}else{copy}
                            match(attachment){case Some(owner)=>owner.returned();case None=>()}
                            transferred=toolPayload.isSome() || attachment.isSome();copyReturned=true
                            return Result.Ok(result)
                        }finally{if(!copyReturned){copy.releasePayload()}}
                        case None=>()}
                    match (context.outputSink.emit(ToolOutputChunk(prepared.call.callId,
                        if (value.isError) { ToolOutputChannel.Stderr } else { ToolOutputChannel.Stdout }, stringifyUnifiedJson(value.value)))) {
                        case Result.Err(error) => Result.Err(error)
                        case Result.Ok(_) =>
                            let result = ToolResult(prepared.call.callId, value.value, isError: value.isError,
                                payloadLease: if (toolPayload.isSome() || attachment.isSome() || preparedCompletion152) { Some(ToolResultPayloadLease({ =>
                                    value.releasePayload(); match (attachment) { case Some(owner) => owner.acknowledge(); case None => () } })) } else { Option<ToolResultPayloadLease>.None })
                            match (attachment) { case Some(owner) => owner.returned(); case None => () }
                            transferred = toolPayload.isSome() || attachment.isSome() || preparedCompletion152
                            Result.Ok(result)
                    }
            }
        } finally {
            if (!transferred) { match (outcome) { case Result.Ok(value) => value.releasePayload(); case _ => () }
                match (attachment) { case Some(owner) => owner.abort(); case None => () } }
        }
        } finally {
            // After complete Native worker/transport/output/copy frames. A
            // failed retirement retains the actual paid controller debt.
            let _ = observer.retireOwnedAwait166()
        }
    }
    public func cancel(runId: RunId): Result<Unit> {
        let _ = runId
        Result.Ok(())
    }
}
public func hostPluginInvocationAuthorityScope(context: ToolInvocationContext): String {
    managedInvocationAuthorityScope(context)
}
// An allocation choice, not invocation authority. Only the actual ordinary
// Tool path can select it, after matching the current operator configuration
// to the frozen invocation profile and the inspected/ready contribution.
public func hostOrdinaryToolPayloadSelection(settingsRoot: String, descriptor: PluginPackageDescriptor,
    availableTools: Array<String>, kind: String, tool: String, limits: ?OrdinaryToolPayloadLimits, document!: Bool = false): Result<String> {
    let requested = match (limits) { case None => return Result.Ok(""); case Some(value) => value }
    var declared = false
    for (entry in descriptor.contributions where entry.kind == PluginContributionKind.Tool && entry.name == tool) { declared = true }
    if (descriptor.entryKind != PluginEntryKind.NativeExecutable ||
        (kind != "tool" && !(kind == "prepare" && descriptor.requestedCapabilities.contains("process.readview") && !document)) ||
        !declared || !availableTools.contains(tool) || requested.contribution != tool) {
        return hostPluginResourceError("plugin.tool_payload_selection_invalid", "ordinary payload selection requires the exact available native Tool") }
    // The caller selects this source from the actual frozen parent plan;
    // a package capability never redirects an unrelated ordinary contribution.
    if (document) {
        if (!descriptor.requestedCapabilities.contains("document.store")) {
            return hostPluginResourceError("plugin.tool_payload_selection_invalid", "document allocation requires the actual document Tool path") }
        let config = match (loadHostPluginDocumentConfiguration(settingsRoot, descriptor.namespace, descriptor.contentDigest)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let selected = match (config.toolPayloadLimits(tool)) { case Some(value) => value
            case None => return hostPluginResourceError("plugin.tool_payload_selection_invalid", "operator has not selected this exact document Tool profile") }
        if (canonicalAgentValue(selected.value()) != canonicalAgentValue(requested.value())) {
            return hostPluginResourceError("plugin.tool_payload_selection_invalid", "document Tool profile changed after preparation") }
        match (config.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        return Result.Ok("document:" + config.digest + ":" + modelPolicySha256Text(canonicalAgentValue(selected.value())))
    }
    let config = match (loadHostPluginHttpConfiguration(settingsRoot, descriptor.namespace, descriptor.contentDigest)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let selected = match (config.toolPayloadLimits(tool)) { case Some(value) => value
        case None => return hostPluginResourceError("plugin.tool_payload_selection_invalid", "operator has not selected this ordinary Tool payload profile") }
    if (canonicalAgentValue(selected.value()) != canonicalAgentValue(requested.value())) {
        return hostPluginResourceError("plugin.tool_payload_selection_invalid", "ordinary Tool payload profile changed after preparation") }
    match (config.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    // A previous unprofiled worker, or another contribution/configuration, must
    // not be reused for a newly negotiated transfer. Existing owners retain
    // their normal bounded cleanup and generation cancellation responsibilities.
    Result.Ok(config.digest + ":" + modelPolicySha256Text(canonicalAgentValue(selected.value())))
}
public func hostStartJavaScriptHost(
    descriptor: PluginPackageDescriptor,
    generation: UInt64,
    launcher: JavaScriptHostProcessLauncher,
    timeoutMillis!: Int64 = 30000,
    cancellation!: ?process.CancellationToken = None, serviceLimits!: ?ServiceProtocolLimits = None, payloadLimits!: ?ServicePayloadLimits = None,
    ordinaryToolPayload!: Bool = false, providerSequence!: Bool = false, contextSequence!: Bool = false,
    dispatchFence!: ?JavaScriptHostDispatchFence = None
): JavaScriptHostResult<JavaScriptExtensionHost> {
    var contentPayload = false
    if (descriptor.entryKind == PluginEntryKind.NativeExecutable) {
        for (item in descriptor.contributions where item.kind == PluginContributionKind.ContextProvider ||
            (item.kind == PluginContributionKind.ResourceProvider || item.kind == PluginContributionKind.Provider)) { contentPayload = true }
    }
    startJavaScriptExtensionHostWithLauncher(JavaScriptHostLaunchRequest(
        descriptor.root,
        descriptor.entrypoint,
        runtime: "node",
        profile: if (descriptor.entryKind == PluginEntryKind.NativeExecutable) {
            JavaScriptHostLaunchProfile.NativeExecutable
        } else {
            JavaScriptHostLaunchProfile.PiV0871
        },
        extensionId: descriptor.id,
        extensionVersion: descriptor.version,
        generation: generation,
        defaultTimeoutMillis: timeoutMillis,
        maxFrameBytes: match (serviceLimits) { case Some(value) => value.maxFrameBytes; case None => JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES },
        serviceLimits: serviceLimits, payloadLimits: payloadLimits,
        contentPayload: contentPayload,
        ordinaryToolPayload: ordinaryToolPayload, providerSequence: providerSequence, contextSequence: contextSequence,
        grantedCapabilities: [],
        enforceNodePermissions: true,
        contributions: descriptor.contributions
    ), launcher, cancellation: cancellation, dispatchFence: dispatchFence)
}
public func hostJavascriptPluginAgentError(error: JavaScriptHostError): AgentError {
    let kind = if (error.code == "extension.cancelled") {
        AgentErrorKind.Cancelled
    } else if (error.code == "extension.invocation_timeout" ||
        error.code == "extension.handshake_timeout") {
        AgentErrorKind.Timeout
    } else if (error.code == "extension.permission_denied") {
        AgentErrorKind.PermissionDenied
    } else if (error.code.startsWith("sandbox.") ||
        error.code.startsWith("extension.sandbox_")) {
        AgentErrorKind.Configuration
    } else {
        AgentErrorKind.Protocol
    }
    AgentError(kind, error.code, error.message)
}
public func hostJavascriptPluginDecodeValue(
    source: String,
    maxBytes!: Int64 = 1048576, decodedData180!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
): Result<AgentValue> {
    try {
        match (decodedData180) {
            case Some(paid) =>
                if (source.size <= maxBytes) {
                    if (source.size > (Int64.Max - 1114112) / 12) { throw LogicalJsonPayloadError("decoded ingress invoice overflow") }
                    paid.ensureRetainedPeak(1114112 + source.size * 12)
                    let nodes = logicalJsonNodeCount(source)
                    if (nodes > (Int64.Max - 1114112 - source.size * 12) / 512) { throw LogicalJsonPayloadError("decoded ingress DOM invoice overflow") }
                    paid.ensureRetainedPeak(1114112 + source.size * 12 + nodes * 512)
                }
            case None => ()
        }

        Result.Ok(parseUnifiedJson(source, maxBytes: maxBytes))
    } catch (error: JsonException) {
        Result.Err(AgentError(
            AgentErrorKind.Protocol,
            "value.invalid_json",
            error.message
        ))
    }
}

public func hostJavascriptPluginError<T>(code: String, message: String): Result<T> {
    Result.Err(hostJavascriptPluginAgentError(JavaScriptHostError(code, message)))
}

// This identifier is part of the immutable executor binding, not a capability
// or a ModelLane registration ID. If its live instance is gone, a later mount
// must not impersonate it; historical pending calls remain unavailable.
public func hostNewPluginInstanceIdentity(): Result<String> {
    let bytes = Array<Byte>(32, repeat: 0)
    try { process.fillSecureRandom(bytes) }
    catch (_: Exception) {
        return hostPluginResourceError("plugin.instance_entropy_unavailable", "cannot create a plugin instance identity")
    }
    let digits = "0123456789abcdef".toArray()
    let encoded = ArrayList<Byte>()
    for (byte in bytes) {
        let value = UInt8(byte)
        encoded.add(digits[Int64((value >> 4) & 0x0f)])
        encoded.add(digits[Int64(value & 0x0f)])
    }
    Result.Ok(String.fromUtf8(encoded.toArray()))
}
