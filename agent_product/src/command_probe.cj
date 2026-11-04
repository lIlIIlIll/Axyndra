package agent_product

import yjson.*
import yjson_support.*

import agent_domain.*
import agent_host_runtime.*
import agent_ports.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.convert.*
import process4cj.*
import sandbox4cj.*

// A probe owns exactly one direct executable invocation. Status is supplied
// by the process boundary; stdout is never interpreted as a status protocol.
func registerCommandProbeTool(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    shellNetworkMode: ShellNetworkMode
): Result<Unit> {
    catalog.register(ToolDescriptor(ModelToolDefinition(
        "command_probe",
        "Run one executable and argv with a runtime deadline. Networked probes accept trusted curl HTTPS GET or npm view/install only. " +
            "curl argv: --disable --fail --silent --show-error --proto =https -- URL. " +
            "npm install requires --ignore-scripts --no-save --no-audit --no-fund, one fixed registry package version, and an empty approved cwd prefix. " +
            "No shell, scripts, async, pty or environment overrides for networked commands. " +
            "Offline readonly_workspace=true enforces a read-only source tree for verification commands.",
        objectSchema([
            schemaProperty("executable", "string"),
            schemaStringListProperty("argv"),
            schemaProperty("cwd", "string"),
            schemaProperty("timeout", "number"),
            schemaProperty("readonly_workspace", "boolean"),
            schemaNetworkPolicyProperty()
        ], ["executable", "argv"])),
        Capability(CapabilityKind.ProcessSpawn),
        sideEffecting: true,
        sideEffectResolver: Some({call => commandProbeSideEffecting(call)}),
        supervisedExecutionSafe: true,
        coreMetadataResolverClosed204: true,
        canonicalArgumentsResolver: Some({_,call => processToolCanonicalArguments(call, workspace)}),
        networkPolicyResolver: Some({call => commandProbeNetworkPolicy(call, shellNetworkMode)})
    ), CommandProbeTool(workspace, processes))
}

func processToolCanonicalArguments(call: ToolCall, workspace: LocalWorkspace): Result<AgentValue> {
    if (call.arguments.field("cwd").isNone()) { return Result.Ok(call.arguments) }
    let requested = optionalString(call, "cwd", "")
    let cwd = match (workspace.resolve(
        if (requested == "") { workspace.rootPath() } else { requested }, allowDirectory: true
    )) {
        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
    }
    let fields = ArrayList<ValueField>()
    for (field in call.arguments.fields where field.name != "cwd") { fields.add(field) }
    fields.add(ValueField("cwd", textValue(cwd)))
    Result.Ok(objectValue(fields.toArray()))
}

func commandProbeNetworkPolicy(call: ToolCall, shellNetworkMode: ShellNetworkMode): Result<NetworkPolicy> {
    let policy = match (call.arguments.field("network")) {
        case Some(value) => match (parseNetworkPolicy(value)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        case None => NetworkPolicy(NetworkPolicyMode.Denied)
    }
    if (optionalBoolean(call, "readonly_workspace", false) && !networkPolicyModeIsDenied(policy.mode)) {
        return probeInputError<NetworkPolicy>("readonly_workspace is supported only for offline probes")
    }
    if (shellNetworkMode == ShellNetworkMode.Proxy && networkPolicyModeIsHost(policy.mode)) {
        return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
            "network.mode_denied", "proxy shell mode forbids HostNetwork"))
    }
    if (!policy.publish.isEmpty()) {
        return Result.Err(AgentError(AgentErrorKind.InvalidInput,
            "network.publish_not_supported", "command probes cannot publish mediated ports"))
    }
    match (commandProbeTimeout(call)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
    }
    // Resolve the controlled command before asking for network approval.
    match (commandProbeArguments(call)) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(arguments) =>
            match (commandProbeExecutable(call, arguments, policy)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => ()
            }
    }
    Result.Ok(policy)
}

func commandProbeTimeout(call: ToolCall): Result<Int64> {
    var seconds: Int64 = 60
    match (call.arguments.field("timeout")) {
        case Some(value) =>
            if (value.unifiedKind != ValueKind.Number) {
                return probeInputError<Int64>("timeout must be an integer number of seconds")
            }
            try { seconds = Int64.parse(value.asNumberText()) }
            catch (_: Exception) { return probeInputError<Int64>("timeout must be an integer number of seconds") }
        case None => ()
    }
    if (seconds < 1 || seconds > 600) { return probeInputError<Int64>("timeout must be 1 through 600 seconds") }
    Result.Ok(seconds)
}

func commandProbeArguments(call: ToolCall): Result<Array<String>> {
    let value = match (call.arguments.field("argv")) {
        case Some(item) => item
        case None => return probeInputError<Array<String>>("argv must be a string list")
    }
    if (value.unifiedKind != ValueKind.List || value.items.size > 256) {
        return probeInputError<Array<String>>("argv must be a string list of at most 256 items")
    }
    let arguments = ArrayList<String>()
    for (item in value.items) {
        if (item.unifiedKind != ValueKind.Text || item.text.contains("\u{0000}")) {
            return probeInputError<Array<String>>("argv entries must be strings without NUL")
        }
        arguments.add(item.text)
    }
    Result.Ok(arguments.toArray())
}

func commandProbeExecutable(call: ToolCall, arguments: Array<String>, policy: NetworkPolicy): Result<String> {
    let executable = match (requiredString(call, "executable")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (networkPolicyModeIsDenied(policy.mode)) {
        if (!Path(executable).isAbsolute() || executable.contains("\u{0000}")) {
            return probeInputError<String>("offline probes require an absolute executable path")
        }
        return Result.Ok(executable)
    }
    // Do not search a workspace-controlled PATH or accept a same-named
    // wrapper. These host-owned entry points are mounted read-only by the
    // sandbox. Exact argv remains part of the approved Operation arguments.
    let name = if (executable == "curl" || executable == "/usr/bin/curl") { "curl" }
        else if (executable == "npm" || executable == "/usr/bin/npm") { "npm" }
        else { "" }
    if (name == "" || !validNetworkProbeArguments(name, arguments)) {
        return probeInputError<String>("networked probes require a controlled curl or npm invocation")
    }
    let path = "/usr/bin/" + name
    if (!exists(Path(path))) {
        return Result.Err(AgentError(AgentErrorKind.Configuration,
            "probe.dependency_unavailable", "the trusted probe executable is unavailable",
            fields: [ErrorField("failure_class", "dependency_unavailable"), ErrorField("started", "false")]))
    }
    Result.Ok(path)
}

func commandProbeSideEffecting(call: ToolCall): Bool {
    if (optionalBoolean(call, "readonly_workspace", false)) { return false }
    let arguments = match (commandProbeArguments(call)) {
        case Result.Ok(value) => value; case Result.Err(_) => return true
    }
    let executable = optionalString(call, "executable", "")
    if ((executable == "curl" || executable == "/usr/bin/curl") &&
        validNetworkProbeArguments("curl", arguments)) { return false }
    (executable != "npm" && executable != "/usr/bin/npm") ||
        arguments.isEmpty() || arguments[0] != "view" || !validNetworkProbeArguments("npm", arguments)
}

func validNetworkProbeArguments(name: String, arguments: Array<String>): Bool {
    if (name == "curl") {
        let prefix = ["--disable", "--fail", "--silent", "--show-error", "--proto", "=https", "--"]
        if (arguments.size != prefix.size + 1) { return false }
        for (index in 0..prefix.size where arguments[index] != prefix[index]) { return false }
        let url = arguments[prefix.size]
        return url.startsWith("https://") && url.size > 8 && !url.contains("@") &&
            !url.contains("\n") && !url.contains("\r") && !url.contains(" ")
    }
    if (name != "npm") { return false }
    if (arguments.size == 3 && arguments[0] == "view" && arguments[2] == "version") {
        return validProbePackage(arguments[1], false)
    }
    let prefix = ["install", "--ignore-scripts", "--no-save", "--no-audit", "--no-fund"]
    if (arguments.size != prefix.size + 1) { return false }
    for (index in 0..prefix.size where arguments[index] != prefix[index]) { return false }
    validProbePackage(arguments[prefix.size], true)
}

func validProbePackage(value: String, fixedVersion: Bool): Bool {
    if (value == "" || value.size > 256) { return false }
    var separator: Int64 = -1
    for (index in 1..value.size where value[index] == b'@') {
        if (separator != -1) { return false }
        separator = index
    }
    let name = if (separator == -1) { value } else { value[..separator] }
    if (name.size > 214) { return false }
    if (name.startsWith("@")) {
        var slashes: Int64 = 0
        for (byte in unsafe { name.rawData() } where byte == b'/') { slashes += 1 }
        let parts = name[1..].split("/")
        if (slashes != 1 || parts.size != 2 || !validProbePackageNamePart(parts[0]) ||
            !validProbePackageNamePart(parts[1])) { return false }
    } else if (!validProbePackageNamePart(name) || name.endsWith(".tgz") ||
        name.endsWith(".tar.gz") || name.endsWith(".tar")) { return false }
    if (separator == -1) { return !fixedVersion }
    let version = value[separator + 1..]
    var dots: Int64 = 0
    for (byte in unsafe { version.rawData() } where byte == b'.') { dots += 1 }
    let numbers = version.split(".")
    if (dots != 2 || numbers.size != 3) { return false }
    for (number in numbers) {
        if (number == "" || (number.size > 1 && number[0] == b'0')) { return false }
        for (byte in unsafe { number.rawData() } where byte < b'0' || byte > b'9') { return false }
        try { if (Int64.parse(number) > 9007199254740991) { return false } }
        catch (_: Exception) { return false }
    }
    true
}

func validProbePackageNamePart(value: String): Bool {
    if (value == "" || value == "node_modules" || value == "favicon.ico" ||
        !((value[0] >= b'a' && value[0] <= b'z') || (value[0] >= b'0' && value[0] <= b'9'))) { return false }
    for (byte in unsafe { value.rawData() }) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'0' && byte <= b'9') ||
            byte == b'-' || byte == b'_' || byte == b'.')) { return false }
    }
    true
}

func validateFreshNpmProbePrefix(cwd: String): Result<Unit> {
    try {
        // An explicit --prefix prevents npm's ancestor/workspace discovery.
        // Requiring a fresh directory also excludes existing manifests,
        // shrinkwraps, locks, node_modules and project .npmrc configuration.
        for (_ in Directory.readFrom(cwd)) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput,
                "probe.npm_prefix_not_fresh", "npm install requires an empty approved prefix directory"))
        }
        Result.Ok(())
    } catch (_: Exception) {
        probeInputError<Unit>("npm install prefix must be a readable empty directory")
    }
}

func commandProbeEffectiveArguments(
    executable: String, arguments: Array<String>, policy: NetworkPolicy, cwd: String,
    workspaceRoot!: String = ""
): Result<Array<String>> {
    if (networkPolicyModeIsDenied(policy.mode)) { return Result.Ok(arguments) }
    if (executable == "/usr/bin/curl") {
        // --disable must be argv[0]; later occurrences do not suppress the
        // implicit HOME/cwd curl configuration load.
        return Result.Ok(["--disable", "--fail", "--silent", "--show-error", "--proto", "=https",
            "--proto-redir", "=https", "--", arguments[arguments.size - 1]])
    }
    if (npmProbePrivatePathsOverlapWorkspace(if (workspaceRoot == "") { cwd } else { workspaceRoot })) {
        return Result.Err(AgentError(AgentErrorKind.Configuration,
            "probe.private_storage_unavailable", "controlled npm probes require private configuration storage outside the workspace",
            fields: [ErrorField("failure_class", "infrastructure_unavailable"),
                ErrorField("stage", "npm_private_storage_overlap"), ErrorField("started", "false")]))
    }
    let install = arguments[0] == "install"
    if (install) {
        match (validateFreshNpmProbePrefix(cwd)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
    }
    let effective = ArrayList<String>()
    effective.add(all: arguments)
    effective.add(all: [
        "--prefix=" + (if (install) { cwd } else { "/tmp/axyndra-npm-probe-prefix" }),
        "--userconfig=/tmp/axyndra-npm-probe-user.npmrc", "--globalconfig=/tmp/axyndra-npm-probe-global.npmrc", "--global=false", "--workspaces=false",
        "--git=/usr/bin/false", "--script-shell=/usr/bin/false", "--ignore-scripts",
        "--no-audit", "--no-fund", "--no-update-notifier", "--package-lock=false",
        "--registry=https://registry.npmjs.org/", "--replace-registry-host=always", "--fetch-retries=0",
        "--cache=/tmp/axyndra-npm-probe-cache", "--logs-dir=/tmp/axyndra-npm-probe-logs"
    ])
    Result.Ok(effective.toArray())
}

func npmProbePrivatePathsOverlapWorkspace(workspaceRoot: String): Bool {
    let root = Path(workspaceRoot).normalize().toString()
    for (path in ["/tmp/axyndra-npm-probe-prefix", "/tmp/axyndra-npm-probe-user.npmrc",
        "/tmp/axyndra-npm-probe-global.npmrc", "/tmp/axyndra-npm-probe-cache", "/tmp/axyndra-npm-probe-logs"]) {
        if (root == "/" || path == root || path.startsWith(root + "/") || root.startsWith(path + "/")) { return true }
    }
    false
}

func commandProbeFallbackAllowed(
    call: ToolCall, policy: NetworkPolicy, result: ProcessResult, writeRoots: Array<String>
): Bool {
    if (networkPolicyModeIsDenied(policy.mode) || !result.started ||
        (!result.timedOut && result.exitCode == 0)) { return false }
    let name = optionalString(call, "executable", "")
    let arguments = match (commandProbeArguments(call)) {
        case Result.Ok(value) => value; case Result.Err(_) => return false
    }
    let controlled = if (name == "npm" || name == "/usr/bin/npm") {
        validNetworkProbeArguments("npm", arguments)
    } else if (name == "curl" || name == "/usr/bin/curl") {
        validNetworkProbeArguments("curl", arguments)
    } else { false }
    controlled && (!commandProbeSideEffecting(call) || !writeRoots.isEmpty())
}

func probeInputError<T>(message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, "probe.arguments_invalid", message))
}

class CommandProbeTool <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let processes: LocalProcessPort
    private let operations: ProductProcessOperations
    init(workspace: LocalWorkspace, processes: LocalProcessPort) {
        this.workspace = workspace
        this.processes = processes
        this.operations = processOperations(processes, "command-probe")
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        prepared.withCall204({ originalCall => prepared.withOperationPlan204({ plan =>
            prepared.withApproval204({ approval => executePlanFrame204(context, prepared, originalCall, plan, approval) })
        }) })
    }

    private func executePlanFrame204(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        originalCall: ToolCall, plan: NormalizedOperationPlan, approval: ?ApprovalRequest): Result<ToolResult> {
        if (!commandProbeAuthorizationAllowed(prepared.authorization)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "probe.authorization_mode_denied", "command probes require their own canonical operation authorization"))
        }
        let call = ToolCall(originalCall.callId, originalCall.name, plan.canonicalArguments)
        let arguments = match (commandProbeArguments(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let policy = plan.networkPolicy
        let executable = match (commandProbeExecutable(call, arguments, policy)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let seconds = match (commandProbeTimeout(call)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        let cwd = match (workspace.resolve(plan.cwd, allowDirectory: true)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let effectiveArguments = match (commandProbeEffectiveArguments(executable, arguments, policy, cwd,
            workspaceRoot: workspace.rootPath())) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        let result = match (operations.execute(context, prepared, {id => processes.executeProbe(ProcessRequest(
            executable, resourceOwner: Some(ProcessResourceOwner.Operation(id)), arguments: effectiveArguments, workingDirectory: cwd,
            timeoutMillis: seconds * 1000,
            sandboxMode: if (commandProbeSideEffecting(call)) { ProcessSandboxMode.WorkspaceReadWrite }
                else { ProcessSandboxMode.WorkspaceReadOnly },
            networkPolicy: Some(policy), processLimits: context.budget.processLimits,
            approvedWriteRoots: plan.approvedWriteRoots
        ))})) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(ToolResult(commandProbeResultString204(call.callId), objectValue([
            ValueField("command", textValue(commandProbeResultString204(executable))),
            ValueField("argv", listValue(Array<AgentValue>(effectiveArguments.size,
                {index => textValue(commandProbeResultString204(effectiveArguments[index]))}))),
            ValueField("internal_retry_limit", if (!networkPolicyModeIsDenied(policy.mode)) {
                integerValue(0)
            } else { nullValue() }),
            ValueField("started", boolValue(result.started)),
            ValueField("start_boundary", textValue("target_exec_acknowledgement")),
            ValueField("completed", boolValue(result.completed)),
            ValueField("target_stopped", boolValue(true)),
            ValueField("fallback_allowed", boolValue(commandProbeFallbackAllowed(call, policy, result,
                plan.approvedWriteRoots))),
            ValueField("launch_errno", integerValue(result.launchErrno)),
            ValueField("exit_code", integerValue(result.exitCode)),
            ValueField("timed_out", boolValue(result.timedOut)),
            ValueField("stdout", textValue(result.stdout)),
            ValueField("stderr", textValue(result.stderr)),
            ValueField("truncated", boolValue(result.truncated)),
            ValueField("network_policy", commandProbeResultPolicy204(policy)),
            ValueField("actual_network_mode", textValue(networkPolicyModeName(policy.mode))),
            ValueField("policy_source", textValue("frozen_operation_plan")),
            ValueField("authorization_source", textValue(commandProbeAuthorizationSource(prepared.authorization))),
            ValueField("approval_argument_hash", textValue(match (approval) {
                case Some(approval) => commandProbeResultString204(approval.argumentHash); case None => ""
            })),
            ValueField("operation_id", textValue(commandProbeResultString204(prepared.operationId.value))),
            ValueField("actual_isolation", textValue("workspace_sandbox")),
            ValueField("failure_class", textValue(if (!result.started) { "dependency_unavailable" }
                else if (result.timedOut) { "timeout" }
                else if (result.exitCode != 0) { "command_failed" } else { "" }))
        ]), isError: !result.started || result.exitCode != 0 || result.timedOut, receiptId: commandProbeResultString204(prepared.operationId.value)))
    }
    public func cancel(runId: RunId): Result<Unit> { operations.cancel(runId) }
}

// The output uses the existing ToolResult payload owner. Do not place a
// borrowed metadata String in that independently retained result graph.
func commandProbeResultString204(value: String): String { String.fromUtf8(value.toArray()) }

func commandProbeResultPolicy204(policy: NetworkPolicy): AgentValue {
    let rules = Array<NetworkEgressRule>(policy.egress.size, { index =>
        let rule = policy.egress[index]
        NetworkEgressRule(commandProbeResultString204(rule.host), rule.port,
            privateAddresses: Array<String>(rule.privateAddresses.size,
                { address => commandProbeResultString204(rule.privateAddresses[address]) }))
    })
    let published = Array<NetworkPublishRule>(policy.publish.size,
        { index => NetworkPublishRule(policy.publish[index].hostPort, policy.publish[index].targetPort) })
    networkPolicyCanonicalValue(NetworkPolicy(policy.mode, egress: rules, publish: published))
}

func commandProbeAuthorizationAllowed(authorization: PreparedAuthorization): Bool {
    match (authorization) {
        case PreparedAuthorization.StaticPolicy => true
        case PreparedAuthorization.SessionGrant => true
        case PreparedAuthorization.Approved => true
        case PreparedAuthorization.ApprovalRequired => false
        case PreparedAuthorization.ParentIntent => false
        case PreparedAuthorization.ManagedJob => false
    }
}

func commandProbeAuthorizationSource(authorization: PreparedAuthorization): String {
    match (authorization) {
        case PreparedAuthorization.StaticPolicy => "static_policy"
        case PreparedAuthorization.SessionGrant => "session_grant"
        case PreparedAuthorization.Approved => "operation_approval"
        case PreparedAuthorization.ApprovalRequired => "approval_required"
        case PreparedAuthorization.ParentIntent => "parent_intent"
        case PreparedAuthorization.ManagedJob => "managed_job"
    }
}

// Only the trusted helper owns this frame. Target stdout and stderr are
// length-delimited payloads behind private child capture pipes, not headers.
func decodeCommandProbeFrame(bytes: Array<Byte>, cwd: String, redactor: SecretRedactor): Result<ProcessResult> {
    hostDecodeCommandProbeFrame(bytes, cwd, redactor)
}
