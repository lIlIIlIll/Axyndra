package product_contract

import yjson_support.*
import yjson.*
import agent_domain.*
import agent_ports.*
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
    let cancelStarted = MonoTime.now()
    expect(processes.cancel(stubbornOperation).isOk(), "stubborn process cancellation is accepted")
    let stubbornResult = stubborn.get().value().getOrThrow()
    expect(
        stubbornResult.exitCode != 0 &&
            (MonoTime.now() - cancelStarted).toMilliseconds() < 3000 &&
            !processes.hasActiveOperation(stubbornOperation),
        "ignored SIGTERM escalates and releases the owned process"
    )
    runEscapedDescendantCancellationContract(directory, processes)
    runThreadedDescendantCancellationContract(directory, processes)
    runDisplayServerEnvironmentContracts(directory, processes)
    let catalog = ToolCatalog()
    installLocalTools(catalog, workspace, processes).value().getOrThrow()
    let pipeline = ToolPipeline(catalog, MemoryOperationRepository(), RecordingAuditPort(), ProductIds(),
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
    try {
        // Observe the real rg command, rather than assuming a sleep
        // has crossed the native process registration boundary.
        for (name in ["first", "second", "other"]) { waitGrepProcess(directory + "/" + name) }
        let started = MonoTime.now()
        let _ = source.cancel()
        let _ = pipeline.cancel(context.runId)
        expect(first.get().isError() && second.get().isError(), "cancel both concurrent grep calls in the run")
        expect((MonoTime.now() - started).toMilliseconds() < 3000 && !otherDone.load(),
            "grep cancellation is prompt and does not stop an unrelated run")
    } finally {
        let _ = source.cancel()
        let _ = otherSource.cancel()
        let _ = pipeline.cancel(context.runId)
        let _ = pipeline.cancel(other.runId)
        let _ = first.get(); let _ = second.get(); let _ = third.get()
    }
    expect(pipeline.invoke(context, blockingGrep(directory + "/first")).isError(), "already cancelled grep cannot start a new operation")
    processes.close().value().getOrThrow()
    println("process output and concurrent grep cancellation contracts passed")
}

func runEscapedDescendantCancellationContract(
    directory: String,
    processes: LocalProcessPort
): Unit {
    let pidFile = directory + "/escaped-descendant.pid"
    let operationId = OperationId("escaped-descendant-cancel")
    let worker = spawn {
        processes.execute(ProcessRequest(
            "/bin/sh",
            operationId: operationId,
            arguments: [
                "-c",
                "( setsid /bin/sh -c 'exec >/dev/null 2>&1; trap \"\" TERM; echo $$ > \"$1\"; while :; do sleep 1; done' escaped \"$1\" ) & sleep 5",
                "leader",
                pidFile
            ],
            timeoutMillis: 10000
        ))
    }
    var escapedPid: Int64 = 0
    try {
        let deadline = MonoTime.now() + Duration.second * 3
        while (!exists(Path(pidFile)) && MonoTime.now() < deadline) {
            sleep(Duration.millisecond * 10)
        }
        expect(exists(Path(pidFile)), "escaped descendant writes its identity")
        escapedPid = parseProcessPid(String.fromUtf8(File.readFrom(pidFile)))
        expect(processes.hasActiveOperation(operationId), "leader remains owned before cancellation")
        expect(processes.cancel(operationId).isOk(), "leader-exit descendant cancellation is accepted")
        let goneDeadline = MonoTime.now() + Duration.second * 2
        while (exists(Path("/proc/" + escapedPid.toString())) &&
            MonoTime.now() < goneDeadline) {
            sleep(Duration.millisecond * 10)
        }
        expect(
            !exists(Path("/proc/" + escapedPid.toString())),
            "captured descendant is killed after its leader exits"
        )
    } finally {
        if (escapedPid > 0) {
            let _ = executeWithOutput("kill", ["-KILL", escapedPid.toString()])
        }
        let _ = processes.cancel(operationId)
        let _ = worker.get()
        try { let _ = removeIfExists(pidFile) } catch (_: Exception) {}
    }
}

func runThreadedDescendantCancellationContract(
    directory: String,
    processes: LocalProcessPort
): Unit {
    let pidFile = directory + "/threaded-descendant.pid"
    let operationId = OperationId("threaded-descendant-cancel")
    let script =
        "import subprocess, sys, threading, time\n" +
        "def spawn_child():\n" +
        "    subprocess.Popen([\"setsid\", \"/bin/sh\", \"-c\", \"exec >/dev/null 2>&1; trap '' TERM; echo $$ > $1; while :; do sleep 1; done\", \"worker\", sys.argv[1]])\n" +
        "threading.Thread(target=spawn_child).start()\n" +
        "time.sleep(5)\n"
    let worker = spawn {
        processes.execute(ProcessRequest(
            "/usr/bin/python3",
            operationId: operationId,
            arguments: ["-c", script, pidFile],
            timeoutMillis: 10000
        ))
    }
    var threadedPid: Int64 = 0
    try {
        let deadline = MonoTime.now() + Duration.second * 3
        while (!exists(Path(pidFile)) && MonoTime.now() < deadline) {
            sleep(Duration.millisecond * 10)
        }
        expect(exists(Path(pidFile)), "threaded descendant writes its identity")
        threadedPid = parseProcessPid(String.fromUtf8(File.readFrom(pidFile)))
        expect(processes.hasActiveOperation(operationId), "threaded leader remains owned before cancellation")
        expect(processes.cancel(operationId).isOk(), "threaded descendant cancellation is accepted")
        let goneDeadline = MonoTime.now() + Duration.second * 2
        while (exists(Path("/proc/" + threadedPid.toString())) &&
            MonoTime.now() < goneDeadline) {
            sleep(Duration.millisecond * 10)
        }
        expect(
            !exists(Path("/proc/" + threadedPid.toString())),
            "captured child of a worker thread is killed"
        )
    } finally {
        if (threadedPid > 0) {
            let _ = executeWithOutput("kill", ["-KILL", threadedPid.toString()])
        }
        let _ = processes.cancel(operationId)
        let _ = worker.get()
        try { let _ = removeIfExists(pidFile) } catch (_: Exception) {}
    }
}

func parseProcessPid(value: String): Int64 {
    var result: Int64 = 0
    let text = value.trimAscii()
    if (text == "") { throw IllegalArgumentException("process pid is empty") }
    for (byte in text.toArray()) {
        if (byte < b'0' || byte > b'9') {
            throw IllegalArgumentException("process pid is not numeric")
        }
        result = result * 10 + Int64(byte - b'0')
    }
    result
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
            pathProbe.isOk() && pathValue == callerPath,
            "display-server process preserves the caller PATH for installed clients"
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
        displayServerAccess: true
    ))
}

func blockingGrep(name: String): ToolCall {
    ToolCall("grep-" + name, "grep", objectValue([
        ValueField("pattern", textValue("needle")), ValueField("path", textValue(name))]))
}

func waitGrepProcess(path: String): Unit {
    let deadline = MonoTime.now() + Duration.second * 10
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
    let result = pipeline.invoke(context, blockingGrep(path))
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
