package agent_host_runtime

import agent_domain.*
import agent_ports.*
import std.collection.*
import std.sync.*

// The constructor accepts an already admitted channel. It is not a launch
// grant, service handle, executable selector or Operation settlement API.
// The eventual executor must retain this owner until closeAcknowledged().
public class HostHttpExchangeReader {
    private let channel: ProcessChannel
    private let cancellation: CancellationToken
    private let parser: HostHttpExchangeHeadParser
    private let bodyGate: HostTransportOutputGate
    private let secrets: Array<String>
    private let readLock = Mutex()
    private let stateLock = Mutex()
    private var stopping = false
    private var acknowledged = false
    private var failure: ?AgentError = None
    private var head: ?HostHttpExchangeHead = None
    private var ready: Array<Byte> = []
    private var bodyBytes: Int64 = 0
    private var pipeEof = false
    private var stderrEof = false
    private var bodyEof = false

    public init(channel: ProcessChannel, cancellation: CancellationToken, secrets: Array<String>,
        maxBodyBytes!: Int64 = 1048576) {
        this.channel = channel; this.cancellation = cancellation; this.secrets = secrets.clone()
        parser = HostHttpExchangeHeadParser(maxBodyBytes: maxBodyBytes)
        bodyGate = HostTransportOutputGate(this.secrets, maxBytes: maxBodyBytes)
    }

    // One bounded channel poll per call. None means more response metadata is
    // needed; it never means the HTTP exchange has completed successfully.
    public func pollHead(waitMillis!: Int64 = 25): Result<?HostHttpExchangeHead> {
        if (waitMillis < 0 || waitMillis > 25) { return invalid() }
        readLock.lock()
        try {
            match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (head.isSome()) { return publishHead() }
            match (discardDiagnostics()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let received = match (channel.read(ProcessChannelStream.Stdout, 8192, waitMillis)) {
                case Result.Err(error) => return fail(); case Result.Ok(value) => value
            }
            let parsed = match (parser.push(received.bytes)) {
                case Result.Err(error) => return fail(); case Result.Ok(value) => value
            }
            if (parsed.isNone()) {
                if (received.eof) { return fail() }
                return publishHead()
            }
            let selected = parsed.getOrThrow()
            // Raw cookies, redirects, reason strings and diagnostics never
            // escape. Even the selected content type must pass the same gate.
            let metadata = HostTransportOutputGate(secrets, maxBytes: 1024)
            if (metadata.push(selected.contentType.toArray(), eof: true).isError()) { return fail() }
            let retryMetadata = HostTransportOutputGate(secrets, maxBytes: 1024)
            if (retryMetadata.push(selected.retryAfter.toArray(), eof: true).isError()) { return fail() }
            head = Some(selected)
            let prefix = match (parser.takeBodyPrefix()) {
                case Result.Err(error) => return fail(); case Result.Ok(value) => value
            }
            match (acceptBody(prefix, received.eof)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
            }
            publishHead()
        } catch (_: Exception) { fail() }
        finally { readLock.unlock() }
    }

    public func readBody(maxBytes: Int64, waitMillis!: Int64 = 25): Result<ProcessChannelRead> {
        if (maxBytes < 1 || maxBytes > 16384 || waitMillis < 0 || waitMillis > 25) { return invalid() }
        readLock.lock()
        try {
            match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (head.isNone()) { return invalid() }
            if (ready.isEmpty() && !bodyEof) {
                match (discardDiagnostics()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                if (!pipeEof) {
                    let received = match (channel.read(ProcessChannelStream.Stdout, 8192, waitMillis)) {
                        case Result.Err(error) => return fail(); case Result.Ok(value) => value
                    }
                    match (acceptBody(received.bytes, received.eof)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
                    }
                }
                match (confirmBodyEnd()) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
                }
            }
            // Deadline polling can synchronously invoke a caller callback
            // which closes this reader. Never poll while holding stateLock.
            let cancelled = cancellation.isCancelled()
            stateLock.lock()
            try {
                match (checkLocked(cancelled)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let count = min(maxBytes, ready.size)
                let bytes = ready[..count].clone(); ready = ready[count..].clone()
                Result.Ok(ProcessChannelRead(bytes, bodyEof && ready.isEmpty()))
            } finally { stateLock.unlock() }
        } catch (_: Exception) { fail() }
        finally { readLock.unlock() }
    }

    private func publishHead(): Result<?HostHttpExchangeHead> {
        let cancelled = cancellation.isCancelled()
        stateLock.lock()
        try {
            match (checkLocked(cancelled)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(head)
        } finally { stateLock.unlock() }
    }

    private func acceptBody(bytes: Array<Byte>, eof: Bool): Result<Unit> {
        if (pipeEof || head.isNone()) { return fail() }
        bodyBytes += bytes.size
        let length = head.getOrThrow().bodySize
        if (length.isSome() && (bodyBytes > length.getOrThrow() || (eof && bodyBytes != length.getOrThrow()))) {
            return fail()
        }
        let filtered = match (bodyGate.push(bytes)) {
            case Result.Err(error) => return fail(); case Result.Ok(value) => value
        }
        let combined = ArrayList<Byte>(); combined.add(all: ready); combined.add(all: filtered)
        // The body gate can release a previously withheld credential prefix
        // when later bytes disprove it. Keep that finite suffix until reads.
        if (combined.size > 57356) { return fail() }
        ready = combined.toArray(); pipeEof = eof
        confirmBodyEnd()
    }

    private func confirmBodyEnd(): Result<Unit> {
        if (!pipeEof || bodyEof) { return Result.Ok(()) }
        // A truncated chunked/HTTP2 response can have stdout EOF while curl
        // exits unsuccessfully. Pipe EOF alone is never HTTP framing proof.
        let status = match (channel.terminalStatus()) {
            case Result.Err(error) => return fail(); case Result.Ok(value) => value
        }
        if (status.isNone()) { return Result.Ok(()) }
        if (status.getOrThrow() != 0) { return fail() }
        match (discardDiagnostics()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        // Wait for both pumps to finish charging the channel's shared output
        // quota. A cached leader exit is still not resource cleanup ACK.
        if (!stderrEof) { return Result.Ok(()) }
        let tail = match (bodyGate.push([], eof: true)) {
            case Result.Err(error) => return fail(); case Result.Ok(value) => value
        }
        let combined = ArrayList<Byte>(); combined.add(all: ready); combined.add(all: tail)
        if (combined.size > 57356) { return fail() }
        ready = combined.toArray(); bodyEof = true
        Result.Ok(())
    }

    private func discardDiagnostics(): Result<Unit> {
        // The channel's cumulative stdout+stderr quota is charged at ingress.
        // Consume a bounded amount without reflecting private curl diagnostics.
        if (stderrEof) { return Result.Ok(()) }
        match (channel.read(ProcessChannelStream.Stderr, 8192, 0)) {
            case Result.Err(error) => fail()
            case Result.Ok(value) => stderrEof = value.eof; Result.Ok(())
        }
    }

    private func check(): Result<Unit> {
        let cancelled = cancellation.isCancelled()
        stateLock.lock(); try { checkLocked(cancelled) } finally { stateLock.unlock() }
    }
    private func checkLocked(cancelled: Bool): Result<Unit> {
        if (cancelled) {
            return Result.Err(AgentError(AgentErrorKind.Cancelled, "http.exchange_cancelled",
                "HTTP exchange caller was cancelled", retryable: false, fallbackAllowed: false))
        }
        match (failure) { case Some(error) => return Result.Err(error); case None => () }
        if (stopping) { return unknown() }
        Result.Ok(())
    }
    private func fail<T>(): Result<T> {
        stateLock.lock()
        try {
            stopping = true
            if (failure.isNone()) { failure = Some(hostHttpExchangeReadFailure()) }
        } finally { stateLock.unlock() }
        // Abort never waits for readLock. Retain the channel even if its signal
        // fails; only an acknowledged close may release the outer reservation.
        try { let _ = channel.abort() } catch (_: Exception) {}
        if (cancellation.isCancelled()) {
            return Result.Err(AgentError(AgentErrorKind.Cancelled, "http.exchange_cancelled",
                "HTTP exchange caller was cancelled", retryable: false, fallbackAllowed: false))
        }
        unknown()
    }
    private func invalid<T>(): Result<T> {
        Result.Err(AgentError(AgentErrorKind.InvalidInput, "http.exchange_read_invalid",
            "HTTP exchange read is outside its bounded state or limits"))
    }
    private func unknown<T>(): Result<T> { Result.Err(hostHttpExchangeReadFailure()) }

    // Caller-requested early close is necessary for finite consumers of an
    // open SSE response. Its receipt must describe consumed bytes plus close,
    // never claim remote business success or full-body EOF from this ACK.
    public func close(): Result<Unit> {
        stateLock.lock()
        let done = try { stopping = true; acknowledged } finally { stateLock.unlock() }
        if (done) { return Result.Ok(()) }
        try { let _ = channel.abort() } catch (_: Exception) {}
        let result = try { channel.close() } catch (_: Exception) { unknown<Unit>() }
        if (result.isError()) {
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "http.exchange_cleanup_pending",
                "HTTP exchange cleanup remains owned and unacknowledged", retryable: false, fallbackAllowed: false))
        }
        stateLock.lock(); try { acknowledged = true } finally { stateLock.unlock() }
        Result.Ok(())
    }
    // Actual stdout+stderr ingress, including data queued before early
    // close. Metadata/diagnostics are charged without exposing their contents.
    public func receivedOutputBytes(): Result<Int64> { channel.receivedOutputBytes() }
    public func closeAcknowledged(): Bool { stateLock.lock(); try { acknowledged } finally { stateLock.unlock() } }
}

public func hostHttpExchangeReadFailure(): AgentError {
    AgentError(AgentErrorKind.RecoveryRequired, "http.exchange_outcome_unknown",
        "HTTP exchange lacks a verified bounded response", retryable: false, fallbackAllowed: false)
}
