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
            hostSchemaProperty("contribution", "string"), hostSchemaProperty("intent", "object")],
            ["plugin", "generation", "package_digest", "configuration_digest", "contribution", "intent"])),
        Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true, neverReplay: true,
        implementationVersion: HOST_READ_VIEW_FINGERPRINT, implementationFingerprint: HOST_READ_VIEW_FINGERPRINT,
        capabilityResolver: Some({ call => readViewRequiredCapabilities(call.arguments)[0] }),
        additionalCapabilityResolver: Some({ call => let all = readViewRequiredCapabilities(call.arguments); all[1..] }),
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

    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (prepared.source.kind != PreparedInvocationSourceKind.Derived || prepared.source.parentOperationId.isNone() ||
            prepared.source.operationRoot.isNone() || !isReadViewServiceChildPlan(prepared.operationPlan)) {
            return hostPluginResourceError("read_view.source_invalid", "read view requires an admitted exact ParentIntent child")
        }
        let parent = match (operations.loadPlan(prepared.source.parentOperationId.getOrThrow(), context.runId)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        if (!readViewServiceChildAllowed(parent, prepared.operationPlan)) {
            return hostPluginResourceError("read_view.intent_changed", "read view differs from its actual parent intent")
        }
        let args = prepared.operationPlan.canonicalArguments
        let namespace = httpIntentText(args, "plugin")
        let generation = try { UInt64.parse(httpIntentText(args, "generation")) } catch (_: Exception) { 0u64 }
        match (hostValidatePluginReadViewParent(host, settingsRoot, parent, namespace, httpIntentText(args, "contribution"), generation)) {
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
        let intent = args.field("intent").getOrThrow(); let request = intent.field("request").getOrThrow()
        let executable = match (hostResolvePluginProcessExecutable(descriptor.root, httpIntentText(request, "executable"))) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        match (reserveView()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let view = try { Directory.createTemp("/tmp").toString() }
            catch (_: Exception) {
                cleanupLock.lock(); activeViews--; cleanupLock.unlock()
                return hostPluginResourceError("read_view.snapshot_unavailable", "cannot create a private bounded read view")
            }
        let owned = HostReadViewCleanup(prepared.operationId, view)
        let cancellation = CancellationSource(parent: Some(context.cancellation))
        let registration = match (host.observeServiceRevocation(namespace, generation, { => let _ = cancellation.cancel() })) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                cancellation.close(); let done = cleanup(owned)
                cleanupLock.lock(); activeViews--; if (done.isError()) { retained.add(owned) }; cleanupLock.unlock()
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
            run(scoped, prepared, intent, view, descriptor.root, executable, configuration)
        }
            catch (_: Exception) { Result<ToolResult>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "read_view.outcome_unknown", "read-view execution or resource cleanup could not be verified", retryable: false, fallbackAllowed: false)) }
            finally {
                let _ = finished.cancel()
                match (watcher) { case Some(task) => try { task.get() } catch (_: Exception) { () }; case None => () }
                registration.dispose(); cancellation.close()
            }
        let done = cleanup(owned)
        cleanupLock.lock(); activeViews--; if (done.isError()) { retained.add(owned) }; cleanupLock.unlock()
        if (done.isError()) { return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "read_view.cleanup_pending", "worker cleanup is still owned; the read view was not released", retryable: false, fallbackAllowed: false)) }
        outcome
    }

    private func run(context: ToolInvocationContext, prepared: PreparedToolInvocation, intent: AgentValue,
        view: String, packageRoot: String, executable: String, configuration: HostPluginHttpConfiguration): Result<ToolResult> {
        let workspace = host.readTargetInspector(context.workspaceRoot)
        let resources = intent.field("resources").getOrThrow()
        var copied: Int64 = 0
        for (resource in resources.items) {
            match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let source = httpIntentText(resource, "source"); let path = httpIntentText(resource, "path")
            if (httpIntentText(resource, "kind") == "reference") {
                // No router, artifact store, filesystem classification, or content read.
                if (!readViewResourceReference(source) || httpIntentText(resource, "witness") != "r:" + modelPolicySha256Text(source) ||
                    !context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: source)) {
                    return hostPluginResourceError("read_view.reference_denied", "opaque reference no longer fits its frozen actual ceiling") }
                continue
            }
            let classification = match (workspace.inspectReadTarget(source)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
            }
            let permission = if (host.readViewSensitive(source)) { "sensitive-path.read" } else { classification.permissionClass }
            if (!classification.exists || classification.normalizedPath != source ||
                permission != httpIntentText(resource, "permission") ||
                !context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: source)) {
                return hostPluginResourceError("read_view.resource_changed", "resource classification or current capability changed before content read")
            }
            let witness = match (hostReadResourceWitness(source)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            if (witness != httpIntentText(resource, "witness")) { return hostPluginResourceError("read_view.resource_changed", "resource identity changed after approval") }
            let target = if (path == ".") { view } else { Path(view).join(path).toString() }
            if (httpIntentText(resource, "kind") == "directory") {
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
        let request = intent.field("request").getOrThrow()
        match (request.field("input")) {
            case Some(input) => 
                let encoded = stringifyUnifiedJson(input)
                if (input.unifiedKind != ValueKind.Object || encoded.size > HOST_READ_VIEW_INPUT_BYTES) {
                    return hostPluginResourceError("read_view.input_invalid", "frozen input exceeds its private view bound") }
                File.writeTo(Path(view).join(HOST_READ_VIEW_INPUT_PATH).toString(), encoded.toArray())
            
            case None => ()
        }
        let maximumOutput = if (request.field("input").isSome()) { HOST_READ_VIEW_INPUT_OUTPUT_BYTES } else { PLUGIN_READONLY_PROCESS_OUTPUT_BYTES }
        let originalLimits = context.budget.processLimits
        let limits = ExecutionResourceLimits(
            maxOutputBytes: if (originalLimits.maxOutputBytes > 0) { min(originalLimits.maxOutputBytes, maximumOutput) } else { maximumOutput },
            addressSpaceBytes: originalLimits.addressSpaceBytes, fileSizeBytes: originalLimits.fileSizeBytes,
            openFiles: originalLimits.openFiles, processes: originalLimits.processes, cpuSeconds: originalLimits.cpuSeconds)
        let argv = ArrayList<String>(); for (arg in request.field("arguments").getOrThrow().items) { argv.add(arg.text) }
        var timeout = hostPluginProcessTimeout(request)
        if (context.cancellation.deadlineMillis > 0) { timeout = min(timeout, context.cancellation.deadlineMillis - agentUtcMillis()) }
        if (timeout < 1) { return hostPluginResourceError("read_view.deadline", "read view deadline expired before launch") }
        let channel = match (processes.openChannel(ProcessRequest(executable, operationId: prepared.operationId,
            arguments: argv.toArray(), workingDirectory: view, filesystemRoot: view,
            sandboxMode: ProcessSandboxMode.IsolatedReadOnly, readOnlyMounts: [packageRoot],
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), timeoutMillis: timeout,
            processLimits: limits), context.cancellation, 1)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        match (channel.closeInput()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let output = ArrayList<Byte>(); let errors = ArrayList<Byte>(); var outDone = false; var errDone = false
        while (!outDone || !errDone) {
            match (hostReadViewCancellation(context)) { case Result.Err(error) => let _ = channel.abort(); return Result.Err(error); case Result.Ok(_) => () }
            for (stream in [ProcessChannelStream.Stdout, ProcessChannelStream.Stderr]) {
                let read = match (channel.read(stream, 8192, 25)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
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
        if (stringifyUnifiedJson(result).size > (if (request.field("input").isSome()) { 262144 } else { 196608 })) { return hostPluginResourceError("read_view.output_limit", "encoded worker result exceeds its service bound") }
        Result.Ok(ToolResult(prepared.call.callId, result, isError: status != 0))
    }
}
