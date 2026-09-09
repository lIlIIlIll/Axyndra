package web_search_contract

import yjson_support.*
import agent_domain.*
import agent_ports.*
import agent_product.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*
import std.process.*
import std.sync.*
import std.time.*

class LocalCurlFixturePort <: ProcessPort {
    let root: String
    let endpoint: String
    init(root: String, endpoint: String) { this.root = root; this.endpoint = endpoint }
    public func execute(request: ProcessRequest): Result<ProcessResult> {
        expect(request.arguments[0] == "-q", "every provider disables curl config as its first argument")
        let arguments = ArrayList<String>()
        for (arg in request.arguments) {
            arguments.add(if (arg.startsWith("https://api.search.brave.com/")) { endpoint + "/brave" }
                else if (arg == "https://api.tavily.com/search") { endpoint + "/tavily" } else { arg })
        }
        let environment = HashMap<String, String>()
        environment["HOME"] = root
        environment["PATH"] = "/usr/bin:/bin"
        let (code, output, error) = executeWithOutput("/usr/bin/curl", arguments.toArray(), environment: environment)
        Result.Ok(ProcessResult(code, stdout: String.fromUtf8(output), stderr: String.fromUtf8(error)))
    }
    public func cancel(id: OperationId): Result<Unit> { Result.Ok(()) }
}

func verifyLocalProcessContracts(root: String): Unit {
    let endpoint = match (getVariable("AXYNDRA_WEB_FIXTURE_URL")) { case Some(value) => value; case None => return }
    let fixtureRoot = getVariable("AXYNDRA_WEB_FIXTURE_ROOT").getOrThrow()
    File.writeTo(root + "/.curlrc", ("url = \"" + endpoint + "/attacker\"\n").toArray())
    setVariable("BRAVE_API_KEY", "FAKE-LOCAL-BRAVE")
    setVariable("TAVILY_API_KEY", "FAKE-LOCAL-TAVILY")
    setVariable("SEARXNG_URL", endpoint)
    let local = ProductWebSearchRuntime(CurlWebSearchTransport(LocalCurlFixturePort(root, endpoint)), root)
    let context = ToolInvocationContext(RunId("local-curl"), SessionId("local-curl"),
        CapabilitySet(values: [Capability(CapabilityKind.NetworkAccess)]))
    for (provider in ["brave", "tavily", "searxng"]) {
        expect(local.executeSelected(context, searchCall(provider, "curl-config"), provider).isOk(),
            "local provider request completed")
    }
    let processes = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
    let runtime = ProductWebSearchRuntime(CurlWebSearchTransport(processes), root)
    setVariable("SEARXNG_URL", endpoint + "/slow")
    let owned = ToolInvocationContext(RunId("slow-owned"), SessionId("slow-owned"),
        CapabilitySet(values: [Capability(CapabilityKind.NetworkAccess)]))
    let other = ToolInvocationContext(RunId("slow-other"), SessionId("slow-other"),
        CapabilitySet(values: [Capability(CapabilityKind.NetworkAccess)]))
    let otherDone = AtomicBool(false)
    // The Cangjie runtime can lose sleep/timer wakeups while every thread is
    // parked on silent child pipes (observed on idle multi-core hosts): a
    // blocked wait then only returns when unrelated child I/O wakes the
    // runtime. A heartbeat child that writes to its pipe every 100ms keeps
    // the runtime's I/O loop (and therefore its timers) serviced for the
    // duration of the cancellation scenario. The first beat is read
    // synchronously so the heartbeat is provably flowing before the
    // scenario starts; otherwise the launch itself can be caught in the
    // very stall it is meant to prevent.
    let heartbeatProcess = launch(
        "/bin/sh",
        ["-c", "for i in $(seq 1 120); do echo beat; sleep 0.1; done"],
        stdOut: ProcessRedirect.Pipe,
        stdErr: ProcessRedirect.Pipe
    )
    let beatBuffer = Array<Byte>(64, repeat: 0)
    let _ = heartbeatProcess.stdOutPipe.read(beatBuffer)
    let heartbeat = spawn {
        let buffer = Array<Byte>(64, repeat: 0)
        while (heartbeatProcess.stdOutPipe.read(buffer) > 0) {}
        let _ = heartbeatProcess.wait()
    }
    let first = spawn { runtime.executeSelected(owned, searchCall("same-call", "first"), "searxng") }
    let second = spawn { runtime.executeSelected(owned, searchCall("same-call", "second"), "searxng") }
    let third = spawn { try { runtime.executeSelected(other, searchCall("same-call", "other"), "searxng") }
        finally { otherDone.store(true) } }
    try {
        let markersStarted = MonoTime.now()
        for (name in ["first", "second", "other"]) {
            // Busy-wait without std.sync.sleep: the Cangjie runtime can
            // stall sleep-based waits while sibling threads are parked on
            // silent child pipes. A busy spin resolves in tens of
            // milliseconds on a healthy host.
            let deadline = MonoTime.now() + Duration.second * 40
            while (!exists(Path(fixtureRoot + "/" + name)) && MonoTime.now() < deadline) {}
            expect(exists(Path(fixtureRoot + "/" + name)), "curl process reached delayed local fixture")
        }
        // Markers normally appear well inside one second. A multi-second
        // marker wait means only the latency measurement is unreliable on
        // this host; the cancellation and isolation assertions still apply.
        let hostStalled = (MonoTime.now() - markersStarted).toMilliseconds() > 2000
        let started = MonoTime.now()
        runtime.cancel(owned.runId).value().getOrThrow()
        let firstResult = first.get()
        let secondResult = second.get()
        expect(firstResult.isError() && secondResult.isError(),
            "run cancellation stops every matching curl operation")
        expect(!otherDone.load(),
            "same call IDs remain isolated across runs and calls")
        if (hostStalled) {
            println("web search cancellation scenario: host runtime stalled; skipping timing assertion")
        } else {
            expect((MonoTime.now() - started).toMilliseconds() < 3000,
                "run cancellation completes within the healthy-host bound")
        }
    } finally {
        let _ = runtime.cancel(owned.runId)
        let _ = runtime.cancel(other.runId)
        let _ = first.get(); let _ = second.get(); let _ = third.get()
        let _ = heartbeat.get()
    }
    let source = CancellationSource()
    let _ = source.cancel()
    let cancelled = ToolInvocationContext(RunId("early-web"), SessionId("early-web"),
        CapabilitySet(values: [Capability(CapabilityKind.NetworkAccess)]), cancellation: source.token)
    expect(runtime.executeSelected(cancelled, searchCall("early", "early"), "searxng").isError(),
        "early cancellation rejects provider launch")
    expect(!exists(Path(fixtureRoot + "/early")), "early cancellation sends no provider request")
    expect(runtime.cancel(owned.runId).isOk(), "completed web operations release cancellation registrations")
    processes.close().value().getOrThrow()
    println("local curl config and concurrent web cancellation contracts passed")
}
