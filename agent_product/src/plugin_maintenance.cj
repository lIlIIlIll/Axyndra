package agent_product

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import yjson.*
import yjson_support.*

func pluginAcquisitionAdditionalCapabilities(call: ToolCall): Array<Capability> {
    match (call.arguments.field("workspace_read_root")) {
        case Some(value) => if (value.unifiedKind == ValueKind.Text && value.text != "") {
            [Capability(CapabilityKind.WorkspaceRead, resource: value.text)]
        } else { [] }
        case None => []
    }
}

func pluginMaintenanceNetworkPolicy(mode: ShellNetworkMode, call: ToolCall): Result<NetworkPolicy> {
    let declared = match (call.arguments.field("network")) {
        case Some(value) => value
        case None => return Result.Err(AgentError(
            AgentErrorKind.InvalidInput, "plugin.acquisition_network_required",
            "plugin acquisition requires an explicit network policy"
        ))
    }
    let policy = match (parseNetworkPolicy(declared)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    controlledProcessNetworkPolicy(mode, Some(policy))
}

func registerPluginAcquisitionTool(
    catalog: ToolCatalog,
    settingsRoot: String,
    workspaceRoot: String,
    sandboxCaBundle: String,
    shellNetworkMode: ShellNetworkMode
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "plugin_acquisition", "Internal approved plugin source acquisition.",
                objectSchema([
                    schemaProperty("command", "string"),
                    schemaProperty("timeout", "number"),
                    schemaProperty("pty", "boolean"),
                    schemaProperty("async", "boolean"),
                    schemaProperty("workspace_read_root", "string"),
                    schemaNetworkPolicyProperty()
                ], ["command", "network"])
            ),
            Capability(CapabilityKind.ProcessSpawn), sideEffecting: true, controlOnly: true,
            implementationVersion: "plugin-acquisition-v3",
            implementationFingerprint: "host-owned-plugin-maintenance-v3",
            additionalCapabilityResolver: Some({ call => pluginAcquisitionAdditionalCapabilities(call) }),
            networkPolicyResolver: Some({ call => pluginMaintenanceNetworkPolicy(shellNetworkMode, call) })
        ),
        PluginAcquisitionTool(settingsRoot, workspaceRoot, sandboxCaBundle)
    )
}

// Host-owned maintenance uses the same canonical prepared execution and process
// primitives as tools, without requiring a Shell tool, persistent session, model
// plugin or plugin-provided installer. Commands are authored by SourceAcquirer.
class PluginAcquisitionTool <: ToolExecutor {
    private let settingsRoot: String
    private let workspaceRoot: String
    private let sandboxCaBundle: String
    private let activeLock = Mutex()
    private let active = ArrayList<(String, ProductProcessOperations)>()

    init(settingsRoot: String, workspaceRoot: String, sandboxCaBundle: String) {
        this.settingsRoot = settingsRoot
        this.workspaceRoot = workspaceRoot
        this.sandboxCaBundle = sandboxCaBundle
    }

    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        match (context.cancellation.check()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let call = ToolCall(prepared.call.callId, prepared.call.name, prepared.operationPlan.canonicalArguments)
        for (name in ["async", "pty"]) {
            match (call.arguments.field(name)) {
                case Some(value) => if (value.unifiedKind != ValueKind.Boolean || value.asBool()) {
                    return Result.Err(AgentError(
                        AgentErrorKind.InvalidInput, "plugin.acquisition_execution_mode_invalid",
                        "plugin acquisition must use synchronous non-PTY execution"
                    ))
                }
                case None => ()
            }
        }
        let command = match (requiredString(call, "command")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (command.trimAscii() == "") {
            return invalidArgument(call, "command", "maintenance command must not be empty")
        }
        let timeoutSeconds = optionalInteger(call, "timeout", 60)
        if (timeoutSeconds < 0 || timeoutSeconds > 600) {
            return invalidArgument(call, "timeout", "timeout must be between 0 and 600 seconds")
        }
        let timeoutMillis = if (timeoutSeconds == 0) { 600000 } else { timeoutSeconds * 1000 }
        let root = match (productPluginAcquisitionRoot(settingsRoot, workspaceRoot)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return Result.Err(AgentError(
                AgentErrorKind.Configuration, error.code, error.message
            ))
        }
        let plannedRoot = try {
            canonicalize(Path(prepared.operationPlan.cwd)).toString()
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration, "plugin.acquisition_plan_root_invalid", error.message
            ))
        }
        let contextRoot = try {
            canonicalize(Path(context.workspaceRoot)).toString()
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration, "plugin.acquisition_context_root_invalid", error.message
            ))
        }
        if (plannedRoot != root || contextRoot != root) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied, "plugin.acquisition_root_mismatch",
                "plugin acquisition execution is not bound to host-owned staging"
            ))
        }
        let readOnlyRoots = ArrayList<String>()
        for (required in prepared.operationPlan.requiredCapabilities) {
            if (required.kind == CapabilityKind.WorkspaceRead && required.resource == workspaceRoot) {
                readOnlyRoots.add(workspaceRoot)
            }
        }
        let processes = match (createProductProcessPort(
            LocalWorkspace(root), sandboxCaBundle, settingsRoot,
            additionalReadOnlyRoots: readOnlyRoots.toArray()
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let operations = processOperations(processes, "plugin-maintenance")
        activeLock.lock()
        try { active.add((prepared.operationId.value, operations)) } finally { activeLock.unlock() }
        try {
            let request = ProcessRequest(
                "/bin/bash", operationId: prepared.operationId,
                arguments: ["--noprofile", "--norc", "-c", command],
                workingDirectory: root, timeoutMillis: timeoutMillis,
                sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
                networkPolicy: Some(prepared.operationPlan.networkPolicy),
                processLimits: context.budget.processLimits
            )
            let result = match (operations.execute(context, prepared, { _ => processes.execute(request) })) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let captured = captureProductProcessArtifacts(Option<ProductArtifactStore>.None, result.stdout, result.stderr)
            Result.Ok(ToolResult(
                call.callId,
                objectValue([
                    ValueField("exit_code", integerValue(result.exitCode)),
                    ValueField("stdout", textValue(captured.stdout.preview)),
                    ValueField("stderr", textValue(captured.stderr.preview)),
                    ValueField("stdout_bytes", integerValue(captured.stdout.bytes)),
                    ValueField("stderr_bytes", integerValue(captured.stderr.bytes)),
                    ValueField("artifacts", captured.artifactsValue()),
                    ValueField("artifact_error", captured.errorValue()),
                    ValueField("timed_out", boolValue(result.timedOut)),
                    ValueField("truncated", boolValue(result.truncated || captured.stdout.truncated || captured.stderr.truncated)),
                    ValueField("cwd", textValue(result.workingDirectory)),
                    ValueField("pty", boolValue(false))
                ]),
                isError: result.exitCode != 0 || result.timedOut,
                receiptId: prepared.operationId.value
            ))
        } finally {
            activeLock.lock()
            try {
                for (index in 0..active.size where active[index][0] == prepared.operationId.value) {
                    active.remove(at: index)
                    break
                }
            } finally { activeLock.unlock() }
            let _ = processes.close()
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        activeLock.lock()
        let registrations = try { active.toArray() } finally { activeLock.unlock() }
        var failure: ?AgentError = None
        for (registration in registrations) {
            match (registration[1].cancel(runId)) {
                case Result.Err(error) => if (failure.isNone()) { failure = Some(error) }
                case Result.Ok(_) => ()
            }
        }
        match (failure) { case Some(error) => Result.Err(error); case None => Result.Ok(()) }
    }
}
