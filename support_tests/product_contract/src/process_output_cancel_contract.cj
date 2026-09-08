package product_contract

import yjson_support.*
import yjson.*
import agent_domain.*
import agent_ports.*
import agent_product.*
import agent_testkit.*
import tool_runtime.*
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
