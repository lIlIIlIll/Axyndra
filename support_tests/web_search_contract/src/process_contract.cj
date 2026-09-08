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
    let first = spawn { runtime.executeSelected(owned, searchCall("same-call", "first"), "searxng") }
    let second = spawn { runtime.executeSelected(owned, searchCall("same-call", "second"), "searxng") }
    let third = spawn { try { runtime.executeSelected(other, searchCall("same-call", "other"), "searxng") }
        finally { otherDone.store(true) } }
    try {
        for (name in ["first", "second", "other"]) {
            for (_ in 0..500) {
                if (exists(Path(fixtureRoot + "/" + name))) { break }
                sleep(Duration.millisecond * 10)
            }
            expect(exists(Path(fixtureRoot + "/" + name)), "curl process reached delayed local fixture")
        }
        let started = MonoTime.now()
        runtime.cancel(owned.runId).value().getOrThrow()
        expect(first.get().isError() && second.get().isError(), "run cancellation stops every matching curl operation")
        expect((MonoTime.now() - started).toMilliseconds() < 3000 && !otherDone.load(),
            "same call IDs remain isolated across runs and calls")
    } finally {
        let _ = runtime.cancel(owned.runId)
        let _ = runtime.cancel(other.runId)
        let _ = first.get(); let _ = second.get(); let _ = third.get()
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
