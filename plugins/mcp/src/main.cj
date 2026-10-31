package mcp_client_plugin

import std.env.*
import std.collection.*
import std.io.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

class InvocationJob {
    let invocation: JsonNode
    let cancelled = AtomicBool(false)
    let done = AtomicBool(false)
    let deadline: MonoTime
    init(invocation: JsonNode, deadline: MonoTime) { this.invocation = invocation; this.deadline = deadline }
}
func runProtocol(): Int64 {
    let extensionId = installedMcpPackageId()
    let output = WireOutput()
    let input = ProtocolInput()
    let session = McpPluginSession(output)
    var hello: ?JsonNode = None
    var active: ?InvocationJob = None
    var worker: ?Future<Unit> = None
    var transfer: ?PayloadReceiver = None
    let windows = HashSet<String>()
    try {
        while (true) {
            let incoming = readFrame(input, maxBytes: output.limits.frame, payloadEnabled: output.limits.payload.isSome())
            if (incoming.isNone()) { return 0 }
            let physicalCharge = input.takeFrameCharge()
            var chargeTransferred = false
            try {
            var frame = incoming.getOrThrow()
            var kind = text(frame, "type")
            if (kind == "hello") {
                require(hello.isNone() && text(frame, "protocol") == "axyndra-js-host-v2" &&
                    text(frame, "extension_id") == extensionId && text(frame, "extension_version") == "1.0.0" &&
                    number(frame, "generation") > 0, "mcp_plugin.hello_invalid")
                output.configure(frame)
                hello = Some(frame)
                output.write(jsonObject([JsonObjectEntry("type", jsonString("ready")),
                    JsonObjectEntry("protocol", field(frame, "protocol")), JsonObjectEntry("extension_id", field(frame, "extension_id")),
                    JsonObjectEntry("extension_version", field(frame, "extension_version")), JsonObjectEntry("generation", field(frame, "generation")),
                    JsonObjectEntry("capabilities", field(frame, "capabilities")), JsonObjectEntry("tools", jsonArray([])),
                    JsonObjectEntry("commands", jsonArray([])), JsonObjectEntry("hooks", jsonArray([])),
                    JsonObjectEntry("services", jsonArray([jsonObject([JsonObjectEntry("name", jsonString("session")),
                        JsonObjectEntry("description", jsonString("MCP client session"))])]))]))
                continue
            }
            require(hello.isSome(), "mcp_plugin.hello_required")
            for (name in ["protocol", "extension_id", "extension_version", "generation"]) {
                require(stringifyUnifiedJson(field(frame, name)) == stringifyUnifiedJson(field(hello.getOrThrow(), name)), "mcp_plugin.identity_invalid")
            }
            if (kind == "payload_begin") {
                require(transfer.isNone() && (active.isNone() || active.getOrThrow().done.load()), "mcp_plugin.payload_overlap")
                let receiver = PayloadReceiver(frame, output.limits, extensionId)
                if (windows.contains(receiver.window) || windows.size >= 8192) { receiver.close(); throw PluginFailure("mcp_plugin.payload_reused") }
                windows.add(receiver.window); transfer = Some(receiver); input.transferDeadline = Some(receiver.deadline)
                continue
            }
            if (transfer.isSome()) {
                let receiver = transfer.getOrThrow()
                if (kind == "cancel") {
                    require(sameIdentity(receiver.invocation, frame), "mcp_plugin.cancel_identity_invalid")
                    receiver.close(); transfer = None; input.transferDeadline = None; session.abort()
                    output.write(jsonObject(envelope(frame, "cancelled").toArray())); continue
                }
                let assembled = receiver.accept(frame)
                if (assembled.isNone()) { continue }
                frame = assembled.getOrThrow(); kind = "invoke"; input.transferDeadline = None
            } else { require(!kind.startsWith("payload_"), "mcp_plugin.payload_missing_begin") }
            if (kind == "service_response") { session.receive(frame); continue }
            if (kind == "cancel") {
                require(active.isSome() && sameIdentity(active.getOrThrow().invocation, frame), "mcp_plugin.cancel_identity_invalid")
                let job = active.getOrThrow(); job.cancelled.store(true); session.abort(); job.done.store(true)
                output.write(jsonObject(envelope(frame, "cancelled").toArray())); continue
            }
            require(kind == "invoke" && (active.isNone() || active.getOrThrow().done.load()), "mcp_plugin.concurrent_invocation")
            validateInvocation(frame, extensionId: extensionId, limits: output.limits)
            match (worker) { case Some(value) => value.get(); case None => () }
            let invocationFrame = frame
            let job = InvocationJob(invocationFrame, match (transfer) { case Some(value) => value.deadline
                case None => MonoTime.now() + Duration.millisecond * output.limits.timeout }); active = Some(job)
            let ownedTransfer = transfer
            worker = Some(spawn {
                var resultCharge: ?PayloadCharge = None
                try {
                    // Reserve before the MCP response decoder, cache copies and
                    // JSON result construction, not only before serialization.
                    if (output.limits.payload.isSome()) {
                        let maximum = if (text(invocationFrame, "kind") == "service_prepare") { output.limits.prepared } else { output.limits.result }
                        resultCharge = Some(payloadPool.acquire(maximum + 65536))
                    }
                    let reply = session.handle(invocationFrame, responseBudget: resultCharge)
                    // The terminal may be consumed before finally runs. Admit the next
                    // frame now, but its worker.get() still joins this exact worker
                    // before any session access or new result reservation.
                    job.done.store(true)
                    output.result(invocationFrame, reply.value, reply.ok, allowed: { => !job.cancelled.load() }, deadline: Some(job.deadline), reserved: resultCharge.isSome())
                } catch (error: PluginFailure) {
                    job.done.store(true)
                    output.result(invocationFrame, jsonObject([JsonObjectEntry("error", jsonString(error.code))]), false,
                        allowed: { => !job.cancelled.load() }, deadline: Some(job.deadline), reserved: resultCharge.isSome())
                } catch (_: Exception) {
                    session.abort()
                    job.done.store(true)
                    output.result(invocationFrame, jsonObject([JsonObjectEntry("error", jsonString("mcp_plugin.session_failed"))]), false,
                        allowed: { => !job.cancelled.load() }, deadline: Some(job.deadline), reserved: resultCharge.isSome())
                } finally {
                    match (resultCharge) { case Some(value) => value.close(); case None => () }
                    match (ownedTransfer) { case Some(value) => value.close(); case None => () }
                    match (physicalCharge) { case Some(value) => value.close(); case None => () }
                    job.done.store(true)
                }
            })
            transfer = None; chargeTransferred = true
            } finally { if (!chargeTransferred) { match (physicalCharge) { case Some(value) => value.close(); case None => () } } }
        }
        0
    } finally {
        // Stop result publication before abort wakes the invocation worker.
        match (active) { case Some(job) => job.cancelled.store(true); case None => () }
        match (transfer) { case Some(value) => value.close(); case None => () }
        session.abort()
        match (worker) { case Some(value) => value.get(); case None => () }
        session.close()
    }
}
main(): Int64 {
    if (getCommandLine().size != 1) { return 2 }
    try { runProtocol() } catch (_: Exception) {
        getStdErr().write("MCP plugin rejected its protocol stream\n".toArray()); 3
    }
}
