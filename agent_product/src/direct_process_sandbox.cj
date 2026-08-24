package agent_product

import agent_domain.*
import process4cj.*
import sandbox4cj.*
import std.collection.*
import std.env.*

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

class DirectProcessHandle {
    let process: ManagedProcess
    let redactor: SecretRedactor
    let secretValues: Array<String>
    let sandboxed: Bool

    init(
        process: ManagedProcess,
        redactor: SecretRedactor,
        secretValues: Array<String>,
        sandboxed: Bool
    ) {
        this.process = process
        this.redactor = redactor
        this.secretValues = secretValues
        this.sandboxed = sandboxed
    }
}

func launchDirectPersistentProcess(
    workspaceRoot: String,
    sandboxEnabled: Bool,
    allowUnsafeTestBypass: Bool,
    filesystem: FilesystemIsolationMode,
    networkAllowed: Bool,
    executable: String,
    arguments: Array<String>,
    cwd: String,
    bindings!: Array<DirectEnvironmentBinding> = [],
    literalEnvironment!: Array<SandboxEnvironmentEntry> = [],
    errorCode!: String = "direct.process_start_failed"
): Result<DirectProcessHandle> {
    let resolved = match (resolveDirectEnvironment(bindings, literalEnvironment)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
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

    let allowedNames = ArrayList<String>()
    for (entry in resolved.entries) { allowedNames.add(entry.name) }
    let toolchain = configuredProductSandboxToolchain()
    let sandbox = try {
        WorkspaceSandbox(WorkspaceSandboxPolicy(
            workspaceRoot,
            filesystem: filesystem,
            process: ProcessIsolationMode.Isolated,
            network: if (networkAllowed) {
                NetworkIsolationMode.Allowed
            } else {
                NetworkIsolationMode.Denied
            },
            environment: EnvironmentFilter(
                allowlist: allowedNames.toArray(),
                allowedSecrets: resolved.secretTargets,
                secretValues: resolved.secretValues
            ),
            resources: defaultProductSandboxResourceLimits(),
            readOnlyMounts: toolchain.mounts,
            pathEntries: toolchain.pathEntries
        ))
    } catch (error: Exception) {
        return Result.Err(AgentError(
            AgentErrorKind.Configuration,
            errorCode,
            resolved.redactor.redact(error.message)
        ))
    }
    match (sandbox.availability()) {
        case SandboxResult.Ok(_) => ()
        case SandboxResult.Err(error) => return Result.Err(
            directRedactError(sandboxAgentError(error), resolved.redactor)
        )
    }
    let plan = match (sandbox.plan(WorkspaceSandboxCommand(
        executable,
        arguments: arguments,
        workingDirectory: cwd,
        environment: resolved.entries,
        // Persistent runtimes own request deadlines and child lifecycle.  The
        // value is validated by WorkspaceSandboxCommand but its timeout wrapper
        // is deliberately not launched below.
        timeoutMillis: 60000
    ))) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) => return Result.Err(
            directRedactError(sandboxAgentError(error), resolved.redactor)
        )
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
            true
        ))
    } catch (error: Exception) {
        Result.Err(AgentError(
            AgentErrorKind.Transport,
            errorCode,
            resolved.redactor.redact(error.message)
        ))
    }
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
