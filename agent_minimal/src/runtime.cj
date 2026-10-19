package agent_minimal

import agent_core.*
import agent_domain
import agent_domain.*
import agent_runtime.*
import agent_ports.*
import agent_store.*
import agent_extension_runtime.*
import agent_plugin_registry.*
import agent_host_runtime.*
import persistence_runtime.*
import tool_runtime.*
import process4cj.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import std.time.*

// Only CLI/operator configuration enters these immutable composition inputs.
// A package's requested capabilities remain requirements; they are never grants.
class MinimalRuntimeOptions {
    let stateRoot: String
    let capabilities: CapabilitySet
    let approvalMode: ApprovalMode
    let timeoutMillis: Int64
    let maxToolCalls: Int64
    let caBundle: String
    init(stateRoot: String, capabilities: CapabilitySet, approvalMode: ApprovalMode,
        timeoutMillis: Int64, maxToolCalls: Int64, caBundle!: String = "") {
        if (stateRoot.trimAscii() == "" || stateRoot.contains("\u{0000}") ||
            timeoutMillis < 1 || timeoutMillis > 120000 || maxToolCalls < 1 || maxToolCalls > 32) {
            throw IllegalArgumentException("runtime state root and finite execution limits are required")
        }
        this.stateRoot = stateRoot; this.capabilities = capabilities; this.approvalMode = approvalMode
        this.timeoutMillis = timeoutMillis; this.maxToolCalls = maxToolCalls; this.caBundle = caBundle
    }
}

class MinimalRuntimeReply {
    let exitCode: Int64
    let json: String
    let runId: String
    init(exitCode: Int64, value: AgentValue, runId!: String = "") {
        this.exitCode = exitCode; this.json = stringifyUnifiedJson(value); this.runId = runId
    }
}

func minimalRuntimeFailure(error: AgentError, thread!: String = "", run!: String = "", call!: String = ""): MinimalRuntimeReply {
    MinimalRuntimeReply(2, objectValue([
        ValueField("ok", boolValue(false)), ValueField("code", textValue(error.code)),
        ValueField("message", textValue(error.message)), ValueField("thread_id", textValue(thread)),
        ValueField("run_id", textValue(run)), ValueField("call_id", textValue(call))]), runId: run)
}

func minimalOperatorCapability(value: String): Capability {
    if (value == "" || value.contains("\u{0000}")) { throw IllegalArgumentException("grant must name a capability") }
    let separator = value.indexOf(":")
    let name = if (separator.isSome()) { value[..separator.getOrThrow()] } else { value }
    let resource = if (separator.isSome()) { value[separator.getOrThrow() + 1..] } else { "" }
    if (separator.isSome() && resource == "") { throw IllegalArgumentException("grant resource must not be empty") }
    let kind = match (name) {
        case "workspace.read" => CapabilityKind.WorkspaceRead
        case "workspace.write" => CapabilityKind.WorkspaceWrite
        case "process.spawn" => CapabilityKind.ProcessSpawn
        case "network.access" => CapabilityKind.NetworkAccess
        case "peer.message" => CapabilityKind.PeerMessage
        case "delegate" => CapabilityKind.Delegate
        case "extension.invoke" => CapabilityKind.ExtensionInvoke
        case _ => throw IllegalArgumentException("unknown capability grant")
    }
    Capability(kind, resource: resource)
}

func minimalApprovalMode(value: String): ApprovalMode {
    match (value) {
        case "always-ask" => ApprovalMode.AlwaysAsk
        case "write" => ApprovalMode.Write
        case "yolo" => ApprovalMode.Yolo
        case _ => throw IllegalArgumentException("approval mode must be always-ask, write, or yolo")
    }
}

func minimalCapabilityName(kind: CapabilityKind): String {
    match (kind) {
        case CapabilityKind.WorkspaceRead => "workspace.read"
        case CapabilityKind.WorkspaceWrite => "workspace.write"
        case CapabilityKind.ProcessSpawn => "process.spawn"
        case CapabilityKind.NetworkAccess => "network.access"
        case CapabilityKind.PeerMessage => "peer.message"
        case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension.invoke"
    }
}

class MinimalRuntimeIds <: IdGenerator {
    private let lock = Mutex()
    private let bytes = Array<Byte>(16, repeat: 0)
    init() {}
    public func nextRunId(): RunId { RunId(next("run")) }
    public func nextSessionId(): SessionId { SessionId(next("thread")) }
    public func nextInvocationId(): String { next("invocation") }
    public func nextOperationId(): OperationId { OperationId(next("operation")) }
    private func next(prefix: String): String {
        lock.lock()
        try { fillSecureRandom(bytes); prefix + "-" + agentUtcMillis().toString() + "-" + hostArtifactHex(bytes) }
        finally { lock.unlock() }
    }
}

func minimalToolContext(root: String): ToolContextDescriptor {
    ToolContextDescriptor(workspaceRoot: root, cwd: root, services: ToolServiceView(descriptors: [
        ToolServiceDescriptor(ToolServiceKind.Workspace, "host-read-resources"),
        ToolServiceDescriptor(ToolServiceKind.Process, "host-native-process"),
        ToolServiceDescriptor(ToolServiceKind.Conversation, "thread-runtime"),
        ToolServiceDescriptor(ToolServiceKind.Artifact, "host-artifact"),
        ToolServiceDescriptor(ToolServiceKind.Extension, "host-plugin")]))
}

// This executable owns exactly one Registry, Runtime registry, database,
// catalog, pipeline, plugin host and native process owner. None is handed to
// package code. Its fixed native factory accepts only internal actual Model/lifecycle seals.
class MinimalHostRuntime {
    private let database: SqliteDatabase
    private let registry: PluginRegistry
    private let threadRuntimes: SqliteThreadRuntimeRegistry
    private let ids: MinimalRuntimeIds
    private let operations: DurableOperationStore
    private let catalog: ToolCatalog
    private let processes: HostLocalProcessPort
    private let artifacts: HostArtifactStore
    private let host: HostJavaScriptPluginHost
    private let services: HostJavaScriptPluginServiceRuntime
    private let gateway: HostCanonicalToolGateway
    private let core: AgentCore
    private let ingress: HostStdioIngressRuntime
    private let frontendLifetime: agent_domain.CancellationSource
    private var lifecycle: ?HostPluginLifecycleManager = None
    private var activeRun: ?RunId = None
    private let workspaceRoot: String
    private let settingsRoot: String
    private let options: MinimalRuntimeOptions
    private var initialized = false
    private var closed = false
    private var closeFailure: ?AgentError = None

    init(database: SqliteDatabase, registry: PluginRegistry, threadRuntimes: SqliteThreadRuntimeRegistry,
        ids: MinimalRuntimeIds, operations: DurableOperationStore, catalog: ToolCatalog,
        processes: HostLocalProcessPort, artifacts: HostArtifactStore, host: HostJavaScriptPluginHost,
        services: HostJavaScriptPluginServiceRuntime, gateway: HostCanonicalToolGateway, core: AgentCore,
        ingress: HostStdioIngressRuntime,
        workspaceRoot: String, settingsRoot: String, options: MinimalRuntimeOptions) {
        this.database = database; this.registry = registry; this.threadRuntimes = threadRuntimes
        this.ids = ids; this.operations = operations; this.catalog = catalog; this.processes = processes
        this.artifacts = artifacts; this.host = host; this.services = services; this.gateway = gateway; this.core = core
        this.workspaceRoot = workspaceRoot; this.settingsRoot = settingsRoot; this.options = options
        this.ingress = ingress
        this.frontendLifetime = agent_domain.CancellationSource(deadlineMillis: agentUtcMillis() + options.timeoutMillis)
    }

    func initialize(): Result<Unit> {
        if (initialized || closed) { return Result.Err(AgentError(AgentErrorKind.Conflict,
            "minimal.runtime_state_invalid", "runtime may initialize only once before close")) }
        initialized = true
        match (hostRegisterContextRead(catalog, host, operations, payloadArtifacts: Some(artifacts))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match(hostRegisterPluginLiveEffect(host,operations,catalog,HostLiveMemoryJournalNativeAbortEffectExecutor328(host,operations))){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match (hostRegisterPluginReadOnlyProcessService(catalog, host, operations, processes)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (hostRegisterPluginReadViewService(catalog, host, operations, settingsRoot, processes)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (hostRegisterPluginHttpService(catalog, host, operations, settingsRoot, options.caBundle)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lifecycle = match (hostCreatePluginLifecycleManager(database, catalog, host, services, processes,
            payloadArtifacts: Some(artifacts), caBundle: options.caBundle, operations: Some(operations))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => Some(value) }
        match (hostRegisterPluginDocumentService(catalog)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (host.ownContextReadComponents({ => registry.captureContextComponentSnapshot(
            ["skill", "mcp", "prompt", "extension", "hook", "command", "theme", "hosted"]) })) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let records = registry.enabledEffectiveRecords()
        try {
            for (index in 0..records.size) {
                let record = records.take(index)
                // Host retains its separately prepaid private generation graph.
                // This caller handle ends only after the actual mount returns.
                try {
                    match (hostMountAndRegisterPluginTools(record, host, catalog, serviceRuntime: Some(services))) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                } finally { record.close() }
            }
        } finally { records.close() }
        Result.Ok(())
    }

    private func acquireThread(thread: String): Result<AgentThreadRuntime> {
        let actual = match (threadRuntimes.acquire(ThreadId(thread), workspaceRoot)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (actual.threadSnapshot().thread.workspaceId != workspaceRoot) {
            return Result.Err(AgentError(AgentErrorKind.Configuration, "minimal.thread_workspace_mismatch",
                "stored Thread belongs to a different canonical workspace")) }
        Result.Ok(actual)
    }

    func listTools(thread: String): MinimalRuntimeReply {
        match (acquireThread(thread)) { case Result.Err(error) => return minimalRuntimeFailure(error, thread: thread); case Result.Ok(_) => () }
        let snapshot = catalog.toolSetSnapshot("minimal-tools-" + ids.nextInvocationId(), options.capabilities,
            threadId: Some(ThreadId(thread)))
        MinimalRuntimeReply(0, objectValue([ValueField("ok", boolValue(true)), ValueField("thread_id", textValue(thread)),
            ValueField("tools", listValue(snapshot.entries.map { entry => objectValue([
                ValueField("name", textValue(entry.name)), ValueField("description", textValue(entry.description)),
                ValueField("input_schema", entry.inputSchema), ValueField("executor_version", textValue(entry.executorVersion)),
                ValueField("implementation_fingerprint", textValue(entry.implementationFingerprint)),
                ValueField("schema_digest", textValue(entry.schemaDigest)), ValueField("available", boolValue(entry.availableAtSnapshot)),
                ValueField("required_capabilities", listValue(entry.requiredCapabilities.map { capability => objectValue([
                    ValueField("kind", textValue(minimalCapabilityName(capability.kind))),
                    ValueField("resource", textValue(capability.resource))]) }))]) }))]))
    }

    func invoke(thread: String, name: String, arguments: AgentValue): MinimalRuntimeReply {
        match (acquireThread(thread)) { case Result.Err(error) => return minimalRuntimeFailure(error, thread: thread); case Result.Ok(_) => () }
        let run = ids.nextRunId()
        let call = ToolCall(ids.nextInvocationId(), name, arguments)
        // Unknown names deliberately reach the same canonical rejection and
        // Failed Run with actual user input and no admitted Operation, as Product Direct calls.
        let result = gateway.execute(SessionId(thread), options.capabilities, call,
            InvocationContextProjection(), Some(run), Option<ApprovalDecision>.None, budget: ExecutionBudget(
                maxToolCalls: options.maxToolCalls, maxConcurrentTools: 1,
                deadlineMillis: agentUtcMillis() + options.timeoutMillis))
        try {
            match (result) {
                case Result.Err(error) => minimalRuntimeFailure(error, thread: thread, run: run.value, call: call.callId)
                case Result.Ok(ToolInvocationResult.Denied(denial)) =>
                    minimalRuntimeFailure(denial.reason, thread: thread, run: run.value, call: call.callId)
                case Result.Ok(ToolInvocationResult.NeedsApproval(approval)) => MinimalRuntimeReply(2, objectValue([
                    ValueField("ok", boolValue(false)), ValueField("code", textValue("minimal.approval_required")),
                    ValueField("message", textValue("operation requires explicit approval through an interactive frontend")),
                    ValueField("thread_id", textValue(thread)), ValueField("run_id", textValue(run.value)),
                    ValueField("call_id", textValue(call.callId)), ValueField("operation_id", textValue(approval.operationId.value)),
                    ValueField("preview", approval.preview)]), runId: run.value)
                case Result.Ok(ToolInvocationResult.Completed(value)) => MinimalRuntimeReply(if (value.isError) { 2 } else { 0 }, objectValue([
                    ValueField("ok", boolValue(!value.isError)), ValueField("thread_id", textValue(thread)),
                    ValueField("run_id", textValue(run.value)), ValueField("call_id", textValue(value.callId)),
                    ValueField("receipt_id", textValue(value.receiptId)), ValueField("is_error", boolValue(value.isError)),
                    ValueField("output", value.output)]), runId: run.value)
            }
        } finally { releaseToolInvocationPayload(result) }
    }

    func infer(thread: String, namespace: String, contribution: String,
        model!: String = "", prompt!: String = ""): MinimalRuntimeReply {
        match (acquireThread(thread)) { case Result.Err(error) => return minimalRuntimeFailure(error, thread: thread); case Result.Ok(_) => () }
        match (host.modelProviderDeclaration(namespace, host.instanceGeneration(namespace), contribution)) {
            case Result.Err(error) => return minimalRuntimeFailure(error, thread: thread)
            case Result.Ok(_) => ()
        }
        if (model.trimAscii() == "" || prompt.trimAscii() == "") {
            return minimalRuntimeFailure(AgentError(AgentErrorKind.InvalidInput, "minimal.model_input_required",
                "installed ModelProvider inference requires an explicit mapped model and prompt"), thread: thread) }
        let loaded = match (loadHostModelConfiguration(settingsRoot, model)) {
            case Result.Err(error) => return minimalRuntimeFailure(error, thread: thread); case Result.Ok(value) => value }
        if (loaded.namespace != namespace || httpIntentText(loaded.mapping(), "contribution") != contribution) {
            return minimalRuntimeFailure(AgentError(AgentErrorKind.Configuration, "minimal.model_mapping_mismatch",
                "model mapping must select the requested actual installed contribution"), thread: thread) }
        let capabilities = loaded.policy.capabilities
        let policy = ModelExecutionCapabilitiesSnapshot(model, capabilities.thinking, capabilities.maxOutputTokens,
            endpointMaxOutputTokens: loaded.policy.endpointMaxOutput, configurationDigest: loaded.policy.configurationDigest)
        let run = ids.nextRunId()
        let request = AgentRunRequest(run, SessionId(thread), model, prompt,
            thinking: ThinkingLevel.Off, userRequestedThinking: Some(ThinkingLevel.Off),
            thinkingSource: ThinkingPreferenceSource.ExplicitUser, modelCapabilitiesSnapshot: Some(policy),
            capabilities: options.capabilities, approvalModeOverride: Some(options.approvalMode), autoRetry: false,
            parallelToolCalls: capabilities.parallelToolCalling, contextWindow: capabilities.contextWindowTokens,
            toolContext: minimalToolContext(workspaceRoot), budget: ResourceBudget(
                maxInputTokens: capabilities.contextWindowTokens, maxOutputTokens: capabilities.maxOutputTokens,
                maxModelRequests: 2, maxTurns: 2, maxDrainModelRequests: 1, maxDrainTurns: 1,
                maxToolCalls: options.maxToolCalls, maxConcurrentTools: 1,
                maxWallMillis: options.timeoutMillis, maxIdleMillis: options.timeoutMillis,
                deadlineMillis: agentUtcMillis() + options.timeoutMillis))
        activeRun = Some(run)
        let result = core.start(request)
        // The canonical Core owns ModelDecision/Attempt creation and terminal
        // settlement. This CLI only describes its real durable outcome.
        let reply = match (result) {
            case Result.Err(error) => minimalRuntimeFailure(error, thread: thread, run: run.value)
            case Result.Ok(AgentRunOutcome.AwaitingApproval(_, approval)) => MinimalRuntimeReply(2, objectValue([
                ValueField("ok", boolValue(false)), ValueField("code", textValue("minimal.approval_required")),
                ValueField("message", textValue("operation requires explicit approval through an interactive frontend")),
                ValueField("thread_id", textValue(thread)), ValueField("run_id", textValue(run.value)),
                ValueField("operation_id", textValue(approval.operationId.value))]), runId: run.value)
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                if (snapshot.status != RunState.Completed) {
                    minimalRuntimeFailure(match (snapshot.error) {
                        case Some(error) => error
                        case None => AgentError(AgentErrorKind.RecoveryRequired, "minimal.model_run_incomplete",
                            "canonical model Run has not completed") }, thread: thread, run: run.value)
                } else { MinimalRuntimeReply(0, objectValue([
                    ValueField("ok", boolValue(true)), ValueField("thread_id", textValue(thread)),
                    ValueField("run_id", textValue(snapshot.runId.value)), ValueField("summary", textValue(snapshot.summary)),
                    ValueField("model_requests", integerValue(snapshot.modelRequests)),
                    ValueField("input_tokens", integerValue(snapshot.inputTokens)),
                    ValueField("output_tokens", integerValue(snapshot.outputTokens))]), runId: snapshot.runId.value) }
        }
        activeRun = None
        reply
    }

    // The target context below is descriptive host scope, as in the original
    // Product frontend. Only manager.startProtocol/startHttpProtocol creates
    // the actual maintenance Run, HostServiceOrigin and admitted startup.
    private func startService(thread: String, namespace: String, serviceId: String,
        route: String, decision: ApprovalDecision): MinimalRuntimeReply {
        match (frontendLifetime.token.check()) {
            case Result.Err(error) => return minimalRuntimeFailure(error, thread: thread); case Result.Ok(_) => () }
        match (acquireThread(thread)) {
            case Result.Err(error) => return minimalRuntimeFailure(error, thread: thread); case Result.Ok(_) => () }
        let record = match (registry.get(namespace)) {
            case Some(value) => value
            case None => return minimalRuntimeFailure(AgentError(AgentErrorKind.Configuration, "plugin.not_found",
                "plugin is not installed"), thread: thread)
        }
        try { return startOwnedService86(record, thread, serviceId, route, decision) }
        finally { record.close() }
    }

    // The owned borrow is confined to this complete service-start frame.
    // Host configuration overloads prepay any legacy callback aliases in the
    // same bank before copying; returning here retires only this caller loan.
    private func startOwnedService86(record: ProductPluginRecord, thread: String, serviceId: String,
        route: String, decision: ApprovalDecision): MinimalRuntimeReply {
        if (!record.enabled || record.descriptor.entryKind != PluginEntryKind.NativeExecutable) {
            return minimalRuntimeFailure(AgentError(AgentErrorKind.Configuration, "plugin.service_unavailable",
                "an enabled native service plugin is required"), thread: thread) }
        // Transport is selected by the exact installed operator configuration.
        // Requested package capabilities alone never select a launch backend.
        let httpConfiguration: ?HostPluginHttpConfiguration = match (loadHostPluginHttpConfiguration(settingsRoot,
            record.descriptor)) {
            case Result.Ok(value) => Some(value)
            case Result.Err(error) => if (error.code == "plugin.http_configuration_missing") { None }
                else { return minimalRuntimeFailure(error, thread: thread) }
        }
        if (httpConfiguration.isSome()) {
            let transport = httpConfiguration.getOrThrow().configuration.field("transport")
            if (transport.isNone() || transport.getOrThrow().unifiedKind != ValueKind.Text || transport.getOrThrow().text != "http") {
                return minimalRuntimeFailure(AgentError(AgentErrorKind.Configuration, "plugin.service_transport_unsupported",
                    "HTTP service configuration must explicitly select transport http"), thread: thread) }
            if (!record.descriptor.hasCapability("network.http")) {
                return minimalRuntimeFailure(AgentError(AgentErrorKind.PermissionDenied, "plugin.service_unavailable",
                    "HTTP service requires its declared network.http capability"), thread: thread) }
        }
        let channelConfiguration: ?HostPluginLifecycleConfiguration = if (httpConfiguration.isNone()) {
            let selected = match (hostLoadPluginLifecycleConfiguration(settingsRoot, record.descriptor)) {
                case Result.Err(error) => return minimalRuntimeFailure(error, thread: thread)
                case Result.Ok(value) => value
            }
            let transport = selected.configuration.field("transport")
            if (transport.isSome() && (transport.getOrThrow().unifiedKind != ValueKind.Text || transport.getOrThrow().text != "stdio")) {
                return minimalRuntimeFailure(AgentError(AgentErrorKind.Configuration, "plugin.service_transport_unsupported",
                    "channel service configuration supports transport stdio only"), thread: thread) }
            if (!record.descriptor.hasCapability("process.channel")) {
                return minimalRuntimeFailure(AgentError(AgentErrorKind.PermissionDenied, "plugin.service_unavailable",
                    "stdio service requires its declared process.channel capability"), thread: thread) }
            Some(selected)
        } else { None }
        let manager = lifecycle.getOrThrow()
        let budget = maintenanceBudget()
        let context = ToolInvocationContext(RunId("service-scope-" + ids.nextInvocationId()), SessionId(thread),
            options.capabilities, epoch: 1, cancellation: frontendLifetime.token,
            toolContext: minimalToolContext(workspaceRoot), budget: budget)
        let maintenance = ThreadId(ids.nextSessionId().value)
        let generation = host.instanceGeneration(record.descriptor)
        let started = if (httpConfiguration.isSome()) {
            manager.startHttpProtocol(gateway, context, maintenance, httpConfiguration.getOrThrow(),
                serviceId, route, generation, decision, budget: budget)
        } else {
            manager.startProtocol(gateway, context, maintenance, channelConfiguration.getOrThrow(),
                serviceId, route, generation, decision, budget: budget)
        }
        let result: Result<ToolInvocationResult> = match (started) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => Result.Ok(value.outcome)
        }
        try { minimalServiceInvocationReply(result, thread) }
        finally { releaseToolInvocationPayload(result) }
    }

    private func maintenanceBudget(): ExecutionBudget {
        ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1,
            deadlineMillis: frontendLifetime.token.deadlineMillis)
    }

    private func refreshService(thread: String, namespace: String, serviceId: String,
        decision: ApprovalDecision): MinimalRuntimeReply {
        let budget = maintenanceBudget()
        let context = ToolInvocationContext(RunId("service-refresh-scope-" + ids.nextInvocationId()),
            SessionId(thread), options.capabilities, epoch: 1, cancellation: frontendLifetime.token,
            toolContext: minimalToolContext(workspaceRoot), budget: budget)
        let result = lifecycle.getOrThrow().refresh(gateway, context, namespace, serviceId, decision, budget)
        try { minimalServiceInvocationReply(result, thread) }
        finally { releaseToolInvocationPayload(result) }
    }

    private func stopService(thread: String, namespace: String, serviceId: String): MinimalRuntimeReply {
        let manager = lifecycle.getOrThrow()
        let deadline = MonoTime.now() + Duration.second * 2
        var result = manager.stop(ThreadId(thread), namespace, serviceId)
        while (result.isError() && result.error().getOrThrow().code == "plugin.lifecycle_manager_cleanup_pending" && MonoTime.now() < deadline) {
            sleep(Duration.millisecond * 25)
            result = manager.stop(ThreadId(thread), namespace, serviceId)
        }
        match (result) {
            case Result.Err(error) => minimalRuntimeFailure(error, thread: thread)
            case Result.Ok(_) => MinimalRuntimeReply(0, objectValue([ValueField("ok", boolValue(true)),
                ValueField("statuses", listValue(manager.statuses()))]))
        }
    }

    func serviceCommand(thread: String, namespace: String, serviceId: String, route: String,
        decision: ApprovalDecision, actions: Array<AgentValue>): MinimalRuntimeReply {
        let startup = startService(thread, namespace, serviceId, route, decision)
        if (startup.exitCode != 0) { return startup }
        let replies = ArrayList<AgentValue>(); replies.add(parseUnifiedJson(startup.json))
        var failed = false
        // Every bounded action was validated before construction or I/O. These
        // are operator frontend requests; tools still enter the same Direct
        // gateway, while refresh goes through the retained maintenance owner.
        for (action in actions) {
            let reply = match (minimalServiceText(action, "action")) {
                case "tools" => listTools(minimalServiceText(action, "thread"))
                case "invoke" => invoke(minimalServiceText(action, "thread"),
                    minimalServiceText(action, "tool"), action.field("arguments").getOrThrow())
                case "refresh" => refreshService(thread, namespace, serviceId,
                    minimalServiceDecision(minimalServiceText(action, "decision")))
                case "stop" => stopService(thread, namespace, serviceId)
                case _ => MinimalRuntimeReply(0, objectValue([ValueField("ok", boolValue(true)),
                    ValueField("statuses", listValue(lifecycle.getOrThrow().statuses()))]))
            }
            if (reply.exitCode != 0) { failed = true }
            replies.add(parseUnifiedJson(reply.json))
        }
        MinimalRuntimeReply(if (failed) { 2 } else { 0 }, objectValue([ValueField("ok", boolValue(!failed)),
            ValueField("thread_id", textValue(thread)), ValueField("results", listValue(replies.toArray()))]))
    }

    func serve(grant: String, starts: Array<AgentValue>): Result<Unit> {
        // Optional client starts are explicitly supplied by the operator before
        // fd0/fd1 belongs to ingress. No startup/status JSON is written to the
        // successful wire stream and no peer can select these grants.
        for (start in starts) {
            let result = startService(minimalServiceText(start, "thread"), minimalServiceText(start, "namespace"),
                minimalServiceText(start, "service"), minimalServiceText(start, "route"),
                minimalServiceDecision(minimalServiceText(start, "decision")))
            if (result.exitCode != 0) {
                let value = parseUnifiedJson(result.json)
                return Result.Err(AgentError(AgentErrorKind.PermissionDenied, minimalServiceText(value, "code"),
                    minimalServiceText(value, "message"))) }
        }
        // The internal grant loader pins real operator ingress.json bytes,
        // powerless decoder package/instance, export publication and Thread.
        ingress.servePluginStdio(grant)
    }

    func close(): Result<Unit> {
        try {
        if (closed) { return match (closeFailure) { case Some(error) => Result.Err(error); case None => Result.Ok(()) } }
        closed = true
        var failure: ?AgentError = None
        // Keep every actual owner close attempt even if an earlier ACK fails.
        match (activeRun) { case Some(run) => match (core.cancel(run)) {
            case Result.Err(error) => failure = Some(error); case Result.Ok(_) => () }; case None => () }
        match (ingress.close()) { case Result.Err(error) => if (failure.isNone()) { failure = Some(error) }; case Result.Ok(_) => () }
        match (lifecycle) { case Some(owner) =>
            let deadline = MonoTime.now() + Duration.second * 2
            var result = owner.close()
            while (result.isError() && result.error().getOrThrow().code == "plugin.lifecycle_manager_cleanup_pending" && MonoTime.now() < deadline) {
                sleep(Duration.millisecond * 25); result = owner.close()
            }
            match (result) { case Result.Err(error) => if (failure.isNone()) { failure = Some(error) }; case Result.Ok(_) => () }
            case None => () }
        frontendLifetime.close()
        try { match (host.close()) { case Result.Err(error) => if (failure.isNone()) { failure = Some(error) }; case Result.Ok(_) => () } }
        catch (error: Exception) { if (failure.isNone()) { failure = Some(AgentError(AgentErrorKind.RecoveryRequired, "minimal.plugin_close_failed", error.message)) } }
        try { match (processes.close()) { case Result.Err(error) => if (failure.isNone()) { failure = Some(error) }; case Result.Ok(_) => () } }
        catch (error: Exception) { if (failure.isNone()) { failure = Some(AgentError(AgentErrorKind.RecoveryRequired, "minimal.process_close_failed", error.message)) } }
        try { database.close() }
        catch (error: Exception) { if (failure.isNone()) { failure = Some(AgentError(AgentErrorKind.RecoveryRequired, "minimal.database_close_failed", error.message)) } }
        closeFailure = failure
        match (failure) { case Some(error) => Result.Err(error); case None => Result.Ok(()) }
        } finally { registry.close() }
    }
}

func createMinimalHostRuntime(settings: String, workspace: String, options: MinimalRuntimeOptions): MinimalHostRuntime {
    let inspector = HostLocalReadTargetInspector(workspace)
    let root = inspector.rootPath()
    let database = SqliteDatabase(Path(options.stateRoot).normalize().toString() + "/state.db")
    var registryOwner: ?PluginRegistry = None
    var registryTransferred = false
    try {
        let registry = PluginRegistry(settings, root); registryOwner = Some(registry)
        let ids = MinimalRuntimeIds()
        let operations = hostOperationStore(database)
        let threadRuntimes = SqliteThreadRuntimeRegistry(database,
            ContextProjector("agent-minimal-v1", ConservativeThreadTokenEstimator()), { => agentUtcMillis() },
            continuationVerifier: Some(SqliteContinuationRunVerifier(ContinuationAllowanceRepository(SqliteRunRepository(database)),
                requireDocumentPin: true, documentAllocation: Some({ bytes => reserveNativeDocumentPayload(bytes) }))))
        let catalog = ToolCatalog()
        let pipeline = ToolPipeline(catalog, operations, SqliteAuditRepository(database), ids,
            policy: DefaultCapabilityPolicy(mode: options.approvalMode), permissions: SqlitePermissionRepository(database))
        let network: NetworkGatewayPort = HostLocalNetworkGatewayPort()
        let processes = hostCreatePluginRuntimeProcessPort(inspector, sandboxEnabled: true,
            sandboxCaBundle: options.caBundle, networkGateway: Some(network))
        let artifacts = HostArtifactStore(options.stateRoot, database: Some(database))
        let host = HostJavaScriptPluginHost({ path => HostLocalReadTargetInspector(path) },
            settingsRoot: settings, readViewStateRoot: options.stateRoot)
        match (host.ownRegistry(registry)) { case Result.Err(error) => throw IllegalStateException(error.describe()); case Result.Ok(_) => () }
        let services = HostJavaScriptPluginServiceRuntime(catalog, pipeline, operations, HostAskRuntime())
        let gateway = HostCanonicalToolGateway(database, catalog, pipeline, ids, threadRuntimes, operations,
            root, { path => minimalToolContext(path) }, { name => host.readonlyDelegationTool(name) }, { _ => Result<Unit>.Ok(()) })
        let runs: RunRepository = SqliteRunRepository(database)
        let model = ControlledModelPort(HostInstalledModelPort(host, settings, database, threadRuntimes, processes, artifacts),
            runs: Some(runs))
        let runtimePort: ThreadRuntimeRegistry = threadRuntimes
        let operationPort: OperationRuntimePort = operations
        let decisionPort: ModelDecisionRuntimePort = SqliteModelDecisionStore(database)
        let contextPort: ModelContextManifestRuntimePort = HostContextManifestRuntime(database)
        let core = AgentCore(model, runs, pipeline, catalog, threadRuntimes: Some(runtimePort),
            operationRuntime: Some(operationPort), modelDecisionRuntime: Some(decisionPort), contextManifestRuntime: Some(contextPort))
        let ingress = HostStdioIngressRuntime(gateway, runtimePort, ids, catalog, host,
            settings, root, { path => minimalToolContext(path) })
        let result = MinimalHostRuntime(database, registry, threadRuntimes, ids, operations, catalog, processes, artifacts,
            host, services, gateway, core, ingress, root, settings, options)
        registryTransferred = true
        result
    } catch (error: Exception) { database.close(); throw error }
    finally { if (!registryTransferred) { match (registryOwner) { case Some(value) => value.close(); case None => () } } }
}

func validateMinimalRuntimeCommandArguments(command: String, args: Array<String>): Result<Unit> {
    if (!((command == "tools" && args.size == 1) || (command == "invoke" && args.size == 3) ||
        (command == "infer" && (args.size == 3 || args.size == 5)) ||
        (command == "service" && args.size == 6) || (command == "serve" && (args.size == 1 || args.size == 2)))) {
        return Result.Err(AgentError(AgentErrorKind.InvalidInput, "minimal.command_invalid",
            "tools <thread>; invoke <thread> <tool> <arguments-json>; infer <thread> <namespace> <contribution>")) }
    Result.Ok(())
}

func minimalRuntimeCommand(settings: String, workspace: String, options: MinimalRuntimeOptions,
    command: String, args: Array<String>): Int64 {
    match (validateMinimalRuntimeCommandArguments(command, args)) {
        case Result.Err(error) => return minimalError(error.code, error.message)
        case Result.Ok(_) => () }
    if (settings.trimAscii() == "" || workspace.trimAscii() == "") {
        return minimalError("minimal.paths_required", "runtime requires explicit --settings-root, --workspace-root and --state-root") }
    let arguments = if (command == "invoke") { match (decodeAgentValue(args[2], maxBytes: 1048576)) {
        case Result.Err(error) => return minimalError(error.code, error.message); case Result.Ok(value) => value }
    } else { objectValue([]) }
    let actions: Array<AgentValue> = if (command == "service") { minimalServiceActions(args[5]) } else { [] }
    let starts: Array<AgentValue> = if (command == "serve" && args.size == 2) { minimalServiceStarts(args[1]) } else { [] }
    let decision = if (command == "service") { minimalServiceDecision(args[4]) } else { ApprovalDecision.Reject }
    // Retain the actual owners before package initialization can launch workers.
    let runtime = createMinimalHostRuntime(settings, workspace, options)
    var reply = minimalRuntimeFailure(AgentError(AgentErrorKind.RecoveryRequired, "minimal.runtime_unavailable", "runtime did not complete initialization"))
    try {
        match (runtime.initialize()) {
            case Result.Err(error) => reply = minimalRuntimeFailure(error, thread: args[0])
            case Result.Ok(_) => reply = match (command) {
                case "tools" => runtime.listTools(args[0])
                case "invoke" => runtime.invoke(args[0], args[1], arguments)
                case "service" => runtime.serviceCommand(args[0], args[1], args[2], args[3], decision, actions)
                case "serve" => match (runtime.serve(args[0], starts)) {
                    case Result.Err(error) => minimalRuntimeFailure(error)
                    case Result.Ok(_) => MinimalRuntimeReply(0, objectValue([ValueField("ok", boolValue(true))])) }
                case _ => runtime.infer(args[0], args[1], args[2],
                    model: if (args.size == 5) { args[3] } else { "" }, prompt: if (args.size == 5) { args[4] } else { "" })
            }
        }
    } catch (error: Exception) { reply = minimalRuntimeFailure(AgentError(AgentErrorKind.RecoveryRequired,
        "minimal.runtime_failed", error.message), thread: args[0], run: reply.runId) }
    finally { match (runtime.close()) {
        case Result.Err(error) => reply = minimalRuntimeFailure(error, thread: args[0], run: reply.runId)
        case Result.Ok(_) => () } }
    if (command != "serve" || reply.exitCode != 0) { println(reply.json) }; reply.exitCode
}
