package agent_product

import agent_domain.*
import agent_ports.*
import process4cj.*
import sandbox4cj.*
import std.collection.*
import std.env.*
import std.fs.*
import std.sync.*

// Direct-launch runtimes (LSP, DAP, and the process supervisor) cannot use
// ProcessRequest because their children outlive one request.  They still use
// exactly the same WorkspaceSandbox plan; only the one-shot timeout wrapper is
// intentionally omitted so the owning runtime controls cancellation/reaping.
class DirectEnvironmentBinding {
    let target: String
    let source: String
    let secret: Bool

    init(target: String, source: String, secret!: Bool = false) {
        if (!validEnvironmentName(target) || !validEnvironmentName(source)) {
            throw IllegalArgumentException("environment mappings require valid variable names")
        }
        if (!secret && (directSecretName(target) || directSecretName(source))) {
            throw IllegalArgumentException(
                "secret-like environment mappings must be declared in secret_env"
            )
        }
        this.target = target
        this.source = source
        this.secret = secret
    }
}

class DirectResolvedEnvironment {
    let entries: Array<SandboxEnvironmentEntry>
    let secretTargets: Array<String>
    let secretValues: Array<String>
    let redactor: SecretRedactor

    init(
        entries: Array<SandboxEnvironmentEntry>,
        secretTargets: Array<String>,
        secretValues: Array<String>
    ) {
        this.entries = entries
        this.secretTargets = secretTargets
        this.secretValues = secretValues
        this.redactor = SecretRedactor(secretValues)
    }
}

class DirectNetworkLease {
    let gateway: NetworkGatewayPort
    let lease: NetworkGatewayLease

    init(gateway: NetworkGatewayPort, lease: NetworkGatewayLease) {
        this.gateway = gateway
        this.lease = lease
    }

    func release(): Unit {
        let _ = gateway.release(lease)
    }
}

class DirectProcessHandle {
    let process: ManagedProcess
    let redactor: SecretRedactor
    let secretValues: Array<String>
    let sandboxed: Bool
    private let releaseAction: () -> Unit
    private let releaseLock = Mutex()
    private var released = false

    init(
        process: ManagedProcess,
        redactor: SecretRedactor,
        secretValues: Array<String>,
        sandboxed: Bool,
        releaseAction!: () -> Unit = { => () }
    ) {
        this.process = process
        this.redactor = redactor
        this.secretValues = secretValues
        this.sandboxed = sandboxed
        this.releaseAction = releaseAction
    }

    func release(): Unit {
        var shouldRelease = false
        releaseLock.lock()
        try {
            if (!released) {
                released = true
                shouldRelease = true
            }
        } finally {
            releaseLock.unlock()
        }
        if (shouldRelease) { releaseAction() }
    }
}

func launchDirectPersistentProcess(
    workspaceRoot: String,
    sandboxEnabled: Bool,
    allowUnsafeTestBypass: Bool,
    filesystem: FilesystemIsolationMode,
    networkPolicy: NetworkPolicy,
    executable: String,
    arguments: Array<String>,
    cwd: String,
    bindings!: Array<DirectEnvironmentBinding> = [],
    literalEnvironment!: Array<SandboxEnvironmentEntry> = [],
    sandboxCaBundle!: String = "",
    errorCode!: String = "direct.process_start_failed"
): Result<DirectProcessHandle> {
    let caBundle = sandboxCaBundle.trimAscii()
    let resolved = match (resolveDirectEnvironment(bindings, literalEnvironment)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (networkPolicyModeIsMediated(networkPolicy.mode) && !sandboxEnabled) {
        return Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "sandbox.direct_launch_disabled",
            "mediated persistent process launch requires the workspace sandbox"
        ))
    }
    if (!sandboxEnabled && !allowUnsafeTestBypass) {
        return Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "sandbox.direct_launch_disabled",
            "model-visible direct process launch requires the workspace sandbox"
        ))
    }
    if (!sandboxEnabled) {
        try {
            let process = startProcess(ProcessCommand(
                executable,
                arguments: arguments,
                workingDirectory: cwd,
                environment: directHostEnvironment(workspaceRoot, resolved.entries)
            ))
            return Result.Ok(DirectProcessHandle(
                process,
                resolved.redactor,
                resolved.secretValues,
                false
            ))
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.Transport,
                errorCode,
                resolved.redactor.redact(error.message)
            ))
        }
    }

    let sandboxEnvironment = ArrayList<SandboxEnvironmentEntry>()
    for (entry in resolved.entries) { sandboxEnvironment.add(entry) }
    let configuredNames = ArrayList<String>()
    for (entry in resolved.entries) { configuredNames.add(entry.name) }
    var caMount: ?SandboxReadOnlyMount = None
    if (caBundle != "") {
        if (directContains(configuredNames, "SSL_CERT_FILE") ||
            directContains(configuredNames, "CURL_CA_BUNDLE")) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "sandbox.environment_duplicate",
                "configured CA bundle variables cannot be overridden"
            ))
        }
        try {
            caMount = Some(SandboxReadOnlyMount(caBundle))
            sandboxEnvironment.add(SandboxEnvironmentEntry("SSL_CERT_FILE", caBundle))
            sandboxEnvironment.add(SandboxEnvironmentEntry("CURL_CA_BUNDLE", caBundle))
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "sandbox.ca_unavailable",
                resolved.redactor.redact(error.message)
            ))
        }
    }
    let networkLease = match (acquireDirectNetworkLease(networkPolicy)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let allowedNames = ArrayList<String>()
    for (entry in sandboxEnvironment) { allowedNames.add(entry.name) }
    let toolchain = configuredProductSandboxToolchain()
    let mounts = ArrayList<SandboxReadOnlyMount>()
    for (mount in toolchain.mounts) { mounts.add(mount) }
    match (caMount) {
        case Some(value) => mounts.add(value)
        case None => ()
    }
    match (networkLease) {
        case Some(value) =>
            try {
                addDirectSandboxMount(mounts, value.lease.bridgeExecutable)
                addDirectSandboxMount(mounts, Path(value.lease.bridgeSocket).parent.toString())
            } catch (error: Exception) {
                releaseDirectNetworkLease(networkLease)
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    errorCode,
                    resolved.redactor.redact(error.message)
                ))
            }
        case None => ()
    }
    let sandbox = try {
        WorkspaceSandbox(WorkspaceSandboxPolicy(
            workspaceRoot,
            filesystem: filesystem,
            process: ProcessIsolationMode.Isolated,
            network: match (networkPolicy.mode) {
                case NetworkPolicyMode.HostNetwork => NetworkIsolationMode.Allowed
                case NetworkPolicyMode.Denied => NetworkIsolationMode.Denied
                case NetworkPolicyMode.Mediated => NetworkIsolationMode.Mediated
            },
            environment: EnvironmentFilter(
                allowlist: allowedNames.toArray(),
                allowedSecrets: resolved.secretTargets,
                secretValues: resolved.secretValues
            ),
            resources: defaultProductSandboxResourceLimits(),
            readOnlyMounts: mounts.toArray(),
            pathEntries: toolchain.pathEntries
        ))
    } catch (error: Exception) {
        releaseDirectNetworkLease(networkLease)
        return Result.Err(AgentError(
            AgentErrorKind.Configuration,
            errorCode,
            resolved.redactor.redact(error.message)
        ))
    }
    match (sandbox.availability()) {
        case SandboxResult.Ok(_) => ()
        case SandboxResult.Err(error) =>
            releaseDirectNetworkLease(networkLease)
            return Result.Err(directRedactError(sandboxAgentError(error), resolved.redactor))
    }
    let plan = match (sandbox.plan(WorkspaceSandboxCommand(
        executable,
        arguments: arguments,
        workingDirectory: cwd,
        environment: sandboxEnvironment.toArray(),
        timeoutMillis: 60000,
        networkBridgeExecutable: match (networkLease) {
            case Some(value) => value.lease.bridgeExecutable
            case None => ""
        },
        networkBridgeSocket: match (networkLease) {
            case Some(value) => value.lease.bridgeSocket
            case None => ""
        }
    ))) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) =>
            releaseDirectNetworkLease(networkLease)
            return Result.Err(directRedactError(sandboxAgentError(error), resolved.redactor))
    }
    try {
        let process = startProcess(ProcessCommand(
            plan.sandboxExecutable,
            arguments: plan.sandboxArguments,
            environment: HashMap<String, String>()
        ))
        Result.Ok(DirectProcessHandle(
            process,
            resolved.redactor,
            resolved.secretValues,
            true,
            releaseAction: { => releaseDirectNetworkLease(networkLease) }
        ))
    } catch (error: Exception) {
        releaseDirectNetworkLease(networkLease)
        Result.Err(AgentError(
            AgentErrorKind.Transport,
            errorCode,
            resolved.redactor.redact(error.message)
        ))
    }
}

func acquireDirectNetworkLease(
    policy: NetworkPolicy
): Result<?DirectNetworkLease> {
    if (!networkPolicyModeIsMediated(policy.mode)) {
        return Result.Ok(None)
    }
    let gateway: NetworkGatewayPort = LocalNetworkGatewayPort()
    match (gateway.acquire(OperationId("direct-process"), policy)) {
        case Result.Ok(lease) => Result.Ok(Some(DirectNetworkLease(gateway, lease)))
        case Result.Err(error) => Result.Err(error)
    }
}

func releaseDirectNetworkLease(lease: ?DirectNetworkLease): Unit {
    match (lease) {
        case Some(value) => value.release()
        case None => ()
    }
}

func addDirectSandboxMount(
    mounts: ArrayList<SandboxReadOnlyMount>,
    path: String
): Unit {
    let candidate = SandboxReadOnlyMount(path)
    for (existing in mounts where existing.path == candidate.path) { return }
    mounts.add(candidate)
}


func resolveDirectEnvironment(
    bindings: Array<DirectEnvironmentBinding>,
    literalEnvironment: Array<SandboxEnvironmentEntry>
): Result<DirectResolvedEnvironment> {
    let entries = ArrayList<SandboxEnvironmentEntry>()
    let targets = ArrayList<String>()
    let secretTargets = ArrayList<String>()
    let secretValues = ArrayList<String>()
    for (literal in literalEnvironment) {
        if (directSecretName(literal.name)) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "sandbox.literal_secret_denied",
                "secret-like literal environment values are forbidden; use secret_env",
                fields: [ErrorField("name", literal.name)]
            ))
        }
        if (directContains(targets, literal.name)) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "sandbox.environment_duplicate",
                "environment target is declared more than once",
                fields: [ErrorField("name", literal.name)]
            ))
        }
        targets.add(literal.name)
        entries.add(literal)
    }
    let variables = getVariables()
    for (binding in bindings) {
        if (directContains(targets, binding.target)) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "sandbox.environment_duplicate",
                "environment target is declared more than once",
                fields: [ErrorField("name", binding.target)]
            ))
        }
        var found = false
        for ((name, value) in variables where name == binding.source) {
            if (binding.secret && value.toArray().size < 4) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "sandbox.secret_value_too_short",
                    "secret environment values must contain at least four bytes",
                    fields: [ErrorField("name", binding.source)]
                ))
            }
            try {
                entries.add(SandboxEnvironmentEntry(binding.target, value))
            } catch (error: Exception) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "sandbox.environment_invalid",
                    error.message,
                    fields: [ErrorField("name", binding.source)]
                ))
            }
            if (binding.secret) {
                secretTargets.add(binding.target)
                secretValues.add(value)
            }
            targets.add(binding.target)
            found = true
            break
        }
        if (!found) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "sandbox.environment_source_missing",
                "required environment source is unavailable",
                fields: [ErrorField("name", binding.source)]
            ))
        }
    }
    Result.Ok(DirectResolvedEnvironment(
        entries.toArray(),
        secretTargets.toArray(),
        secretValues.toArray()
    ))
}

func directHostEnvironment(
    workspaceRoot: String,
    entries: Array<SandboxEnvironmentEntry>
): HashMap<String, String> {
    let environment = HashMap<String, String>()
    environment["PATH"] = "/usr/local/bin:/usr/bin:/bin"
    environment["HOME"] = workspaceRoot
    environment["TMPDIR"] = "/tmp"
    environment["LANG"] = "C.UTF-8"
    for (entry in entries) { environment[entry.name] = entry.value }
    environment
}

func directRedactError(error: AgentError, redactor: SecretRedactor): AgentError {
    let fields = ArrayList<ErrorField>()
    for (field in error.fields) {
        fields.add(ErrorField(field.name, redactor.redact(field.value)))
    }
    AgentError(
        error.kind,
        error.code,
        redactor.redact(error.message),
        retryable: error.retryable,
        fallbackAllowed: error.fallbackAllowed,
        fields: fields.toArray()
    )
}

func directSecretName(name: String): Bool {
    let normalized = name.toAsciiUpper().replace("-", "_")
    normalized.contains("SECRET") || normalized.contains("TOKEN") ||
        normalized.contains("PASSWORD") || normalized.contains("PASSWD") ||
        normalized.contains("CREDENTIAL") || normalized.endsWith("_KEY") ||
        normalized.contains("API_KEY") || normalized == "SSH_AUTH_SOCK" ||
        normalized.contains("COOKIE")
}

func directContains(values: ArrayList<String>, value: String): Bool {
    for (existing in values where existing == value) { return true }
    false
}
