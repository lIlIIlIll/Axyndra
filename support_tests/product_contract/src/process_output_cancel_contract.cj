package product_contract

import yjson_support.*
import yjson.*
import agent_domain.*
import agent_runtime.*
import agent_product.*
import agent_testkit.*
import tool_runtime.*
import std.env.*
import std.fs.*
import std.process.*
import std.sync.*
import std.time.*

func runProcessRemediationContracts(root: String): Unit {
    let directory = root + "/process-remediation"
    Directory.create(directory, recursive: true)
    let workspace = LocalWorkspace(directory)
    let processes = LocalProcessPort(workspace, sandboxEnabled: true)
    let output = processes.execute(ProcessRequest("/bin/sh",
        arguments: ["-c", "printf '\\377A'; exit 9"])).value().getOrThrow()
    expect(output.exitCode == 9 && output.stdout == "�A" && !output.truncated,
        "host arbitrary bytes retain exit code and valid suffix")
    let size = processes.sandboxResourceLimits().maxOutputBytes
    let bounded = processes.execute(ProcessRequest("/bin/sh", arguments: ["-c",
        "head -c " + (size - 1).toString() + " /dev/zero | tr '\\000' a; printf '中'; exit 7"])).value().getOrThrow()
    expect(bounded.exitCode == 7 && bounded.truncated && bounded.stdout.endsWith("�"),
        "host byte cap cutting UTF8 retains command result: code=" + bounded.exitCode.toString() +
            " truncated=" + bounded.truncated.toString() + " size=" + bounded.stdout.size.toString() +
            " stderr=" + bounded.stderr + " tail=" + bounded.stdout[max(0, bounded.stdout.size - 12)..])
    let concurrent = processes.execute(ProcessRequest("/bin/sh", arguments: ["-c",
        "head -c 131072 /dev/zero | tr '\\000' e >&2; printf done"])).value().getOrThrow()
    expect(
        concurrent.exitCode == 0 && concurrent.stdout == "done" && concurrent.stderr.size == 131072,
        "host execution drains stdout and stderr concurrently"
    )
    let descriptorsBefore = Directory.readFrom("/proc/self/fd").size
    for (index in 0..12) {
        let result = processes.execute(ProcessRequest(
            "/bin/true",
            operationId: OperationId("process-fd-" + index.toString()),
            timeoutMillis: 3000,
            sandboxMode: ProcessSandboxMode.Host,
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.HostNetwork))
        )).value().getOrThrow()
        expect(result.exitCode == 0 && !result.timedOut,
            "short one-shot process exits normally during handle soak")
    }
    let descriptorsAfter = Directory.readFrom("/proc/self/fd").size
    expect(
        descriptorsAfter <= descriptorsBefore + 1,
        "completed process launches do not accumulate pipe handles: before=" +
            descriptorsBefore.toString() + " after=" + descriptorsAfter.toString()
    )
    let stubbornOperation = OperationId("stubborn-output-cancel")
    let stubborn = spawn {
        processes.execute(ProcessRequest(
            "/bin/sh",
            operationId: stubbornOperation,
            arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"],
            timeoutMillis: 10000
        ))
    }
    let registrationDeadline = MonoTime.now() + Duration.second * 3
    while (!processes.hasActiveOperation(stubbornOperation) && MonoTime.now() < registrationDeadline) {
        sleep(Duration.millisecond * 10)
    }
    expect(processes.hasActiveOperation(stubbornOperation), "stubborn process enters the owned registry")
    let startupReadyFile = directory + "/startup-cancel.ready"
    let startupOperation = OperationId("startup-cancel")
    let startup = spawn {
        processes.execute(ProcessRequest(
            "/bin/sh",
            operationId: startupOperation,
            arguments: ["-c", "sleep 5; printf ready > \"$1\"; sleep 5", "startup-cancel", startupReadyFile],
            timeoutMillis: 10000,
            sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied))
        ))
    }
    try {
        let startupDeadline = MonoTime.now() + Duration.second * 3
        while (!processes.hasActiveOperation(startupOperation) && MonoTime.now() < startupDeadline) {
            sleep(Duration.millisecond * 10)
        }
        expect(processes.hasActiveOperation(startupOperation),
            "startup process becomes cancellable before command readiness")
        expect(!exists(Path(startupReadyFile)), "startup delay has not completed before cancellation")
        expect(processes.cancel(startupOperation).isOk(), "startup cancellation is accepted")
        let startupResult = startup.get().value().getOrThrow()
        expect(
            startupResult.exitCode != 0 && !startupResult.timedOut &&
                !exists(Path(startupReadyFile)) && !processes.hasActiveOperation(startupOperation),
            "startup cancellation is distinct from timeout and releases ownership"
        )
    } finally {
        let _ = processes.cancel(startupOperation)
        let _ = startup.get()
        try { let _ = removeIfExists(startupReadyFile) } catch (_: Exception) {}
    }
    let cancelStarted = MonoTime.now()
    expect(processes.cancel(stubbornOperation).isOk(), "stubborn process cancellation is accepted")
    let stubbornResult = stubborn.get().value().getOrThrow()
    expect(
        stubbornResult.exitCode != 0 &&
            (MonoTime.now() - cancelStarted).toMilliseconds() < 3000 &&
            !processes.hasActiveOperation(stubbornOperation),
        "ignored SIGTERM escalates and releases the owned process"
    )
    let cooperativeReadyFile = directory + "/cooperative-cancel.ready"
    let cooperativeStoppedFile = directory + "/cooperative-cancel.stopped"
    let cooperativeOperation = OperationId("cooperative-cancel")
    let cooperative = spawn {
        processes.execute(ProcessRequest(
            "/bin/sh",
            operationId: cooperativeOperation,
            arguments: [
                "-c",
                "trap 'printf stopped > \"$2\"; exit 0' TERM; printf ready > \"$1\"; while :; do :; done",
                "cooperative",
                cooperativeReadyFile,
                cooperativeStoppedFile
            ],
            timeoutMillis: 10000,
            sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied))
        ))
    }
    try {
        let cooperativeDeadline = MonoTime.now() + Duration.second * 3
        while ((!exists(Path(cooperativeReadyFile)) ||
                !processes.hasActiveOperation(cooperativeOperation)) &&
               MonoTime.now() < cooperativeDeadline) {
            sleep(Duration.millisecond * 10)
        }
        expect(exists(Path(cooperativeReadyFile)) &&
                processes.hasActiveOperation(cooperativeOperation),
            "cooperative process is ready before cancellation")
        expect(processes.cancel(cooperativeOperation).isOk(),
            "cooperative cancellation is accepted")
        let cooperativeResult = cooperative.get().value().getOrThrow()
        expect(
            exists(Path(cooperativeStoppedFile)) && !cooperativeResult.timedOut &&
                !processes.hasActiveOperation(cooperativeOperation),
            "TERM handler completes before forced escalation"
        )
    } finally {
        let _ = processes.cancel(cooperativeOperation)
        let _ = cooperative.get()
        try { let _ = removeIfExists(cooperativeReadyFile) } catch (_: Exception) {}
        try { let _ = removeIfExists(cooperativeStoppedFile) } catch (_: Exception) {}
    }
    runEscapedDescendantCancellationContract(directory, processes)
    runThreadedDescendantCancellationContract(directory, processes)
    runDisplayServerEnvironmentContracts(directory, processes)
    runEvalStartupFailureContract(processes)
    let catalog = ToolCatalog()
    installLocalTools(catalog, workspace, processes).value().getOrThrow()
    let pipeline = ToolPipeline(catalog, InMemoryOperationRuntimePort(), RecordingAuditPort(), ProductIds(),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo))
    let source = CancellationSource()
    let context = ToolInvocationContext(RunId("grep-owned"), SessionId("grep-owned"),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]), cancellation: source.token)
    let otherSource = CancellationSource()
    let other = ToolInvocationContext(RunId("grep-other"), SessionId("grep-other"),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]), cancellation: otherSource.token)
    for (name in ["first", "second", "other"]) {
        let (code, _, _) = executeWithOutput("mkfifo", [directory + "/" + name])
        expect(code == 0, "create grep blocking pipe")
    }
    let first = spawn { checkedBlockingGrep(pipeline, context, directory + "/first") }
    let second = spawn { checkedBlockingGrep(pipeline, context, directory + "/second") }
    let otherDone = AtomicBool(false)
    let third = spawn { try { checkedBlockingGrep(pipeline, other, directory + "/other") } finally { otherDone.store(true) } }
    let firstReady = spawn { waitGrepProcess(directory + "/first") }
    let secondReady = spawn { waitGrepProcess(directory + "/second") }
    let otherReady = spawn { waitGrepProcess(directory + "/other") }
    try {
        // Observe the real rg commands in parallel; serial waits can let the
        // unrelated 15-second search timeout before cancellation is issued.
        let _ = firstReady.get()
        let _ = secondReady.get()
        let _ = otherReady.get()
        let started = MonoTime.now()
        let _ = source.cancel()
        let _ = pipeline.cancel(context.runId)
        expect(first.get().isError() && second.get().isError(), "cancel both concurrent grep calls in the run")
        let cancellationMillis = (MonoTime.now() - started).toMilliseconds()
        expect(cancellationMillis < 3000 && !otherDone.load(),
            "grep cancellation remains prompt and isolated: elapsed=" + cancellationMillis.toString() +
                "ms unrelated_completed=" + otherDone.load().toString())
    } finally {
        let _ = source.cancel()
        let _ = otherSource.cancel()
        let _ = pipeline.cancel(context.runId)
        let _ = pipeline.cancel(other.runId)
        let _ = first.get(); let _ = second.get(); let _ = third.get()
    }
    expect(executePipelineCall(pipeline, context, blockingGrep(directory + "/first")).isError(), "already cancelled grep cannot start a new operation")
    processes.close().value().getOrThrow()
    println("process lifecycle, eval startup, output and cancellation contracts passed")
}

func runEvalStartupFailureContract(processes: LocalProcessPort): Unit {
    let sessionId = SessionId("silent-eval-startup")
    let failedOperation = OperationId("silent-eval-startup")
    let failed = processes.executeEval(
        sessionId,
        "py",
        "40 + 2",
        false,
        ProcessRequest(
            "/usr/bin/true",
            operationId: failedOperation,
            timeoutMillis: 1000,
            sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied))
        )
    )
    match (failed) {
        case Result.Err(error) =>
            expect(
                error.code == "eval.runtime_write_failed",
                "silent eval startup failure has a stable transport diagnostic"
            )
        case Result.Ok(value) =>
            expect(
                value.exitCode == -1 && value.transportClosed && !value.timedOut,
                "silent eval runtime exit is classified as a closed transport"
            )
    }
    expect(!processes.hasActiveOperation(failedOperation),
        "failed eval startup releases its active process registration")
    let recoveredOperation = OperationId("silent-eval-recovered")
    let recovered = match (processes.executeEval(
        sessionId,
        "py",
        "40 + 2",
        false,
        ProcessRequest(
            "python3",
            operationId: recoveredOperation,
            timeoutMillis: 3000,
            sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied))
        )
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(
        recovered.exitCode == 0 && recovered.stdout.trimAscii() == "42" &&
            !recovered.transportClosed && !processes.hasActiveOperation(recoveredOperation),
        "eval starts a fresh process after a no-response runtime"
    )
}

func runEscapedDescendantCancellationContract(
    directory: String,
    processes: LocalProcessPort
): Unit {
    let pidFile = directory + "/escaped-descendant.ready"
    let heartbeatFile = directory + "/escaped-descendant.heartbeat"
    let operationId = OperationId("escaped-descendant-cancel")
    let worker = spawn {
        processes.execute(ProcessRequest(
            "/bin/sh",
            operationId: operationId,
            arguments: [
                "-c",
                "( setsid /bin/sh -c 'exec >/dev/null 2>&1; echo ready > \"$1\"; while :; do printf x >> \"$2\"; sleep 0.05; done' escaped \"$1\" \"$2\" ) & sleep 5",
                "leader",
                pidFile,
                heartbeatFile
            ],
            timeoutMillis: 10000,
            sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied))
        ))
    }
    try {
        let deadline = MonoTime.now() + Duration.second * 3
        while (!exists(Path(pidFile)) && MonoTime.now() < deadline) {
            sleep(Duration.millisecond * 10)
        }
        expect(exists(Path(pidFile)), "escaped descendant signals readiness")
        let heartbeatDeadline = MonoTime.now() + Duration.second * 3
        while (!exists(Path(heartbeatFile)) && MonoTime.now() < heartbeatDeadline) {
            sleep(Duration.millisecond * 10)
        }
        expect(exists(Path(heartbeatFile)), "escaped descendant starts heartbeat")
        let before = File.readFrom(heartbeatFile).size
        expect(processes.hasActiveOperation(operationId), "leader remains owned before cancellation")
        expect(processes.cancel(operationId).isOk(), "leader-exit descendant cancellation is accepted")
        sleep(Duration.millisecond * 250)
        let after = File.readFrom(heartbeatFile).size
        expect(
            before == after,
            "captured descendant stops after its leader exits"
        )
    } finally {
        let _ = processes.cancel(operationId)
        let _ = worker.get()
        try { let _ = removeIfExists(pidFile) } catch (_: Exception) {}
        try { let _ = removeIfExists(heartbeatFile) } catch (_: Exception) {}
    }
}

func runThreadedDescendantCancellationContract(
    directory: String,
    processes: LocalProcessPort
): Unit {
    let readyFile = directory + "/threaded-descendant.ready"
    let heartbeatFile = directory + "/threaded-descendant.heartbeat"
    let operationId = OperationId("threaded-descendant-cancel")
    let script =
        "import subprocess, sys, threading, time\n" +
        "def spawn_child():\n" +
        "    subprocess.Popen([\"setsid\", \"/bin/sh\", \"-c\", \"exec >/dev/null 2>&1; echo ready > $1; while :; do printf x >> $2; sleep 0.05; done\", \"worker\", sys.argv[1], sys.argv[2]])\n" +
        "threading.Thread(target=spawn_child).start()\n" +
        "time.sleep(5)\n"
    let worker = spawn {
        processes.execute(ProcessRequest(
            "/usr/bin/python3",
            operationId: operationId,
            arguments: ["-c", script, readyFile, heartbeatFile],
            timeoutMillis: 10000,
            sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied))
        ))
    }
    try {
        let deadline = MonoTime.now() + Duration.second * 3
        while (!exists(Path(readyFile)) && MonoTime.now() < deadline) {
            sleep(Duration.millisecond * 10)
        }
        expect(exists(Path(readyFile)), "threaded descendant signals readiness")
        let before = File.readFrom(heartbeatFile).size
        expect(processes.hasActiveOperation(operationId), "threaded leader remains owned before cancellation")
        expect(processes.cancel(operationId).isOk(), "threaded descendant cancellation is accepted")
        sleep(Duration.millisecond * 250)
        let after = File.readFrom(heartbeatFile).size
        expect(
            before == after,
            "captured child of a worker thread stops after cancellation"
        )
    } finally {
        let _ = processes.cancel(operationId)
        let _ = worker.get()
        try { let _ = removeIfExists(readyFile) } catch (_: Exception) {}
        try { let _ = removeIfExists(heartbeatFile) } catch (_: Exception) {}
    }
}


func runDisplayServerEnvironmentContracts(
    directory: String,
    processes: LocalProcessPort
): Unit {
    let output = directory + "/display-environment.txt"
    let fallbackOutput = directory + "/display-environment-fallback.txt"
    let pathOutput = directory + "/display-path.txt"
    let authority = directory + "/xauthority"
    let hostHome = directory + "/host-home"
    let originalHome = getVariable("HOME")
    let originalAuthority = getVariable("XAUTHORITY")
    let originalPath = getVariable("PATH")
    try {
        setVariable("HOME", hostHome)
        let callerPath = "/contract/clipboard-bin:/usr/bin:/bin"
        setVariable("PATH", callerPath)
        let pathProbe = displayPathEnvironmentProbe(processes, pathOutput)
        let pathValue = match (pathProbe) {
            case Result.Ok(_) => String.fromUtf8(File.readFrom(pathOutput))
            case Result.Err(error) => error.message
        }
        expect(
            pathProbe.isOk() && pathValue == "/usr/local/bin:/usr/bin:/bin",
            "display-server host process replaces caller PATH with fixed system directories"
        )
        setVariable("XAUTHORITY", authority)
        let explicit = displayEnvironmentProbe(processes, output)
        let explicitValue = match (explicit) {
            case Result.Ok(_) => String.fromUtf8(File.readFrom(output))
            case Result.Err(error) => error.message
        }
        expect(
            explicit.isOk() && explicitValue == authority,
            "display-server process preserves explicit X11 authority path"
        )
        removeVariable("XAUTHORITY")
        let fallbackAuthority = Path(hostHome).join(".Xauthority").normalize().toString()
        let fallback = displayEnvironmentProbe(processes, fallbackOutput)
        let fallbackValue = match (fallback) {
            case Result.Ok(_) => String.fromUtf8(File.readFrom(fallbackOutput))
            case Result.Err(error) => error.message
        }
        expect(
            fallback.isOk() && fallbackValue == fallbackAuthority,
            "display-server process derives the default X11 authority path"
        )
    } finally {
        match (originalAuthority) {
            case Some(value) => setVariable("XAUTHORITY", value)
            case None => removeVariable("XAUTHORITY")
        }
        match (originalHome) {
            case Some(value) => setVariable("HOME", value)
            case None => removeVariable("HOME")
        }
        match (originalPath) {
            case Some(value) => setVariable("PATH", value)
            case None => removeVariable("PATH")
        }
        try { let _ = removeIfExists(pathOutput) } catch (_: Exception) {}
        try { let _ = removeIfExists(output) } catch (_: Exception) {}
        try { let _ = removeIfExists(fallbackOutput) } catch (_: Exception) {}
    }
}

func displayEnvironmentProbe(
    processes: LocalProcessPort,
    output: String
): Result<ProcessResult> {
    processes.execute(ProcessRequest(
        "/bin/sh",
        arguments: [
            "-c",
            "printf '%s' \"$XAUTHORITY\" > \"$1\"",
            "display-environment",
            output
        ],
        timeoutMillis: 5000,
        sandboxMode: ProcessSandboxMode.Host,
        networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)),
        displayServerAccess: true
    ))
}
func displayPathEnvironmentProbe(
    processes: LocalProcessPort,
    output: String
): Result<ProcessResult> {
    processes.execute(ProcessRequest(
        "/bin/sh",
        arguments: [
            "-c",
            "printf '%s' \"$PATH\" > \"$1\"",
            "display-path-environment",
            output
        ],
        timeoutMillis: 5000,
        sandboxMode: ProcessSandboxMode.Host,
        networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)),
        displayServerAccess: true
    ))
}

func blockingGrep(name: String): ToolCall {
    ToolCall("grep-" + name, "grep", objectValue([
        ValueField("pattern", textValue("needle")), ValueField("path", textValue(name))]))
}

func waitGrepProcess(path: String): Unit {
    let deadline = MonoTime.now() + Duration.second * 6
    while (MonoTime.now() < deadline) {
        // Observe the actual executable and exact FIFO argument directly;
        // an extra SDK subprocess would introduce its own wait lifecycle.
        for (entry in Directory.readFrom("/proc")) {
            try {
                let arguments = String.fromUtf8(File.readFrom(entry.path.toString() + "/cmdline")).split("\0")
                if (arguments.isEmpty() || !(arguments[0] == "rg" || arguments[0].endsWith("/rg"))) { continue }
                var hasPattern = false
                var hasPath = false
                for (argument in arguments) {
                    if (argument == "needle") { hasPattern = true }
                    if (argument == path) { hasPath = true }
                }
                if (hasPattern && hasPath) { return }
            } catch (_: Exception) {} // Processes may exit while /proc is read.
        }
        sleep(Duration.millisecond * 10)
    }
    throw IllegalStateException("grep did not enter the blocking fixture: " + path)
}

func checkedBlockingGrep(pipeline: ToolPipeline, context: ToolInvocationContext, path: String): Result<ToolInvocationResult> {
    let result = executePipelineCall(pipeline, context, blockingGrep(path))
    match (result) {
        case Result.Err(error) => println("grep fixture ended: " + path + " " + error.code + ": " + error.message)
        case Result.Ok(ToolInvocationResult.Denied(denial)) => println("grep fixture denied: " + denial.reason.code + ": " + denial.reason.message)
        case Result.Ok(ToolInvocationResult.NeedsApproval(_)) => println("grep fixture needs approval: " + path)
        case Result.Ok(ToolInvocationResult.Completed(value)) => println("grep fixture completed: " + path +
            " isError=" + value.isError.toString() + " error=" + (value.output.field("error") ?? textValue("")).text +
            " message=" + (value.output.field("message") ?? textValue("")).text +
            " stderr=" + (value.output.field("stderr") ?? textValue("")).text)
    }
    result
}
