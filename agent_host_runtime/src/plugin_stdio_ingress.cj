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
// Original frontend bytes and their exact prepaid DATA custody; never Source
// or execution authority. Only actual Host consumers can borrow or retire it.
public class HostStdioInputFrame180 {
    private var frame180: ?String
    private var payment180: ?LogicalJsonOwnerReservation
    public init(frame: String, payment: LogicalJsonOwnerReservation) {
        frame180 = Some(frame); payment180 = Some(payment)
    }
    func borrowFrame180(): String { frame180.getOrThrow() }
    func deriveOutputPayment180(invoice: Int64): LogicalJsonOwnerReservation {
        let paid = payment180.getOrThrow().deriveRetainedLease()
        try { paid.ensureRetainedPeak(invoice); paid }
        catch (error: Exception) { paid.close(); throw error }
    }
    func deriveInputPayment180(invoice: Int64): LogicalJsonOwnerReservation {
        let paid = payment180.getOrThrow().deriveRetainedLease()
        try { paid.ensureRetainedPeak(invoice); paid }
        catch (error: Exception) { paid.close(); throw error }
    }
    private func clearFrameWholeHelper180(): ?LogicalJsonOwnerReservation {
        frame180 = None; let paid = payment180; payment180 = None; paid
    }
    func retireAfterActualHostHelpers180(): Unit {
        let paid = clearFrameWholeHelper180()
        match (paid) { case Some(value) => value.close(); case None => () }
    }
}
class HostIngressOutputFrame180 {
    private var frame180: ?String
    private var payment180: ?LogicalJsonOwnerReservation
    let size: Int64
    init(frame: String, payment: ?LogicalJsonOwnerReservation) {
        frame180 = Some(frame); payment180 = payment; size = frame.size
    }
    func borrowFrame180(): String { frame180.getOrThrow() }
    private func clearFrameWholeHelper180(): ?LogicalJsonOwnerReservation {
        frame180 = None; let paid = payment180; payment180 = None; paid
    }
    func retireAfterOutputHelper180(): Unit {
        let paid = clearFrameWholeHelper180()
        match (paid) { case Some(value) => value.close(); case None => () }
    }
}
class HostIngressJob {
    private var originalFrame180: ?ExternalReceivedFrame
    private var originalId180: ?ExternalRequestId = None
    private var invocationData180: ?HostIngressInvocationData180 = None
    private var input180: ?HostStdioInputFrame180
    private var metadata180: ?LogicalJsonOwnerReservation
    private var parserWindows180: ?HostIngressParserWindow180 = None
    private var pendingArguments180: ?LogicalJsonOwnerReservation = None
    private var pendingDecoded180: ?LogicalJsonOwnerReservation = None
    private var nodeInvoice180: Int64 = 131072
    var output180: ?HostIngressOutputFrame180 = None
    var debtNext180: ?HostIngressJob = None
    private var canonicalReturn180: ?HostCanonicalInputReturn180 = Some(HostCanonicalInputReturn180())
    func originalCanonicalReturn180(): HostCanonicalInputReturn180 { canonicalReturn180.getOrThrow() }
    func originalCanonicalInputReturned180(): Bool {
        match (canonicalReturn180) { case Some(receiver) => if (!receiver.originalInputConsumersReturned180()) { return false }; case None => () }
        if (pendingArguments180.isSome() || pendingDecoded180.isSome()) { return false }
        var cursor = parserWindows180
        while (cursor.isSome()) {
            let actual = cursor.getOrThrow()
            if (!actual.originalConsumersReturned180()) { return false }
            cursor = actual.next180
        }
        true
    }
    prop frame: ExternalReceivedFrame { get() { originalFrame180.getOrThrow() } }
    prop id: ExternalRequestId { get() { originalId180.getOrThrow() } }
    prop call: ToolCall { get() { invocationData180.getOrThrow().borrowCall180() } }
    prop isInvocation180: Bool { get() { invocationData180.isSome() } }
    let cancelled = AtomicBool(false)
    init(frame: ?ExternalReceivedFrame, input: ?HostStdioInputFrame180, metadata: LogicalJsonOwnerReservation) {
        originalFrame180 = frame; input180 = input; metadata180 = Some(metadata)
    }
    func installParserWindowBeforeHelper180(arguments: AgentValue): HostIngressParserWindow180 {
        if (pendingArguments180.isSome() || pendingDecoded180.isSome()) { throw IllegalStateException("parser allocation remains held") }
        if (nodeInvoice180 > Int64.Max - 4096) { throw LogicalJsonPayloadError("parser node SUM overflow") }
        metadata180.getOrThrow().ensureRetainedPeak(nodeInvoice180 + 4096); nodeInvoice180 += 4096
        pendingArguments180 = Some(metadata180.getOrThrow().deriveRetainedLease())
        let meter = ToolSnapshotMeasure159(pendingArguments180.getOrThrow())
        meter.addValue159(arguments); meter.fund159()
        pendingDecoded180 = Some(metadata180.getOrThrow().deriveRetainedLease())
        pendingDecoded180.getOrThrow().ensureRetainedPeak(131072)
        let window = HostIngressParserWindow180(arguments, pendingArguments180.getOrThrow(), pendingDecoded180.getOrThrow())
        window.next180 = parserWindows180; parserWindows180 = Some(window)
        pendingArguments180 = None; pendingDecoded180 = None
        window
    }
    func lastParserWindow180(): HostIngressParserWindow180 { parserWindows180.getOrThrow() }
    func bindInvocation180(id: ExternalRequestId, response: AgentValue, call: ToolCall): Unit {
        originalId180 = Some(id)
        let window = lastParserWindow180()
        // Install the actual carrier before the window drops its payment alias.
        invocationData180 = Some(HostIngressInvocationData180(response, call, window.decodedPayment180()))
        canonicalReturn180.getOrThrow().bindOriginalInputPayment180(invocationData180.getOrThrow().originalPayment180())
        let _ = window.transferDecodedPayment180()
    }
    func deriveOutputPayment180(invoice: Int64): ?LogicalJsonOwnerReservation {
        let paid = metadata180.getOrThrow().deriveRetainedLease()
        try { paid.ensureRetainedPeak(invoice); Some(paid) }
        catch (error: Exception) { paid.close(); throw error }
    }
    private func clearJobWholeHelper180(): (?HostStdioInputFrame180, ?HostIngressInvocationData180, ?HostIngressParserWindow180, ?LogicalJsonOwnerReservation, ?HostCanonicalInputReturn180) {
        let input = input180; let data = invocationData180; let windows = parserWindows180; let paid = metadata180; let receiver = canonicalReturn180
        originalFrame180 = None; originalId180 = None; canonicalReturn180 = None
        input180 = None; invocationData180 = None; parserWindows180 = None; metadata180 = None
        (input, data, windows, paid, receiver)
    }
    func retireAfterJobHelpers180(): Unit {
        if (!originalCanonicalInputReturned180()) { throw IllegalStateException("original input consumers still own this job") }
        let returned = clearJobWholeHelper180()
        match (returned[4]) { case Some(receiver) => receiver.retireAfterOriginalInputHelpers180(); case None => () }
        var cursor = returned[2]
        while (cursor.isSome()) { let window = cursor.getOrThrow(); cursor = window.next180; window.next180 = None; window.retireAfterActualParserHelpers180() }
        match (returned[1]) { case Some(value) => value.retireAfterActualConsumers180(); case None => () }
        match (returned[0]) { case Some(value) => value.retireAfterActualHostHelpers180(); case None => () }
        match (returned[3]) { case Some(value) => value.close(); case None => () }
    }
}


// One physical stdio connection, inherited or supplied by the trusted frontend.
// The same owner keeps the fixed Thread/catalog and canonical External gateway;
// explicit callbacks never substitute another registry or execute raw peer calls.
class HostStdioIngressOwner {
    private let control: HostStdioIngressRuntime
    private let host: HostJavaScriptPluginHost
    private var actualGrant180: ?HostStdioIngressGrant = None<HostStdioIngressGrant>
    private prop grant: HostStdioIngressGrant { get() { actualGrant180.getOrThrow() } }
    private var admittedConnection: ?ExternalIngressConnection = None
    private prop connection: ExternalIngressConnection { get() { admittedConnection.getOrThrow() } }
    private var actualLifetime180: ?CancellationSource = None<CancellationSource>
    private prop lifetime: CancellationSource { get() { actualLifetime180.getOrThrow() } }
    private let parentCancellation180: ?CancellationToken
    private var metadata180: ?LogicalJsonOwnerReservation
    private var pendingJobData180: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var bootstrapJob180: ?HostIngressJob = None<HostIngressJob>
    private var input180: ?(() -> Result<?HostStdioInputFrame180>)
    private var output180: ?((String) -> Result<Unit>)
    private var inputWorker180: ?Future<Result<?HostStdioInputFrame180>> = None
    private var currentInput180: ?HostStdioInputFrame180 = None
    private var pendingJob180: ?HostIngressJob = None
    private var retainedJobs180: ?HostIngressJob = None
    private var revocationRegistration: ?ingress_process.CancellationRegistration = None
    private let decoderLock = Mutex()
    private let queueLock = Mutex()
    private let queue = ArrayList<HostIngressJob>()
    private let seen = HashSet<String>()
    private var current: ?HostIngressJob = None
    private var cancelledDrainEligible = false
    private let terminalDraining = AtomicBool(false)
    private var terminalDrainDeadline: Int64 = 0
    private var failure: ?AgentError = None<AgentError>
    private var executionFailure180: ?Exception = None<Exception>
    private var outputFailure180: ?Exception = None<Exception>
    private var ingressFailure180: ?Exception = None<Exception>
    private var cleanupFailure180: ?Exception = None<Exception>
    private var cleanupError180: ?AgentError = None<AgentError>
    private var endpoint: ?HostPinnedNativeServiceEndpoint = None
    private var writer: ?ingress_process.BorrowedPipeWriter = None
    private let outputLock = Mutex()
    private let output = ArrayList<HostIngressOutputFrame180>()
    private var activeOutput: ?HostIngressOutputFrame180 = None
    private var pendingOutputPayment180: ?LogicalJsonOwnerReservation = None
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

    init(control: HostStdioIngressRuntime, host: HostJavaScriptPluginHost, metadata: LogicalJsonOwnerReservation,
        input180!: ?(() -> Result<?HostStdioInputFrame180>) = None, output180!: ?((String) -> Result<Unit>) = None,
        callerCancellation180!: ?CancellationToken = None) {
        this.control = control; this.host = host; metadata180 = Some(metadata)
        this.input180 = input180; this.output180 = output180; parentCancellation180 = callerCancellation180
    }
    func initializeGrant180(grant: HostStdioIngressGrant): Unit {
        actualGrant180 = Some(grant)
        actualLifetime180 = Some(CancellationSource(parent: parentCancellation180, deadlineMillis: grant.binding.expiresAtMillis))
    }
    func retainOriginalIngressException180(error: Exception): Unit { if (ingressFailure180.isNone()) { ingressFailure180 = Some(error) } }
    private func reserveJobDataBeforeConstruction180(input: ?HostStdioInputFrame180): LogicalJsonOwnerReservation {
        if (pendingJobData180.isSome()) { throw IllegalStateException("original job allocation remains paid") }
        let paid = match (input) { case Some(value) => value.deriveInputPayment180(131072)
            case None => let owner = metadata180.getOrThrow().deriveRetainedLease(); pendingJobData180 = Some(owner); owner.ensureRetainedPeak(131072); owner }
        pendingJobData180 = Some(paid); paid
    }

    private func readExplicitInput180(): Result<?HostStdioInputFrame180> { input180.getOrThrow()() }
    private func getInputWholeHelper180(): Result<Bool> {
        match (inputWorker180.getOrThrow().get()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => currentInput180 = value; Result<Bool>.Ok(value.isSome())
        }
    }
    private func inputReturned180(): Bool {
        match (inputWorker180) { case Some(value) => value.tryGet().isSome(); case None => true }
    }
    private func parseWindow(arguments: AgentValue, digest: String, job: HostIngressJob): HostJavaScriptPluginInvocationResult {
        let window = job.installParserWindowBeforeHelper180(arguments)
        match (control.ingressPrepareWindow(grant, endpoint.getOrThrow(), window, digest, lifetime.token)) {
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(value) => value }
    }

    private func upload(slot: String, bytes: String, digest: String, job: HostIngressJob): Unit {
        let maximum = if (slot == "result") { grant.resultUploadBytes } else { 65536 }
        hostLifecycleRequire(bytes.size <= maximum)
        let until = MonoTime.now() + Duration.second * (if (grant.payloadLimits.isSome()) { 30 } else { 10 })
        let begin = parseWindow(objectValue([ValueField("action", textValue("blob_begin")), ValueField("slot", textValue(slot)),
            ValueField("size", integerValue(bytes.size)), ValueField("digest", textValue(modelPolicySha256Text(bytes)))]), digest, job)
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
                ValueField("offset", integerValue(offset)), ValueField("bytes_hex", textValue(String.fromUtf8(encoded.toArray())))]), digest, job)
            appended.releasePayload()
            hostLifecycleRequire(MonoTime.now() < until, "plugin.ingress_decoder_deadline")
            offset += count
        }
    }
    private func directive(frame: ExternalReceivedFrame, result: ?AgentValue, job: HostIngressJob): HostJavaScriptPluginInvocationResult {
        decoderLock.lock()
        try {
            upload("frame", frame.raw, frame.digest, job)
            match (result) { case Some(value) => upload("result", stringifyUnifiedJson(value), frame.digest, job); case None => () }
            let response = parseWindow(objectValue([ValueField("action", textValue(if (result.isSome()) { "encode" } else { "decode" })),
                ValueField("frame_id", textValue(frame.id))]), frame.digest, job)
            try {
                hostLifecycleRequire(hostLifecycleText(response.value, "schema") == "axyndra.ingress-directive/v1" &&
                    hostLifecycleText(response.value, "frame_id") == frame.id, "plugin.ingress_response_mismatch")
                response
            } catch (error: Exception) { response.releasePayload(); throw error }
        } finally { decoderLock.unlock() }
    }
    private func send(response: AgentValue, job: HostIngressJob): Unit {
        hostLifecycleExact(response, ["schema", "frame_id", "action", "response_hex"])
        hostLifecycleRequire(hostLifecycleText(response, "action") == "respond")
        let hex = hostLifecycleText(response, "response_hex")
        hostLifecycleRequire(hex.size % 2 == 0 && hex.size <= grant.responseBytes * 2)
        outputLock.lock()
        try {
            hostLifecycleRequire(pendingOutputPayment180.isNone() && job.output180.isNone())
            pendingOutputPayment180 = job.deriveOutputPayment180(65536 + (hex.size / 2 + 1) * 8)
            let raw = hostIngressUnhex(hex, grant.responseBytes)
            hostLifecycleRequire(raw != "" && !raw.contains("\n") && !raw.contains("\r"))
            hostLifecycleRequire(!closing.load() && outputCount < 16 && outputBytes + raw.size + 1 <= grant.outputQueueBytes, "plugin.ingress_output_limit")
            job.output180 = Some(HostIngressOutputFrame180(raw + "\n", pendingOutputPayment180))
            pendingOutputPayment180 = None
            outputBytes += raw.size + 1; outputCount++
        } finally { outputLock.unlock() }
    }
    private func publishJobOutput180(job: HostIngressJob): Unit {
        outputLock.lock()
        try { match (job.output180) {
            case Some(value) => output.add(value); job.output180 = None
            case None => ()
        } } finally { outputLock.unlock() }
    }
    private func accept(raw: String): Unit {
        let frame = connection.captureFrame(raw).value().getOrThrow()
        hostLifecycleRequire(pendingJob180.isNone())
        let paid = reserveJobDataBeforeConstruction180(currentInput180)
        pendingJob180 = Some(HostIngressJob(Some(frame), currentInput180, paid)); currentInput180 = None; pendingJobData180 = None
        let retained = directive(frame, Option<AgentValue>.None, pendingJob180.getOrThrow())
        try {
        let response = retained.value
        let action = hostLifecycleText(response, "action")
        if (action == "respond") { connection.discardFrame(frame).value().getOrThrow(); send(response, pendingJob180.getOrThrow()); return }
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
            collectReturnedJobDebtLocked180()
            hostLifecycleRequire(!closing.load() && queue.size + retainedJobDebtCountLocked180() < 16 && seen.size < 4096 && !seen.contains(id.key()), "plugin.ingress_queue_or_replay")
            cancelledDrainEligible = false
            seen.add(id.key()); pendingJob180.getOrThrow().bindInvocation180(id, response, call)
        } finally { queueLock.unlock() }
        } finally { retained.releasePayload() }
    }
    private func publishAcceptedFrame180(): Unit {
        let job = pendingJob180.getOrThrow()
        if (job.isInvocation180) {
            queueLock.lock()
            try { hostLifecycleRequire(!closing.load(), "plugin.ingress_queue_or_replay"); queue.add(job) }
            finally { queueLock.unlock() }
        } else {
            publishJobOutput180(job)
            queueLock.lock()
            try { if (job.originalCanonicalInputReturned180()) { job.retireAfterJobHelpers180() }
                else { job.debtNext180 = retainedJobs180; retainedJobs180 = Some(job) } } finally { queueLock.unlock() }
        }
        pendingJob180 = None
    }
    private func executeJobWholeHelper180(selected: HostIngressJob): Bool {
        var invocationResult: ?Result<ToolInvocationResult> = None
        var returned = true
        try {
            let result = if (selected.cancelled.load()) {
                let _ = connection.discardFrame(selected.frame)
                objectValue([ValueField("status", textValue("error")), ValueField("code", textValue("external.cancelled"))])
            } else {
                let executed = control.executeExternalTool(connection, selected.id, selected.call,
                    budget: ExecutionBudget(maxToolCalls: 32, maxConcurrentTools: 1,
                        deadlineMillis: min(bindingDeadline(), agentUtcMillis() + 120000)), receivedFrame: Some(selected.frame),
                    dataReturn180: Some(selected.originalCanonicalReturn180()))
                invocationResult = Some(executed)
                hostIngressToolOutcome(executed)
            }
            if (!closing.load()) {
                let retained = directive(selected.frame, Some(result), selected)
                try { send(retained.value, selected) } finally { retained.releasePayload() }
            } else { returned = false }
        } finally {
            match (invocationResult) { case Some(value) => releaseToolInvocationPayload(value); case None => () }
        }
        returned
    }
    private func finishJobAfterHelper180(returned: Bool): Unit {
        queueLock.lock()
        try {
            let job = current.getOrThrow()
            publishJobOutput180(job)
            if (returned && job.originalCanonicalInputReturned180()) { job.retireAfterJobHelpers180() }
            else { job.debtNext180 = retainedJobs180; retainedJobs180 = Some(job) }
            current = None
        } finally { queueLock.unlock() }
    }
    private func collectReturnedJobDebtLocked180(): Unit {
        var previous: ?HostIngressJob = None
        var cursor = retainedJobs180
        while (cursor.isSome()) {
            let job = cursor.getOrThrow(); let next = job.debtNext180
            if (job.originalCanonicalInputReturned180()) {
                match (previous) { case Some(before) => before.debtNext180 = next; case None => retainedJobs180 = next }
                job.debtNext180 = None; job.retireAfterJobHelpers180()
            } else { previous = Some(job) }
            cursor = next
        }
    }
    private func retainedJobDebtCountLocked180(): Int64 {
        var count: Int64 = 0; var cursor = retainedJobs180
        while (cursor.isSome()) { count++; cursor = cursor.getOrThrow().debtNext180 }; count
    }

    private func executeQueued(): Unit {
        try {
            while (!closing.load()) {
                queueLock.lock()
                let available = try {
                    collectReturnedJobDebtLocked180()
                    if (queue.isEmpty()) { false } else { current = Some(queue.remove(at: 0)); true }
                } finally { queueLock.unlock() }
                if (!available) { sleep(Duration.millisecond * 2); continue }
                let returned = executeJobWholeHelper180(current.getOrThrow())
                finishJobAfterHelper180(returned)
            }
        } catch (error: OwnedCanonicalDataFailure113) { retainOriginalExecutionFailure180(error); failOwned(error.error) }
        catch (error: Exception) { retainOriginalExecutionFailure180(error); failOwned(AgentError(AgentErrorKind.Internal, "plugin.ingress_execution_failed", error.message)) }
        finally { workerDone.store(true) }
    }
    private func bindingDeadline(): Int64 { connection.binding.expiresAtMillis }
    private func writeActiveOutput(): Result<Unit> {
        // The owner retains the actual physical loan until this whole frame returns.
        let value = activeOutput.getOrThrow().borrowFrame180()
        match (output180) {
            case Some(write) => write(value)
            case None =>
                writer.getOrThrow().write(value.toArray(), { => closing.load() || lifetime.token.isCancelled() }, timeoutMillis: 5000)
                Result<Unit>.Ok(())
        }
    }
    private func writeQueued(): Unit {
        try {
            while (!closing.load()) {
                outputLock.lock()
                let selected = try {
                    if (output.isEmpty()) { false } else { activeOutput = Some(output.remove(at: 0)); true }
                } finally { outputLock.unlock() }
                if (!selected) { sleep(Duration.millisecond * 2); continue }
                var outputReturned = false
                try { match (writeActiveOutput()) {
                    case Result.Ok(_) => outputReturned = true
                    case Result.Err(error) => failOwned(error)
                } }
                catch (error: ingress_process.ProcessError) {
                    retainOriginalOutputFailure180(error)
                    // Only returned cancellation caused by owner shutdown is
                    // abandonment, never a successful delivery acknowledgement.
                    match (error.kind) {
                        case ingress_process.ProcessErrorKind.Cancelled => if (!closing.load()) { failOwned("plugin.ingress_output_failed") }
                        case _ => failOwned(AgentError(AgentErrorKind.Transport, "plugin.ingress_output_failed", error.message))
                    }
                } catch (error: OwnedCanonicalDataFailure113) { retainOriginalOutputFailure180(error); failOwned(error.error) }
                catch (error: Exception) { retainOriginalOutputFailure180(error); failOwned(AgentError(AgentErrorKind.Transport, "plugin.ingress_output_failed", error.message)) }
                finally {
                    // A callback error carries no physical delivery ACK. Its
                    // original buffer and charge stay with this cleanup owner.
                    if (outputReturned) {
                        outputLock.lock()
                        try {
                            let frame = activeOutput.getOrThrow()
                            outputBytes -= frame.size; outputCount--; activeOutput = None
                            frame.retireAfterOutputHelper180()
                        }
                        finally { outputLock.unlock() }
                    }
                }
            }
        } catch (error: OwnedCanonicalDataFailure113) { retainOriginalOutputFailure180(error); failOwned(error.error) }
        catch (error: Exception) { retainOriginalOutputFailure180(error); failOwned(AgentError(AgentErrorKind.Transport, "plugin.ingress_output_failed", error.message)) }
        finally { outputDone.store(true) }
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
        let empty = try { failure.isNone() && queue.isEmpty() && current.isNone() } finally { queueLock.unlock() }
        if (!empty) { return false }
        outputLock.lock()
        // Count includes the physical writer's currently charged item.
        try { outputCount == 0 && activeOutput.isNone() } finally { outputLock.unlock() }
    }
    func serveConsole(): Result<Unit> {
        hostStdioIngressOwnerLock.lock()
        try {
            if (hostStdioIngressOwned) { return hostLifecycleError("plugin.ingress_stdio_busy", "stdio already has an ingress owner") }
            hostStdioIngressOwned = true; descriptorOwned = true; readerDone.store(false)
        } finally { hostStdioIngressOwnerLock.unlock() }
        try {
            if (output180.isNone()) { writer = Some(ingress_process.BorrowedPipeWriter(1)) }
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
            try {
                let paid = reserveJobDataBeforeConstruction180(None<HostStdioInputFrame180>)
                bootstrapJob180 = Some(HostIngressJob(None<ExternalReceivedFrame>, None<HostStdioInputFrame180>, paid)); pendingJobData180 = None
                upload("catalogue", grant.catalogue, modelPolicySha256Text("ingress-catalogue"), bootstrapJob180.getOrThrow())
            }
            finally { decoderLock.unlock() }
            workerDone.store(false)
            try { worker = Some(spawn { executeQueued() }) } catch (error: Exception) { workerDone.store(true); throw error }
            outputDone.store(false)
            try { outputWorker = Some(spawn { writeQueued() }) } catch (error: Exception) { outputDone.store(true); throw error }
            let pending = ArrayList<Byte>()
            while (!closing.load()) {
                if (lifetime.token.isCancelled() || !endpoint.getOrThrow().available() || grant.stillCurrent().isError()) {
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
                let bytes: Array<Byte>
                if (input180.isSome()) {
                    if (inputWorker180.isNone()) { inputWorker180 = Some(spawn { readExplicitInput180() }) }
                    if (!inputReturned180()) { sleep(Duration.millisecond); continue }
                    // tryGet is readiness DATA only. The actual get consumer
                    // must return before its Future reference can be retired.
                    let received = getInputWholeHelper180()
                    inputWorker180 = None
                    if (!received.value().getOrThrow()) { break }
                    consumeExplicitFrameWholeHelper180()
                    publishAcceptedFrame180()
                    continue
                } else {
                    if (!ingress_process.waitReadableFd(0, 10)) { sleep(Duration.millisecond); continue }
                    bytes = match (ingress_process.readFdChunk(0, maxBytes: 4096)) { case Some(value) => value; case None => break }
                }
                for (byte in bytes) {
                    if (byte == 10u8) {
                        hostLifecycleRequire(!pending.isEmpty(), "plugin.ingress_empty_frame")
                        accept(String.fromUtf8(pending.toArray())); pending.clear()
                        publishAcceptedFrame180()
                    } else { hostLifecycleRequire(pending.size < 65536, "plugin.ingress_frame_limit"); pending.add(byte) }
                }
            }
            if (!pending.isEmpty()) { return hostLifecycleError("plugin.ingress_incomplete_frame", "stdio ended before a complete frame") }
            queueLock.lock()
            let error = try { failure } finally { queueLock.unlock() }
            match (error) { case Some(original) => Result.Err(original); case None => Result.Ok(()) }
        } catch (error: OwnedCanonicalDataFailure113) { ingressFailure180 = Some(error); Result.Err(error.error) }
        catch (error: Exception) { ingressFailure180 = Some(error); hostLifecycleError("plugin.ingress_failed", error.message) }
        finally { revoke(); readerDone.store(true) }
    }
    private func consumeExplicitFrameWholeHelper180(): Unit {
        let raw = currentInput180.getOrThrow().borrowFrame180()
        hostLifecycleRequire(raw.size <= 65537, "plugin.ingress_frame_limit")
        let bytes = raw.toArray()
        hostLifecycleRequire(!bytes.isEmpty() && bytes[bytes.size - 1] == 10u8, "plugin.ingress_incomplete_frame")
        let pending = ArrayList<Byte>()
        for (byte in bytes) {
            if (byte == 10u8) {
                hostLifecycleRequire(!pending.isEmpty(), "plugin.ingress_empty_frame")
                hostLifecycleRequire(pending.size + 1 == bytes.size, "plugin.ingress_frame_limit")
                accept(String.fromUtf8(pending.toArray())); pending.clear()
            } else { hostLifecycleRequire(pending.size < 65536, "plugin.ingress_frame_limit"); pending.add(byte) }
        }
    }
    private func retainOriginalExecutionFailure180(error: Exception): Unit {
        queueLock.lock(); try { if (executionFailure180.isNone()) { executionFailure180 = Some(error) } } finally { queueLock.unlock() }
    }
    private func retainOriginalOutputFailure180(error: Exception): Unit {
        outputLock.lock(); try { if (outputFailure180.isNone()) { outputFailure180 = Some(error) } } finally { outputLock.unlock() }
    }
    private func failOwned(error: AgentError): Unit {
        queueLock.lock(); try { if (failure.isNone()) { failure = Some(error) } } finally { queueLock.unlock() }
        revoke()
    }
    private func failOwned(code: String): Unit {
        failOwned(AgentError(AgentErrorKind.PermissionDenied, code,
            "stdio ingress lost its fixed worker, authority or bounded output", retryable: false, fallbackAllowed: false))
    }

    func revoke(): Unit { closing.store(true)
        match (actualGrant180) { case Some(value) => value.revoke(); case None => () }
        match (actualLifetime180) { case Some(value) => let _ = value.cancel(); case None => () }
        match (admittedConnection) { case Some(value) => value.revoke(); case None => () }
        match (endpoint) { case Some(value) => value.revoke(); case None => () } }
    func settledResult(result: Result<Unit>): Result<Unit> {
        // close has joined every producer and closed the actual endpoint.
        // EOF may have raced a real execution/output failure before those joins.
        if (result.isError()) { return result }
        queueLock.lock()
        try { match (failure) {
            case Some(original) => Result.Err(original)
            case None => result
        } } finally { queueLock.unlock() }
    }
    func close(): Result<Unit> {
        closeLock.lock()
        try {
        if (released) { return Result.Ok(()) }
        revoke()
        let until = MonoTime.now() + Duration.second * 2
        while ((!readerDone.load() || !workerDone.load() || !outputDone.load() || !inputReturned180()) && MonoTime.now() < until) { sleep(Duration.millisecond) }
        if (!readerDone.load() || !workerDone.load() || !outputDone.load() || !inputReturned180()) { return hostLifecycleError("plugin.ingress_cleanup_pending", "stdio tasks retain their owner until cleanup acknowledgement") }
        try {
            if (inputWorker180.isSome()) { match (getInputWholeHelper180()) {
                case Result.Err(error) => retainOriginalCleanupError180(error); return Result.Err(error)
                case Result.Ok(_) => inputWorker180 = None } }
            match (worker) { case Some(value) => value.get(); case None => () }
            match (outputWorker) { case Some(value) => value.get(); case None => () }
            match (writer) { case Some(value) => value.close(); case None => () }
        } catch (error: OwnedCanonicalDataFailure113) { cleanupFailure180 = Some(error); return Result.Err(error.error) }
        catch (error: Exception) { cleanupFailure180 = Some(error); return hostLifecycleError("plugin.ingress_cleanup_pending", error.message) }
        match (endpoint) { case Some(value) => match (value.close()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; case None => () }
        outputLock.lock()
        let outputReturned = try { activeOutput.isNone() } finally { outputLock.unlock() }
        if (!outputReturned) { return hostLifecycleError("plugin.ingress_cleanup_pending", "stdio output still retains its physical loan") }
        match (revocationRegistration) { case Some(value) => value.dispose(); revocationRegistration = None; case None => () }
        match (actualLifetime180) { case Some(value) => value.close(); case None => () }
        // All real producers and endpoint loans have returned. Dropping these
        // abandoned queued buffers is resource release, not wire delivery ACK.
        outputLock.lock()
        try {
            for (frame in output) { frame.retireAfterOutputHelper180() }
            output.clear(); outputBytes = 0; outputCount = 0
            match (pendingOutputPayment180) { case Some(value) => value.close(); pendingOutputPayment180 = None; case None => () }
        } finally { outputLock.unlock() }
        if (!retireInputAfterCloseHelpers180()) { return hostLifecycleError("plugin.ingress_cleanup_pending", "original canonical input consumers retain their paid jobs") }
        if (ingressFailure180.isSome() || executionFailure180.isSome() || outputFailure180.isSome() || cleanupFailure180.isSome() || cleanupError180.isSome()) {
            return hostLifecycleError("plugin.ingress_cleanup_pending", "the actual original failure still retains its paid owner")
        }
        retireSuccessfulOwnerData180()
        hostStdioIngressOwnerLock.lock()
        try { if (descriptorOwned) { hostStdioIngressOwned = false; descriptorOwned = false }; released = true }
        finally { hostStdioIngressOwnerLock.unlock() }
        Result.Ok(())
        } finally { closeLock.unlock() }
    }
    func retainOriginalCleanupError180(error: AgentError): Unit { cleanupError180 = Some(error) }
    private func clearSuccessfulOwnerDataHelper180(): ?LogicalJsonOwnerReservation {
        actualGrant180 = None<HostStdioIngressGrant>; actualLifetime180 = None<CancellationSource>
        admittedConnection = None<ExternalIngressConnection>; endpoint = None<HostPinnedNativeServiceEndpoint>
        writer = None<ingress_process.BorrowedPipeWriter>; inputWorker180 = None; worker = None; outputWorker = None
        input180 = None; output180 = None; seen.clear()
        let paid = metadata180; metadata180 = None<LogicalJsonOwnerReservation>; paid
    }
    private func retireSuccessfulOwnerData180(): Unit {
        let paid = clearSuccessfulOwnerDataHelper180()
        match (paid) { case Some(value) => value.close(); case None => () }
    }
    func originalMetadataForGrant180(): LogicalJsonOwnerReservation { metadata180.getOrThrow() }

    private func retireJobAfterClose180(job: HostIngressJob): Unit {
        match (job.output180) { case Some(frame) => job.output180 = None; frame.retireAfterOutputHelper180(); case None => () }
        job.retireAfterJobHelpers180()
    }
    private func retireInputAfterCloseHelpers180(): Bool {
        if (pendingJobData180.isSome()) { return false }
        match (bootstrapJob180) { case Some(job) => if (!job.originalCanonicalInputReturned180()) { return false }; case None => () }
        if (pendingJob180.isSome() && !pendingJob180.getOrThrow().originalCanonicalInputReturned180()) { return false }
        if (current.isSome() && !current.getOrThrow().originalCanonicalInputReturned180()) { return false }
        for (job in queue) { if (!job.originalCanonicalInputReturned180()) { return false } }
        var original = retainedJobs180
        while (original.isSome()) { if (!original.getOrThrow().originalCanonicalInputReturned180()) { return false }; original = original.getOrThrow().debtNext180 }

        match (currentInput180) { case Some(value) => currentInput180 = None; value.retireAfterActualHostHelpers180(); case None => () }
        match (bootstrapJob180) { case Some(job) => bootstrapJob180 = None; job.retireAfterJobHelpers180(); case None => () }
        match (pendingJob180) { case Some(value) => pendingJob180 = None; retireJobAfterClose180(value); case None => () }
        match (current) { case Some(value) => current = None; retireJobAfterClose180(value); case None => () }
        for (job in queue) { retireJobAfterClose180(job) }; queue.clear()
        while (retainedJobs180.isSome()) {
            let job = retainedJobs180.getOrThrow(); retainedJobs180 = job.debtNext180; job.debtNext180 = None
            retireJobAfterClose180(job)
        }
        true
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
