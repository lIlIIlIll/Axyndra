package agent_app

import agent_domain.*
import agent_product.*
import agent_runtime.*
import agent_rpc.*
import agent_tui.*
import std.collection.*
import std.sync.*
import std.time.*
import yjson_support.*
import yjson.*
import process4cj.*
import std.convert.*

func ownerFrontendBoolean180(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(actual) => actual.unifiedKind == ValueKind.Boolean && actual.asBool()
        case None => false
    }
}

func ownerFrontendText180(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(actual) => if (actual.unifiedKind == ValueKind.Text) { actual.text } else { "" }
        case None => ""
    }
}
func ownerFrontendArguments180(value: AgentValue): Array<String> {
    let result = ArrayList<String>()
    match (value.field("arguments")) {
        case Some(actual) => for (item in actual.items) {
            if (item.unifiedKind != ValueKind.Text) { throw IllegalArgumentException("frontend argument is not text") }
            result.add(item.text)
        }
        case None => ()
    }
    result.toArray()
}
func ownerFrontendRequest180(frontend: String, rawArguments: Array<String>,
    command: String, arguments: Array<String>): AgentValue {
    let original = ArrayList<AgentValue>()
    original.add(textValue("axyndra"))
    for (name in ["--approval-mode", "--shell-network-mode", "--model", "--max-time",
        "--model-attempt-recovery", "--model-stream-idle-timeout-ms", "--model-stream-fault-profile"]) {
        let value = argumentValue(rawArguments, name)
        if (value != "") { original.add(textValue(name + "=" + value)) }
    }
    let tail = ArrayList<AgentValue>()
    for (value in arguments) { tail.add(textValue(value)) }
    objectValue([
        ValueField("frontend", textValue(frontend)), ValueField("command", textValue(command)),
        ValueField("arguments", listValue(tail.toArray())),
        ValueField("options", objectValue([ValueField("arguments", listValue(original.toArray()))]))
    ])
}

// Application input and output retain their original logical limits. The
// existing broker's 1 MiB physical request bound is unchanged: UTF-8 is split
// at codepoint boundaries into bounded DATA pieces, never prepared calls.
func sendOwnerFrontendInput180(peer: ProductOwnerPeer180, line: String): Result<Unit> {
    let paid = peer.deriveOwnerFrameData180(65536 + line.size * 8)
    let result = sendOwnerFrontendInputHelper180(peer, line)
    paid.close()
    result
}
private func sendOwnerFrontendInputHelper180(peer: ProductOwnerPeer180, line: String): Result<Unit> {
    let bytes = unsafe { line.rawData() }
    var start: Int64 = 0
    while (start < bytes.size || (start == 0 && bytes.isEmpty())) {
        var end = min(bytes.size, start + 65536)
        while (end < bytes.size && (bytes[end] & 192u8) == 128u8) { end-- }
        let part = String.fromUtf8(bytes[start..end])
        let frame = encodeAgentValue(objectValue([
            ValueField("kind", textValue("input_chunk")), ValueField("line", textValue(part)),
            ValueField("final", boolValue(end == bytes.size))]))
        match (peer.writeOwnerFrame180(frame, None)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        if (end == bytes.size) { break }
        start = end
    }
    Result.Ok(())
}

private class OwnerFrontendIngressCredit180 {
    private let lock = Mutex()
    private var available = true
    func take180(stopped: AtomicBool): Bool {
        while (!stopped.load()) {
            lock.lock()
            try { if (available) { available = false; return true } } finally { lock.unlock() }
            sleep(Duration.millisecond * 10)
        }
        false
    }
    func grant180(): Unit {
        lock.lock()
        try {
            if (available) { throw IllegalStateException("duplicate frontend ingress credit") }
            available = true
        } finally { lock.unlock() }
    }
}

private func pumpOwnerFrontendStdinHelper180(peer: ProductOwnerPeer180,
    stopped: AtomicBool, input: AcpOwnedJsonlInput113, credit: OwnerFrontendIngressCredit180): Result<Unit> {
    while (!stopped.load()) {
        let (eof, line) = input.poll113(50)
        match (line) {
            case Some(actual) =>
                if (!credit.take180(stopped)) { return Result.Ok(()) }
                let answer = actual.withLine113({ text, _ => sendOwnerFrontendInput180(peer, text) })
                match (answer) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                if (!input.retireHandledInputAfterHelperReturn113()) {
                    return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "owner.frontend_input_retirement_pending", "frontend input helper has not retired")) }
            case None => ()
        }
        if (eof) { return peer.writeOwnerFrame180(encodeAgentValue(objectValue([
            ValueField("kind", textValue("eof"))])), None) }
    }
    Result.Ok(())
}


func ownerFrontendPluginStdio180(request: AgentValue): Bool {
    let arguments = ownerFrontendArguments180(request)
    ownerFrontendText180(request, "frontend") == "cli" &&
        ownerFrontendText180(request, "command") == "plugin" &&
        !arguments.isEmpty() && arguments[0] == "serve"
}

// The program Root constructs and retains this concrete consumer before its
// first read, callback, worker or inherited-fd borrow. Root alone retires it
// after the original enclosing run and close helpers have actually returned.
private class OwnerNativeClientFrontend180 <: ProductOwnerClientFrontend180 {
    private var peer: ?ProductOwnerPeer180
    private var prompt: ?String
    private var stream = false
    private var pluginStdio = false
    private var initialRequest180: ?AgentValue
    private let stopped = AtomicBool(false)
    private let credit = OwnerFrontendIngressCredit180()
    private var metadata: ?LogicalJsonOwnerReservation
    private var rawFrame: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var decodedFrame: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var inputControl: ?AcpOwnedWorkerControl113 = None<AcpOwnedWorkerControl113>
    private var input: ?AcpOwnedJsonlInput113 = None<AcpOwnedJsonlInput113>
    private var inputWorker: ?Future<Result<Unit>> = None<Future<Result<Unit>>>
    private var boundedWriter: ?BorrowedPipeWriter = None<BorrowedPipeWriter>
    private var writeDeadline: ?MonoTime = None<MonoTime>
    private var rawData180: ?String = None<String>
    private var decodedData180: ?AgentValue = None<AgentValue>
    init(peer: ProductOwnerPeer180, request: AgentValue, prompt: ?String) {
        this.peer = Some(peer); this.metadata = None<LogicalJsonOwnerReservation>; this.prompt = prompt
        this.initialRequest180 = Some(request)
    }
    public func runOwnerClientFrontend180(): Int64 {
        let actual = peer.getOrThrow()
        metadata = Some(actual.deriveOwnerFrameData180(65536))
        let request = initialRequest180.getOrThrow()
        pluginStdio = ownerFrontendPluginStdio180(request)
        stream = ownerFrontendText180(request, "frontend") == "rpc" || pluginStdio
        initialRequest180 = None<AgentValue>
        tuiStartupStage("configuration_loading_completed")
        if (pluginStdio) {
            // Only the original plugin-stdio command requires a pipe/socket.
            // Ordinary text/json/CLI TTY and file output keeps its checked fd
            // writer, rather than silently changing its admission contract.
            boundedWriter = Some(BorrowedPipeWriter(1))
        }
        if (stream) {
            let control = newAcpOwnedWorkerControl113(actual.deriveOwnerFrameData180(65536))
            inputControl = Some(control)
            let source = AcpOwnedJsonlInput113(control, control.prepareFrontendCustody113())
            input = Some(source); control.installFrontendCustody113(source)
            inputWorker = Some(spawn { pumpInput180(actual, source) })
        } else {
            match (prompt) {
                case Some(text) => match (sendOwnerFrontendInput180(actual, text)) {
                    case Result.Err(error) => consoleCliIo180.eprintln(error.describe()); return 1
                    case Result.Ok(_) => () }
                case None => ()
            }
            prompt = None<String>
        }
        while (true) {
            rawFrame = Some(actual.deriveOwnerFrameData180(65536))
            decodedFrame = Some(actual.deriveOwnerFrameData180(65536))
            let status = readFrameHelper180(actual, rawFrame.getOrThrow(), decodedFrame.getOrThrow())
            // Neither the raw String nor its decoded DOM crosses the whole
            // private helper return. Primitive status is not a writer ACK.
            retireFrame180()
            match (status) { case Some(code) => return code; case None => () }
        }
        1
    }
    private func pumpInput180(actual: ProductOwnerPeer180, source: AcpOwnedJsonlInput113): Result<Unit> {
        let answer = pumpOwnerFrontendStdinHelper180(actual, stopped, source, credit)
        if (answer.isError()) { let _ = actual.closeOwnerPeer180() }
        answer
    }
    private func readFrameHelper180(actual: ProductOwnerPeer180,
        raw: LogicalJsonOwnerReservation, codec: LogicalJsonOwnerReservation): ?Int64 {
        let text = match (actual.readOwnerFrame180(raw, None)) {
            case Result.Ok(value) => value
            case Result.Err(error) => consoleCliIo180.eprintln(error.describe()); return Some(1) }
        codec.ensureRetainedPeak(ownerFrontendDecodeInvoice180(text))
        rawData180 = Some(text)
        let value = match (decodeAgentValue(text)) {
            case Result.Ok(decoded) => decoded
            case Result.Err(error) => consoleCliIo180.eprintln(error.describe()); return Some(1) }
        decodedData180 = Some(value)
        match (ownerFrontendText180(value, "kind")) {
            case "input_credit" => if (stream) { credit.grant180() }; None<Int64>
            case "output" | "error_output" => writeOwnerFrontendOutput180(actual, value,
                physicalOutput180: Some({ frame => writePhysicalFrame180(frame) }))
            case "read" =>
                if (stream) {
                    if (!pluginStdio) { throw IllegalStateException("RPC frontend requested terminal input") }
                    return None<Int64>
                }
                match (consoleCliIo180.readln()) {
                    case Some(line) => match (sendOwnerFrontendInput180(actual, line)) {
                        case Result.Ok(_) => None<Int64>
                        case Result.Err(error) => consoleCliIo180.eprintln(error.describe()); Some(1) }
                    case None => match (actual.writeOwnerFrame180(encodeAgentValue(objectValue([
                        ValueField("kind", textValue("eof"))])), None)) {
                        case Result.Ok(_) => None<Int64>
                        case Result.Err(error) => consoleCliIo180.eprintln(error.describe()); Some(1) }
                }
            case "exit" => Some(Int64.parse(value.field("status").getOrThrow().asNumberText()))
            case _ => consoleCliIo180.eprintln("unexpected owner frontend frame"); Some(1)
        }
    }
    private func writePhysicalFrame180(value: AgentValue): Unit {
        if (!pluginStdio || ownerFrontendText180(value, "kind") == "error_output") {
            writeOwnerFrontendOutputHelper180(value); return
        }
        let until = match (writeDeadline) {
            case Some(deadline) => deadline
            case None => let deadline = MonoTime.now() + Duration.millisecond * 5000
                writeDeadline = Some(deadline); deadline }
        if (MonoTime.now() >= until) {
            throw ProcessError(ProcessErrorKind.DeadlineExceeded, "plugin stdio frame write timed out") }
        let remaining = max(1, (until - MonoTime.now()).toMilliseconds())
        let bytes = unsafe { ownerFrontendText180(value, "text").rawData() }
        boundedWriter.getOrThrow().write(bytes, { => stopped.load() }, timeoutMillis: remaining)
        if (MonoTime.now() >= until) {
            throw ProcessError(ProcessErrorKind.DeadlineExceeded, "plugin stdio frame write timed out") }
        if (ownerFrontendBoolean180(value, "final")) { writeDeadline = None<MonoTime> }
    }
    private func retireFrame180(): Unit {
        decodedData180 = None<AgentValue>; rawData180 = None<String>
        let codec = decodedFrame; decodedFrame = None<LogicalJsonOwnerReservation>
        let raw = rawFrame; rawFrame = None<LogicalJsonOwnerReservation>
        match (codec) { case Some(paid) => paid.close(); case None => () }
        match (raw) { case Some(paid) => paid.close(); case None => () }
    }
    private func joinInputHelper180(): Result<Unit> {
        match (inputWorker) {
            // get, not a readiness flag, and its result/error aliases end in
            // this complete helper before the owning fields can be cleared.
            case Some(worker) => match (worker.get()) {
                case Result.Err(error) => consoleCliIo180.eprintln(error.describe()); Result.Err(error)
                case Result.Ok(_) => Result.Ok(()) }
            case None => Result.Ok(()) }
    }
    public func closeOwnerClientFrontend180(): Result<Unit> {
        stopped.store(true)
        let joined = joinInputHelper180()
        if (joined.isError()) { return joined }
        inputWorker = None<Future<Result<Unit>>>
        match (boundedWriter) { case Some(writer) => writer.close(); case None => () }
        boundedWriter = None<BorrowedPipeWriter>; writeDeadline = None<MonoTime>
        match (input) {
            case Some(source) => if (!source.destroyInputAfterFailedFrontendReturn113()) {
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "owner.frontend_input_retirement_pending", "frontend input helper has not retired")) }
            case None => () }
        input = None<AcpOwnedJsonlInput113>
        match (inputControl) {
            case Some(control) =>
                if (!control.collectFrontendAfterHelperReturn113()) {
                    return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "owner.frontend_input_retirement_pending", "frontend input custody has not retired")) }
                match (control.takeOwnerFrontendPaymentAfterScopeReturn180()) {
                    case Some(paid) => paid.close()
                    case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "owner.frontend_control_retirement_pending", "frontend controller still owns metadata")) }
            case None => () }
        inputControl = None<AcpOwnedWorkerControl113>
        retireFrame180()
        prompt = None<String>; peer = None<ProductOwnerPeer180>
        let paid = metadata; metadata = None<LogicalJsonOwnerReservation>
        match (paid) { case Some(actual) => actual.close(); case None => () }
        Result.Ok(())
    }
}
func runOwnerFrontendClient180(config: ProductConfig, request: AgentValue,
    frontendRoot: LogicalJsonOwnerReservation, prompt!: ?String = None<String>): Int64 {
    if (ownerFrontendText180(request, "frontend") == "acp") {
        return runOwnerAcpClient180(config, request, frontendRoot) }
    let allocate = { bytes: Int64 =>
        let paid = frontendRoot.deriveRetainedLease()
        try { paid.ensureRetainedPeak(bytes); paid }
        catch (error: Exception) { paid.close(); throw error } }
    runProductOwnerClientFrontend180(config, request,
        { peer => OwnerNativeClientFrontend180(peer, request, prompt) }, allocate: allocate)
}
func writeOwnerFrontendOutput180(peer: ProductOwnerPeer180, value: AgentValue,
    physicalOutput180!: ?((AgentValue) -> Unit) = None<(AgentValue) -> Unit>): ?Int64 {
    let sequence = Int64.parse(value.field("frame").getOrThrow().asNumberText())
    try { match (physicalOutput180) {
        case Some(write) => write(value)
        case None => writeOwnerFrontendOutputHelper180(value)
    } }
    catch (failure: Exception) {
        // No success ACK: the original physical writer exception reaches the
        // pending owner helper, which still owns its exact original Source.
        let paid = peer.deriveOwnerFrameData180(65536 + failure.message.size * 16)
        let result = reportOwnerFrontendOutputFailureHelper180(peer, sequence, failure)
        paid.close()
        match (result) { case Result.Err(error) => printError(error); case Result.Ok(_) => () }
        throw failure
    }
    match (peer.writeOwnerFrame180(encodeAgentValue(objectValue([
        ValueField("kind", textValue("output_returned")), ValueField("frame", integerValue(sequence))])), None)) {
        case Result.Ok(_) => None<Int64>
        case Result.Err(error) => printError(error); Some(1)
    }
}
private func writeOwnerFrontendOutputHelper180(value: AgentValue): Unit {
    let text = ownerFrontendText180(value, "text")
    if (ownerFrontendText180(value, "kind") == "error_output") { writeFdUtf8Checked182(2, text) }
    else { consoleCliIo180.print(text) }
}
private func reportOwnerFrontendOutputFailureHelper180(peer: ProductOwnerPeer180, sequence: Int64,
    failure: Exception): Result<Unit> {
    peer.writeOwnerFrame180(encodeAgentValue(objectValue([
        ValueField("kind", textValue("output_failed")), ValueField("frame", integerValue(sequence)),
        ValueField("message", textValue(failure.message))])), None)
}
