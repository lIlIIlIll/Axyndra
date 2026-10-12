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
import yjson.*
import yjson_support.*

public let PLUGIN_READONLY_PROCESS_TOOL = "host.process.readonly"
public let PLUGIN_READONLY_PROCESS_OUTPUT_BYTES: Int64 = 131072

// This binding is created by the frozen executor, never decoded from IPC.
public class HostPluginServiceIdentity {
    public let host: HostJavaScriptPluginHost
    public let namespace: String
    public let generation: UInt64

    public init(host: HostJavaScriptPluginHost, namespace: String, generation: UInt64) {
        this.host = host
        this.namespace = namespace
        this.generation = generation
    }

    public func readViewArguments(parent: NormalizedOperationPlan, arguments: AgentValue, requestId: String): Result<AgentValue> {
        if (!httpIntentExactFields(arguments, ["intent_id"]) || httpIntentText(arguments, "intent_id") != requestId) {
            return hostPluginResourceError("read_view.intent_identity", "read-view request must name only its frozen intent id")
        }
        let bound = match (readViewChildArguments(parent.canonicalArguments, requestId)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        if (httpIntentText(bound, "plugin") != namespace || httpIntentText(bound, "generation") != generation.toString()) {
            return hostPluginResourceError("read_view.identity_changed", "read view belongs to another actual executor")
        }
        Result.Ok(bound)
    }

    public func readonlyDelegationArguments(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        arguments: AgentValue): Result<ToolCall> {
        let contribution = httpIntentText(prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow(), "contribution")
        match (host.delegationInput(context, prepared, namespace, contribution, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!httpIntentExactFields(arguments, ["tool", "input"]) || arguments.field("input").getOrThrow().unifiedKind != ValueKind.Object) {
            return hostPluginResourceError("readonly_delegation.arguments_invalid", "readonly service selects one frozen alias and object input") }
        for (entry in prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("tools").getOrThrow().items
            where httpIntentText(entry, "alias") == httpIntentText(arguments, "tool")) {
            return Result.Ok(ToolCall("selection-only", httpIntentText(entry, "name"), arguments.field("input").getOrThrow())) }
        hostPluginResourceError("readonly_delegation.tool_denied", "tool alias is absent from the host-frozen operator allowlist")
    }

    // Validate before any UI/exec/read/proposal service can create an effect.
    public func validateService(prepared: PreparedToolInvocation, service: String): Result<Unit> {
        let descriptor = match (host.servicePackageData81(namespace, generation)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        let prefix = "plugin." + namespace + "."
        let localTool = if (prepared.call.name.startsWith(prefix)) { prepared.call.name[prefix.size..] } else { "" }
        let primitive = match (host.primitiveConfiguration111(namespace, localTool, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (primitive.isSome() || isFrozenPluginChildParent111(prepared.operationPlan)) {
            if (primitive.isNone() || !primitive.getOrThrow().permitsService(localTool, service) || !isFrozenPluginChildParent111(prepared.operationPlan) ||
                prepared.source.kind == PreparedInvocationSourceKind.Derived || prepared.source.operationRoot.isNone()) {
                return hostPluginResourceError("child.service_denied", "only this exact selected canonical Tool may request its frozen child service") }
            let binding = prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
            if (httpIntentText(binding, "namespace") != namespace || httpIntentText(binding, "generation") != generation.toString() ||
                httpIntentText(binding, "configuration_digest") != primitive.getOrThrow().digest ||
                httpIntentText(binding, "parent_call_id") != prepared.call.callId ||
                httpIntentText(binding, "contribution") != prepared.call.name) {
                return hostPluginResourceError("child.service_binding_changed", "child service belongs to another selected contribution or invocation") }
            return primitive.getOrThrow().validateCurrent()
        }
        if (pluginPrimitiveService111(service)) { return hostPluginResourceError("child.profile_missing", "this contribution has no operator-selected child profile") }
        if (descriptor.requestedCapabilities.contains("tool.readonly")) {
            if (service == "tool.readonly" && isFrozenReadonlyDelegationParentPlan(prepared.operationPlan)) { return Result.Ok(()) }
            if(service=="file.plan.propose" && readonlyDelegationFilePlanProposalsEnabled(prepared.operationPlan) &&
                prepared.source.kind!=PreparedInvocationSourceKind.Derived && prepared.source.operationRoot.isSome()){
                return Result.Ok(())}
            return hostPluginResourceError("readonly_delegation.service_denied", "delegation endpoint has only the exact readonly child service")
        }
        if (service == "tool.readonly") { return hostPluginResourceError("readonly_delegation.not_requested", "package has not requested readonly delegation") }
        if (!descriptor.requestedCapabilities.contains("process.readview")) {
            if (service == "process.readview") { return hostPluginResourceError("read_view.not_requested", "package has not requested read views") }
            return Result.Ok(())
        }
        let plan = prepared.operationPlan.canonicalArguments.field("host_plan")
        let contribution = match (plan) { case Some(value) => httpIntentText(value, "contribution"); case None => "" }
        match (host.readViewInput(prepared, namespace, contribution, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        let readGranted = plan.getOrThrow().field("read_granted").getOrThrow().asBool()
        if (service == "process.readview" || (!readGranted && service == "file.plan.propose")) { return Result.Ok(()) }
        hostPluginResourceError("read_view.service_denied", "read-view invocation cannot escape its exact host resource services")
    }

    public func httpArguments(parent: NormalizedOperationPlan, arguments: AgentValue, requestId: String): Result<AgentValue> {
        if (!httpIntentExactFields(arguments, ["intent_id"]) ||
            httpIntentText(arguments, "intent_id") != requestId || !httpIntentIdentifier(requestId)) {
            return hostPluginResourceError("http.intent_identity_invalid", "HTTP request id must equal its sole frozen intent_id")
        }
        let descriptor = match (host.servicePackageData81(namespace, generation)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let bound = match (httpServiceChildArguments(parent.canonicalArguments, requestId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!descriptor.requestedCapabilities.contains("network.http") ||
            httpIntentText(bound, "plugin") != namespace ||
            httpIntentText(bound, "generation") != generation.toString() ||
            httpIntentText(bound, "package_digest") != descriptor.contentDigest) {
            return hostPluginResourceError("http.intent_identity_invalid", "HTTP intent does not belong to this active plugin instance")
        }
        Result.Ok(bound)
    }

    public func filePlanArguments(arguments: AgentValue): Result<AgentValue> {
        if (arguments.unifiedKind != ValueKind.Object || arguments.fields.size != 1 ||
            arguments.field("proposal").isNone()) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput,
                "extension.file_plan_arguments_invalid", "file.plan.propose accepts only proposal"))
        }
        let proposal = arguments.field("proposal").getOrThrow()
        match (hostValidatePluginFilePlanProposal(proposal)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let descriptor = match (host.servicePackageData81(namespace, generation)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(objectValue([
            ValueField("plugin", textValue(namespace)),
            ValueField("generation", textValue(generation.toString())),
            ValueField("package_digest", textValue(descriptor.contentDigest)),
            ValueField("proposal", proposal)
        ]))
    }

    public func processArguments(arguments: AgentValue): Result<AgentValue> {
        for (field in arguments.fields where
            field.name != "executable" && field.name != "arguments" && field.name != "timeout_ms") {
            return hostPluginResourceError("extension.process_arguments_invalid", "unknown process.readonly argument")
        }
        let descriptor = match (host.servicePackageData81(namespace, generation)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (hostValidatePluginProcessArguments(arguments)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        Result.Ok(objectValue([
            ValueField("plugin", textValue(namespace)),
            ValueField("generation", textValue(generation.toString())),
            ValueField("package_digest", textValue(descriptor.contentDigest)),
            ValueField("executable", arguments.field("executable").getOrThrow()),
            ValueField("arguments", arguments.field("arguments").getOrThrow()),
            ValueField("timeout_ms", match (arguments.field("timeout_ms")) {
                case Some(value) => value
                case None => integerValue(30000)
            })
        ]))
    }
}

public func hostRegisterPluginReadOnlyProcessService(
    catalog: ToolCatalog,
    host: HostJavaScriptPluginHost,
    operations: OperationRuntimePort,
    processes: ProcessPort
): Result<Unit> {
    catalog.register(ToolDescriptor(
        ModelToolDefinition(PLUGIN_READONLY_PROCESS_TOOL,
            "Run a fixed plugin package executable with read-only workspace access.",
            hostObjectSchema([
                hostSchemaProperty("plugin", "string"), hostSchemaProperty("generation", "string"),
                hostSchemaProperty("package_digest", "string"), hostSchemaProperty("executable", "string"),
                hostSchemaStringListProperty("arguments"), hostSchemaProperty("timeout_ms", "number")
            ], ["plugin", "generation", "package_digest", "executable", "arguments", "timeout_ms"])
        ),
        Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true,
        implementationVersion: "host-process-readonly-v1",
        implementationFingerprint: "host-process-readonly-v1",
        networkPolicyResolver: Some({ _ => Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied)) })
    ), HostPluginReadOnlyProcessExecutor(host, operations, processes))
}

// A host primitive, not a business dispatcher. Only an admitted child of an
// executing plugin root can reach it. The plugin chooses its own worker/argv;
// the host fixes package identity, isolation, accounting and result settlement.
public class HostPluginReadOnlyProcessExecutor <: ToolExecutor {
    private let host: HostJavaScriptPluginHost
    private let operations: OperationRuntimePort
    private let processes: ProcessPort

    init(host: HostJavaScriptPluginHost, operations: OperationRuntimePort, processes: ProcessPort) {
        this.host = host
        this.operations = operations
        this.processes = processes
    }

    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (prepared.source.kind != PreparedInvocationSourceKind.Derived ||
            prepared.source.parentOperationId.isNone() || prepared.source.operationRoot.isNone() ||
            prepared.call.name != PLUGIN_READONLY_PROCESS_TOOL ||
            prepared.operationPlan.effectClass != OperationEffectClass.ReadOnly ||
            !networkPolicyModeIsDenied(prepared.operationPlan.networkPolicy.mode)) {
            return hostPluginResourceError("extension.process_source_invalid", "process.readonly requires an admitted plugin child Operation")
        }
        let arguments = prepared.operationPlan.canonicalArguments
        match (hostValidatePluginProcessArguments(arguments)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let namespace = hostPluginReceiptText(arguments, "plugin")
        let generation = try { UInt64.parse(hostPluginReceiptText(arguments, "generation")) }
            catch (_: Exception) { return hostPluginResourceError("plugin.instance_stale", "invalid plugin instance generation") }
        let descriptor = match (host.servicePackageData81(namespace, generation)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let parentPlan = match (operations.loadPlan(prepared.source.parentOperationId.getOrThrow(), context.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (descriptor.contentDigest == "" ||
            descriptor.contentDigest != hostPluginReceiptText(arguments, "package_digest") ||
            parentPlan.implementation.implementationFingerprint != namespace + ":" + descriptor.contentDigest ||
            !parentPlan.toolName.startsWith("plugin." + namespace + ".")) {
            return hostPluginResourceError("extension.process_parent_mismatch", "worker package does not match the frozen parent Operation")
        }
        let packageMatches = match (host.registryPackageMatches81(descriptor.root, namespace: Some(namespace),
            version: Some(descriptor.version), digest: Some(descriptor.contentDigest))) {
            case Result.Err(_) => return hostPluginResourceError("plugin.snapshot_stale", "worker package is unavailable or changed")
            case Result.Ok(value) => value }
        if (!packageMatches) {
            return hostPluginResourceError("plugin.snapshot_stale", "worker package no longer matches its frozen snapshot")
        }
        let executable = match (hostResolvePluginProcessExecutable(descriptor.root, hostPluginReceiptText(arguments, "executable"))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let root = try { canonicalize(Path(context.workspaceRoot)).toString() }
            catch (_: Exception) { return hostPluginResourceError("extension.process_workspace_invalid", "workspace root is unavailable") }
        let argv = ArrayList<String>()
        for (value in arguments.field("arguments").getOrThrow().items) { argv.add(value.text) }
        var timeout = hostPluginProcessTimeout(arguments)
        if (context.cancellation.deadlineMillis > 0) {
            let remaining = context.cancellation.deadlineMillis - agentUtcMillis()
            if (remaining < 1) { return hostPluginResourceError("extension.cancelled", "parent invocation deadline elapsed") }
            if (remaining < timeout) { timeout = remaining }
        }
        let cancellation = CancellationSource(parent: Some(context.cancellation))
        let registration = match (host.observeServiceRevocation(namespace, generation, { => let _ = cancellation.cancel() })) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                cancellation.close()
                return Result.Err(error)
        }
        // Do not expose development toolchains, user settings, credentials or
        // environment to the worker. Runtime libraries must ship in its package.
        let boundedTimeout = timeout
        try {
            let scoped = hostPluginProcessCancellationContext(context, cancellation.token)
            let result = match (hostProcessOperations(processes, "plugin-readonly-worker").execute(scoped, prepared, { _ =>
                let admitted = match (processes as HostRegistryPackageProcessPort) {
                    case Some(value) => value
                    case None => return hostPluginResourceError("plugin.registry_package_worker_unsupported",
                        "the package worker port cannot retain the actual plugin registry launch admission")
                }
                admitted.executePackageReadOnlyWithRegistry(ProcessRequest(
                    executable, operationId: prepared.operationId, arguments: argv.toArray(),
                    workingDirectory: root, timeoutMillis: boundedTimeout,
                    sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
                    readOnlyMounts: [descriptor.root],
                    networkPolicy: Some(prepared.operationPlan.networkPolicy),
                    processLimits: hostPluginProcessLimits(context.budget.processLimits)
                ), root, { => host.enterRegistryEffect(namespace, generation) })
            })) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let output = objectValue([
                ValueField("exit_code", integerValue(result.exitCode)),
                ValueField("stdout", textValue(result.stdout)),
                ValueField("stderr", textValue(result.stderr)),
                ValueField("timed_out", boolValue(result.timedOut)),
                ValueField("truncated", boolValue(result.truncated))
            ])
            // Raw bytes and escaped JSON have different sizes. Keep enough
            // room for the broker and correlation envelopes in a 256 KiB frame.
            if (stringifyUnifiedJson(output).size > 196608) {
                return Result.Ok(ToolResult(prepared.call.callId, objectValue([
                    ValueField("code", textValue("extension.process_output_limit")),
                    ValueField("message", textValue("worker output exceeds the serialized service limit")),
                    ValueField("exit_code", integerValue(result.exitCode)),
                    ValueField("stdout", textValue("")), ValueField("stderr", textValue("")),
                    ValueField("timed_out", boolValue(result.timedOut)),
                    ValueField("truncated", boolValue(true))
                ]), isError: true))
            }
            Result.Ok(ToolResult(prepared.call.callId, output,
                isError: result.exitCode != 0 || result.timedOut || result.truncated))
        } finally {
            registration.dispose()
            cancellation.close()
        }
    }
}

public func hostValidatePluginProcessArguments(arguments: AgentValue): Result<Unit> {
    let executable = hostPluginReceiptText(arguments, "executable")
    if (!hostValidPluginProcessRelativePath(executable)) {
        return hostPluginResourceError("extension.process_executable_invalid", "worker executable must be a bounded package-relative path")
    }
    let argv = match (arguments.field("arguments")) {
        case Some(value) => value
        case None => return hostPluginResourceError("extension.process_arguments_invalid", "worker arguments must be an array")
    }
    if (argv.unifiedKind != ValueKind.List || argv.items.size > 128) {
        return hostPluginResourceError("extension.process_arguments_invalid", "worker arguments must contain at most 128 strings")
    }
    var bytes: Int64 = 0
    for (value in argv.items) {
        if (value.unifiedKind != ValueKind.Text || value.text.contains("\u{0000}")) {
            return hostPluginResourceError("extension.process_arguments_invalid", "worker arguments must be NUL-free strings")
        }
        bytes += value.text.size
        if (bytes > 65536) { return hostPluginResourceError("extension.process_arguments_invalid", "worker argv exceeds 64 KiB") }
    }
    let timeout = hostPluginProcessTimeout(arguments)
    if (timeout < 1 || timeout > 60000) {
        return hostPluginResourceError("extension.process_timeout_invalid", "worker timeout_ms must be an integer from 1 to 60000")
    }
    Result.Ok(())
}

public func hostPluginProcessTimeout(arguments: AgentValue): Int64 {
    match (arguments.field("timeout_ms")) {
        case None => 30000
        case Some(value) => if (value.unifiedKind != ValueKind.Number) { -1 }
            else { try { Int64.parse(value.asNumberText()) } catch (_: Exception) { -1 } }
    }
}

public func hostValidPluginProcessRelativePath(value: String): Bool {
    if (value == "" || value.size > 4096 || value.startsWith("/") ||
        value.contains("\\") || value.contains(":") || value.contains("\u{0000}")) { return false }
    for (part in value.split("/")) { if (part == "" || part == "." || part == "..") { return false } }
    true
}

public func hostResolvePluginProcessExecutable(root: String, relative: String): Result<String> {
    if (!hostValidPluginProcessRelativePath(relative)) {
        return hostPluginResourceError("extension.process_executable_invalid", "worker executable must remain inside its package")
    }
    try {
        let canonicalRoot = canonicalize(Path(root)).toString()
        var path = Path(canonicalRoot)
        for (part in relative.split("/")) {
            path = path.join(part)
            if (FileInfo(path).isSymbolicLink()) {
                return hostPluginResourceError("extension.process_executable_invalid", "worker path may not traverse symbolic links")
            }
        }
        let info = FileInfo(path)
        let resolved = canonicalize(path).toString()
        if (!info.isRegular() || !info.canExecute() || !resolved.startsWith(canonicalRoot + "/")) {
            return hostPluginResourceError("extension.process_executable_invalid", "worker must be an executable regular file in its package")
        }
        Result.Ok(resolved)
    } catch (_: Exception) {
        hostPluginResourceError("extension.process_executable_invalid", "worker executable is unavailable")
    }
}

public func hostPluginProcessLimits(requested: ExecutionResourceLimits): ExecutionResourceLimits {
    ExecutionResourceLimits(
        maxOutputBytes: if (requested.maxOutputBytes > 0 && requested.maxOutputBytes < PLUGIN_READONLY_PROCESS_OUTPUT_BYTES) {
            requested.maxOutputBytes
        } else { PLUGIN_READONLY_PROCESS_OUTPUT_BYTES },
        addressSpaceBytes: requested.addressSpaceBytes, fileSizeBytes: requested.fileSizeBytes,
        openFiles: requested.openFiles, processes: requested.processes, cpuSeconds: requested.cpuSeconds
    )
}

public func hostPluginProcessCancellationContext(context: ToolInvocationContext, cancellation: CancellationToken): ToolInvocationContext {
    ToolInvocationContext(context.runId, context.sessionId, context.capabilities,
        epoch: context.epoch, toolContext: ToolContextDescriptor(
            workspaceRoot: context.workspaceRoot, cwd: context.workspaceRoot
        ), cancellation: cancellation, budget: context.budget,
        budgetModeFn: context.budgetModeFn, outputSink: context.outputSink,
        contextProjection: context.contextProjection, toolSetSnapshot: context.toolSetSnapshot
    )
}


