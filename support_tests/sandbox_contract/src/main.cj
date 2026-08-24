package sandbox_contract

import agent_domain.*
import agent_product.*
import sandbox4cj.*
import std.env.*
import std.fs.*

main(): Int64 {
    let root = prepareWorkspace()
    if (!pathEscapeIsRejected(root)) { return 1 }
    if (!environmentIsDefaultDeny()) { return 1 }
    if (!redactionIsLongestFirstAndSkipsShortValues()) { return 1 }
    if (!policyArgumentsAreExplicit(root)) { return 1 }
    if (!toolchainMountAndControlledPathAreExplicit(root)) { return 1 }
    if (!unsupportedFailsClosed(root)) { return 1 }
    if (!realBubblewrapSmokeWhenSupported(root)) { return 1 }
    if (!processPortRequiresSandbox(root)) { return 1 }
    if (!realProcessPortSmokeWhenSupported(root)) { return 1 }
    println("sandbox_contract: all contracts passed")
    0
}

func processPortRequiresSandbox(root: String): Bool {
    let processes = LocalProcessPort(
        LocalWorkspace(root),
        sandboxEnabled: false
    )
    let direct = processes.execute(ProcessRequest(
        "/usr/bin/true",
        operationId: OperationId("required-direct"),
        sandboxMode: ProcessSandboxMode.WorkspaceReadOnly
    ))
    let shell = processes.executeShell(
        SessionId("required-shell-session"),
        ProcessRequest(
            "/bin/bash",
            operationId: OperationId("required-shell"),
            arguments: ["--noprofile", "--norc", "-lc", "true"],
            sandboxMode: ProcessSandboxMode.WorkspaceReadOnly
        )
    )
    expect(
        errorCode(direct) == "sandbox.required" &&
            errorCode(shell) == "sandbox.required",
        "non-host ProcessRequest execution fails closed when sandbox enforcement is disabled"
    )
}

func realProcessPortSmokeWhenSupported(root: String): Bool {
    let processes = LocalProcessPort(
        LocalWorkspace(root),
        sandboxEnabled: true
    )
    let productLimits = processes.sandboxResourceLimits()
    if (!expect(
        productLimits.maxOutputBytes > 0 && productLimits.addressSpaceBytes > 0 &&
            productLimits.fileSizeBytes > 0 && productLimits.openFiles > 0 &&
            productLimits.processes > 0 && productLimits.cpuSeconds > 0,
        "LocalProcessPort product defaults bound every declared resource dimension"
    )) { return false }
    let probe = processes.execute(ProcessRequest(
        "/usr/bin/true",
        operationId: OperationId("process-probe"),
        sandboxMode: ProcessSandboxMode.WorkspaceReadOnly
    ))
    match (probe) {
        case Result.Err(error) => return expect(
            sandboxUnavailable(error),
            "unavailable ProcessPort isolation is reported explicitly"
        )
        case Result.Ok(value) => if (value.exitCode != 0) {
            return expect(false, "sandbox-enabled ProcessPort probe succeeds")
        }
    }

    let limitedProcesses = LocalProcessPort(
        LocalWorkspace(root),
        sandboxEnabled: true,
        sandboxResources: SandboxResourceLimits(
            maxOutputBytes: 96,
            addressSpaceBytes: 1073741824,
            fileSizeBytes: 67108864,
            openFiles: 64,
            processes: 64,
            cpuSeconds: 30
        )
    )
    let oneShotLimit = limitedProcesses.execute(ProcessRequest(
        "/bin/bash",
        operationId: OperationId("resource-one-shot"),
        arguments: ["--noprofile", "--norc", "-lc", "ulimit -n; head -c 4096 /dev/zero | tr '\\000' x"],
        sandboxMode: ProcessSandboxMode.WorkspaceReadOnly
    ))
    let persistentLimit = limitedProcesses.executeShell(
        SessionId("resource-persistent-shell"),
        ProcessRequest(
            "/bin/bash",
            operationId: OperationId("resource-persistent"),
            arguments: [
                "--noprofile", "--norc", "-lc",
                "head -c 4096 /dev/zero | tr '\\000' y; printf marker-after-truncation"
            ],
            sandboxMode: ProcessSandboxMode.WorkspaceReadOnly
        )
    )
    let oneShotValue = match (oneShotLimit) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "one-shot resource limit failed: " + error.message)
    }
    let persistentValue = match (persistentLimit) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "persistent resource limit failed: " + error.message)
    }
    if (!expect(
        oneShotValue.exitCode == 0 && oneShotValue.stdout.startsWith("64\n") &&
            oneShotValue.truncated && oneShotValue.stdout.toArray().size <= 96 &&
            persistentValue.exitCode == 0 && persistentValue.truncated &&
            persistentValue.stdout.toArray().size <= 96,
        "real one-shot and persistent bwrap processes enforce prlimit and bounded output while finding a later marker"
    )) { return false }

    let readOnlyProof = root + "/process-read-only-proof"
    let writeProof = root + "/process-write-proof"
    let _ = removeIfExists(readOnlyProof)
    let _ = removeIfExists(writeProof)
    let readOnly = processes.executeShell(
        SessionId("sandbox-shell"),
        ProcessRequest(
            "/bin/bash",
            operationId: OperationId("process-read-only"),
            arguments: [
                "--noprofile", "--norc", "-lc",
                "touch " + shellQuote(readOnlyProof)
            ],
            sandboxMode: ProcessSandboxMode.WorkspaceReadOnly
        )
    )
    let writable = processes.executeShell(
        SessionId("sandbox-shell"),
        ProcessRequest(
            "/bin/bash",
            operationId: OperationId("process-write"),
            arguments: [
                "--noprofile", "--norc", "-lc",
                "touch " + shellQuote(writeProof)
            ],
            sandboxMode: ProcessSandboxMode.WorkspaceReadWrite
        )
    )
    setVariable("OMP_PROCESS_CONTRACT_SECRET", "process-contract-secret")
    let environment = processes.execute(ProcessRequest(
        "/usr/bin/env",
        operationId: OperationId("process-environment"),
        sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
        secretEnvironmentAllowlist: ["OMP_PROCESS_CONTRACT_SECRET"]
    ))
    removeVariable("OMP_PROCESS_CONTRACT_SECRET")
    let denied = match (readOnly) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "read-only ProcessPort launch failed: " + error.message)
    }
    let allowed = match (writable) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "read-write ProcessPort launch failed: " + error.message)
    }
    let environmentValue = match (environment) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "scoped environment launch failed: " + error.message)
    }
    if (!expect(
        denied.exitCode != 0 && !exists(Path(readOnlyProof)) &&
            allowed.exitCode == 0 && exists(Path(writeProof)) &&
            environmentValue.exitCode == 0 &&
            environmentValue.stdout.contains(
                "OMP_PROCESS_CONTRACT_SECRET=[REDACTED]"
            ) && !environmentValue.stdout.contains("process-contract-secret"),
        "ProcessPort enforces RO/RW mounts and redacts explicitly scoped secret environment"
    )) { return false }

    let child = root + "/profile-child"
    if (!exists(Path(child))) { Directory.create(child, recursive: true) }
    let session = SessionId("eval-profile-session")
    let baseRequest = ProcessRequest(
        "/usr/bin/python3",
        operationId: OperationId("eval-base-first"),
        workingDirectory: root,
        timeoutMillis: 3000,
        sandboxMode: ProcessSandboxMode.WorkspaceReadWrite
    )
    let initialized = processes.executeEval(
        session,
        "py",
        "value = 41\nvalue",
        false,
        baseRequest
    )
    let isolated = processes.executeEval(
        session,
        "py",
        "globals().get('value', 'missing')",
        false,
        ProcessRequest(
            "/usr/bin/python3",
            operationId: OperationId("eval-child"),
            workingDirectory: child,
            timeoutMillis: 3000,
            sandboxMode: ProcessSandboxMode.WorkspaceReadWrite
        )
    )
    let resumed = processes.executeEval(
        session,
        "py",
        "value + 1",
        false,
        ProcessRequest(
            "/usr/bin/python3",
            operationId: OperationId("eval-base-second"),
            workingDirectory: root,
            timeoutMillis: 3000,
            sandboxMode: ProcessSandboxMode.WorkspaceReadWrite
        )
    )
    let initializedValue = match (initialized) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "sandbox eval initialization failed: " + error.message)
    }
    let isolatedValue = match (isolated) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "sandbox eval profile split failed: " + error.message)
    }
    let resumedValue = match (resumed) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "sandbox eval resume failed: " + error.message)
    }
    expect(
        initializedValue.exitCode == 0 &&
            initializedValue.stdout.trimAscii() == "41" &&
            isolatedValue.exitCode == 0 &&
            isolatedValue.stdout.trimAscii() == "missing" &&
            resumedValue.exitCode == 0 &&
            resumedValue.stdout.trimAscii() == "42",
        "persistent eval runs under bwrap and caches kernels by exact sandbox profile"
    )
}

func sandboxUnavailable(error: AgentError): Bool {
    error.code == "sandbox.isolation_unsupported" ||
        error.code == "sandbox.bubblewrap_unavailable"
}

func shellQuote(value: String): String {
    "'" + value.replace("'", "'\\''") + "'"
}

func pathEscapeIsRejected(root: String): Bool {
    let sandbox = WorkspaceSandbox(WorkspaceSandboxPolicy(
        root,
        network: NetworkIsolationMode.Allowed
    ))
    let result = sandbox.plan(WorkspaceSandboxCommand(
        "/usr/bin/true",
        workingDirectory: ".."
    ))
    expect(
        errorCode(result) == "sandbox.path_escape",
        "canonical working-directory escape is rejected before launch"
    )
}

func environmentIsDefaultDeny(): Bool {
    let source = [
        SandboxEnvironmentEntry("VISIBLE", "public-value"),
        SandboxEnvironmentEntry("API_TOKEN", "very-secret-token")
    ]
    let denied = EnvironmentFilter(secretNames: ["API_TOKEN"]).filter(source)
    let allowed = EnvironmentFilter(
        allowlist: ["VISIBLE", "API_TOKEN"],
        secretNames: ["API_TOKEN"]
    ).filter(source)
    let scopedSecret = EnvironmentFilter(
        allowlist: ["VISIBLE", "API_TOKEN"],
        allowedSecrets: ["API_TOKEN"],
        secretNames: ["API_TOKEN"]
    ).filter(source)
    let deniedRequest = EnvironmentFilter(allowlist: ["VISIBLE"]).validateRequested([
        SandboxEnvironmentEntry("NOT_ALLOWED", "value")
    ])
    let deniedSecretRequest = EnvironmentFilter(
        allowlist: ["API_TOKEN"]
    ).validateRequested([SandboxEnvironmentEntry("API_TOKEN", "very-secret-token")])
    let allowedSecretRequest = EnvironmentFilter(
        allowlist: ["API_TOKEN"],
        allowedSecrets: ["API_TOKEN"]
    ).validateRequested([SandboxEnvironmentEntry("API_TOKEN", "very-secret-token")])
    expect(
        denied.entries.size == 0 && allowed.entries.size == 1 &&
            allowed.entries[0].name == "VISIBLE" &&
            scopedSecret.entries.size == 2 &&
            errorCode(deniedRequest) == "sandbox.environment_denied" &&
            errorCode(deniedSecretRequest) == "sandbox.environment_secret_denied" &&
            allowedSecretRequest.isOk() &&
            scopedSecret.redactor().redact("token=very-secret-token") == "token=[REDACTED]",
        "environment is default-deny and secrets require an explicit second grant"
    )
}

func redactionIsLongestFirstAndSkipsShortValues(): Bool {
    let redactor = SecretRedactor([
        "abcd",
        "abcdefgh",
        "xy"
    ])
    expect(
        redactor.redact("abcdefgh abcd xy") == "[REDACTED] [REDACTED] xy",
        "redactor replaces longest credentials first and ignores short values"
    )
}

func policyArgumentsAreExplicit(root: String): Bool {
    let denied = WorkspaceSandbox(WorkspaceSandboxPolicy(
        root,
        filesystem: FilesystemIsolationMode.WorkspaceReadOnly,
        process: ProcessIsolationMode.Isolated,
        network: NetworkIsolationMode.Denied,
        resources: SandboxResourceLimits(
            maxOutputBytes: 4096,
            openFiles: 64,
            processes: 8,
            cpuSeconds: 2
        )
    )).plan(WorkspaceSandboxCommand("/usr/bin/true"))
    let writable = WorkspaceSandbox(WorkspaceSandboxPolicy(
        root,
        filesystem: FilesystemIsolationMode.WorkspaceReadWrite,
        process: ProcessIsolationMode.Shared,
        network: NetworkIsolationMode.Allowed
    )).plan(WorkspaceSandboxCommand("/usr/bin/true"))
    let deniedPlan = match (denied) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) => return expect(false, "denied policy should produce plan: " + error.message)
    }
    let writablePlan = match (writable) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) => return expect(false, "writable policy should produce plan: " + error.message)
    }
    expect(
        contains(deniedPlan.sandboxArguments, "--unshare-net") &&
            contains(deniedPlan.sandboxArguments, "--unshare-pid") &&
            containsPair(deniedPlan.sandboxArguments, "--ro-bind", root) &&
            contains(deniedPlan.sandboxArguments, "--nofile=64") &&
            contains(deniedPlan.sandboxArguments, "--nproc=8") &&
            contains(deniedPlan.sandboxArguments, "--cpu=2") &&
            !contains(writablePlan.sandboxArguments, "--unshare-net") &&
            !contains(writablePlan.sandboxArguments, "--unshare-pid") &&
            containsPair(writablePlan.sandboxArguments, "--bind", root),
        "filesystem, process, network, and resource policies map to explicit argv"
    )
}

func toolchainMountAndControlledPathAreExplicit(root: String): Bool {
    let toolchain = root + "-toolchain"
    if (!exists(Path(toolchain + "/bin"))) {
        Directory.create(toolchain + "/bin", recursive: true)
    }
    File.writeTo(toolchain + "/bin/fake-cjpm", "fixture".toArray())
    let plan = WorkspaceSandbox(WorkspaceSandboxPolicy(
        root,
        readOnlyMounts: [SandboxReadOnlyMount(toolchain)],
        pathEntries: [toolchain + "/bin"]
    )).plan(WorkspaceSandboxCommand("fake-cjpm"))
    let value = match (plan) {
        case SandboxResult.Ok(item) => item
        case SandboxResult.Err(error) => return expect(false, "toolchain plan failed: " + error.message)
    }
    let path = environmentValue(value.environment, "PATH")
    expect(
        value.resolvedExecutable == canonicalize(toolchain + "/bin/fake-cjpm").toString() &&
            containsPair(value.sandboxArguments, "--ro-bind", toolchain) &&
            path == toolchain + "/bin:/usr/local/bin:/usr/bin:/bin",
        "explicit toolchain roots are read-only mounts and the ambient PATH is replaced with a controlled PATH"
    )
}

func unsupportedFailsClosed(root: String): Bool {
    let sandbox = WorkspaceSandbox(WorkspaceSandboxPolicy(
        root,
        network: NetworkIsolationMode.Allowed,
        bubblewrapExecutable: "/definitely/missing/bwrap"
    ))
    let planned = sandbox.plan(WorkspaceSandboxCommand("/usr/bin/true"))
    let executed = sandbox.execute(WorkspaceSandboxCommand("/usr/bin/true"))
    expect(
        errorCode(planned) == "sandbox.bubblewrap_unavailable" &&
            errorCode(executed) == "sandbox.bubblewrap_unavailable",
        "missing enforcement runtime is Unsupported and never falls back to host execution"
    )
}

func realBubblewrapSmokeWhenSupported(root: String): Bool {
    let _ = removeIfExists(root + "/read-only-proof")
    let _ = removeIfExists(root + "/write-proof")
    setVariable("OMP_SANDBOX_CONTRACT_SECRET", "contract-secret-value")
    let environment = EnvironmentFilter(
        allowlist: ["OMP_SANDBOX_VISIBLE", "OMP_SANDBOX_CONTRACT_SECRET"],
        allowedSecrets: ["OMP_SANDBOX_CONTRACT_SECRET"],
        secretNames: ["OMP_SANDBOX_CONTRACT_SECRET"]
    )
    setVariable("OMP_SANDBOX_VISIBLE", "visible-value")
    let readOnly = WorkspaceSandbox(WorkspaceSandboxPolicy(
        root,
        filesystem: FilesystemIsolationMode.WorkspaceReadOnly,
        network: NetworkIsolationMode.Allowed,
        environment: environment
    ))
    let available = readOnly.availability()
    match (available) {
        case SandboxResult.Err(error) =>
            removeVariable("OMP_SANDBOX_VISIBLE")
            removeVariable("OMP_SANDBOX_CONTRACT_SECRET")
            // Installed-but-restricted bwrap is still a correct fail-closed
            // outcome in a container that prohibits namespace creation.
            return expect(
                error.code == "sandbox.isolation_unsupported" ||
                    error.code == "sandbox.bubblewrap_unavailable",
                "unavailable kernel isolation is reported explicitly"
            )
        case SandboxResult.Ok(_) => ()
    }
    let environmentResult = readOnly.execute(WorkspaceSandboxCommand("/usr/bin/env"))
    let writeDenied = readOnly.execute(WorkspaceSandboxCommand(
        "/usr/bin/touch",
        arguments: [root + "/read-only-proof"]
    ))
    let writable = WorkspaceSandbox(WorkspaceSandboxPolicy(
        root,
        filesystem: FilesystemIsolationMode.WorkspaceReadWrite,
        network: NetworkIsolationMode.Allowed,
        environment: environment
    ))
    let writeAllowed = writable.execute(WorkspaceSandboxCommand(
        "/usr/bin/touch",
        arguments: [root + "/write-proof"]
    ))
    removeVariable("OMP_SANDBOX_VISIBLE")
    removeVariable("OMP_SANDBOX_CONTRACT_SECRET")
    let envValue = match (environmentResult) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) => return expect(false, "environment smoke failed: " + error.message)
    }
    let deniedValue = match (writeDenied) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) => return expect(false, "read-only smoke failed to launch: " + error.message)
    }
    let allowedValue = match (writeAllowed) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) => return expect(false, "writable smoke failed to launch: " + error.message)
    }
    expect(
        envValue.exitCode == 0 && envValue.stdout.contains("OMP_SANDBOX_VISIBLE=visible-value") &&
            !envValue.stdout.contains("contract-secret-value") &&
            envValue.stdout.contains("OMP_SANDBOX_CONTRACT_SECRET=[REDACTED]") &&
            deniedValue.exitCode != 0 && !exists(Path(root + "/read-only-proof")) &&
            allowedValue.exitCode == 0 && exists(Path(root + "/write-proof")),
        "real bubblewrap redacts explicitly scoped secrets and enforces workspace mount mode"
    )
}

func prepareWorkspace(): String {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = canonicalize("target").toString() + "/sandbox-contract-workspace"
    if (!exists(Path(root))) { Directory.create(root, recursive: true) }
    root
}

func contains(values: Array<String>, needle: String): Bool {
    for (value in values where value == needle) { return true }
    false
}

func containsPair(values: Array<String>, flag: String, path: String): Bool {
    if (values.size < 2) { return false }
    for (index in 0..(values.size - 1)) {
        if (values[index] == flag && values[index + 1] == path) { return true }
    }
    false
}

func errorCode<T>(value: Result<T>): String {
    match (value) {
        case Result.Ok(_) => ""
        case Result.Err(error) => error.code
    }
}

func errorCode<T>(value: SandboxResult<T>): String {
    match (value) {
        case SandboxResult.Ok(_) => ""
        case SandboxResult.Err(error) => error.code
    }
}

func environmentValue(values: Array<SandboxEnvironmentEntry>, name: String): String {
    for (value in values where value.name == name) { return value.value }
    ""
}

func expect(condition: Bool, message: String): Bool {
    if (condition) {
        println("PASS " + message)
        true
    } else {
        println("FAIL " + message)
        false
    }
}
