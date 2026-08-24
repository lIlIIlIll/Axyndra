package llm4cj

import process4cj.*
import std.collection.*
import std.convert.*
import std.io.*

public enum LlmTransportErrorKind {
    InvalidWire | Http | BodyLimit | Sse | Cancelled | Deadline | Transport
}

public class LlmTransportError <: Exception {
    public let kind: LlmTransportErrorKind
    public let code: String
    public let retryable: Bool
    public let httpStatus: ?Int64
    public let retryAfterMillis: Int64
    public let provider: String
    public let providerErrorCode: String
    public let providerErrorType: String

    public init(
        kind: LlmTransportErrorKind,
        code: String,
        message: String,
        retryable!: Bool = false,
        httpStatus!: ?Int64 = None,
        retryAfterMillis!: Int64 = 0,
        provider!: String = "",
        providerErrorCode!: String = "",
        providerErrorType!: String = ""
    ) {
        super(message)
        this.kind = kind
        this.code = code
        this.retryable = retryable
        this.httpStatus = httpStatus
        this.retryAfterMillis = retryAfterMillis
        this.provider = provider
        this.providerErrorCode = providerErrorCode
        this.providerErrorType = providerErrorType
    }
}

public enum LlmResult<T> {
    Ok(T) | Err(LlmTransportError)
    public func isOk(): Bool { match (this) { case Ok(_) => true; case Err(_) => false } }
}

public class SseEvent {
    public let event: String
    public let data: String
    public let id: String
    public let retryMillis: Int64
    public init(event: String, data: String, id: String, retryMillis: Int64) {
        this.event = event
        this.data = data
        this.id = id
        this.retryMillis = retryMillis
    }
}

// Incremental SSE codec. It owns only wire framing; provider event semantics
// remain in the caller.
public class SseDecoder {
    private var pending = ""
    private let maxEventBytes: Int64
    private let maxBufferedBytes: Int64

    public init(maxEventBytes!: Int64 = 8388608, maxBufferedBytes!: Int64 = 16777216) {
        if (maxEventBytes < 1 || maxBufferedBytes < maxEventBytes) {
            throw IllegalArgumentException("invalid SSE limits")
        }
        this.maxEventBytes = maxEventBytes
        this.maxBufferedBytes = maxBufferedBytes
    }

    public func push(chunk: String): LlmResult<Array<SseEvent>> {
        pending += chunk
        let events = ArrayList<SseEvent>()
        while (true) {
            let normalized = pending.replace("\r\n", "\n")
            match (normalized.indexOf("\n\n")) {
                case Some(index) =>
                    let block = normalized[..index]
                    pending = normalized[index + 2..]
                    match (decodeSseBlock(block, maxEventBytes)) {
                        case LlmResult.Ok(Some(event)) => events.add(event)
                        case LlmResult.Ok(None) => ()
                        case LlmResult.Err(error) => return LlmResult.Err(error)
                    }
                case None =>
                    pending = normalized
                    break
            }
        }
        if (utf8Size(pending) > maxBufferedBytes) {
            return llmFailure<Array<SseEvent>>(LlmTransportErrorKind.BodyLimit, "llm.sse_buffer_too_large", "SSE buffer exceeds configured limit")
        }
        LlmResult.Ok(events.toArray())
    }

    public func finish(): LlmResult<Array<SseEvent>> {
        let tail = pending.replace("\r", "\n")
        pending = ""
        if (tail.trimAscii() == "") { return LlmResult.Ok([]) }
        match (decodeSseBlock(tail, maxEventBytes)) {
            case LlmResult.Ok(Some(event)) => LlmResult.Ok([event])
            case LlmResult.Ok(None) => LlmResult.Ok([])
            case LlmResult.Err(error) => LlmResult.Err(error)
        }
    }
}

public func parseRetryAfterMillis(value: String): Int64 {
    let seconds = try { Int64.parse(value.trimAscii()) } catch (_: Exception) { return 0 }
    if (seconds <= 0) { return 0 }
    let maximumSeconds = Int64.Max / 1000
    if (seconds > maximumSeconds) { return Int64.Max }
    seconds * 1000
}

public func extractRetryAfterMillis(headers: String): Int64 {
    var result: Int64 = 0
    for (line in headers.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.toAsciiLower().startsWith("retry-after:")) {
            result = max(result, parseRetryAfterMillis(trimmed[12..]))
        }
    }
    result
}

public func sseDataLine(line: String): ?String {
    if (!line.startsWith("data:")) { return None }
    var value = line[5..]
    if (value.startsWith(" ")) { value = value[1..] }
    Some(value)
}

public func readLlmHttpBody(
    stream: InputStream,
    declaredSize: ?Int64,
    maxBytes: Int64
): LlmResult<Array<Byte>> {
    if (maxBytes < 1) {
        return llmFailure<Array<Byte>>(LlmTransportErrorKind.BodyLimit, "llm.body_limit_invalid", "response body limit must be positive")
    }
    match (declaredSize) {
        case Some(value) => if (value < 0 || value > maxBytes) {
            return llmFailure<Array<Byte>>(LlmTransportErrorKind.BodyLimit, "llm.body_too_large", "provider response exceeds configured limit")
        }
        case None => ()
    }
    try {
        let budget = BoundedOutputBudget(maxBytes)
        let bytes = readBounded(stream, budget)
        if (budget.wasTruncated()) {
            llmFailure<Array<Byte>>(LlmTransportErrorKind.BodyLimit, "llm.body_too_large", "provider response exceeds configured limit")
        } else {
            LlmResult.Ok(bytes)
        }
    } catch (error: ProcessError) {
        llmFailure<Array<Byte>>(LlmTransportErrorKind.Transport, "llm.body_read_failed", error.message)
    }
}

func decodeSseBlock(block: String, maxEventBytes: Int64): LlmResult<?SseEvent> {
    var event = ""
    var data = ""
    var id = ""
    var retry: Int64 = 0
    for (line in block.split("\n")) {
        if (line.startsWith(":")) { continue }
        let colon = line.indexOf(":")
        let name: String
        var value: String
        match (colon) {
            case Some(index) => name = line[..index]; value = line[index + 1..]
            case None => name = line; value = ""
        }
        if (value.startsWith(" ")) { value = value[1..] }
        match (name) {
            case "data" => if (data == "") { data = value } else { data += "\n" + value }
            case "event" => event = value
            case "id" => if (!value.contains("\u{0000}")) { id = value }
            case "retry" => retry = parseRetryAfterMillis(value) / 1000
            case _ => ()
        }
        if (utf8Size(data) > maxEventBytes) {
            return llmFailure<?SseEvent>(LlmTransportErrorKind.BodyLimit, "llm.sse_event_too_large", "SSE event exceeds configured limit")
        }
    }
    if (data == "" && event == "" && id == "" && retry == 0) { LlmResult.Ok(None) } else {
        LlmResult.Ok(Some(SseEvent(event, data, id, retry)))
    }
}

func utf8Size(value: String): Int64 { unsafe { value.rawData().size } }

func llmFailure<T>(kind: LlmTransportErrorKind, code: String, message: String): LlmResult<T> {
    LlmResult.Err(LlmTransportError(kind, code, message))
}
