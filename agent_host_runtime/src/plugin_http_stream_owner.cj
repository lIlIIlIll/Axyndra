package agent_host_runtime

import agent_domain.*
import agent_plugin_registry.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

// One actual request. The owning invocation retains this object BEFORE any
// worker/credential resolution/launch, including failed-open cleanup debt.
class HostManagedHttpExchange {
    let id: String
    let intentId: String
    let request: AgentValue
    let network: NetworkPolicy
    let port: HostLocalProcessPort
    let source: CancellationSource
    let maxBodyBytes: Int64
    let maxIngressBytes: Int64
    let lock = Mutex()
    let closeRequested = AtomicBool(false)
    let workerSettled = AtomicBool(false)
    let workerSpawned = AtomicBool(false)
    let workerReleased = AtomicBool(false)
    let workerAdmitted = AtomicBool(false)
    let executionStarted = AtomicBool(false)
    let openingFinished = AtomicBool(false)
    let cleanupAcknowledged = AtomicBool(false)
    var reader: ?HostHttpExchangeReader = None
    var head: ?HostHttpExchangeHead = None
    var failure: ?AgentError = None
    var receipt = ""
    var consumed: Int64 = 0
    var bodyEof = false
    var closeDelivered = false
    var registration: ?CancellationRegistration = None

    init(id: String, intentId: String, request: AgentValue, network: NetworkPolicy,
        packageRoot: String, caBundle: String, context: ToolInvocationContext, until: Int64, maxBodyBytes: Int64, maxIngressBytes: Int64,
        registryAdmission: () -> Result<PluginRegistryExecutionFence>) {
        this.id = id; this.intentId = intentId; this.request = request; this.network = network
        port = HostLocalProcessPort(HostLocalReadTargetInspector(packageRoot), sandboxEnabled: true,
            sandboxCaBundle: caBundle, networkGateway: Some(HostLocalNetworkGatewayPort()), registryAdmission: Some(registryAdmission))
        source = CancellationSource(parent: Some(context.cancellation), deadlineMillis: until)
        this.maxBodyBytes = maxBodyBytes
        this.maxIngressBytes = maxIngressBytes
    }
    func observe(resource: CancellationToken): Unit {
        let localSource = source
        let value = resource.onCancel({ _ => let _ = localSource.cancel() })
        lock.lock(); try { registration = Some(value) } finally { lock.unlock() }
    }
    func fail(error: AgentError): Unit {
        lock.lock(); try { if (failure.isNone()) { failure = Some(error) } } finally { lock.unlock() }
        closeRequested.store(true)
    }
    func error(): ?AgentError { lock.lock(); try { failure } finally { lock.unlock() } }
    func selectedReader(): ?HostHttpExchangeReader { lock.lock(); try { reader } finally { lock.unlock() } }
    func selectedHead(): ?HostHttpExchangeHead { lock.lock(); try { head } finally { lock.unlock() } }
    func closeResources(): Result<Unit> {
        closeRequested.store(true)
        if (cleanupAcknowledged.load()) { return Result.Ok(()) }
        // No read lock and no invocation/service lock. Closing a pending read
        // must remain possible. A later opener sees closeRequested and closes.
        let selected = selectedReader()
        match (selected) { case Some(value) => let _ = value.close(); case None => () }
        let closed = port.close()
        if (!openingFinished.load() || closed.isError() ||
            (selected.isSome() && !selected.getOrThrow().closeAcknowledged())) {
            return hostLifecycleLeaseError("http.stream_cleanup_pending")
        }
        lock.lock()
        let observer = try {
            if (cleanupAcknowledged.load()) { return Result.Ok(()) }
            cleanupAcknowledged.store(true)
            let value = registration; registration = None; value
        } finally { lock.unlock() }
        match (observer) { case Some(value) => value.dispose(); case None => () }
        source.close()
        Result.Ok(())
    }
    func output(): AgentValue {
        lock.lock()
        try { objectValue([ValueField("closed", boolValue(cleanupAcknowledged.load())),
            ValueField("body_eof", boolValue(bodyEof)), ValueField("consumed_bytes", integerValue(consumed))]) }
        finally { lock.unlock() }
    }
}

// A worker runs the EXISTING canonical broker while the observer exposes only
// its bounded response stream. The broker lends the parent's slot, keeps the
// derived Operation executing until actual close ACK, and commits its Receipt.
class HostManagedHttpInvocation <: HostManagedServiceInvocation {
    private let service: HostPluginManagedService
    private let endpoint: HostPinnedNativeServiceEndpoint
    private let context: ToolInvocationContext
    private let prepared: PreparedToolInvocation
    private let configuration: HostPluginHttpConfiguration
    private let store: DurableOperationStore
    private let caBundle: String
    private let broker: ?HostJavaScriptPluginServiceBroker
    private let bindingText: ?String
    private let action: ?HostServiceAction
    private let maintenanceText: ?String
    private let until: Int64
    private let artifacts: ?HostArtifactStore
    private let gate = HostManagedChannelGate()
    private let lock = Mutex()
    private let exchanges = ArrayList<HostManagedHttpExchange>()
    private let intents = HashSet<String>()
    private var active: ?HostManagedHttpExchange = None
    private var inputReserved: Int64 = 0
    private var outputReserved: Int64 = 0
    private var failed = false

    init(service: HostPluginManagedService, endpoint: HostPinnedNativeServiceEndpoint,
        context: ToolInvocationContext, prepared: PreparedToolInvocation,
        configuration: HostPluginHttpConfiguration, store: DurableOperationStore, caBundle: String,
        broker!: ?HostJavaScriptPluginServiceBroker = None, binding!: ?AgentValue = None,
        action!: ?HostServiceAction = None, artifacts!: ?HostArtifactStore = None) {
        this.service = service; this.endpoint = endpoint; this.context = context; this.prepared = prepared
        this.configuration = configuration; this.store = store; this.caBundle = caBundle; this.broker = broker
        this.bindingText = binding.map({ value => stringifyUnifiedJson(value) }); this.action = action; this.artifacts = artifacts
        hostLifecycleRequire((broker.isSome() && binding.isSome() && action.isNone()) ||
            (broker.isNone() && binding.isNone() && action.isSome()), "http.stream_scope_invalid")
        let maintenance: ?AgentValue = match (action) {
            case Some(value) => Some(service.maintenancePlan(context, prepared, value).value().getOrThrow())
            case None => None
        }
        maintenanceText = maintenance.map({ value => stringifyUnifiedJson(value) })
        var deadline = if (maintenance.isSome()) {
            let plan = maintenance.getOrThrow()
            let window = if (action.getOrThrow() == HostServiceAction.Start) {
                plan.field("grant").getOrThrow().field("startup").getOrThrow()
            } else { plan.field("window").getOrThrow() }
            agentUtcMillis() + hostLifecycleInt(window, "timeout_ms", 60000)
        } else { agentUtcMillis() + 120000 }
        for (value in [context.cancellation.deadlineMillis, context.budget.deadlineMillis] where value > 0) { deadline = min(deadline, value) }
        until = deadline
    }
    private func binding(): AgentValue { parseUnifiedJson(bindingText.getOrThrow(), maxBytes: 196608) }
    private func window(): AgentValue {
        let plan = parseUnifiedJson(maintenanceText.getOrThrow(), maxBytes: 196608)
        if (action.getOrThrow() == HostServiceAction.Start) { plan.field("grant").getOrThrow().field("startup").getOrThrow() }
        else { plan.field("window").getOrThrow() }
    }
    private func validateLifetime(): Result<Unit> {
        if (!gate.isOpen() || agentUtcMillis() >= until || service.resourceCancellation().isCancelled()) {
            return hostLifecycleLeaseError("http.stream_scope_closed")
        }
        context.cancellation.check()
    }
    // Already admitted pumps own their frozen request and channel. Waiting or
    // dequeuing cannot authorize another effect; keep cancellation, the exact
    // exchange owner and its original finite window live without rehashing the
    // package/configuration on each poll. Publication still uses validate().
    private func validateExchangeOwner(exchange: HostManagedHttpExchange): Result<Unit> {
        match (validateLifetime()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        let retained = try { active.isSome() && refEq(active.getOrThrow(), exchange) } finally { lock.unlock() }
        if (!retained) { return hostLifecycleLeaseError("http.stream_exchange_changed") }
        Result.Ok(())
    }
    private func validateExchangeLifetime(exchange: HostManagedHttpExchange): Result<Unit> {
        match (validateExchangeOwner(exchange)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        exchange.source.token.check()
    }
    private func validate(): Result<Unit> {
        match (validateLifetime()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (action.isSome()) {
            let current = match (service.maintenancePlan(context, prepared, action.getOrThrow())) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
            }
            if (canonicalAgentValue(current) != canonicalAgentValue(parseUnifiedJson(maintenanceText.getOrThrow(), maxBytes: 196608))) {
                return hostLifecycleLeaseError("http.stream_maintenance_changed")
            }
            Result.Ok(())
        } else {
            match (service.validateInvocation(context, prepared, binding())) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            store.verifyHttpStreamInvocationRoot(prepared.operationId, context.runId, ThreadId(context.sessionId.value),
                context.epoch, prepared.source.operationRoot.getOrThrow(), prepared.operationPlan, binding())
        }
    }
    public func owns(child: PreparedToolInvocation): Bool {
        broker.isSome() && child.source.parentOperationId.isSome() && child.source.kind == PreparedInvocationSourceKind.Derived &&
            child.source.parentOperationId.getOrThrow().value == prepared.operationId.value &&
            child.source.runId.value == context.runId.value && child.source.sessionId.value == context.sessionId.value && child.source.epoch == context.epoch
    }
    private func verifyChild(childContext: ToolInvocationContext, child: PreparedToolInvocation): Result<Unit> {
        if (!owns(child) || childContext.trustedControl || child.authorization != PreparedAuthorization.ParentIntent ||
            child.source.operationRoot.isNone() || !httpStreamServiceChildAllowed(prepared.operationPlan, child.operationPlan) ||
            childContext.runId.value != context.runId.value || childContext.sessionId.value != context.sessionId.value ||
            childContext.epoch != context.epoch || !refEq(childContext.cancellation, context.cancellation) ||
            !refEq(childContext.budget, context.budget) || childContext.workspaceRoot != context.workspaceRoot || childContext.cwd != context.cwd) {
            return hostLifecycleLeaseError("http.stream_child_context_invalid")
        }
        for (capability in childContext.capabilities.values where !context.capabilities.allows(capability.kind, resource: capability.resource)) {
            return hostLifecycleLeaseError("http.stream_child_capability_widened")
        }
        let left = context.environment.entries(); let right = childContext.environment.entries()
        if (left.size != right.size) { return hostLifecycleLeaseError("http.stream_child_context_invalid") }
        for (index in 0..left.size where left[index].name != right[index].name || left[index].value != right[index].value) {
            return hostLifecycleLeaseError("http.stream_child_context_invalid")
        }
        for (capability in child.operationPlan.requiredCapabilities where !childContext.capabilities.allows(capability.kind, resource: capability.resource)) {
            return hostLifecycleLeaseError("http.stream_child_capability_denied")
        }
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        store.verifyHttpStreamExecution(child.operationId, prepared.operationId, context.runId, ThreadId(context.sessionId.value),
            context.epoch, child.source.operationRoot.getOrThrow(), child.source.requestKey, child.operationPlan, binding())
    }
    public func executeChild(childContext: ToolInvocationContext, child: PreparedToolInvocation): Result<ToolResult> {
        match (verifyChild(childContext, child)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock(); let selected = try { active } finally { lock.unlock() }
        if (selected.isNone()) { return hostLifecycleLeaseError("http.stream_exchange_missing") }
        let exchange = selected.getOrThrow()
        let intent = child.operationPlan.canonicalArguments.field("intent").getOrThrow()
        exchange.lock.lock()
        let alreadyStarted = try { let value = exchange.executionStarted.load(); exchange.executionStarted.store(true); value }
            finally { exchange.lock.unlock() }
        if (exchange.intentId != httpIntentText(intent, "id") || alreadyStarted ||
            canonicalAgentValue(exchange.request) != canonicalAgentValue(intent.field("request").getOrThrow())) {
            return hostLifecycleLeaseError("http.stream_exchange_changed")
        }
        runExchange(exchange, child.operationId, child.call.callId)
    }
    private func runExchange(exchange: HostManagedHttpExchange, operationId: OperationId, callId: String): Result<ToolResult> {
        let result = try { performExchange(exchange, operationId, callId) }
            catch (_: Exception) { hostManagedChannelUnknown<ToolResult>() }
        exchange.openingFinished.store(true)
        // Cleanup is an existing obligation, allowed a finite settlement grace
        // even after the request deadline. It grants no further request I/O.
        let cleanupUntil = agentUtcMillis() + 5000
        var closed = exchange.closeResources()
        while (closed.isError() && agentUtcMillis() < cleanupUntil) {
            sleep(Duration.millisecond * 2); closed = exchange.closeResources()
        }
        if (closed.isError()) { let error = hostManagedChannelUnknown<ToolResult>().error().getOrThrow(); exchange.fail(error); return Result.Err(error) }
        match (exchange.selectedReader()) {
            case Some(reader) => match (reader.receivedOutputBytes()) {
                case Result.Err(error) => exchange.fail(error); return hostManagedChannelUnknown()
                case Result.Ok(count) => if (count < 0 || count > exchange.maxIngressBytes) {
                    let error = hostManagedChannelUnknown<ToolResult>().error().getOrThrow(); exchange.fail(error); return Result.Err(error)
                }
            }
            case None => ()
        }
        match (result) {
            case Result.Ok(_) =>
                // Cleanup ACK and ingress accounting discharge obligations, not
                // authority. Revalidate immediately before the canonical child
                // can publish its successful terminal Receipt.
                match (validate()) {
                    case Result.Err(error) => exchange.fail(error); return Result.Err(error)
                    case Result.Ok(_) => ()
                }
                // The request clock governed completed I/O, not its separate
                // cleanup grace. Current authority and the actual owner remain live.
                match (validateExchangeOwner(exchange)) {
                    case Result.Err(error) => exchange.fail(error); return Result.Err(error)
                    case Result.Ok(_) => ()
                }
                if (!exchange.closeRequested.load() || !exchange.cleanupAcknowledged.load()) {
                    return hostManagedChannelUnknown()
                }
                match (exchange.source.token.reason()) {
                    case Some(reason) =>
                        let requestDeadline = exchange.source.token.deadlineMillis
                        if (reason.kind != CancellationReasonKind.Deadline || requestDeadline <= 0 || requestDeadline >= until ||
                            reason.cancelledAtMillis < requestDeadline) {
                            let error = exchange.source.token.check().error().getOrThrow()
                            exchange.fail(error); return Result.Err(error)
                        }
                    case None => ()
                }
                Result.Ok(ToolResult(callId, exchange.output()))
            case Result.Err(error) => exchange.fail(error); Result.Err(error)
        }
    }
    private func performExchange(exchange: HostManagedHttpExchange, operationId: OperationId, callId: String): Result<ToolResult> {
        var result: Result<ToolResult> = hostLifecycleLeaseError("http.stream_not_opened")
        try {
            match (validate()) { case Result.Err(error) => exchange.fail(error); return Result.Err(error); case Result.Ok(_) => () }
            if (exchange.closeRequested.load()) { return hostLifecycleLeaseError("http.stream_exchange_closed") }
            let credentials = match (configuration.resolveStreamCredentials(exchange.request)) {
                case Result.Err(error) => exchange.fail(error); return Result.Err(error); case Result.Ok(value) => value
            }
            // Only tighten a host response ceiling. Method/URL/header/body/ref
            // bytes remain identical to the approved request and credential grant.
            let loadedBody: ?Array<Byte> = match (exchange.request.field("body_payload")) {
                case Some(reference) =>
                    if (action.isSome() || configuration.payloadLimits.isNone() || artifacts.isNone()) {
                        return hostLifecycleLeaseError("http.stream_payload_not_granted")
                    }
                    match (artifacts.getOrThrow().readServicePayload(reference, configuration.payloadLimits.getOrThrow().maxWriteBytes)) {
                        case Result.Err(error) => exchange.fail(error); return Result.Err(error)
                        case Result.Ok(bytes) => Some(bytes)
                    }
                case None => None
            }
            // The canonical request retains its content reference; loaded bytes
            // cross only the host-private factory and are checked again there.
            match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let limited = parseUnifiedJson(stringifyUnifiedJson(exchange.request), maxBytes: HOST_HTTP_STREAM_ENCODED_MAX_BYTES)
            limited.put("max_response_bytes", integerValue(exchange.maxBodyBytes))
            let original = context.budget.processLimits
            let limits = ExecutionResourceLimits(maxOutputBytes: if (original.maxOutputBytes > 0) {
                    min(original.maxOutputBytes, exchange.maxIngressBytes) } else { exchange.maxIngressBytes },
                addressSpaceBytes: original.addressSpaceBytes, fileSizeBytes: original.fileSizeBytes,
                openFiles: original.openFiles, processes: original.processes, cpuSeconds: original.cpuSeconds)
            let opened = exchange.port.openHttpExchange(operationId, limited, endpoint.generation.descriptor.root,
                exchange.network, exchange.source.token, credentials, limits, payloadBody: loadedBody, expanded: configuration.payloadLimits.isSome())
            exchange.openingFinished.store(true)
            let reader = match (opened) { case Result.Err(error) => exchange.fail(error); return Result.Err(error); case Result.Ok(value) => value }
            exchange.lock.lock(); try { exchange.reader = Some(reader) } finally { exchange.lock.unlock() }
            while (!exchange.closeRequested.load() && !exchange.source.token.isCancelled() && exchange.selectedHead().isNone()) {
                match (validateExchangeLifetime(exchange)) { case Result.Err(error) => exchange.fail(error); break; case Result.Ok(_) => () }
                match (reader.pollHead()) {
                    case Result.Err(error) => exchange.fail(error)
                    case Result.Ok(Some(head)) => exchange.lock.lock(); try { exchange.head = Some(head) } finally { exchange.lock.unlock() }
                    case Result.Ok(None) => ()
                }
            }
            while (!exchange.closeRequested.load() && !exchange.source.token.isCancelled()) {
                match (validateExchangeLifetime(exchange)) { case Result.Err(error) => exchange.fail(error); break; case Result.Ok(_) => () }
                sleep(Duration.millisecond * 2)
            }
            if (exchange.source.token.isCancelled() || agentUtcMillis() >= until) {
                result = if (hostManagedChannelCallerCancelled(context)) { hostLifecycleIoCancelled() } else { hostManagedChannelUnknown() }
            } else if (exchange.error().isSome() || exchange.selectedHead().isNone()) { result = hostManagedChannelUnknown() }
            else { result = Result.Ok(ToolResult(callId, exchange.output())) }
        } catch (_: Exception) { result = hostManagedChannelUnknown() }
        result
    }
    private func rememberFailure(): Unit { lock.lock(); try { failed = true } finally { lock.unlock() } }
    private func settled(exchange: HostManagedHttpExchange, response: JavaScriptHostResult<String>): Unit {
        try {
            match (response) {
                case JavaScriptHostResult.Err(_) => rememberFailure()
                case JavaScriptHostResult.Ok(text) =>
                    let value = parseUnifiedJson(text, maxBytes: 65536)
                    let receipt = httpIntentText(value, "receipt_id")
                    let output = value.field("output").getOrThrow()
                    if (value.field("is_error").getOrThrow().asBool() || receipt == "" ||
                        canonicalAgentValue(output) != canonicalAgentValue(exchange.output()) || !exchange.cleanupAcknowledged.load()) {
                        rememberFailure()
                    } else { exchange.lock.lock(); try { exchange.receipt = receipt } finally { exchange.lock.unlock() } }
            }
        } catch (_: Exception) { rememberFailure() }
        exchange.openingFinished.store(true)
        if (!exchange.executionStarted.load()) { let _ = exchange.closeResources() }
        exchange.workerSettled.store(true)
    }
    public func onProgress(invocationId: String, progressJson: String): JavaScriptHostResult<Unit> {
        if (!gate.progress(invocationId)) { return hostPluginServiceError("http.stream_closed", "HTTP invocation is closed") }
        match (validate()) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
        match (context.outputSink.emit(ToolOutputChunk(prepared.call.callId, ToolOutputChannel.Progress, progressJson))) {
            case Result.Err(error) => hostPluginServiceAgentError(error); case Result.Ok(_) => JavaScriptHostResult.Ok(())
        }
    }
    public func onServiceRequest(invocationId: String, requestId: String, name: String, argumentsJson: String): JavaScriptHostResult<String> {
        if (!gate.accept(invocationId, requestId)) { return hostPluginServiceError("http.stream_request_invalid", "HTTP request identity is closed or repeated") }
        // Read only dequeues an admitted pump. The complete current authority
        // check in readExchange still precedes every returned body publication.
        let current = if (name == "network.http.stream.read") { validateLifetime() } else { validate() }
        match (current) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
        let args = match (hostJavascriptPluginDecodeValue(argumentsJson, maxBytes: 196608)) {
            case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value
        }
        if (name == "network.http.stream.open") { return openExchange(invocationId, requestId, args) }
        let selected = findExchange(httpIntentText(args, "exchange_id"))
        if (selected.isNone()) { return hostPluginServiceError("http.stream_handle_invalid", "HTTP exchange is foreign, stale or closed") }
        let exchange = selected.getOrThrow()
        if (name == "network.http.stream.read") { return readExchange(exchange, args) }
        if (name == "network.http.stream.close" && httpIntentExactFields(args, ["exchange_id"])) { return closeExchange(exchange) }
        hostPluginServiceError("http.stream_service_invalid", "HTTP stream supports bounded open, read and close only")
    }
    private func findExchange(id: String): ?HostManagedHttpExchange {
        lock.lock(); try { match (active) { case Some(value) => if (value.id == id) { Some(value) } else { None }; case None => None } }
        finally { lock.unlock() }
    }
    private func openExchange(invocationId: String, requestId: String, args: AgentValue): JavaScriptHostResult<String> {
        let maintenance = action.isSome()
        if (!httpIntentExactFields(args, if (maintenance) { ["request"] } else { ["intent_id"] })) {
            return hostPluginServiceError("http.stream_open_invalid", "HTTP open requires its exact authorized request selector")
        }
        let intentId = if (maintenance) { "maintenance-" + requestId } else { httpIntentText(args, "intent_id") }
        let intent = if (maintenance) {
            let requests = configuration.bindStreamIntents(objectValue([ValueField("intents", listValue([
                objectValue([ValueField("id", textValue(intentId)), ValueField("request", args.field("request").getOrThrow())])]))]))
            match (requests) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value[0] }
        } else {
            let bound = match (httpStreamServiceChildArguments(prepared.operationPlan.canonicalArguments, intentId)) {
                case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value
            }
            bound.field("intent").getOrThrow()
        }
        let request = intent.field("request").getOrThrow()
        let profileBinding = if (maintenance) {
            let plan = parseUnifiedJson(maintenanceText.getOrThrow(), maxBytes: 196608)
            plan.field(if (action.getOrThrow() == HostServiceAction.Start) { "grant" } else { "launch" }).getOrThrow()
        } else { binding() }
        let network = match (httpStreamIntentPolicy(intent, binding: Some(profileBinding))) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value }
        let serializedInput = stringifyUnifiedJson(request).size
        let maxRequests = if (maintenance) { hostLifecycleInt(window(), "max_requests", 32) } else { 4 }
        let inputCeiling = match (configuration.payloadLimits) { case Some(value) => value.maxPrepareBytes; case None => 262144 }
        let outputCeiling = match (configuration.payloadLimits) { case Some(value) => value.maxResultBytes; case None => 1048576 }
        let maxOutput = hostLifecycleInt(request, "max_response_bytes", outputCeiling)
        let maxInput = if (maintenance) { hostLifecycleInt(window(), "max_input_bytes", inputCeiling) } else { 196608 }
        let maxResponse = if (maintenance) { hostLifecycleInt(window(), "max_output_bytes", outputCeiling) } else {
            match (configuration.payloadLimits) { case Some(value) => value.maxResultBytes; case None => 4194304 } }
        lock.lock()
        let exchange = try {
            if (active.isSome() || failed || !gate.isOpen() || intents.contains(intentId) || exchanges.size >= maxRequests ||
                serializedInput > maxInput - inputReserved || outputReserved >= maxResponse) {
                return hostPluginServiceError("http.stream_window_limit", "HTTP request exceeds its finite invocation window")
            }
            let value = HostManagedHttpExchange("exchange-" + prepared.operationId.value + "-" + exchanges.size.toString(),
                intentId, parseUnifiedJson(stringifyUnifiedJson(request), maxBytes: HOST_HTTP_STREAM_ENCODED_MAX_BYTES), network,
                endpoint.generation.descriptor.root, caBundle, context,
                min(until, agentUtcMillis() + hostLifecycleInt(request, "timeout_ms", 120000)), min(maxOutput, maxResponse - outputReserved),
                maxResponse - outputReserved, { => endpoint.generation.enterRegistryEffect() })
            exchanges.add(value); active = Some(value); intents.add(intentId)
            inputReserved += serializedInput
            value
        } finally { lock.unlock() }
        exchange.observe(service.resourceCancellation())
        try {
            let task = spawn {
                // No canonical admission, credentials or IO until this exact
                // Future belongs to the actual Run/epoch cancellation join.
                while (!exchange.workerReleased.load()) { sleep(Duration.millisecond) }
                if (!exchange.workerAdmitted.load()) {
                    exchange.openingFinished.store(true); let _ = exchange.closeResources(); exchange.workerSettled.store(true)
                    return
                }
                if (maintenance) {
                    exchange.executionStarted.store(true)
                    let result = runExchange(exchange, prepared.operationId, prepared.call.callId)
                    if (result.isError()) { rememberFailure() }
                    exchange.workerSettled.store(true)
                } else {
                    try { settled(exchange, broker.getOrThrow().execute(invocationId, requestId, "network.http.stream", stringifyUnifiedJson(args))) }
                    catch (_: Exception) { rememberFailure(); exchange.openingFinished.store(true); let _ = exchange.closeResources(); exchange.workerSettled.store(true) }
                }
            }
            exchange.workerSpawned.store(true)
            match (context.ownTask("http-stream-" + exchange.id, task)) {
                case Result.Err(error) =>
                    rememberFailure(); exchange.workerReleased.store(true)
                    return hostPluginServiceAgentError(error)
                case Result.Ok(_) => exchange.workerAdmitted.store(true); exchange.workerReleased.store(true)
            }
        } catch (_: Exception) {
            rememberFailure(); exchange.workerReleased.store(true)
            if (!exchange.workerSpawned.load()) {
                exchange.openingFinished.store(true); let _ = exchange.closeResources(); exchange.workerSettled.store(true)
            }
            return hostPluginServiceError("http.stream_worker_unavailable", "HTTP exchange worker could not be started")
        }
        while (exchange.selectedHead().isNone() && !exchange.workerSettled.load() && !exchange.source.token.isCancelled()) {
            // Waiting on this already-owned Future performs no new effect or
            // publication. Keep live cancellation/deadline checks cheap; the
            // child verifies full current authority before I/O, and the parent
            // does so again before returning the observed response headers.
            match (validateExchangeLifetime(exchange)) { case Result.Err(_) => break; case Result.Ok(_) => () }
            sleep(Duration.millisecond * 2)
        }
        let head = exchange.selectedHead()
        if (head.isNone() || exchange.error().isSome() || exchange.source.token.isCancelled()) {
            rememberFailure(); let _ = exchange.closeResources()
            return hostPluginServiceError("http.stream_open_failed", "HTTP response headers were not received within the authorized window")
        }
        match (validate()) {
            case Result.Err(error) => rememberFailure(); let _ = exchange.closeResources(); return hostPluginServiceAgentError(error)
            case Result.Ok(_) => ()
        }
        match (validateExchangeLifetime(exchange)) {
            case Result.Err(error) => rememberFailure(); let _ = exchange.closeResources(); return hostPluginServiceAgentError(error)
            case Result.Ok(_) => ()
        }
        let metadata = head.getOrThrow()
        JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([ValueField("exchange_id", textValue(exchange.id)),
            ValueField("status", integerValue(metadata.status)), ValueField("content_type", textValue(metadata.contentType)),
            ValueField("body_size", match (metadata.bodySize) { case Some(value) => integerValue(value); case None => nullValue() })])))
    }
    private func readExchange(exchange: HostManagedHttpExchange, args: AgentValue): JavaScriptHostResult<String> {
        if (!httpIntentExactFields(args, ["exchange_id", "max_bytes", "wait_ms"]) || exchange.closeRequested.load()) {
            return hostPluginServiceError("http.stream_read_invalid", "HTTP read requires one active exchange and bounded limits")
        }
        let maximum = try { hostLifecycleInt(args, "max_bytes", 16384) } catch (_: Exception) { 0 }
        let wait = try {
            let field = args.field("wait_ms").getOrThrow()
            let number = Int64.parse(field.asNumberText())
            if (field.unifiedKind == ValueKind.Number && number >= 0 && number <= 25 && field.asNumberText() == number.toString()) { number } else { -1 }
        } catch (_: Exception) { -1 }
        if (maximum < 1 || wait < 0 || exchange.selectedReader().isNone()) {
            return hostPluginServiceError("http.stream_read_invalid", "HTTP read bounds are invalid")
        }
        match (validateExchangeLifetime(exchange)) {
            case Result.Err(error) => exchange.fail(error); rememberFailure(); return hostPluginServiceAgentError(error)
            case Result.Ok(_) => ()
        }
        match (exchange.selectedReader().getOrThrow().readBody(maximum, waitMillis: wait)) {
            case Result.Err(error) => exchange.fail(error); rememberFailure(); hostPluginServiceAgentError(error)
            case Result.Ok(value) =>
                match (validate()) { case Result.Err(error) => exchange.fail(error); rememberFailure(); return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
                match (validateExchangeLifetime(exchange)) { case Result.Err(error) => exchange.fail(error); rememberFailure(); return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
                exchange.lock.lock(); try { exchange.consumed += value.bytes.size; exchange.bodyEof = value.eof } finally { exchange.lock.unlock() }
                hostManagedChannelReadResult(value)
        }
    }
    private func closeExchange(exchange: HostManagedHttpExchange): JavaScriptHostResult<String> {
        exchange.closeRequested.store(true)
        let deadline = min(until, agentUtcMillis() + 5000)
        while (!exchange.workerSettled.load() && agentUtcMillis() < deadline) {
            let _ = exchange.closeResources(); sleep(Duration.millisecond * 2)
        }
        if (exchange.closeResources().isError() || !exchange.workerSettled.load() || exchange.error().isSome()) {
            rememberFailure(); return hostPluginServiceError("http.stream_close_pending", "HTTP exchange lacks its actual cleanup acknowledgement and terminal operation")
        }
        exchange.lock.lock(); let receipt = try { exchange.receipt } finally { exchange.lock.unlock() }
        if (broker.isSome() && receipt == "") {
            rememberFailure(); return hostPluginServiceError("http.stream_receipt_missing", "HTTP exchange has no canonical completed child Receipt")
        }
        let result = exchange.output()
        result.put("receipt_id", if (broker.isSome()) { textValue(receipt) } else { nullValue() })
        exchange.lock.lock()
        try {
            if (exchange.closeDelivered) { return hostPluginServiceError("http.stream_handle_closed", "HTTP exchange was already closed") }
            exchange.closeDelivered = true
        } finally { exchange.lock.unlock() }
        let rawBytes = match (exchange.selectedReader()) {
            case Some(reader) => match (reader.receivedOutputBytes()) {
                case Result.Ok(value) => value
                case Result.Err(error) => rememberFailure(); return hostPluginServiceAgentError(error)
            }
            case None => 0
        }
        lock.lock()
        try { outputReserved += rawBytes; if (active.isSome() && refEq(active.getOrThrow(), exchange)) { active = None } }
        finally { lock.unlock() }
        JavaScriptHostResult.Ok(stringifyUnifiedJson(result))
    }
    public func finish(response: Result<HostJavaScriptPluginInvocationResult>): Result<ToolResult> {
        gate.close()
        lock.lock(); let snapshot = try { exchanges.toArray() } finally { lock.unlock() }
        // A terminal cannot release its parent slot while its broker still
        // borrows it. First revoke IO and let actual child settlement return
        // the slot. If cleanup remains blocked the scheduler must retain the
        // outstanding reservation and recovery debt, never mark it joined.
        for (exchange in snapshot) {
            exchange.lock.lock(); let delivered = try { exchange.closeDelivered } finally { exchange.lock.unlock() }
            if (!delivered) { rememberFailure() }
            let _ = exchange.closeResources()
        }
        let settlementUntil = agentUtcMillis() + 5000
        var pending = true
        while (pending && agentUtcMillis() < settlementUntil) {
            pending = false
            for (exchange in snapshot) {
                if (exchange.closeResources().isError() || !exchange.workerSettled.load()) { pending = true }
            }
            if (pending) { sleep(Duration.millisecond * 2) }
        }
        var attempted = false
        for (exchange in snapshot) {
            attempted = attempted || exchange.executionStarted.load()
            exchange.lock.lock(); let delivered = try { exchange.closeDelivered && (broker.isNone() || exchange.receipt != "") } finally { exchange.lock.unlock() }
            if (!delivered || !exchange.workerSettled.load() || !exchange.cleanupAcknowledged.load() || exchange.error().isSome()) { rememberFailure() }
        }
        lock.lock(); let bad = try { failed } finally { lock.unlock() }
        if (bad) {
            if (attempted && prepared.operationPlan.effectClass == OperationEffectClass.ReadOnly) { return hostManagedChannelUnknown() }
            return if (hostManagedChannelCallerCancelled(context)) { hostLifecycleIoCancelled() } else { hostManagedChannelUnknown() }
        }
        match (response) {
            case Result.Err(error) => hostManagedChannelFailure(error, attempted, callerCancelled: hostManagedChannelCallerCancelled(context),
                readonlyParent: prepared.operationPlan.effectClass == OperationEffectClass.ReadOnly)
            case Result.Ok(value) => if (action.isSome()) {
                if (value.isError) { hostManagedChannelUnknown() } else { Result.Ok(ToolResult(prepared.call.callId, value.value)) }
            } else { hostManagedChannelTerminal(prepared.call.callId, value, attempted) }
        }
    }
    public func close(): Result<Unit> {
        gate.close()
        lock.lock(); let snapshot = try { exchanges.toArray() } finally { lock.unlock() }
        var acknowledged = true
        for (exchange in snapshot) {
            if (exchange.closeResources().isError() || !exchange.workerSettled.load()) { acknowledged = false }
        }
        if (acknowledged) { Result.Ok(()) } else { hostLifecycleLeaseError("http.stream_cleanup_pending") }
    }
}
