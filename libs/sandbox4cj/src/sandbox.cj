package sandbox4cj


import process4cj.*
import std.collection.*
import std.deriving.*
import std.env.*
import std.fs.*
import std.process.*

public enum SandboxErrorKind {
    Configuration | InvalidInput | PermissionDenied | Transport | Cancelled | Deadline
}

public class SandboxErrorField {
    public let name: String
    public let value: String
    public init(name: String, value: String) { this.name = name; this.value = value }
}

public class SandboxError <: Exception {
    public let kind: SandboxErrorKind
    public let code: String
    public let fields: Array<SandboxErrorField>
    public init(
        kind: SandboxErrorKind,
        code: String,
        message: String,
        fields!: Array<SandboxErrorField> = []
    ) {
        super(message)
        this.kind = kind
        this.code = code
        this.fields = fields
    }
}

public enum SandboxResult<T> {
    Ok(T) | Err(SandboxError)
    public func isOk(): Bool { match (this) { case Ok(_) => true; case Err(_) => false } }
}

@Derive[Equatable]
public enum FilesystemIsolationMode {
    WorkspaceReadOnly | WorkspaceReadWrite
}

@Derive[Equatable]
public enum ProcessIsolationMode {
    Isolated | Shared
}

@Derive[Equatable]
public enum NetworkIsolationMode {
    Denied | Allowed
}

public class SandboxEnvironmentEntry {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        requireEnvironmentName(name)
        if (value.contains("\u{0000}")) {
            throw IllegalArgumentException("environment value must not contain NUL")
        }
        this.name = name
        this.value = value
    }
}

public class FilteredEnvironment {
    public let entries: Array<SandboxEnvironmentEntry>
    private let secrets: Array<String>

    init(entries: Array<SandboxEnvironmentEntry>, secrets: Array<String>) {
        this.entries = entries
        this.secrets = secrets
    }

    public func redactor(marker!: String = "[REDACTED]"): SecretRedactor {
        SecretRedactor(secrets, marker: marker)
    }

}

public class EnvironmentFilter {
    private let allowedNames: Array<String>
    private let allowedSecretNames: Array<String>
    private let deniedSecretNames: Array<String>
    private let explicitSecretValues: Array<String>
    private let minimumSecretLength: Int64

    public init(
        allowlist!: Array<String> = [],
        allowedSecrets!: Array<String> = [],
        secretNames!: Array<String> = [],
        secretValues!: Array<String> = [],
        minimumSecretLength!: Int64 = 4
    ) {
        if (minimumSecretLength < 1) {
            throw IllegalArgumentException("minimum secret length must be positive")
        }
        this.allowedNames = uniqueEnvironmentNames(allowlist)
        this.allowedSecretNames = uniqueEnvironmentNames(allowedSecrets)
        this.deniedSecretNames = uniqueEnvironmentNames(secretNames)
        this.explicitSecretValues = uniqueLongValues(secretValues, minimumSecretLength)
        this.minimumSecretLength = minimumSecretLength
    }

    // Ambient variables are copied only when explicitly allowlisted. A
    // secret-like name needs a second, explicit grant so adding a broad normal
    // allowlist cannot accidentally expose credentials. Granted secret values
    // are always registered with the output redactor.
    public func filter(entries: Array<SandboxEnvironmentEntry>): FilteredEnvironment {
        let accepted = ArrayList<SandboxEnvironmentEntry>()
        let secrets = ArrayList<String>()
        secrets.add(all: explicitSecretValues)
        for (entry in entries) {
            if (isSecretName(entry.name)) {
                addSecret(secrets, entry.value, minimumSecretLength)
                if (!containsName(allowedSecretNames, entry.name)) { continue }
            }
            if (containsName(allowedNames, entry.name)) {
                upsertEnvironment(accepted, entry)
            }
        }
        FilteredEnvironment(accepted.toArray(), longestFirst(secrets.toArray()))
    }

    public func filterCurrent(): FilteredEnvironment {
        let entries = ArrayList<SandboxEnvironmentEntry>()
        for ((name, value) in getVariables()) {
            // POSIX permits host-created names that are not valid portable
            // variable identifiers (for example exported shell functions).
            // They are denied without letting malformed ambient state abort a
            // sandbox plan.
            if (validEnvironmentName(name) && !value.contains("\u{0000}")) {
                entries.add(SandboxEnvironmentEntry(name, value))
            }
        }
        filter(entries.toArray())
    }

    public func validateRequested(entries: Array<SandboxEnvironmentEntry>): SandboxResult<Unit> {
        for (entry in entries) {
            if (isSecretName(entry.name) && !containsName(allowedSecretNames, entry.name)) {
                return sandboxError<Unit>(
                    SandboxErrorKind.PermissionDenied,
                    "sandbox.environment_secret_denied",
                    "secret environment variable is missing an explicit secret grant",
                    fields: [SandboxErrorField("name", entry.name)]
                )
            }
            if (!containsName(allowedNames, entry.name)) {
                return sandboxError<Unit>(
                    SandboxErrorKind.PermissionDenied,
                    "sandbox.environment_denied",
                    "environment variable is not on the sandbox allowlist",
                    fields: [SandboxErrorField("name", entry.name)]
                )
            }
        }
        SandboxResult.Ok(())
    }

    private func isSecretName(name: String): Bool {
        if (containsName(deniedSecretNames, name)) {
            return true
        }
        let normalized = name.toAsciiUpper().replace("-", "_")
        normalized.contains("SECRET") || normalized.contains("TOKEN") ||
            normalized.contains("PASSWORD") || normalized.contains("PASSWD") ||
            normalized.contains("CREDENTIAL") || normalized.endsWith("_KEY") ||
            normalized.contains("API_KEY") || normalized == "SSH_AUTH_SOCK" ||
            normalized.contains("COOKIE")
    }
}

public class SecretRedactor {
    private let values: Array<String>
    private let marker: String

    public init(
        secretValues: Array<String>,
        marker!: String = "[REDACTED]",
        minimumSecretLength!: Int64 = 4
    ) {
        if (minimumSecretLength < 1) {
            throw IllegalArgumentException("minimum secret length must be positive")
        }
        if (marker == "") {
            throw IllegalArgumentException("redaction marker must not be empty")
        }
        this.values = longestFirst(uniqueLongValues(secretValues, minimumSecretLength))
        this.marker = marker
    }

    public func redact(text: String): String {
        var result = text
        // Longest-first prevents a shorter credential prefix from leaving a
        // distinguishable suffix behind.
        for (value in values) {
            result = result.replace(value, marker)
        }
        result
    }
}

public class SandboxResourceLimits {
    public let maxOutputBytes: Int64
    public let addressSpaceBytes: Int64
    public let fileSizeBytes: Int64
    public let openFiles: Int64
    public let processes: Int64
    public let cpuSeconds: Int64

    public init(
        maxOutputBytes!: Int64 = 1048576,
        addressSpaceBytes!: Int64 = 0,
        fileSizeBytes!: Int64 = 0,
        openFiles!: Int64 = 0,
        processes!: Int64 = 0,
        cpuSeconds!: Int64 = 0
    ) {
        if (maxOutputBytes < 1 || addressSpaceBytes < 0 || fileSizeBytes < 0 ||
            openFiles < 0 || processes < 0 || cpuSeconds < 0) {
            throw IllegalArgumentException("sandbox resource limits must be non-negative and output must be positive")
        }
        this.maxOutputBytes = maxOutputBytes
        this.addressSpaceBytes = addressSpaceBytes
        this.fileSizeBytes = fileSizeBytes
        this.openFiles = openFiles
        this.processes = processes
        this.cpuSeconds = cpuSeconds
    }

    public func usesProcessLimits(): Bool {
        addressSpaceBytes > 0 || fileSizeBytes > 0 || openFiles > 0 ||
            processes > 0 || cpuSeconds > 0
    }
}

// A composition root may expose an explicitly selected toolchain without
// widening the writable workspace boundary. Both the authored mount point and
// its canonical source are retained so symlinked SDK installations remain
// usable while executable validation still follows the real path.
public class SandboxReadOnlyMount {
    public let path: String
    public let resolvedPath: String

    public init(path: String) {
        if (!Path(path).isAbsolute() || !exists(Path(path))) {
            throw IllegalArgumentException("sandbox read-only mount must be an existing absolute path")
        }
        let normalized = Path(path).normalize().toString()
        let resolved = canonicalize(normalized).toString()
        if (normalized == "/" || resolved == "/") {
            throw IllegalArgumentException("sandbox read-only mount must not expose the host root")
        }
        this.path = normalized
        this.resolvedPath = resolved
    }
}

public class WorkspaceSandboxPolicy {
    public let workspaceRoot: String
    public let filesystem: FilesystemIsolationMode
    public let process: ProcessIsolationMode
    public let network: NetworkIsolationMode
    public let environment: EnvironmentFilter
    public let resources: SandboxResourceLimits
    public let readOnlyMounts: Array<SandboxReadOnlyMount>
    public let pathEntries: Array<String>
    public let bubblewrapExecutable: String
    public let timeoutExecutable: String

    public init(
        workspaceRoot: String,
        filesystem!: FilesystemIsolationMode = FilesystemIsolationMode.WorkspaceReadOnly,
        process!: ProcessIsolationMode = ProcessIsolationMode.Isolated,
        network!: NetworkIsolationMode = NetworkIsolationMode.Denied,
        environment!: EnvironmentFilter = EnvironmentFilter(),
        resources!: SandboxResourceLimits = SandboxResourceLimits(),
        readOnlyMounts!: Array<SandboxReadOnlyMount> = [],
        pathEntries!: Array<String> = [],
        bubblewrapExecutable!: String = "/usr/bin/bwrap",
        timeoutExecutable!: String = "/usr/bin/timeout"
    ) {
        let root = requireWorkspaceRoot(workspaceRoot)
        this.workspaceRoot = root
        this.filesystem = filesystem
        this.process = process
        this.network = network
        this.environment = environment
        this.resources = resources
        this.readOnlyMounts = validatedReadOnlyMounts(readOnlyMounts, root)
        this.pathEntries = validatedPathEntries(pathEntries, root, this.readOnlyMounts)
        this.bubblewrapExecutable = requireAbsoluteExecutablePath(bubblewrapExecutable, "bubblewrap")
        this.timeoutExecutable = requireAbsoluteExecutablePath(timeoutExecutable, "timeout")
    }
}

public class WorkspaceSandboxCommand {
    public let executable: String
    public let arguments: Array<String>
    public let workingDirectory: String
    public let environment: Array<SandboxEnvironmentEntry>
    public let timeoutMillis: Int64

    public init(
        executable: String,
        arguments!: Array<String> = [],
        workingDirectory!: String = "",
        environment!: Array<SandboxEnvironmentEntry> = [],
        timeoutMillis!: Int64 = 60000
    ) {
        if (executable.trimAscii() == "" || executable.contains("\u{0000}")) {
            throw IllegalArgumentException("sandbox executable must not be empty or contain NUL")
        }
        if (timeoutMillis < 1) {
            throw IllegalArgumentException("sandbox timeout must be positive")
        }
        for (argument in arguments where argument.contains("\u{0000}")) {
            throw IllegalArgumentException("sandbox arguments must not contain NUL")
        }
        ensureUniqueEnvironment(environment)
        this.executable = executable
        this.arguments = arguments
        this.workingDirectory = workingDirectory
        this.environment = environment
        this.timeoutMillis = timeoutMillis
    }
}

public class SandboxLaunchPlan {
    public let launcherExecutable: String
    public let launcherArguments: Array<String>
    public let sandboxExecutable: String
    public let sandboxArguments: Array<String>
    public let resolvedExecutable: String
    public let workingDirectory: String
    public let environment: Array<SandboxEnvironmentEntry>

    init(
        launcherExecutable: String,
        launcherArguments: Array<String>,
        sandboxExecutable: String,
        sandboxArguments: Array<String>,
        resolvedExecutable: String,
        workingDirectory: String,
        environment: Array<SandboxEnvironmentEntry>
    ) {
        this.launcherExecutable = launcherExecutable
        this.launcherArguments = launcherArguments
        this.sandboxExecutable = sandboxExecutable
        this.sandboxArguments = sandboxArguments
        this.resolvedExecutable = resolvedExecutable
        this.workingDirectory = workingDirectory
        this.environment = environment
    }
}

public class SandboxExecutionResult {
    public let exitCode: Int64
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let outputTruncated: Bool

    public init(
        exitCode: Int64,
        stdout: String,
        stderr: String,
        timedOut: Bool,
        outputTruncated: Bool
    ) {
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
        this.timedOut = timedOut
        this.outputTruncated = outputTruncated
    }
}

public type SandboxProcessStarted = (SubProcess) -> Unit

public class WorkspaceSandbox {
    public let policy: WorkspaceSandboxPolicy

    public init(policy: WorkspaceSandboxPolicy) {
        this.policy = policy
    }

    // This is deliberately separate from execute so approval and audit layers
    // can inspect the exact argv without invoking a shell or changing state.
    public func plan(command: WorkspaceSandboxCommand): SandboxResult<SandboxLaunchPlan> {
        match (requireRuntimeBinaries(policy)) {
            case SandboxResult.Err(error) => return SandboxResult.Err(error)
            case SandboxResult.Ok(_) => ()
        }
        let cwd = match (resolveWorkingDirectory(policy.workspaceRoot, command.workingDirectory)) {
            case SandboxResult.Ok(value) => value
            case SandboxResult.Err(error) => return SandboxResult.Err(error)
        }
        let executable = match (resolveCommandExecutable(policy, cwd, command.executable)) {
            case SandboxResult.Ok(value) => value
            case SandboxResult.Err(error) => return SandboxResult.Err(error)
        }
        match (policy.environment.validateRequested(command.environment)) {
            case SandboxResult.Err(error) => return SandboxResult.Err(error)
            case SandboxResult.Ok(_) => ()
        }
        let ambient = policy.environment.filterCurrent()
        let requested = policy.environment.filter(command.environment)
        let sanitized = mergeEnvironment(ambient.entries, requested.entries, policy)
        let arguments = buildSandboxArguments(policy, cwd, executable, command.arguments, sanitized)
        let launcherArguments = ArrayList<String>()
        launcherArguments.add("--signal=TERM")
        launcherArguments.add("--kill-after=1s")
        launcherArguments.add(timeoutDuration(command.timeoutMillis))
        launcherArguments.add(policy.bubblewrapExecutable)
        launcherArguments.add(all: arguments)
        SandboxResult.Ok(SandboxLaunchPlan(
            policy.timeoutExecutable,
            launcherArguments.toArray(),
            policy.bubblewrapExecutable,
            arguments,
            executable,
            cwd,
            sanitized
        ))
    }

    // A present bwrap binary is not enough: namespace creation can be disabled
    // by the host kernel or container. Probe the configured boundary and fail
    // closed before running the caller's command.
    public func availability(): SandboxResult<Unit> {
        match (requireRuntimeBinaries(policy)) {
            case SandboxResult.Err(error) => return SandboxResult.Err(error)
            case SandboxResult.Ok(_) => ()
        }
        let environment = safeBaseEnvironment(policy)
        let arguments = buildSandboxArguments(
            policy,
            policy.workspaceRoot,
            "/usr/bin/true",
            [],
            environment
        )
        let launchArguments = ArrayList<String>()
        launchArguments.add("--signal=KILL")
        launchArguments.add("2s")
        launchArguments.add(policy.bubblewrapExecutable)
        launchArguments.add(all: arguments)
        try {
            let process = launch(
                policy.timeoutExecutable,
                launchArguments.toArray(),
                environment: HashMap<String, String>(),
                stdOut: ProcessRedirect.Pipe,
                stdErr: ProcessRedirect.Pipe
            )
            let probeBudget = BoundedOutputBudget(65536)
            let stdout = spawn { readBounded(process.stdOutPipe, probeBudget) }
            let stderr = spawn { readBounded(process.stdErrPipe, probeBudget) }
            let code = process.wait()
            let _ = stdout.get()
            let detail = String.fromUtf8(stderr.get()).trimAscii()
            if (code == 0) {
                SandboxResult.Ok(())
            } else {
                sandboxError<Unit>(
                    SandboxErrorKind.Configuration,
                    "sandbox.isolation_unsupported",
                    if (detail == "") {
                        "bubblewrap could not establish the configured isolation boundary"
                    } else {
                        "bubblewrap could not establish the configured isolation boundary: " + detail
                    },
                    fields: [SandboxErrorField("exit_code", code.toString())]
                )
            }
        } catch (error: Exception) {
            sandboxError<Unit>(
                SandboxErrorKind.Configuration,
                "sandbox.isolation_unsupported",
                "bubblewrap isolation probe failed: " + error.message
            )
        }
    }

    public func execute(
        command: WorkspaceSandboxCommand,
        onStarted!: ?SandboxProcessStarted = None
    ): SandboxResult<SandboxExecutionResult> {
        match (availability()) {
            case SandboxResult.Err(error) => return SandboxResult.Err(error)
            case SandboxResult.Ok(_) => ()
        }
        let planValue = match (plan(command)) {
            case SandboxResult.Ok(value) => value
            case SandboxResult.Err(error) => return SandboxResult.Err(error)
        }
        let ambient = policy.environment.filterCurrent()
        let requested = policy.environment.filter(command.environment)
        let ambientRedactor = ambient.redactor()
        let requestedRedactor = requested.redactor()
        let budget = BoundedOutputBudget(policy.resources.maxOutputBytes)
        try {
            let process = launch(
                planValue.launcherExecutable,
                planValue.launcherArguments,
                environment: HashMap<String, String>(),
                stdOut: ProcessRedirect.Pipe,
                stdErr: ProcessRedirect.Pipe
            )
            match (onStarted) {
                case Some(callback) => callback(process)
                case None => ()
            }
            let stdout = spawn { readBounded(process.stdOutPipe, budget) }
            let stderr = spawn { readBounded(process.stdErrPipe, budget) }
            let code = process.wait()
            let outputText = requestedRedactor.redact(ambientRedactor.redact(String.fromUtf8(stdout.get())))
            let errorText = requestedRedactor.redact(ambientRedactor.redact(String.fromUtf8(stderr.get())))
            SandboxResult.Ok(SandboxExecutionResult(
                code,
                outputText,
                errorText,
                code == 124 || code == 137,
                budget.wasTruncated()
            ))
        } catch (error: Exception) {
            sandboxError<SandboxExecutionResult>(
                SandboxErrorKind.Transport,
                "sandbox.execute_failed",
                requestedRedactor.redact(ambientRedactor.redact(error.message))
            )
        }
    }
}

func buildSandboxArguments(
    policy: WorkspaceSandboxPolicy,
    cwd: String,
    executable: String,
    commandArguments: Array<String>,
    environment: Array<SandboxEnvironmentEntry>
): Array<String> {
    let arguments = ArrayList<String>()
    arguments.add("--die-with-parent")
    arguments.add("--new-session")
    arguments.add("--unshare-user")
    arguments.add("--disable-userns")
    match (policy.process) {
        case ProcessIsolationMode.Isolated =>
            arguments.add("--unshare-pid")
            arguments.add("--unshare-ipc")
            arguments.add("--unshare-uts")
            arguments.add("--unshare-cgroup-try")
        case ProcessIsolationMode.Shared => ()
    }
    match (policy.network) {
        case NetworkIsolationMode.Denied => arguments.add("--unshare-net")
        case NetworkIsolationMode.Allowed => ()
    }
    arguments.add("--ro-bind")
    arguments.add("/usr")
    arguments.add("/usr")
    addOptionalReadOnlyBind(arguments, "/bin")
    addOptionalReadOnlyBind(arguments, "/lib")
    addOptionalReadOnlyBind(arguments, "/lib64")
    arguments.add("--dir")
    arguments.add("/etc")
    addOptionalReadOnlyBind(arguments, "/etc/ld.so.cache")
    addOptionalReadOnlyBind(arguments, "/etc/passwd")
    addOptionalReadOnlyBind(arguments, "/etc/group")
    addOptionalReadOnlyBind(arguments, "/etc/nsswitch.conf")
    if (policy.network == NetworkIsolationMode.Allowed) {
        addOptionalReadOnlyBind(arguments, "/etc/resolv.conf")
        addOptionalReadOnlyBind(arguments, "/etc/hosts")
    }
    arguments.add("--proc")
    arguments.add("/proc")
    arguments.add("--dev")
    arguments.add("/dev")
    arguments.add("--tmpfs")
    arguments.add("/tmp")
    for (mount in policy.readOnlyMounts) {
        addDestinationParents(arguments, mount.resolvedPath)
        arguments.add("--ro-bind")
        arguments.add(mount.resolvedPath)
        arguments.add(mount.resolvedPath)
        if (mount.path != mount.resolvedPath) {
            addDestinationParents(arguments, mount.path)
            arguments.add("--ro-bind")
            arguments.add(mount.resolvedPath)
            arguments.add(mount.path)
        }
    }
    addDestinationParents(arguments, policy.workspaceRoot)
    arguments.add(if (policy.filesystem == FilesystemIsolationMode.WorkspaceReadWrite) {
        "--bind"
    } else {
        "--ro-bind"
    })
    arguments.add(policy.workspaceRoot)
    arguments.add(policy.workspaceRoot)
    arguments.add("--chdir")
    arguments.add(cwd)
    arguments.add("--clearenv")
    for (entry in environment) {
        arguments.add("--setenv")
        arguments.add(entry.name)
        arguments.add(entry.value)
    }
    arguments.add("--")
    if (policy.resources.usesProcessLimits()) {
        arguments.add("/usr/bin/prlimit")
        addResourceLimitArguments(arguments, policy.resources)
        arguments.add("--")
    }
    arguments.add(executable)
    arguments.add(all: commandArguments)
    arguments.toArray()
}

func addResourceLimitArguments(arguments: ArrayList<String>, limits: SandboxResourceLimits): Unit {
    if (limits.addressSpaceBytes > 0) { arguments.add("--as=" + limits.addressSpaceBytes.toString()) }
    if (limits.fileSizeBytes > 0) { arguments.add("--fsize=" + limits.fileSizeBytes.toString()) }
    if (limits.openFiles > 0) { arguments.add("--nofile=" + limits.openFiles.toString()) }
    if (limits.processes > 0) { arguments.add("--nproc=" + limits.processes.toString()) }
    if (limits.cpuSeconds > 0) { arguments.add("--cpu=" + limits.cpuSeconds.toString()) }
}

func addOptionalReadOnlyBind(arguments: ArrayList<String>, path: String): Unit {
    arguments.add("--ro-bind-try")
    arguments.add(path)
    arguments.add(path)
}

func addDestinationParents(arguments: ArrayList<String>, path: String): Unit {
    let parts = path.split("/")
    var current = ""
    for (part in parts where part != "") {
        current += "/" + part
        if (current == path) { break }
        arguments.add("--dir")
        arguments.add(current)
    }
}

func resolveWorkingDirectory(root: String, authored: String): SandboxResult<String> {
    let candidate = if (authored.trimAscii() == "") {
        root
    } else if (Path(authored).isAbsolute()) {
        authored
    } else {
        Path(root).join(authored).normalize().toString()
    }
    if (!exists(Path(candidate))) {
        return sandboxError<String>(
            SandboxErrorKind.InvalidInput,
            "sandbox.working_directory_missing",
            "sandbox working directory does not exist"
        )
    }
    try {
        let resolved = canonicalize(candidate).toString()
        if (!FileInfo(Path(resolved)).isDirectory()) {
            return sandboxError<String>(
                SandboxErrorKind.InvalidInput,
                "sandbox.working_directory_not_directory",
                "sandbox working directory must be a directory"
            )
        }
        if (!withinPath(resolved, root)) {
            return sandboxError<String>(
                SandboxErrorKind.PermissionDenied,
                "sandbox.path_escape",
                "sandbox working directory resolves outside the workspace"
            )
        }
        SandboxResult.Ok(resolved)
    } catch (error: Exception) {
        sandboxError<String>(
            SandboxErrorKind.InvalidInput,
            "sandbox.working_directory_invalid",
            "sandbox working directory could not be resolved: " + error.message
        )
    }
}

func resolveCommandExecutable(
    policy: WorkspaceSandboxPolicy,
    cwd: String,
    authored: String
): SandboxResult<String> {
    let candidates = ArrayList<String>()
    if (Path(authored).isAbsolute()) {
        candidates.add(authored)
    } else if (authored.contains("/")) {
        candidates.add(Path(cwd).join(authored).normalize().toString())
    } else {
        candidates.add(Path(cwd).join(authored).normalize().toString())
        for (entry in policy.pathEntries) {
            candidates.add(Path(entry).join(authored).normalize().toString())
        }
        candidates.add("/usr/local/bin/" + authored)
        candidates.add("/usr/bin/" + authored)
        candidates.add("/bin/" + authored)
    }
    for (candidate in candidates where exists(Path(candidate))) {
        try {
            let resolved = canonicalize(candidate).toString()
            if (FileInfo(Path(resolved)).isDirectory()) { continue }
            if (withinPath(resolved, policy.workspaceRoot) || withinPath(resolved, "/usr") ||
                withinPath(resolved, "/bin") || withinPath(resolved, "/lib") ||
                withinPath(resolved, "/lib64") || withinReadOnlyMount(resolved, policy.readOnlyMounts)) {
                return SandboxResult.Ok(resolved)
            }
            return sandboxError<String>(
                SandboxErrorKind.PermissionDenied,
                "sandbox.executable_outside_roots",
                "executable resolves outside the mounted sandbox roots"
            )
        } catch (_: Exception) {}
    }
    sandboxError<String>(
        SandboxErrorKind.InvalidInput,
        "sandbox.executable_missing",
        "sandbox executable was not found in the workspace or fixed system path"
    )
}

func mergeEnvironment(
    ambient: Array<SandboxEnvironmentEntry>,
    requested: Array<SandboxEnvironmentEntry>,
    policy: WorkspaceSandboxPolicy
): Array<SandboxEnvironmentEntry> {
    let values = ArrayList<SandboxEnvironmentEntry>()
    for (entry in ambient) { upsertEnvironment(values, entry) }
    for (entry in requested) { upsertEnvironment(values, entry) }
    // Runtime-owned values cannot be influenced by the inherited host state.
    upsertEnvironment(values, SandboxEnvironmentEntry("PATH", controlledPath(policy.pathEntries)))
    upsertEnvironment(values, SandboxEnvironmentEntry("HOME", policy.workspaceRoot))
    upsertEnvironment(values, SandboxEnvironmentEntry("TMPDIR", "/tmp"))
    upsertEnvironment(values, SandboxEnvironmentEntry("LANG", "C.UTF-8"))
    values.toArray()
}

func safeBaseEnvironment(policy: WorkspaceSandboxPolicy): Array<SandboxEnvironmentEntry> {
    [
        SandboxEnvironmentEntry("PATH", controlledPath(policy.pathEntries)),
        SandboxEnvironmentEntry("HOME", policy.workspaceRoot),
        SandboxEnvironmentEntry("TMPDIR", "/tmp"),
        SandboxEnvironmentEntry("LANG", "C.UTF-8")
    ]
}

func controlledPath(entries: Array<String>): String {
    let parts = ArrayList<String>()
    parts.add(all: entries)
    for (value in ["/usr/local/bin", "/usr/bin", "/bin"] where !containsString(parts, value)) {
        parts.add(value)
    }
    joinWithColon(parts.toArray())
}

func joinWithColon(values: Array<String>): String {
    var result = ""
    for (value in values) {
        if (result != "") { result += ":" }
        result += value
    }
    result
}

func containsString(values: ArrayList<String>, target: String): Bool {
    for (value in values where value == target) { return true }
    false
}

func withinReadOnlyMount(path: String, mounts: Array<SandboxReadOnlyMount>): Bool {
    for (mount in mounts where withinPath(path, mount.resolvedPath)) { return true }
    false
}

func validatedReadOnlyMounts(
    values: Array<SandboxReadOnlyMount>,
    workspaceRoot: String
): Array<SandboxReadOnlyMount> {
    let result = ArrayList<SandboxReadOnlyMount>()
    for (value in values) {
        if (withinPath(value.resolvedPath, workspaceRoot) ||
            withinPath(workspaceRoot, value.resolvedPath)) {
            throw IllegalArgumentException(
                "sandbox read-only mounts must not overlap the writable workspace boundary"
            )
        }
        var duplicate = false
        for (existing in result where existing.path == value.path) { duplicate = true }
        if (!duplicate) { result.add(value) }
    }
    result.toArray()
}

func validatedPathEntries(
    values: Array<String>,
    workspaceRoot: String,
    mounts: Array<SandboxReadOnlyMount>
): Array<String> {
    let result = ArrayList<String>()
    for (value in values) {
        if (!Path(value).isAbsolute() || !exists(Path(value))) {
            throw IllegalArgumentException("sandbox PATH entries must be existing absolute paths")
        }
        let normalized = Path(value).normalize().toString()
        let resolved = canonicalize(normalized).toString()
        if (!FileInfo(Path(resolved)).isDirectory()) {
            throw IllegalArgumentException("sandbox PATH entries must be directories")
        }
        if (!withinPath(resolved, workspaceRoot) && !withinPath(resolved, "/usr") &&
            !withinPath(resolved, "/bin") && !withinReadOnlyMount(resolved, mounts)) {
            throw IllegalArgumentException("sandbox PATH entry is outside the mounted roots")
        }
        var duplicate = false
        for (existing in result where existing == normalized) { duplicate = true }
        if (!duplicate) { result.add(normalized) }
    }
    result.toArray()
}


func requireRuntimeBinaries(policy: WorkspaceSandboxPolicy): SandboxResult<Unit> {
    if (!isLinuxHost()) {
        return sandboxError<Unit>(
            SandboxErrorKind.Configuration,
            "sandbox.platform_unsupported",
            "workspace sandbox requires Linux bubblewrap"
        )
    }
    if (!regularFile(policy.bubblewrapExecutable)) {
        return sandboxError<Unit>(
            SandboxErrorKind.Configuration,
            "sandbox.bubblewrap_unavailable",
            "bubblewrap executable is unavailable; refusing unsandboxed execution"
        )
    }
    if (!regularFile(policy.timeoutExecutable)) {
        return sandboxError<Unit>(
            SandboxErrorKind.Configuration,
            "sandbox.timeout_unavailable",
            "timeout executable is unavailable; refusing execution without a deadline boundary"
        )
    }
    if (!regularFile("/usr/bin/true")) {
        return sandboxError<Unit>(
            SandboxErrorKind.Configuration,
            "sandbox.runtime_incomplete",
            "sandbox probe executable is unavailable"
        )
    }
    if (policy.resources.usesProcessLimits() && !regularFile("/usr/bin/prlimit")) {
        return sandboxError<Unit>(
            SandboxErrorKind.Configuration,
            "sandbox.prlimit_unavailable",
            "resource limits were requested but prlimit is unavailable"
        )
    }
    SandboxResult.Ok(())
}

func requireWorkspaceRoot(authored: String): String {
    if (!exists(Path(authored))) {
        throw IllegalArgumentException("sandbox workspace root must exist")
    }
    let root = canonicalize(authored).toString()
    if (!FileInfo(Path(root)).isDirectory()) {
        throw IllegalArgumentException("sandbox workspace root must be a directory")
    }
    if (root == "/" || withinPath(root, "/usr") || withinPath(root, "/bin") ||
        withinPath(root, "/lib") || withinPath(root, "/lib64") || withinPath(root, "/etc") ||
        withinPath(root, "/proc") || withinPath(root, "/dev")) {
        throw IllegalArgumentException("sandbox workspace root overlaps a protected system mount")
    }
    root
}

func requireAbsoluteExecutablePath(path: String, label: String): String {
    if (!Path(path).isAbsolute() || path.contains("\u{0000}")) {
        throw IllegalArgumentException(label + " executable path must be absolute")
    }
    Path(path).normalize().toString()
}

func regularFile(path: String): Bool {
    try {
        exists(Path(path)) && FileInfo(Path(path)).isRegular()
    } catch (_: Exception) {
        false
    }
}

func withinPath(path: String, root: String): Bool {
    if (path == root) { return true }
    if (root == "/") { return path.startsWith("/") }
    path.startsWith(root + "/")
}

func timeoutDuration(milliseconds: Int64): String {
    let seconds = milliseconds / 1000
    let remainder = milliseconds % 1000
    var fraction = remainder.toString()
    while (fraction.size < 3) { fraction = "0" + fraction }
    seconds.toString() + "." + fraction + "s"
}

func ensureUniqueEnvironment(entries: Array<SandboxEnvironmentEntry>): Unit {
    let seen = ArrayList<String>()
    for (entry in entries) {
        if (containsName(seen.toArray(), entry.name)) {
            throw IllegalArgumentException("duplicate sandbox environment name: " + entry.name)
        }
        seen.add(entry.name)
    }
}

func uniqueEnvironmentNames(values: Array<String>): Array<String> {
    let result = ArrayList<String>()
    for (value in values) {
        requireEnvironmentName(value)
        if (!containsName(result.toArray(), value)) { result.add(value) }
    }
    result.toArray()
}

func requireEnvironmentName(name: String): Unit {
    if (!validEnvironmentName(name)) {
        throw IllegalArgumentException("invalid environment variable name")
    }
}

func validEnvironmentName(name: String): Bool {
    if (name == "" || name.contains("=") || name.contains("\u{0000}")) { return false }
    for (byte in name.toArray()) {
        let valid = (byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_'
        if (!valid) { return false }
    }
    true
}

func containsName(values: Array<String>, name: String): Bool {
    for (value in values where value == name) { return true }
    false
}

func upsertEnvironment(values: ArrayList<SandboxEnvironmentEntry>, entry: SandboxEnvironmentEntry): Unit {
    for (index in 0..values.size) {
        if (values[index].name == entry.name) {
            values[index] = entry
            return
        }
    }
    values.add(entry)
}

func addSecret(values: ArrayList<String>, value: String, minimum: Int64): Unit {
    if (value.size < minimum || value == "") { return }
    for (existing in values where existing == value) { return }
    values.add(value)
}

func uniqueLongValues(values: Array<String>, minimum: Int64): Array<String> {
    let result = ArrayList<String>()
    for (value in values) { addSecret(result, value, minimum) }
    result.toArray()
}

func longestFirst(values: Array<String>): Array<String> {
    let result = ArrayList<String>()
    for (value in values) {
        result.add(value)
        var index = result.size - 1
        while (index > 0 && result[index].size > result[index - 1].size) {
            let previous = result[index - 1]
            result[index - 1] = result[index]
            result[index] = previous
            index -= 1
        }
    }
    result.toArray()
}

func sandboxError<T>(
    kind: SandboxErrorKind,
    code: String,
    message: String,
    fields!: Array<SandboxErrorField> = []
): SandboxResult<T> {
    SandboxResult.Err(SandboxError(kind, code, message, fields: fields))
}

@When[os == "Linux"]
func isLinuxHost(): Bool { true }

@When[os != "Linux"]
func isLinuxHost(): Bool { false }
