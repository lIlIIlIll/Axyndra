package eval_plugin

import std.env.*
import std.io.*
import std.sync.*
import yjson.*
import yjson_support.*

class InvocationJob {
    let invocation: JsonNode
    let cancelled = AtomicBool(false)
    let done = AtomicBool(false)
    init(invocation: JsonNode) { this.invocation = invocation }
}
func runProtocol(): Int64 {
    let output = WireOutput()
    let input = ProtocolInput()
    let session = EvalPluginSession(output)
    var hello: ?JsonNode = None
    var active: ?InvocationJob = None
    var worker: ?Future<Unit> = None
    try {
        while (true) {
            let incoming = readFrame(input)
            if (incoming.isNone()) { return 0 }
            let frame = incoming.getOrThrow()
            let kind = text(frame, "type")
            if (kind == "hello") {
                require(hello.isNone() && text(frame, "protocol") == "axyndra-js-host-v2" &&
                    text(frame, "extension_id") == "eval" && text(frame, "extension_version") == "1.0.0" &&
                    number(frame, "generation") > 0, "eval_plugin.hello_invalid")
                hello = Some(frame)
                output.write(jsonObject([JsonObjectEntry("type", jsonString("ready")),
                    JsonObjectEntry("protocol", field(frame, "protocol")), JsonObjectEntry("extension_id", field(frame, "extension_id")),
                    JsonObjectEntry("extension_version", field(frame, "extension_version")), JsonObjectEntry("generation", field(frame, "generation")),
                    JsonObjectEntry("capabilities", field(frame, "capabilities")), JsonObjectEntry("tools", jsonArray([])),
                    JsonObjectEntry("commands", jsonArray([])), JsonObjectEntry("hooks", jsonArray([])),
                    JsonObjectEntry("services", jsonArray([jsonObject([JsonObjectEntry("name", jsonString("session")),
                        JsonObjectEntry("description", jsonString("Persistent language cell session"))])]))]))
                continue
            }
            require(hello.isSome(), "eval_plugin.hello_required")
            for (name in ["protocol", "extension_id", "extension_version", "generation"]) {
                require(stringifyUnifiedJson(field(frame, name)) == stringifyUnifiedJson(field(hello.getOrThrow(), name)), "eval_plugin.identity_invalid")
            }
            if (kind == "service_response") { session.receive(frame); continue }
            if (kind == "cancel") {
                require(active.isSome() && sameIdentity(active.getOrThrow().invocation, frame), "eval_plugin.cancel_identity_invalid")
                let job = active.getOrThrow(); job.cancelled.store(true); session.abort(); job.done.store(true)
                output.write(jsonObject(envelope(frame, "cancelled").toArray())); continue
            }
            require(kind == "invoke" && (active.isNone() || active.getOrThrow().done.load()), "eval_plugin.concurrent_invocation")
            validateInvocation(frame)
            match (worker) { case Some(value) => value.get(); case None => () }
            let job = InvocationJob(frame); active = Some(job)
            worker = Some(spawn {
                try {
                    let reply = session.handle(frame)
                    job.done.store(true)
                    output.result(frame, reply.value, reply.ok, allowed: { => !job.cancelled.load() })
                } catch (error: PluginFailure) {
                    job.done.store(true)
                    output.result(frame, jsonObject([JsonObjectEntry("error", jsonString(error.code))]), false,
                        allowed: { => !job.cancelled.load() })
                } catch (_: Exception) {
                    session.abort()
                    job.done.store(true)
                    output.result(frame, jsonObject([JsonObjectEntry("error", jsonString("eval_plugin.session_failed"))]), false,
                        allowed: { => !job.cancelled.load() })
                } finally { job.done.store(true) }
            })
        }
        0
    } finally {
        // Stop result publication before abort wakes the invocation worker.
        match (active) { case Some(job) => job.cancelled.store(true); case None => () }
        session.abort()
        match (worker) { case Some(value) => value.get(); case None => () }
        session.close()
    }
}
main(): Int64 {
    if (getCommandLine().size != 1) { return 2 }
    try { runProtocol() } catch (_: Exception) {
        getStdErr().write("Eval plugin rejected its protocol stream\n".toArray()); 3
    }
}
