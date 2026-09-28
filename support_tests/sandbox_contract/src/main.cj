package sandbox_contract

import agent_domain.*
import agent_product.*
import sandbox4cj.*
import std.env.*
import std.fs.*
import std.process.*

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
    if (!gatewayProxyAuthenticationSmoke(root)) { return 1 }
    if (!realProcessPortSmokeWhenSupported(root)) { return 1 }
    if (!packageOnlyProcessPortSmokeWhenSupported(root)) { return 1 }
    if (!mediatedNetworkGatewaySmoke(root)) { return 1 }
    println("sandbox_contract: all contracts passed")
    0
}

func mediatedNetworkGatewaySmoke(root: String): Bool {
    let serverRoot = root + "/mediated-gateway-server"
    Directory.create(serverRoot, recursive: true)
    File.writeTo(serverRoot + "/index.html", "mediated-gateway-ok".toArray())
    let server = try {
        launch(
            "/usr/bin/python3",
            ["-m", "http.server", "18772", "--bind", "127.0.0.1", "--directory", serverRoot],
            stdOut: ProcessRedirect.Discard,
            stdErr: ProcessRedirect.Discard
        )
    } catch (error: Exception) {
        return expect(false, "could not start mediated gateway fixture: " + error.message)
    }
    sleep(Duration.millisecond * 100)
    let processes = LocalProcessPort(
        LocalWorkspace(root),
        sandboxEnabled: true,
        sandboxCaBundle: "/etc/ssl/certs/ca-certificates.crt",
        networkGateway: Some(LocalNetworkGatewayPort())
    )
    let deniedNetwork = processes.execute(ProcessRequest(
        "/usr/bin/curl",
        operationId: OperationId("denied-direct-network"),
        arguments: ["-q", "-fsS", "http://127.0.0.1:18772/"],
        timeoutMillis: 10000,
        sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
        networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied))
    ))
    let result = processes.execute(ProcessRequest(
        "/usr/bin/curl",
        operationId: OperationId("mediated-gateway-smoke"),
        arguments: ["-q", "-fsS", "http://127.0.0.1:18772/"],
        timeoutMillis: 10000,
        sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
        networkPolicy: Some(NetworkPolicy(
            NetworkPolicyMode.Mediated,
            egress: [NetworkEgressRule(
                "127.0.0.1",
                18772u16,
                privateAddresses: ["127.0.0.1"]
            )]
        ))
    ))
    try { server.terminate(force: true) } catch (_: Exception) {}
    try { server.wait() } catch (_: Exception) {}
    removeIfExists(Path(serverRoot), recursive: true)
    let deniedValue = match (deniedNetwork) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "direct network denial failed to launch: " + error.message)
    }
    if (!expect(
        deniedValue.exitCode != 0 && !deniedValue.stdout.contains("mediated-gateway-ok"),
        "direct host-loopback access is denied while the mediated route remains available"
    )) { return false }
    match (result) {
        case Result.Ok(value) => expect(
            value.exitCode == 0 && value.stdout.contains("mediated-gateway-ok"),
            "mediated ProcessPort requests cross the sandbox only through the policy gateway"
        )
        case Result.Err(error) => expect(false, "mediated ProcessPort gateway request failed: " + error.message)
    }
}

func gatewayProxyAuthenticationSmoke(root: String): Bool {
    let serverRoot = root + "/authenticated-gateway-server"
    Directory.create(serverRoot, recursive: true)
    let fixture =
        "from http.server import BaseHTTPRequestHandler, HTTPServer\n" +
        "class Handler(BaseHTTPRequestHandler):\n" +
        "    def do_GET(self):\n" +
        "        leaked = self.headers.get('Proxy-Authorization') is not None\n" +
        "        body = b'credential-leaked' if leaked else b'authenticated-gateway-ok'\n" +
        "        self.send_response(400 if leaked else 200)\n" +
        "        self.send_header('Content-Length', str(len(body)))\n" +
        "        self.end_headers()\n" +
        "        self.wfile.write(body)\n" +
        "    def log_message(self, format, *args):\n" +
        "        pass\n" +
        "HTTPServer(('127.0.0.1', 18774), Handler).serve_forever()\n"
    let server = try {
        launch(
            "/usr/bin/python3",
            ["-c", fixture],
            stdOut: ProcessRedirect.Discard,
            stdErr: ProcessRedirect.Discard
        )
    } catch (error: Exception) {
        return expect(false, "could not start authenticated gateway fixture: " + error.message)
    }
    sleep(Duration.millisecond * 100)
    let gateway = LocalNetworkGatewayPort()
    let lease = match (gateway.acquire(
        OperationId("authenticated-gateway-smoke"),
        NetworkPolicy(
            NetworkPolicyMode.Mediated,
            egress: [NetworkEgressRule(
                "127.0.0.1", 18774u16, privateAddresses: ["127.0.0.1"]
            )]
        )
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            try { server.terminate(force: true) } catch (_: Exception) {}
            try { server.wait() } catch (_: Exception) {}
            removeIfExists(Path(serverRoot), recursive: true)
            return expect(false, "could not acquire authenticated gateway: " + error.message)
    }
    let endpoint = lease.proxyHost + ":" + lease.proxyPort.toString()
    let target = "http://127.0.0.1:18774/"
    let (unauthenticatedCode, _, _) = launch(
        "/usr/bin/curl",
        ["-q", "--noproxy", "", "-fsS", "--proxy", "http://" + endpoint, target],
        stdOut: ProcessRedirect.Pipe,
        stdErr: ProcessRedirect.Pipe
    ).waitOutput()
    let (authenticatedCode, authenticatedOutput, _) = launch(
        "/usr/bin/curl",
        [
            "-q", "--noproxy", "", "-fsS", "--proxy",
            "http://axyndra:" + lease.proxyCredential + "@" + endpoint,
            target
        ],
        stdOut: ProcessRedirect.Pipe,
        stdErr: ProcessRedirect.Pipe
    ).waitOutput()
    let _ = gateway.release(lease)
    try { server.terminate(force: true) } catch (_: Exception) {}
    try { server.wait() } catch (_: Exception) {}
    removeIfExists(Path(serverRoot), recursive: true)
    expect(
        unauthenticatedCode != 0 &&
        authenticatedCode == 0 &&
        String.fromUtf8(authenticatedOutput).contains("authenticated-gateway-ok"),
        "host proxy requires its lease credential and strips it before the origin"
    )
}

func packageOnlyProcessPortSmokeWhenSupported(root: String): Bool {
    let packageRoot = root + "-package-only"
    removeIfExists(Path(packageRoot), recursive: true)
    Directory.create(Path(packageRoot), recursive: true)
    File.writeTo(packageRoot + "/entrypoint", "package-visible".toArray())
    File.writeTo(root + "/workspace-secret", "must-stay-hidden".toArray())
    let result = LocalProcessPort(
        LocalWorkspace(root),
        sandboxEnabled: true
    ).execute(ProcessRequest(
        "/bin/sh",
        operationId: OperationId("package-only-process"),
        arguments: [
            "-c",
            "test -r \"$1\" && test ! -e \"$2\" && ! touch \"$3\"",
            "package-check",
            packageRoot + "/entrypoint",
            root + "/workspace-secret",
            packageRoot + "/write-proof"
        ],
        workingDirectory: packageRoot,
        sandboxMode: ProcessSandboxMode.IsolatedReadOnly,
        filesystemRoot: packageRoot,
        networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied))
    ))
    removeIfExists(Path(root + "/workspace-secret"))
    let wrotePackage = exists(Path(packageRoot + "/write-proof"))
    removeIfExists(Path(packageRoot), recursive: true)
    match (result) {
        case Result.Ok(value) => expect(
            value.exitCode == 0 && !wrotePackage,
            "package-only ProcessPort reads its package but neither workspace nor package writes"
        )
        case Result.Err(error) => expect(
            sandboxUnavailable(error),
            "unavailable package-only ProcessPort isolation is reported explicitly"
        )
    }
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
    let effectiveLimitProbe = limitedProcesses.execute(ProcessRequest(
        "/bin/bash",
        operationId: OperationId("resource-request-ceiling"),
        arguments: ["--noprofile", "--norc", "-lc", "ulimit -v; ulimit -f; ulimit -n; ulimit -u; ulimit -t"],
        sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
        processLimits: ExecutionResourceLimits(
            maxOutputBytes: 64,
            addressSpaceBytes: 536870912,
            fileSizeBytes: 33554432,
            openFiles: 16,
            processes: 16,
            cpuSeconds: 10
        )
    ))
    let oneShotLimit = limitedProcesses.execute(ProcessRequest(
        "/bin/bash",
        operationId: OperationId("resource-one-shot"),
        arguments: ["--noprofile", "--norc", "-lc", "ulimit -n; head -c 4096 /dev/zero | tr '\\000' x"],
        sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
        processLimits: ExecutionResourceLimits(
            maxOutputBytes: 32, openFiles: 16
        )
    ))
    let expandedLimit = limitedProcesses.execute(ProcessRequest(
        "/bin/bash",
        operationId: OperationId("resource-expanded-request"),
        arguments: ["--noprofile", "--norc", "-lc", "ulimit -n; head -c 4096 /dev/zero | tr '\\000' z"],
        sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
        processLimits: ExecutionResourceLimits(
            maxOutputBytes: 4096, openFiles: 128
        )
    ))
    let persistentLimit = limitedProcesses.executeShell(
        SessionId("resource-persistent-shell"),
        ProcessRequest(
            "/bin/bash",
            operationId: OperationId("resource-persistent"),
            arguments: [
                "--noprofile", "--norc", "-lc",
                "ulimit -n; head -c 4096 /dev/zero | tr '\\000' y; printf marker-after-truncation"
            ],
            sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
            processLimits: ExecutionResourceLimits(
                maxOutputBytes: 32, openFiles: 16
            )
        )
    )
    let memoryLimited = limitedProcesses.execute(ProcessRequest(
        "/usr/bin/python3",
        operationId: OperationId("resource-address-space"),
        arguments: ["-c", "bytearray(268435456); print('unexpected-success')"],
        timeoutMillis: 5000,
        sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
        processLimits: ExecutionResourceLimits(
            maxOutputBytes: 4096, addressSpaceBytes: 134217728
        )
    ))
    let cpuLimited = limitedProcesses.execute(ProcessRequest(
        "/bin/bash",
        operationId: OperationId("resource-cpu-loop"),
        arguments: ["--noprofile", "--norc", "-lc", "while :; do :; done"],
        timeoutMillis: 5000,
        sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
        processLimits: ExecutionResourceLimits(maxOutputBytes: 4096, cpuSeconds: 1)
    ))
    let effectiveLimitValue = match (effectiveLimitProbe) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "request resource limits failed: " + error.message)
    }
    let oneShotValue = match (oneShotLimit) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "one-shot resource limit failed: " + error.message)
    }
    let expandedValue = match (expandedLimit) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "expanded request resource limit failed: " + error.message)
    }
    let persistentValue = match (persistentLimit) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "persistent resource limit failed: " + error.message)
    }
    let memoryLimitedValue = match (memoryLimited) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "address-space exhaustion probe failed: " + error.message)
    }
    let cpuLimitedValue = match (cpuLimited) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "CPU exhaustion probe failed: " + error.message)
    }
    if (!expect(
        memoryLimitedValue.exitCode != 0 && !memoryLimitedValue.timedOut &&
            !memoryLimitedValue.stdout.contains("unexpected-success"),
        "address-space exhaustion terminates inside the configured process limit"
    )) { return false }
    if (!expect(
        cpuLimitedValue.exitCode != 0,
        "a CPU-bound loop is terminated by the configured CPU or wall limit"
    )) { return false }
    if (!expect(
        effectiveLimitValue.exitCode == 0 &&
            effectiveLimitValue.stdout.startsWith("524288\n32768\n16\n16\n10\n"),
        "ProcessRequest applies each requested RLIMIT: " + effectiveLimitValue.stdout.replace("\n", "/")
    )) { return false }
    if (!expect(
        oneShotValue.exitCode == 0 && oneShotValue.stdout.startsWith("16\n") &&
            oneShotValue.truncated && oneShotValue.stdout.toArray().size <= 32,
        "one-shot output/open-file limits apply: " + oneShotValue.stdout.replace("\n", "/")
    )) { return false }
    if (!expect(
        expandedValue.exitCode == 0 && expandedValue.stdout.startsWith("64\n") &&
            expandedValue.truncated && expandedValue.stdout.toArray().size <= 96,
        "larger request limits cannot exceed host ceilings: " + expandedValue.stdout.replace("\n", "/")
    )) { return false }
    if (!expect(
        persistentValue.exitCode == 0 && persistentValue.stdout.startsWith("16\n") &&
            persistentValue.truncated && persistentValue.stdout.toArray().size <= 32,
        "persistent shell applies request output/open-file limits: " + persistentValue.stdout.replace("\n", "/")
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
    let outputLimited = processes.executeEval(
        session,
        "py",
        "print('x' * 4096)",
        false,
        ProcessRequest(
            "/usr/bin/python3",
            operationId: OperationId("eval-output-limit"),
            workingDirectory: root,
            timeoutMillis: 3000,
            sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
            processLimits: ExecutionResourceLimits(maxOutputBytes: 32)
        )
    )
    let outputLimitedValue = match (outputLimited) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "eval output limit failed: " + error.message)
    }
    let recoveredAfterOutputLimit = processes.executeEval(
        session,
        "py",
        "40 + 2",
        false,
        ProcessRequest(
            "/usr/bin/python3",
            operationId: OperationId("eval-after-output-limit"),
            workingDirectory: root,
            timeoutMillis: 3000,
            sandboxMode: ProcessSandboxMode.WorkspaceReadWrite
        )
    )
    let recoveredAfterOutputLimitValue = match (recoveredAfterOutputLimit) {
        case Result.Ok(value) => value
        case Result.Err(error) => return expect(false, "eval kernel did not recover after output limit: " + error.message)
    }
    if (!expect(
        outputLimitedValue.exitCode == -1 && outputLimitedValue.truncated &&
            outputLimitedValue.transportClosed && outputLimitedValue.stdout == "" &&
            outputLimitedValue.stderr.contains("output exceeded") &&
            recoveredAfterOutputLimitValue.exitCode == 0 &&
            recoveredAfterOutputLimitValue.stdout.trimAscii() == "42",
        "eval output is bounded, reported truncated, and a later cell still executes"
    )) { return false }
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
            addressSpaceBytes: 1073741824,
            fileSizeBytes: 67108864,
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
            contains(deniedPlan.sandboxArguments, "--as=1073741824") &&
            contains(deniedPlan.sandboxArguments, "--fsize=67108864") &&
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
    setVariable("OMP_SANDBOX_HOST_ONLY", "host-only-value")
    let runtimeIsolation = runtimeIsolationSmoke(root)
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
    removeVariable("OMP_SANDBOX_HOST_ONLY")
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
    if (!expect(
        envValue.stdout.contains("HOME=" + root) &&
            envValue.stdout.contains("TMPDIR=/tmp") &&
            envValue.stdout.contains("LANG=C.UTF-8") &&
            envValue.stdout.contains("PATH=/usr/local/bin:/usr/bin:/bin") &&
            !envValue.stdout.contains("OMP_SANDBOX_HOST_ONLY="),
        "sandbox environment keeps only explicit values and runtime-owned defaults"
    )) { return false }
    if (!runtimeIsolation) { return false }
    expect(
        envValue.exitCode == 0 && envValue.stdout.contains("OMP_SANDBOX_VISIBLE=visible-value") &&
            !envValue.stdout.contains("contract-secret-value") &&
            envValue.stdout.contains("OMP_SANDBOX_CONTRACT_SECRET=[REDACTED]") &&
            deniedValue.exitCode != 0 && !exists(Path(root + "/read-only-proof")) &&
            allowedValue.exitCode == 0 && exists(Path(root + "/write-proof")),
        "real bubblewrap redacts explicitly scoped secrets and enforces workspace mount mode"
    )
}
func runtimeIsolationSmoke(root: String): Bool {
    let sandbox = WorkspaceSandbox(WorkspaceSandboxPolicy(
        root,
        filesystem: FilesystemIsolationMode.WorkspaceReadOnly,
        network: NetworkIsolationMode.Allowed
    ))
    let outsidePath = root + "-host-only"
    File.writeTo(outsidePath, "host-only-proof".toArray())
    let outside = sandbox.execute(WorkspaceSandboxCommand(
        "/usr/bin/cat",
        arguments: [outsidePath]
    ))
    removeIfExists(outsidePath)
    let outsideValue = match (outside) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) => return expect(false, "unmounted host file probe failed: " + error.message)
    }

    let privateTempMarker = "/tmp/" + root.replace("/", "_") + "-private-marker"
    let tempWrite = sandbox.execute(WorkspaceSandboxCommand(
        "/usr/bin/touch",
        arguments: [privateTempMarker]
    ))
    let tempRead = sandbox.execute(WorkspaceSandboxCommand(
        "/usr/bin/test",
        arguments: ["-e", privateTempMarker]
    ))
    let tempWriteValue = match (tempWrite) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) => return expect(false, "private temporary write failed to launch: " + error.message)
    }
    let tempReadValue = match (tempRead) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) => return expect(false, "private temporary isolation probe failed: " + error.message)
    }

    let readOnlyResource = root + "-toolchain"
    let resourceProof = readOnlyResource + "/runtime-write-proof"
    removeIfExists(resourceProof)
    let resourceWrite = WorkspaceSandbox(WorkspaceSandboxPolicy(
        root,
        filesystem: FilesystemIsolationMode.WorkspaceReadOnly,
        network: NetworkIsolationMode.Allowed,
        readOnlyMounts: [SandboxReadOnlyMount(readOnlyResource)]
    )).execute(WorkspaceSandboxCommand(
        "/usr/bin/touch",
        arguments: [resourceProof]
    ))
    let resourceValue = match (resourceWrite) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) => return expect(false, "read-only runtime mount probe failed: " + error.message)
    }

    let heldProcess = try {
        launch(
            "/usr/bin/sleep",
            ["30"],
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe
        )
    } catch (error: Exception) {
        return expect(false, "could not hold descriptor fixture process: " + error.message)
    }
    let descriptorProbe = try {
        WorkspaceSandbox(WorkspaceSandboxPolicy(
            root,
            filesystem: FilesystemIsolationMode.WorkspaceReadOnly,
            network: NetworkIsolationMode.Allowed,
            resources: SandboxResourceLimits(openFiles: 64)
        )).execute(WorkspaceSandboxCommand(
            "/usr/bin/python3",
            arguments: ["-c", "import os, resource; fds=[int(fd) for fd in os.listdir('/proc/self/fd')]; limit=resource.getrlimit(resource.RLIMIT_NOFILE)[0]; print('fds='+repr(fds)+' limit='+str(limit)); raise SystemExit(7 if max(fds) > 3 else 8 if limit != 64 else 0)"]
        ))
    } finally {
        try { let _ = heldProcess.terminate(force: true) } catch (_: Exception) {}
        try { let _ = heldProcess.wait() } catch (_: Exception) {}
    }
    let descriptorValue = match (descriptorProbe) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) => return expect(false, "minimal descriptor probe failed to launch: " + error.message)
    }
    if (!expect(
        outsideValue.exitCode != 0 && outsideValue.stdout == "",
        "sandbox cannot read an unmounted host file beside the workspace"
    )) { return false }
    if (!expect(
        tempWriteValue.exitCode == 0 && tempReadValue.exitCode != 0,
        "sandbox tmpfs is writable but private to one invocation"
    )) { return false }
    if (!expect(
        resourceValue.exitCode != 0 && !exists(Path(resourceProof)),
        "read-only runtime resources reject writes"
    )) { return false }
    expect(
        descriptorValue.exitCode == 0,
        "sandbox closes inherited descriptors and applies the configured open-file limit; exit=" + descriptorValue.exitCode.toString() + " output=" + descriptorValue.stdout.trimAscii() + " stderr=" + descriptorValue.stderr.trimAscii()
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
