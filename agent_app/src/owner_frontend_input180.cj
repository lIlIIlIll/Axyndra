package agent_app

import agent_domain.*
import agent_product.*
import agent_host_runtime.*
import agent_runtime.*
import std.collection.*
import std.sync.*
import std.time.*
import std.convert.*
import yjson_support.*
import yjson.*

private class OwnerFrontendLine180 {
    var text: String
    private var payment: ?LogicalJsonOwnerReservation
    init(text: String, paid: LogicalJsonOwnerReservation) { this.text = text; this.payment = Some(paid) }
    func takePayment180(): LogicalJsonOwnerReservation {
        text = ""; let paid = payment.getOrThrow(); payment = None<LogicalJsonOwnerReservation>; paid
    }
    func retireAfterHelper180(): Unit { takePayment180().close() }
}

// One actual reader watches disconnect while an Application request executes.
// Its bounded cursor/queue/future are paid by the same peer bank, not a second
// worker Root. EOF is frontend data; physical disconnect also cancels the exact
// active Session, without closing the longliving Product or its generations.
class OwnerFrontendInput180 {
    private let peer: ProductOwnerPeer180
    private let session: ApplicationSession
    private let product: ProductRuntime
    private let allocatorLock = Mutex()
    private var acpAllocationSequence: Int64 = 0
    private var acpAllocationReturned: Int64 = 0
    private var acpAllocatedId: Int64 = 0
    private let metadata: LogicalJsonOwnerReservation
    private let lock = Mutex()
    private let cancellation: CancellationSource
    private var lines: ?ArrayDeque<OwnerFrontendLine180> = Some(ArrayDeque<OwnerFrontendLine180>())
    private var consumed: ?ArrayList<OwnerFrontendLine180> = Some(ArrayList<OwnerFrontendLine180>())
    private var eof = false
    private var stopping = false
    private var future: ?Future<Result<Unit>> = None<Future<Result<Unit>>>
    private var readerError: ?AgentError = None<AgentError>
    private var readyLine: ?OwnerFrontendLine180 = None<OwnerFrontendLine180>
    private var stdioTransfer: ?OwnerFrontendLine180 = None<OwnerFrontendLine180>
    private var stdioPayment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var stdioText: ?String = None<String>
    private var pending: ?ArrayList<Byte> = Some(ArrayList<Byte>())
    private var pendingPayment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var expectedOutput: Int64 = 0
    private var returnedOutput: Int64 = 0
    private var outputFailure: ?AgentError = None<AgentError>
    private var outputFailurePayment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private let maxLineBytes: Int64
    init(peer: ProductOwnerPeer180, session: ApplicationSession, product: ProductRuntime, metadata: LogicalJsonOwnerReservation,
        cancellation: CancellationSource,
        maxLineBytes!: Int64 = 8388608) {
        this.peer = peer; this.session = session; this.product = product; this.metadata = metadata; this.maxLineBytes = maxLineBytes
        this.cancellation = cancellation
    }
    func allocateAcpRequestId180(): Int64 {
        allocatorLock.lock()
        try {
            lock.lock()
            let sequence = try { acpAllocationSequence++; acpAllocationSequence } finally { lock.unlock() }
            match (peer.writeOwnerFrame180(encodeAgentValue(objectValue([
                ValueField("kind", textValue("acp_request_id")), ValueField("sequence", integerValue(sequence))])), None)) {
                case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
                case Result.Ok(_) => ()
            }
            let until = MonoTime.now() + Duration.millisecond * 5000
            while (true) {
                lock.lock()
                try {
                    if (acpAllocationReturned == sequence) { return acpAllocatedId }
                    if (eof || stopping) { throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.Cancelled,
                        "owner.acp_request_id_cancelled", "ACP peer closed during protocol identifier allocation")) }
                } finally { lock.unlock() }
                if (MonoTime.now() >= until) { throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.Timeout,
                    "owner.acp_request_id_timeout", "ACP protocol identifier allocation exceeded 5000ms")) }
                sleep(Duration.millisecond * 10)
            }
            0
        } finally { allocatorLock.unlock() }
    }
    func cancellation180(): CancellationToken { cancellation.token }
    func start180(): Unit { future = Some(spawn { read180() }) }
    private var activeRaw: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var activeCodec: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var expectedOutputDeadline: ?MonoTime = None<MonoTime>
    private func retireFrameAfterHelper180(): Unit {
        let codec = activeCodec; activeCodec = None<LogicalJsonOwnerReservation>
        let raw = activeRaw; activeRaw = None<LogicalJsonOwnerReservation>
        match (codec) { case Some(paid) => paid.close(); case None => () }
        match (raw) { case Some(paid) => paid.close(); case None => () }
    }
    private func read180(): Result<Unit> {
        while (true) {
            activeRaw = Some(peer.deriveOwnerFrameData180(65536))
            activeCodec = Some(peer.deriveOwnerFrameData180(65536))
            let disposition = readFrameHelper180(activeRaw.getOrThrow(), activeCodec.getOrThrow())
            if (disposition == 0) { publishLineAfterFrameHelper180(); retireFrameAfterHelper180(); continue }
            cancellation.cancel()
            let cancelled = session.cancel()
            if (cancelled.isError()) { return cancelled }
            if (disposition == 1) { return Result.Ok(()) }
            lock.lock()
            try { return Result.Err(readerError.getOrThrow()) } finally { lock.unlock() }
        }
        Result.Ok(())
    }
    private func readFrameHelper180(raw: LogicalJsonOwnerReservation,
        codec: LogicalJsonOwnerReservation): Int64 {
        let frame = match (peer.readOwnerFrame180(raw, None)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                lock.lock(); try { eof = true; readerError = Some(error) } finally { lock.unlock() }
                return 1 }
        codec.ensureRetainedPeak(ownerFrontendDecodeInvoice180(frame))
        match (acceptFrameHelper180(frame)) {
            case Result.Ok(_) => 0
            case Result.Err(error) =>
                lock.lock(); try { eof = true; readerError = Some(error) } finally { lock.unlock() }
                let _ = peer.closeOwnerPeer180()
                // This original raw/DOM/error storage stays in the concrete
                // bound reader until the whole original reader has joined.
                2 }
    }
    private func acceptFrameHelper180(frame: String): Result<Unit> {
        let value = match (decodeAgentValue(frame)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(actual) => actual
        }
        let kind = ownerFrontendText180(value, "kind")
        if (kind == "acp_request_id_returned") {
            let sequence = Int64.parse(value.field("sequence").getOrThrow().asNumberText())
            let id = Int64.parse(value.field("id").getOrThrow().asNumberText())
            lock.lock()
            try {
                if (sequence != acpAllocationSequence || sequence <= acpAllocationReturned || id <= 0) {
                    return Result.Err(AgentError(AgentErrorKind.Protocol,
                        "owner.acp_request_id_order", "ACP protocol identifier reply is not pending")) }
                acpAllocatedId = id; acpAllocationReturned = sequence
                return Result.Ok(())
            } finally { lock.unlock() }
        }
        if (kind == "acp_session_workspace") {
            let workspace = match (product.sessionWorkspaceRoot(SessionId(ownerFrontendText180(value, "sessionId")))) {
                case Result.Ok(path) => path
                // This is advisory routing only. The ORIGINAL ACP method still
                // reaches this same actual Product and emits its original error.
                case Result.Err(_) => ""
            }
            return peer.writeOwnerFrame180(encodeAgentValue(objectValue([
                ValueField("kind", textValue("acp_session_workspace_result")),
                ValueField("sequence", value.field("sequence").getOrThrow()),
                ValueField("workspace", textValue(workspace))])), None)
        }
        if (kind == "output_returned" || kind == "output_failed") {
            let sequence = Int64.parse(value.field("frame").getOrThrow().asNumberText())
            lock.lock()
            try {
                if (sequence != expectedOutput || sequence <= returnedOutput) {
                    return Result.Err(AgentError(AgentErrorKind.Transport,
                        "owner.frontend_output_order", "output completion does not match its actual pending frame")) }
                if (MonoTime.now() >= expectedOutputDeadline.getOrThrow()) {
                    return Result.Err(AgentError(AgentErrorKind.Timeout,
                        "owner.frontend_output_timeout", "frontend physical output helper exceeded 5000ms")) }
                if (kind == "output_failed") {
                    let message = ownerFrontendText180(value, "message")
                    outputFailurePayment = Some(peer.deriveOwnerFrameData180(65536 + message.size * 8))
                    outputFailure = Some(AgentError(AgentErrorKind.Transport,
                        "owner.frontend_output_failed", String.fromUtf8(message.toArray())))
                }
                returnedOutput = sequence
                return Result.Ok(())
            } finally { lock.unlock() }
        }
        if (kind == "eof") {
            if (!pending.getOrThrow().isEmpty()) { return Result.Err(AgentError(AgentErrorKind.InvalidInput,
                "owner.frontend_input_incomplete", "frontend EOF interrupted a logical input")) }
            lock.lock(); try { eof = true } finally { lock.unlock() }
            return Result.Ok(())
        }
        if (kind != "input_chunk") { return Result.Err(AgentError(AgentErrorKind.InvalidInput,
            "owner.frontend_input_invalid", "expected frontend input or EOF")) }
        let part = ownerFrontendText180(value, "line")
        if (part.size > maxLineBytes - pending.getOrThrow().size) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput,
                "owner.frontend_input_too_large", "line frame exceeds configured byte limit")) }
        let extent = pending.getOrThrow().size + part.size
        if (pendingPayment.isNone()) { pendingPayment = Some(peer.deriveOwnerFrameData180(65536 + extent * 8)) }
        else { pendingPayment.getOrThrow().ensureRetainedPeak(65536 + extent * 8) }
        pending.getOrThrow().add(all: unsafe { part.rawData() })
        if (!value.field("final").getOrThrow().asBool()) { return Result.Ok(()) }
        let line = String.fromUtf8(pending.getOrThrow().toArray())
        lock.lock()
        try {
            if (stopping) { return Result.Ok(()) }
            metadata.ensureRetainedPeak(65536 + (lines.getOrThrow().capacity * 2 + consumed.getOrThrow().capacity * 2 + 2) * 4096)
            readyLine = Some(OwnerFrontendLine180(line, pendingPayment.getOrThrow()))
            pendingPayment = None<LogicalJsonOwnerReservation>
            pending = Some(ArrayList<Byte>())
            Result.Ok(())
        } finally { lock.unlock() }
    }
    private func publishLineAfterFrameHelper180(): Unit {
        lock.lock()
        try {
            match (readyLine) {
                case Some(actual) => lines.getOrThrow().addLast(actual); readyLine = None<OwnerFrontendLine180>
                case None => () }
        } finally { lock.unlock() }
    }
    private func sendInputCredit180(): Result<Unit> {
        peer.writeOwnerFrame180(encodeAgentValue(objectValue([ValueField("kind", textValue("input_credit"))])), None)
    }
    func expectOutput180(sequence: Int64, until: MonoTime): Unit {
        lock.lock()
        try {
            if (expectedOutput != returnedOutput || sequence != expectedOutput + 1) {
                throw IllegalStateException("overlapping owner output helper") }
            expectedOutput = sequence; expectedOutputDeadline = Some(until)
        } finally { lock.unlock() }
    }
    func awaitOutputReturn180(sequence: Int64, until: MonoTime): Result<Unit> {
        while (true) {
            lock.lock()
            try {
                if (returnedOutput == sequence) {
                    match (outputFailure) { case Some(error) => return Result.Err(error); case None => return Result.Ok(()) }
                }
                match (readerError) { case Some(error) => return Result.Err(error); case None => () }
                if (stopping) { return Result.Err(AgentError(AgentErrorKind.Transport,
                    "owner.frontend_output_closed", "frontend disconnected during output")) }
            } finally { lock.unlock() }
            if (MonoTime.now() >= until) { return Result.Err(AgentError(AgentErrorKind.Timeout,
                "owner.frontend_output_timeout", "frontend physical output helper did not return within 5000ms")) }
            sleep(Duration.millisecond * 10)
        }
        Result.Ok(())
    }
    func takeOwnedStdioInput180(): Result<?HostStdioInputFrame180> {
        match (nextLine180()) {
            case None => Result.Ok(None<HostStdioInputFrame180>)
            case Some(_) =>
                lock.lock()
                try {
                    stdioTransfer = Some(consumed.getOrThrow().remove(at: consumed.getOrThrow().size - 1))
                    match (sendInputCredit180()) {
                        case Result.Err(error) => return Result.Err(error)
                        case Result.Ok(_) => () }
                    stdioText = Some(stdioTransfer.getOrThrow().text + "\n")
                    stdioPayment = Some(stdioTransfer.getOrThrow().takePayment180())
                    let frame = HostStdioInputFrame180(stdioText.getOrThrow(), stdioPayment.getOrThrow())
                    stdioTransfer = None<OwnerFrontendLine180>; stdioText = None<String>
                    stdioPayment = None<LogicalJsonOwnerReservation>
                    Result.Ok(Some(frame))
                } finally { lock.unlock() }
        }
    }
    func nextLine180(): ?String { nextLineUntil180(None<MonoTime>) }
    func poll180(millis: Int64): ProtocolInputPoll {
        let line = nextLineUntil180(Some(MonoTime.now() + Duration.millisecond * millis))
        lock.lock(); let done = try { (eof || stopping) && lines.getOrThrow().isEmpty() && line.isNone() } finally { lock.unlock() }
        ProtocolInputPoll(line: line, eof: done)
    }
    private func nextLineUntil180(until: ?MonoTime): ?String {
        while (true) {
            lock.lock()
            try {
                if (!lines.getOrThrow().isEmpty()) {
                    metadata.ensureRetainedPeak(65536 + (consumed.getOrThrow().size + 1) * 4096)
                    let actual = lines.getOrThrow().removeFirst().getOrThrow()
                    consumed.getOrThrow().add(actual)
                    return Some(actual.text)
                }
                if (eof || stopping) { return None<String> }
                match (future) {
                    case Some(worker) => match (worker.tryGet()) {
                        case Some(Result.Err(error)) => throw OwnedCanonicalDataFailure113(error)
                        case Some(Result.Ok(_)) => return None<String>
                        case None => () }
                    case None => throw IllegalStateException("owner reader was not started") }
            } finally { lock.unlock() }
            match (until) { case Some(deadline) => if (MonoTime.now() >= deadline) { return None<String> }; case None => () }
            sleep(Duration.millisecond * 10)
        }
        None<String>
    }
    // The caller invokes this after its whole parser/command helper returned.
    func retireLineAfterHelperReturn180(): Unit {
        lock.lock()
        try {
            while (!consumed.getOrThrow().isEmpty()) {
                let actual = consumed.getOrThrow().remove(at: consumed.getOrThrow().size - 1)
                actual.retireAfterHelper180()
                match (sendInputCredit180()) {
                    case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
                    case Result.Ok(_) => () }
            }
        } finally { lock.unlock() }
    }
    private func closeLine180(line: ?OwnerFrontendLine180): Unit {
        match (line) { case Some(actual) => actual.retireAfterHelper180(); case None => () }
    }
    private func joinReaderHelper180(): Result<Unit> {
        match (future) {
            case Some(worker) => worker.get()
            case None => Result.Ok(()) }
    }
    func stopAndJoinAfterFrontendReturn180(): Result<Unit> {
        cancellation.cancel()
        lock.lock(); try { stopping = true } finally { lock.unlock() }
        let closed = peer.closeOwnerPeer180()
        let joined = joinReaderHelper180()
        if (joined.isError()) { return joined }
        future = None<Future<Result<Unit>>>
        closed
    }
    func retireAfterReaderJoin180(): Result<Unit> {
        if (future.isSome()) { return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "owner.frontend_reader_pending", "original frontend reader has not joined")) }
        if (stdioTransfer.isSome() || stdioPayment.isSome() || stdioText.isSome()) {
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "owner.frontend_stdio_transfer_pending", "actual Host input transfer remains owned")) }
        while (!consumed.getOrThrow().isEmpty()) {
            consumed.getOrThrow().remove(at: consumed.getOrThrow().size - 1).retireAfterHelper180() }
        closeLine180(readyLine); readyLine = None<OwnerFrontendLine180>
        while (!lines.getOrThrow().isEmpty()) { closeLine180(lines.getOrThrow().removeFirst()) }
        lines = None<ArrayDeque<OwnerFrontendLine180>>; consumed = None<ArrayList<OwnerFrontendLine180>>
        outputFailure = None<AgentError>
        match (outputFailurePayment) { case Some(paid) => outputFailurePayment = None<LogicalJsonOwnerReservation>; paid.close(); case None => () }
        pending = None<ArrayList<Byte>>
        match (pendingPayment) { case Some(paid) => pendingPayment = None<LogicalJsonOwnerReservation>; paid.close(); case None => () }
        readerError = None<AgentError>; expectedOutputDeadline = None<MonoTime>
        retireFrameAfterHelper180()
        cancellation.close()
        metadata.close()
        Result.Ok(())
    }
}
