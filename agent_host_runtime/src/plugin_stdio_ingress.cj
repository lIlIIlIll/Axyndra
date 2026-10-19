package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import process4cj as ingress_process
import std.collection.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

let hostStdioIngressOwnerLock = Mutex()
var hostStdioIngressOwned = false

func hostIngressHex(value: String): String {
    let alphabet = "0123456789abcdef".toArray(); let bytes = ArrayList<Byte>()
    for (byte in value.toArray()) { bytes.add(alphabet[Int64(byte) / 16]); bytes.add(alphabet[Int64(byte) % 16]) }
    String.fromUtf8(bytes.toArray())
}
func hostIngressUnhex(value: String, maximum: Int64): String {
    hostLifecycleRequire(value.size % 2 == 0 && value.size <= maximum * 2)
    func digit(byte: Byte): Byte {
        if (byte >= b'0' && byte <= b'9') { return byte - b'0' }
        if (byte >= b'a' && byte <= b'f') { return byte - b'a' + 10u8 }
        throw IllegalArgumentException("invalid ingress bytes")
    }
    let raw = value.toArray(); let output = ArrayList<Byte>(); var index: Int64 = 0
    while (index < raw.size) { output.add(digit(raw[index]) * 16u8 + digit(raw[index + 1])); index += 2 }
    String.fromUtf8(output.toArray())
}
class HostIngressJob {
    let frame: ExternalReceivedFrame
    let id: ExternalRequestId
    let call: ToolCall
    let cancelled = AtomicBool(false)
    init(frame: ExternalReceivedFrame, id: ExternalRequestId, call: ToolCall) { this.frame = frame; this.id = id; this.call = call }
}

// One real inherited stdio connection. Only this owner touches fd0/fd1; it is
// not another Tool registry. The worker uses the same fixed Thread/catalog and
// the existing canonical External gateway; cancel input is read independently.
class HostStdioIngressOwner {
    private let control: HostStdioIngressRuntime
    private let host: HostJavaScriptPluginHost
    private let grant: HostStdioIngressGrant
    private var admittedConnection: ?ExternalIngressConnection = None
    private prop connection: ExternalIngressConnection { get() { admittedConnection.getOrThrow() } }
    private let lifetime: CancellationSource
    private var revocationRegistration: ?ingress_process.CancellationRegistration = None
    private let decoderLock = Mutex()
    private let queueLock = Mutex()
    private let queue = ArrayList<HostIngressJob>()
    private let seen = HashSet<String>()
    private var current: ?HostIngressJob = None
    private var cancelledDrainEligible = false
    private let terminalDraining = AtomicBool(false)
    private var terminalDrainDeadline: Int64 = 0
    private var failure: ?String = None
    private var endpoint: ?HostPinnedNativeServiceEndpoint = None
    private var writer: ?ingress_process.BorrowedPipeWriter = None
    private let outputLock = Mutex()
    private let output = ArrayList<String>()
    private var outputBytes: Int64 = 0
    private var outputCount: Int64 = 0
    private let closing = AtomicBool(false)
    private let readerDone = AtomicBool(true)
    private let closeLock = Mutex()
    private let workerDone = AtomicBool(true)
    private let outputDone = AtomicBool(true)
    private var worker: ?Future<Unit> = None
    private var outputWorker: ?Future<Unit> = None
    private var descriptorOwned = false
    private var released = false

    init(control: HostStdioIngressRuntime, host: HostJavaScriptPluginHost, grant: HostStdioIngressGrant) {
        this.control = control; this.host = host; this.grant = grant
        lifetime = CancellationSource(deadlineMillis: grant.binding.expiresAtMillis)
    }
    private func parseWindow(arguments: AgentValue, digest: String): HostJavaScriptPluginInvocationResult {
        control.ingressPrepareWindow(grant, endpoint.getOrThrow(), arguments, digest, lifetime.token).value().getOrThrow()
    }
    private func upload(slot: String, bytes: String, digest: String): Unit {
        let maximum = if (slot == "result") { grant.resultUploadBytes } else { 65536 }
        hostLifecycleRequire(bytes.size <= maximum)
        let until = MonoTime.now() + Duration.second * (if (grant.payloadLimits.isSome()) { 30 } else { 10 })
        let begin = parseWindow(objectValue([ValueField("action", textValue("blob_begin")), ValueField("slot", textValue(slot)),
            ValueField("size", integerValue(bytes.size)), ValueField("digest", textValue(modelPolicySha256Text(bytes)))]), digest)
        begin.releasePayload()
        let raw = bytes.toArray(); var offset: Int64 = 0
        // Chunk byte encodings, preserving UTF-8 only after assembly.
        // Explicit host profile controls larger chunks; default remains 4 KiB.
        while (offset < raw.size) {
            hostLifecycleRequire(MonoTime.now() < until, "plugin.ingress_decoder_deadline")
            let count = min(grant.uploadChunkBytes, raw.size - offset)
            let alphabet = "0123456789abcdef".toArray(); let encoded = ArrayList<Byte>()
            for (index in offset..(offset + count)) { encoded.add(alphabet[Int64(raw[index]) / 16]); encoded.add(alphabet[Int64(raw[index]) % 16]) }
            let appended = parseWindow(objectValue([ValueField("action", textValue("blob_append")), ValueField("slot", textValue(slot)),
                ValueField("offset", integerValue(offset)), ValueField("bytes_hex", textValue(String.fromUtf8(encoded.toArray())))]), digest)
            appended.releasePayload()
            hostLifecycleRequire(MonoTime.now() < until, "plugin.ingress_decoder_deadline")
            offset += count
        }
    }
    private func directive(frame: ExternalReceivedFrame, result: ?AgentValue): HostJavaScriptPluginInvocationResult {
        decoderLock.lock()
        try {
            upload("frame", frame.raw, frame.digest)
            match (result) { case Some(value) => upload("result", stringifyUnifiedJson(value), frame.digest); case None => () }
            let response = parseWindow(objectValue([ValueField("action", textValue(if (result.isSome()) { "encode" } else { "decode" })),
                ValueField("frame_id", textValue(frame.id))]), frame.digest)
            try {
                hostLifecycleRequire(hostLifecycleText(response.value, "schema") == "axyndra.ingress-directive/v1" &&
                    hostLifecycleText(response.value, "frame_id") == frame.id, "plugin.ingress_response_mismatch")
                response
            } catch (error: Exception) { response.releasePayload(); throw error }
        } finally { decoderLock.unlock() }
    }
    private func send(response: AgentValue): Unit {
        hostLifecycleExact(response, ["schema", "frame_id", "action", "response_hex"])
        hostLifecycleRequire(hostLifecycleText(response, "action") == "respond")
        let raw = hostIngressUnhex(hostLifecycleText(response, "response_hex"), grant.responseBytes)
        hostLifecycleRequire(raw != "" && !raw.contains("\n") && !raw.contains("\r"))
        outputLock.lock()
        try {
            hostLifecycleRequire(!closing.load() && outputCount < 16 && outputBytes + raw.size + 1 <= grant.outputQueueBytes, "plugin.ingress_output_limit")
            output.add(raw + "\n"); outputBytes += raw.size + 1; outputCount++
        } finally { outputLock.unlock() }
    }
    private func accept(raw: String): Unit {
        let frame = connection.captureFrame(raw).value().getOrThrow()
        let retained = directive(frame, Option<AgentValue>.None)
        try {
        let response = retained.value
        let action = hostLifecycleText(response, "action")
        if (action == "respond") { connection.discardFrame(frame).value().getOrThrow(); send(response); return }
        if (action == "ignore") {
            hostLifecycleExact(response, ["schema", "frame_id", "action"])
            connection.discardFrame(frame).value().getOrThrow(); return
        }
        if (action == "cancel") {
            hostLifecycleExact(response, ["schema", "frame_id", "action", "request_id"])
            let id = externalRequestIdFromValue(response.field("request_id").getOrThrow())
            connection.discardFrame(frame).value().getOrThrow()
            queueLock.lock()
            let found = try {
                var matched = false
                for (job in queue where job.id.key() == id.key()) { job.cancelled.store(true); matched = true }
                match (current) { case Some(job) => if (job.id.key() == id.key()) { job.cancelled.store(true); matched = true }; case None => () }
                if (matched) { cancelledDrainEligible = true }
                matched
            } finally { queueLock.unlock() }
            if (found) { connection.cancelRequest(id).value().getOrThrow() }
            return
        }
        hostLifecycleExact(response, ["schema", "frame_id", "action", "request_id", "name", "arguments"])
        hostLifecycleRequire(action == "invoke", "plugin.ingress_directive_invalid")
        let id = externalRequestIdFromValue(response.field("request_id").getOrThrow())
        let name = hostLifecycleText(response, "name")
        hostLifecycleRequire(connection.binding.exported(name).isSome(), "plugin.ingress_export_denied")
        // A larger response grant cannot expand the unchanged input queue.
        hostLifecycleRequire(stringifyUnifiedJson(response.field("arguments").getOrThrow()).size <= 65536,
            "plugin.ingress_arguments_limit")
        let call = ToolCall("ingress-" + connection.binding.connectionId + "-" + frame.id, name, response.field("arguments").getOrThrow())
        queueLock.lock()
        try {
            hostLifecycleRequire(!closing.load() && queue.size < 16 && seen.size < 4096 && !seen.contains(id.key()), "plugin.ingress_queue_or_replay")
            cancelledDrainEligible = false
            seen.add(id.key()); queue.add(HostIngressJob(frame, id, call))
        } finally { queueLock.unlock() }
        } finally { retained.releasePayload() }
    }
    private func executeQueued(): Unit {
        try {
            while (!closing.load()) {
                queueLock.lock()
                let job: ?HostIngressJob = try {
                    if (queue.isEmpty()) { None } else { let selected = queue.remove(at: 0); current = Some(selected); Some(selected) }
                } finally { queueLock.unlock() }
                if (job.isNone()) { sleep(Duration.millisecond * 2); continue }
                let selected = job.getOrThrow()
                var invocationResult: ?Result<ToolInvocationResult> = None
                try {
                    let result = if (selected.cancelled.load()) {
                        let _ = connection.discardFrame(selected.frame)
                        objectValue([ValueField("status", textValue("error")), ValueField("code", textValue("external.cancelled"))])
                    } else {
                        // The peer supplies neither an ApprovalDecision nor trustedControl.
                        let executed = control.executeExternalTool(connection, selected.id, selected.call,
                            budget: ExecutionBudget(maxToolCalls: 32, maxConcurrentTools: 1,
                                deadlineMillis: min(bindingDeadline(), agentUtcMillis() + 120000)), receivedFrame: Some(selected.frame))
                        invocationResult = Some(executed)
                        hostIngressToolOutcome(executed)
                    }
                    if (!closing.load()) {
                        let retained = directive(selected.frame, Some(result))
                        try { send(retained.value) } finally { retained.releasePayload() }
                    }
                } finally {
                    match (invocationResult) { case Some(value) => releaseToolInvocationPayload(value); case None => () }
                    queueLock.lock(); current = None; queueLock.unlock()
                }
            }
        } catch (_: Exception) { failOwned("plugin.ingress_execution_failed") } finally { workerDone.store(true) }
    }
    private func bindingDeadline(): Int64 { connection.binding.expiresAtMillis }
    private func writeQueued(): Unit {
        try {
            while (!closing.load()) {
                outputLock.lock()
                let next: ?String = try {
                    if (output.isEmpty()) { None } else { Some(output.remove(at: 0)) }
                } finally { outputLock.unlock() }
                match (next) {
                    case Some(value) =>
                        // In-flight output stays charged through backpressure and cancellation.
                        try { writer.getOrThrow().write(value.toArray(), { => closing.load() || lifetime.token.isCancelled() }, timeoutMillis: 5000) }
                        finally { outputLock.lock(); outputBytes -= value.size; outputCount--; outputLock.unlock() }
                    case None => sleep(Duration.millisecond * 2)
                }
            }
        } catch (_: Exception) { failOwned("plugin.ingress_output_failed") } finally { outputDone.store(true) }
    }
    private func canDrainCancelled(): Bool {
        queueLock.lock()
        try {
            if (!cancelledDrainEligible || failure.isSome()) { return false }
            for (job in queue where !job.cancelled.load()) { return false }
            match (current) { case Some(job) => if (!job.cancelled.load()) { return false }; case None => () }
            true
        } finally { queueLock.unlock() }
    }
    private func terminalOutputSettled(): Bool {
        queueLock.lock()
        let empty = try { queue.isEmpty() && current.isNone() } finally { queueLock.unlock() }
        if (!empty) { return false }
        outputLock.lock()
        // Count includes the physical writer's currently charged item.
        try { outputCount == 0 } finally { outputLock.unlock() }
    }
    func serveConsole(): Result<Unit> {
        hostStdioIngressOwnerLock.lock()
        try {
            if (hostStdioIngressOwned) { return hostLifecycleError("plugin.ingress_stdio_busy", "stdio already has an ingress owner") }
            hostStdioIngressOwned = true; descriptorOwned = true; readerDone.store(false)
        } finally { hostStdioIngressOwnerLock.unlock() }
        try {
            writer = Some(ingress_process.BorrowedPipeWriter(1))
            match (host.pinServiceEndpoint(grant, grant.context, grant.maintenanceThread, grant.route, grant.expectedGeneration,
                leaseCancellation: Some(lifetime.token))) {
                case HostServiceEndpointSelection.Ready(value) => endpoint = Some(value)
                case HostServiceEndpointSelection.CleanupRequired(value, error, _) => endpoint = Some(value); return Result.Err(error)
                case HostServiceEndpointSelection.Rejected(error) => return Result.Err(error)
            }
            grant.bindDecoderEndpoint(endpoint.getOrThrow()).value().getOrThrow()
            admittedConnection = Some(openExternalIngressConnection(HostIngressAuthorizer(grant), { => agentUtcMillis() }).value().getOrThrow())
            revocationRegistration = Some(endpoint.getOrThrow().observeRevocation({ => revoke() }))
            decoderLock.lock()
            try { upload("catalogue", grant.catalogue, modelPolicySha256Text("ingress-catalogue")) }
            finally { decoderLock.unlock() }
            workerDone.store(false)
            try { worker = Some(spawn { executeQueued() }) } catch (error: Exception) { workerDone.store(true); throw error }
            outputDone.store(false)
            try { outputWorker = Some(spawn { writeQueued() }) } catch (error: Exception) { outputDone.store(true); throw error }
            let pending = ArrayList<Byte>()
            while (!closing.load()) {
                if (!endpoint.getOrThrow().available() || grant.stillCurrent().isError()) {
                    failOwned("plugin.ingress_authority_lost"); break
                }
                if (terminalDraining.load()) {
                    if (!canDrainCancelled()) { failOwned("plugin.ingress_authority_lost"); break }
                    if (terminalOutputSettled()) { break }
                    if (agentUtcMillis() >= terminalDrainDeadline) { failOwned("plugin.ingress_cleanup_pending"); break }
                    sleep(Duration.millisecond); continue
                }
                if (connection.validateCurrent().isError()) {
                    // No connection is reopened and no new input is read. The
                    // actual held cancellation flags prove every remaining
                    // job is a terminal response, never a new effect request.
                    if (canDrainCancelled() && !grant.stillCurrent().isError() && grant.fixedExportsCurrent().isError()) {
                        terminalDrainDeadline = min(bindingDeadline(), agentUtcMillis() + 5000)
                        terminalDraining.store(true); continue
                    }
                    failOwned("plugin.ingress_authority_lost"); break
                }
                if (!ingress_process.waitReadableFd(0, 10)) { sleep(Duration.millisecond); continue }
                let bytes = match (ingress_process.readFdChunk(0, maxBytes: 4096)) { case Some(value) => value; case None => break }
                for (byte in bytes) {
                    if (byte == 10u8) {
                        hostLifecycleRequire(!pending.isEmpty(), "plugin.ingress_empty_frame")
                        accept(String.fromUtf8(pending.toArray())); pending.clear()
                    } else { hostLifecycleRequire(pending.size < 65536, "plugin.ingress_frame_limit"); pending.add(byte) }
                }
            }
            if (!pending.isEmpty()) { return hostLifecycleError("plugin.ingress_incomplete_frame", "stdio ended before a complete frame") }
            queueLock.lock()
            let error = try { failure } finally { queueLock.unlock() }
            match (error) { case Some(code) => hostLifecycleError(code, "stdio ingress lost its fixed worker, authority or bounded output"); case None => Result.Ok(()) }
        } catch (_: Exception) { hostLifecycleError("plugin.ingress_failed", "stdio ingress stopped at its bounded protocol or I/O boundary") }
        finally { revoke(); readerDone.store(true) }
    }
    private func failOwned(code: String): Unit {
        queueLock.lock()
        try { if (failure.isNone()) { failure = Some(code) } } finally { queueLock.unlock() }
        revoke()
    }
    func revoke(): Unit { closing.store(true); grant.revoke(); let _ = lifetime.cancel()
        match (admittedConnection) { case Some(value) => value.revoke(); case None => () }
        match (endpoint) { case Some(value) => value.revoke(); case None => () } }
    func close(): Result<Unit> {
        closeLock.lock()
        try {
        if (released) { return Result.Ok(()) }
        revoke()
        let until = MonoTime.now() + Duration.second * 2
        while ((!readerDone.load() || !workerDone.load() || !outputDone.load()) && MonoTime.now() < until) { sleep(Duration.millisecond) }
        if (!readerDone.load() || !workerDone.load() || !outputDone.load()) { return hostLifecycleError("plugin.ingress_cleanup_pending", "stdio tasks retain their owner until cleanup acknowledgement") }
        try {
            match (worker) { case Some(value) => value.get(); case None => () }
            match (outputWorker) { case Some(value) => value.get(); case None => () }
            match (writer) { case Some(value) => value.close(); case None => () }
        } catch (_: Exception) { return hostLifecycleError("plugin.ingress_cleanup_pending", "stdio descriptor cleanup has not acknowledged release") }
        match (endpoint) { case Some(value) => match (value.close()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; case None => () }
        match (revocationRegistration) { case Some(value) => value.dispose(); revocationRegistration = None; case None => () }
        lifetime.close()
        hostStdioIngressOwnerLock.lock()
        try { if (descriptorOwned) { hostStdioIngressOwned = false; descriptorOwned = false }; released = true }
        finally { hostStdioIngressOwnerLock.unlock() }
        Result.Ok(())
        } finally { closeLock.unlock() }
    }
}
func hostIngressToolOutcome(result: Result<ToolInvocationResult>): AgentValue {
    match (result) {
        case Result.Ok(ToolInvocationResult.Completed(value)) => objectValue([ValueField("status", textValue("complete")),
            ValueField("output", value.output), ValueField("is_error", boolValue(value.isError))])
        case Result.Ok(ToolInvocationResult.NeedsApproval(_)) => objectValue([ValueField("status", textValue("error")), ValueField("code", textValue("external.approval_required"))])
        case Result.Ok(ToolInvocationResult.Denied(_)) => objectValue([ValueField("status", textValue("error")), ValueField("code", textValue("external.permission_denied"))])
        case Result.Err(error) => objectValue([ValueField("status", textValue("error")), ValueField("code", textValue(error.code))])
    }
}
