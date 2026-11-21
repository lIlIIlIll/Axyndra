package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.math.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

public func hostValidatePluginReadViewParent(host: HostJavaScriptPluginHost, settingsRoot: String,
    parent: NormalizedOperationPlan, namespace: String, tool: String, generation: UInt64): Result<AgentValue> {
    let descriptor = match (host.servicePackageData81(namespace, generation)) {
        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
    }
    if (!descriptor.requestedCapabilities.contains("process.readview")) { return Result.Ok(parent.canonicalArguments) }
    if (!isFrozenReadViewParentPlan(parent)) { return hostPluginResourceError("read_view.parent_invalid", "read-view package requires its canonical prepared resource view") }
    let plan = parent.canonicalArguments.field("host_plan").getOrThrow()
    if (httpIntentText(plan, "plugin") != namespace || httpIntentText(plan, "contribution") != tool ||
        httpIntentText(plan, "generation") != generation.toString() || httpIntentText(plan, "package_digest") != descriptor.contentDigest) {
        return hostPluginResourceError("read_view.identity_changed", "read-view parent belongs to another package, contribution or generation")
    }
    let configuration = match (loadHostPluginHttpConfiguration(settingsRoot, namespace, descriptor.contentDigest)) {
        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
    }
    if (configuration.digest != httpIntentText(plan, "configuration_digest") ||
        configuration.ordinaryReadTools.contains(tool) != plan.field("read_granted").getOrThrow().asBool()) {
        return hostPluginResourceError("read_view.grant_changed", "ordinary Tool operator grant changed after preparation")
    }
    let selectedPayload = match (configuration.toolPayloadLimits(tool)) { case Some(value) => value.value(); case None => nullValue() }
    if (canonicalAgentValue(selectedPayload) != canonicalAgentValue(plan.field("tool_payload_limits").getOrThrow())) {
        return hostPluginResourceError("read_view.payload_changed", "ordinary read-view representation profile changed after preparation") }
    let intent = plan.field("intents").getOrThrow().items[0]
    match (hostValidateReadViewDeadline(host, configuration, namespace, tool, generation, intent)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    // The process protocol receives the original business input. Host-only
    // filesystem identities and capability decisions remain in durable plans.
    Result.Ok(parent.canonicalArguments.field("input").getOrThrow())
}

public func hostRegisterPluginReadViewService(catalog: ToolCatalog, host: HostJavaScriptPluginHost,
    operations: OperationRuntimePort, settingsRoot: String, processes: ProcessPort): Result<Unit> {
    let executor = HostPluginReadViewExecutor(host, operations, settingsRoot, processes)
    match (host.ownReadViewCleanup({ => executor.closeViews() })) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    catalog.register(ToolDescriptor(ModelToolDefinition(HOST_READ_VIEW_TOOL,
        "Execute a package worker in an exact, host-authorized read-resource snapshot.",
        hostObjectSchema([hostSchemaProperty("plugin", "string"), hostSchemaProperty("generation", "string"),
            hostSchemaProperty("package_digest", "string"), hostSchemaProperty("configuration_digest", "string"),
            hostSchemaProperty("contribution", "string"), ValueField("tool_payload_limits", objectValue([ValueField("type", listValue([textValue("object"), textValue("null")]))])), hostSchemaProperty("intent", "object")],
            ["plugin", "generation", "package_digest", "configuration_digest", "contribution", "tool_payload_limits", "intent"])),
        Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true, neverReplay: true,
        implementationVersion: HOST_READ_VIEW_FINGERPRINT, implementationFingerprint: HOST_READ_VIEW_FINGERPRINT,
        capabilityResolver: Some({ call => resolverReadViewCapabilities(call)[0] }),
        additionalCapabilityResolver: Some({ call => let all = resolverReadViewCapabilities(call); all[1..] }),
        networkPolicyResolver: Some({ _ => Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied)) })),
        executor)
}

public class HostReadViewCleanup {
    let operation: OperationId; let path: String
    init(operation: OperationId, path: String) { this.operation = operation; this.path = path }
}

public class HostPluginReadViewExecutor <: ToolExecutor {
    private let host: HostJavaScriptPluginHost
    private let operations: OperationRuntimePort
    private let settingsRoot: String
    // Existing Product execution-plane owner retains failed channel cleanup,
    // and Product.close still closes that same owner. No second scheduler.
    private let processes: ProcessPort
    private let cleanupLock = Mutex()
    private let retained = ArrayList<HostReadViewCleanup>()
    private var activeViews: Int64 = 0
    private var closed = false

    init(host: HostJavaScriptPluginHost, operations: OperationRuntimePort,
        settingsRoot: String, processes: ProcessPort) {
        this.host = host; this.operations = operations; this.settingsRoot = settingsRoot; this.processes = processes
    }

    private func cleanup(entry: HostReadViewCleanup): Result<Unit> {
        match (processes.closeChannelOperation(entry.operation)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try { if (exists(Path(entry.path))) { remove(entry.path, recursive: true) }; Result.Ok(()) }
        catch (_: Exception) { hostPluginResourceError("read_view.cleanup_pending", "private read view cleanup remains pending") }
    }

    public func closeViews(): Result<Unit> {
        cleanupLock.lock()
        try {
            closed = true
            if (activeViews != 0) { return hostPluginResourceError("read_view.cleanup_pending", "active view still owns its bounded execution and cleanup") }
            var index: Int64 = 0
            while (index < retained.size) {
                if (cleanup(retained[index]).isOk()) { retained.remove(at: index) } else { index++ }
            }
            if (!retained.isEmpty()) { return hostPluginResourceError("read_view.cleanup_pending", "private view cleanup has not acknowledged release") }
            Result.Ok(())
        } finally { cleanupLock.unlock() }
    }

    private func reserveView(): Result<Unit> {
        cleanupLock.lock()
        try {
            if (closed) { return hostPluginResourceError("read_view.closed", "read-view owner is closed") }
            var index: Int64 = 0
            while (index < retained.size) {
                if (cleanup(retained[index]).isOk()) { retained.remove(at: index) } else { index++ }
            }
            if (activeViews + retained.size >= 8) { return hostPluginResourceError("read_view.capacity", "active or pending read views occupy bounded host capacity") }
            activeViews++; Result.Ok(())
        } finally { cleanupLock.unlock() }
    }

    public func executeObserved(context: ToolInvocationContext, prepared: PreparedToolInvocation): ToolExecutionOutcome {
        let cleanupData: Array<String> = ["not_returned"]
        let returned = executeActual(context, prepared, cleanupData)
        // execute returns cancellation only after the original channel and
        // private view acknowledged cleanup. Pending cleanup returns Unknown.
        let evidence: ?ToolExecutionCancellationEvidence = match (returned) {
            case Result.Err(error) => observeToolExecutionCancellation(context, prepared, error, context.cancellation)
            case Result.Ok(_) => None
        }
        ToolExecutionOutcome(returned, cancellationEvidence: evidence,
            diagnostic: objectValue([ValueField("readview_executor_entered", boolValue(true)),
                ValueField("cleanup_return", textValue(cleanupData[0]))]))
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        executeActual(context, prepared, ["not_returned"])
    }
    private func executeActual(context: ToolInvocationContext, prepared: PreparedToolInvocation, cleanupData: Array<String>): Result<ToolResult> {
        if (prepared.source.kind != PreparedInvocationSourceKind.Derived || prepared.source.parentOperationId.isNone() ||
            prepared.source.operationRoot.isNone() || !prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadViewChild)) {
            return hostPluginResourceError("read_view.source_invalid", "read view requires an admitted exact ParentIntent child")
        }
        let parent = match (operations.loadPlan(prepared.source.parentOperationId.getOrThrow(), context.runId)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        if (!prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadViewChildOf(parent))) {
            return hostPluginResourceError("read_view.intent_changed", "read view differs from its actual parent intent")
        }
        // Only select the DATA payer from the already checked parent. The worker
        // below reads its identity, resources, arguments and limits from the child.
        let binding = parent.canonicalArguments.field("host_plan").getOrThrow()
        let funding = match (host.servicePackage(httpIntentText(binding, "plugin"), UInt64.parse(httpIntentText(binding, "generation")))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        let work = try { funding.deriveCopiedDataPayment(16384) }
            catch (_: LogicalJsonPayloadError) { return Result.Err(readViewMetadataBudgetError()) }
            finally { funding.close() }
        try {
            prepared.withCanonicalCallInput({ input =>
                let exports = deriveReadViewDataLease(work)
                let fields = try { HostReadViewWorkerFields(input, work, exports) }
                    catch (error: Exception) { exports.close(); throw error }
                try { executeFields(context, prepared, parent, fields, cleanupData) }
                finally { if (!fields.published) { exports.close() } }
            })
        } catch (_: HostReadViewMetadataCapacity) { Result.Err(readViewMetadataBudgetError()) }
        finally { work.close() }
    }

    private func executeFields(context: ToolInvocationContext, prepared: PreparedToolInvocation, parent: NormalizedOperationPlan,
        fields: HostReadViewWorkerFields, cleanupData: Array<String>): Result<ToolResult> {
        let namespace = fields.root("plugin", external: true)
        let generationText = fields.root("generation")
        let generation = try { UInt64.parse(generationText) } catch (_: Exception) { 0u64 }
        match (hostValidatePluginReadViewParent(host, settingsRoot, parent, namespace, fields.root("contribution", external: true), generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        let descriptor = match (host.servicePackageData81(namespace, generation)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let packageMatches = match (host.registryPackageMatches81(descriptor.root, namespace: Some(namespace),
            digest: Some(descriptor.contentDigest))) {
            case Result.Err(_) => return hostPluginResourceError("read_view.package_changed", "worker package is unavailable")
            case Result.Ok(value) => value }
        if (!packageMatches) {
            return hostPluginResourceError("read_view.package_changed", "worker package bytes changed after preparation")
        }
        let configuration = match (loadHostPluginHttpConfiguration(settingsRoot, namespace, descriptor.contentDigest)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        let executable = match (hostResolvePluginProcessExecutable(descriptor.root, fields.request("executable"))) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        match (reserveView()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let view = try {
            let scratch = Path(settingsRoot).join("read-views")
            if (!exists(scratch)) { Directory.create(scratch, recursive: true) }
            Directory.createTemp(scratch.toString()).toString()
        } catch (_: Exception) {
                cleanupLock.lock(); activeViews--; cleanupLock.unlock()
                return hostPluginResourceError("read_view.snapshot_unavailable", "cannot create a private bounded read view")
            }
        let owned = HostReadViewCleanup(prepared.operationId, view)
        let cancellation = CancellationSource(parent: Some(context.cancellation))
        let registration = match (host.observeServiceRevocation(namespace, generation, { => let _ = cancellation.cancel() })) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                cancellation.close(); let done = cleanup(owned)
                cleanupData[0] = if (done.isError()) { "pending" } else { "acknowledged" }
                cleanupLock.lock(); activeViews--; if (done.isError()) { retained.add(owned) }; cleanupLock.unlock()
                if (done.isError()) {
                    return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "read_view.cleanup_pending", "worker cleanup is still owned; the read view was not released", retryable: false, fallbackAllowed: false))
                }
                return Result.Err(error)
        }
        let finished = CancellationSource()
        var watcher: ?Future<Unit> = None
        let scoped = hostPluginProcessCancellationContext(context, cancellation.token)
        let outcome = try {
            watcher = Some(spawn {
                while (!finished.token.isCancelled() && !cancellation.token.isCancelled()) {
                    if (configuration.stillCurrent().isError()) { let _ = cancellation.cancel() }
                    sleep(Duration.millisecond * 25)
                }
            })
            run(scoped, prepared.operationId, fields, view, descriptor.root, executable, configuration)
        }
            catch (_: HostReadViewMetadataCapacity) { Result<ToolResult>.Err(readViewMetadataBudgetError()) }
            catch (_: Exception) { Result<ToolResult>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "read_view.outcome_unknown", "read-view execution or resource cleanup could not be verified", retryable: false, fallbackAllowed: false)) }
            finally {
                let _ = finished.cancel()
                match (watcher) { case Some(task) => try { task.get() } catch (_: Exception) { () }; case None => () }
                registration.dispose(); cancellation.close()
            }
        let done = cleanup(owned)
        cleanupData[0] = if (done.isError()) { "pending" } else { "acknowledged" }
        cleanupLock.lock(); activeViews--; if (done.isError()) { retained.add(owned) }; cleanupLock.unlock()
        if (done.isError()) {
            match (outcome) { case Result.Ok(value) => value.releasePayload(); case Result.Err(_) => () }
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "read_view.cleanup_pending", "worker cleanup is still owned; the read view was not released", retryable: false, fallbackAllowed: false))
        }

        outcome
    }

    private func run(context: ToolInvocationContext, operationId: OperationId, fields: HostReadViewWorkerFields,
        view: String, packageRoot: String, executable: String, configuration: HostPluginHttpConfiguration): Result<ToolResult> {
        let workspace = host.readTargetInspector(context.workspaceRoot)
        let count = fields.input.count([ToolResolverStep.Field("intent"), ToolResolverStep.Field("resources")])
        var copied: Int64 = 0
        for (index in 0..count) {
            match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let reference = fields.input.textEquals(fields.resource(index, "kind"), "reference")
            let source = fields.text(fields.resource(index, "source"), external: !reference)
            if (reference) {
                // No router, artifact store, filesystem classification, or content read.
                if (!readViewResourceReference(source) || !fields.input.textEquals(fields.resource(index, "witness"), "r:" + modelPolicySha256Text(source)) ||
                    !context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: source)) {
                    return hostPluginResourceError("read_view.reference_denied", "opaque reference no longer fits its frozen actual ceiling") }
                continue
            }
            let classification = match (workspace.inspectReadTarget(source)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
            }
            let permission = if (host.readViewSensitive(source)) { "sensitive-path.read" } else { classification.permissionClass }
            if (!classification.exists || classification.normalizedPath != source ||
                !fields.input.textEquals(fields.resource(index, "permission"), permission) ||
                !context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: source)) {
                return hostPluginResourceError("read_view.resource_changed", "resource classification or current capability changed before content read")
            }
            let witness = match (hostReadResourceWitness(source)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            if (!fields.input.textEquals(fields.resource(index, "witness"), witness)) { return hostPluginResourceError("read_view.resource_changed", "resource identity changed after approval") }
            let path = fields.text(fields.resource(index, "path"))
            let target = if (path == ".") { view } else { Path(view).join(path).toString() }
            if (fields.input.textEquals(fields.resource(index, "kind"), "directory")) {
                if (!exists(Path(target))) { Directory.create(target, recursive: true) }
            } else {
                if (!exists(Path(target).parent)) { Directory.create(Path(target).parent, recursive: true) }
                let count = match (hostReadResourceCopy(source, witness, target, HOST_READ_VIEW_MAX_BYTES - copied)) {
                    case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
                }
                copied += count
            }
        }
        match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let hasInput = fields.input.kind([ToolResolverStep.Field("intent"), ToolResolverStep.Field("request"), ToolResolverStep.Field("input")]).isSome()
        if (hasInput) {
            if (!fields.writeInputFile(Path(view).join(HOST_READ_VIEW_INPUT_PATH).toString())) {
                return hostPluginResourceError("read_view.input_invalid", "frozen input exceeds its private view bound")
            }
        }
        let payload = resolverReadViewResponseLimit(fields.input)
        let serviceMaximum = match (payload) { case Some(value) => value - 4096
            case None => if (hasInput) { 262144 } else { 196608 } }
        if (serviceMaximum < 128) { return hostPluginResourceError("read_view.output_limit", "selected profile cannot contain the worker service envelope") }
        let maximumOutput = match (payload) { case Some(_) => serviceMaximum
            case None => if (hasInput) { HOST_READ_VIEW_INPUT_OUTPUT_BYTES } else { PLUGIN_READONLY_PROCESS_OUTPUT_BYTES } }
        let originalLimits = context.budget.processLimits
        let limits = ExecutionResourceLimits(
            maxOutputBytes: if (originalLimits.maxOutputBytes > 0) { min(originalLimits.maxOutputBytes, maximumOutput) } else { maximumOutput },
            addressSpaceBytes: originalLimits.addressSpaceBytes, fileSizeBytes: originalLimits.fileSizeBytes,
            openFiles: originalLimits.openFiles, processes: originalLimits.processes, cpuSeconds: originalLimits.cpuSeconds)
        let argc = fields.input.count([ToolResolverStep.Field("intent"), ToolResolverStep.Field("request"), ToolResolverStep.Field("arguments")])
        let timeoutText = fields.request("timeout_ms")
        var timeout = try { Int64.parse(timeoutText) } catch (_: Exception) { -1 }
        if (context.cancellation.deadlineMillis > 0) { timeout = min(timeout, context.cancellation.deadlineMillis - agentUtcMillis()) }
        if (timeout < 1) { return hostPluginResourceError("read_view.deadline", "read view deadline expired before launch") }
        // Prepay the original result ID before either a budget refusal or a worker can publish a result.
        let callId = fields.text(ToolResolverText.CallId, external: true)
        let payment = try { reserveNativeDocumentPayload(maximumOutput) }
        catch (_: LogicalJsonPayloadError) {
            // The frozen limit fits a Native document. The bank refused the
            // reservation before openChannel; no worker could have run.
            // executeActual still requires cleanup before publishing this result.
            return Result.Ok(recoverableToolResult(callId, AgentError(AgentErrorKind.BudgetExceeded,
                "read_view.output_capacity", "shared logical JSON output capacity is exhausted",
                retryable: false, fallbackAllowed: false)))
        }
        var transferred = false
        try {
        let argv = Array<String>(argc, { index => fields.argument(index) })
        let channel = match (processes.openChannel(ProcessRequest(executable, operationId: operationId,
            arguments: argv, workingDirectory: view, filesystemRoot: view,
            sandboxMode: ProcessSandboxMode.IsolatedReadOnly, readOnlyMounts: [packageRoot],
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), timeoutMillis: timeout,
            processLimits: limits), context.cancellation, 1)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        match (channel.closeInput()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let output = ArrayList<Byte>(); let errors = ArrayList<Byte>(); var outDone = false; var errDone = false
        var encodedBytes: Int64 = 128
        while (!outDone || !errDone) {
            match (hostReadViewCancellation(context)) { case Result.Err(error) => let _ = channel.abort(); return Result.Err(error); case Result.Ok(_) => () }
            for (stream in [ProcessChannelStream.Stdout, ProcessChannelStream.Stderr]) {
                let read = match (channel.read(stream, 8192, 25)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                let nextEncoded = encodedBytes + hostReadViewEscapedBytes(read.bytes)
                if (read.bytes.size > limits.maxOutputBytes - output.size - errors.size || nextEncoded > serviceMaximum) {
                    let _ = channel.abort(); return hostPluginResourceError("read_view.output_limit", "worker output exceeds the frozen raw or escaped service bound") }
                payment.ensureDecoded(output.size + errors.size + read.bytes.size + nextEncoded, 32)
                encodedBytes = nextEncoded
                match (stream) {
                    case ProcessChannelStream.Stdout => output.add(all: read.bytes); outDone = read.eof
                    case ProcessChannelStream.Stderr => errors.add(all: read.bytes); errDone = read.eof
                }
            }
            if (output.size + errors.size > maximumOutput) {
                return hostPluginResourceError("read_view.output_limit", "worker output exceeded its bounded service result")
            }
        }
        var observedStatus: ?Int64 = None
        let statusDeadline = agentUtcMillis() + 250
        while (observedStatus.isNone() && agentUtcMillis() < statusDeadline) {
            match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (channel.terminalStatus()) { case Result.Ok(value) => observedStatus = value; case Result.Err(error) => return Result.Err(error) }
            if (observedStatus.isNone()) { sleep(Duration.millisecond * 1) }
        }
        let status = match (observedStatus) { case Some(value) => value; case None => return hostPluginResourceError("read_view.terminal_missing", "worker omitted its terminal status") }
        match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let result = objectValue([ValueField("exit_code", integerValue(status)),
            ValueField("stdout", textValue(String.fromUtf8(output.toArray()))), ValueField("stderr", textValue(String.fromUtf8(errors.toArray()))),
            ValueField("timed_out", boolValue(false)), ValueField("truncated", boolValue(false))])
        payment.ensureDecoded(logicalJsonWriteReservationBytes(result, serviceMaximum), logicalJsonValueNodeCount(result))
        if (stringifyUnifiedJson(result).size > serviceMaximum) { return hostPluginResourceError("read_view.output_limit", "encoded worker result exceeds its service bound") }
        let returned = ToolResult(callId, result, isError: status != 0, payloadLease: Some(ToolResultPayloadLease({ => payment.close() })))
        transferred = true; Result.Ok(returned)
        } finally { if (!transferred) { payment.close() } }
    }
}

func hostReadViewEscapedBytes(bytes: Array<Byte>): Int64 {
    var total: Int64 = 0
    for (byte in bytes) {
        total += if (byte == 34u8 || byte == 92u8 || byte == 8u8 || byte == 9u8 || byte == 10u8 || byte == 12u8 || byte == 13u8) { 2 }
            else if (byte < 32u8) { 6 } else { 1 }
    }
    total
}
