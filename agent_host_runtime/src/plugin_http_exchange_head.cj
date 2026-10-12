package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.convert.*

// Metadata only; no socket, process, grant, Operation or response-body authority.
// A future channel-backed HTTP executor must retain ownership until consumption
// and close acknowledgement; producing this value cannot settle its Receipt.
public class HostHttpExchangeHead {
    public let status: Int64
    public let contentType: String
    public let bodySize: ?Int64
    public let retryAfter: String
    init(status: Int64, contentType: String, bodySize: ?Int64, retryAfter!: String = "") {
        this.status = status; this.contentType = contentType; this.bodySize = bodySize; this.retryAfter = retryAfter
    }
}

// Incremental parser for curl --include --no-buffer --suppress-connect-headers
// output. Curl owns HTTP framing/dechunking. Only these bounded metadata fields
// are projected, never raw response headers, cookies, Location or reason text.
// Even the projected content type is untrusted output: a credential-bearing
// owner must check its reflection boundary before exposing any metadata.
public class HostHttpExchangeHeadParser {
    private let maxHeaderBytes: Int64
    private let maxBodyBytes: Int64
    private let pending = ArrayList<Byte>()
    private var totalHeaderBytes: Int64 = 0
    private var interimHeads: Int64 = 0
    private var head: ?HostHttpExchangeHead = None
    private var prefix: Array<Byte> = []
    private var failed = false
    private var taken = false

    public init(maxHeaderBytes!: Int64 = 32768, maxBodyBytes!: Int64 = 1048576) {
        if (maxHeaderBytes < 16 || maxHeaderBytes > 65536 || maxBodyBytes < 1 || maxBodyBytes > 16777216) {
            throw IllegalArgumentException("HTTP exchange requires bounded headers and body")
        }
        this.maxHeaderBytes = maxHeaderBytes; this.maxBodyBytes = maxBodyBytes
    }

    public func push(bytes: Array<Byte>): Result<?HostHttpExchangeHead> {
        if (failed || head.isSome() || bytes.size > 8192) { return reject("http.exchange_headers_state") }
        for (index in 0..bytes.size) {
            if (totalHeaderBytes >= maxHeaderBytes) { return reject("http.exchange_headers_limit") }
            let byte = bytes[index]
            if ((byte < 32u8 && byte != 9u8 && byte != 10u8 && byte != 13u8) || byte == 127u8) {
                return reject("http.exchange_headers_invalid")
            }
            pending.add(byte); totalHeaderBytes += 1
            let size = pending.size
            if (size >= 4 && pending[size - 4] == 13u8 && pending[size - 3] == 10u8 &&
                pending[size - 2] == 13u8 && pending[size - 1] == 10u8) {
                let parsed = match (parseHead(hostHttpExchangeHeaderText(pending.toArray()))) {
                    case Result.Err(error) => failed = true; pending.clear(); return Result.Err(error)
                    case Result.Ok(value) => value
                }
                pending.clear()
                if (parsed.status < 200) {
                    // Protocol upgrades are not an HTTP exchange response.
                    if (parsed.status == 101 || interimHeads >= 8) { return reject("http.exchange_headers_invalid") }
                    interimHeads += 1
                } else {
                    let remainder = bytes[index + 1..].clone()
                    if (remainder.size > maxBodyBytes ||
                        (parsed.bodySize.isSome() && remainder.size > parsed.bodySize.getOrThrow())) {
                        return reject("http.exchange_body_limit")
                    }
                    head = Some(parsed); prefix = remainder
                    return Result.Ok(head)
                }
            }
        }
        Result.Ok(Option<HostHttpExchangeHead>.None)
    }

    // Transfers only the bytes from the OS read that completed the headers.
    // Further reads and cumulative byte charging belong to the exchange owner.
    public func takeBodyPrefix(): Result<Array<Byte>> {
        if (failed || head.isNone() || taken) {
            return Result.Err(AgentError(AgentErrorKind.Protocol, "http.exchange_headers_state", "HTTP response metadata is unavailable"))
        }
        taken = true
        let result = prefix.clone(); prefix = []
        Result.Ok(result)
    }

    public func endOfStream(): Result<HostHttpExchangeHead> {
        match (head) { case Some(value) => if (!failed) { return Result.Ok(value) }; case None => () }
        failed = true; pending.clear()
        Result.Err(AgentError(AgentErrorKind.Protocol, "http.exchange_headers_incomplete", "HTTP response metadata was incomplete"))
    }

    private func reject<T>(code: String): Result<T> {
        failed = true; pending.clear(); prefix = []
        Result.Err(AgentError(AgentErrorKind.Protocol, code, "HTTP response metadata was rejected"))
    }

    private func parseHead(value: String): Result<HostHttpExchangeHead> {
        try {
            let lines = value.split("\r\n")
            for (line in lines where line.contains("\r") || line.contains("\n")) {
                return reject("http.exchange_headers_invalid")
            }
            let statusLine = lines[0].split(" ")
            if (statusLine.size < 2 || !["HTTP/1.0", "HTTP/1.1", "HTTP/2", "HTTP/3"].contains(statusLine[0]) ||
                statusLine[1].size != 3) { return reject("http.exchange_headers_invalid") }
            for (byte in statusLine[1].toArray() where byte < 48u8 || byte > 57u8) {
                return reject("http.exchange_headers_invalid")
            }
            let status = Int64.parse(statusLine[1])
            if (status < 100 || status > 599 || lines.size > 131) { return reject("http.exchange_headers_invalid") }
            var contentType = ""
            var contentLength: ?Int64 = None
            var hasContentType = false
            var hasRetryAfter = false
            var retryAfter = ""
            var chunked = false
            var hasEncoding = false
            for (index in 1..lines.size - 2) {
                let line = lines[index]
                let colon = match (line.indexOf(":")) {
                    case Some(value) => value
                    case None => return reject("http.exchange_headers_invalid")
                }
                let name = line[..colon]
                if (!hostHttpExchangeHeaderName(name)) { return reject("http.exchange_headers_invalid") }
                let key = name.toAsciiLower()
                let field = line[colon + 1..].trimAscii()
                if (field.contains("\r") || field.contains("\n")) { return reject("http.exchange_headers_invalid") }
                if (key == "content-type") {
                    if (hasContentType || field.size > 1024) { return reject("http.exchange_headers_invalid") }
                    // Projected media metadata is ASCII only. Opaque obs-text
                    // in unselected headers is accepted and never projected.
                    for (byte in field.toArray() where byte > 126u8) { return reject("http.exchange_headers_invalid") }
                    hasContentType = true; contentType = field
                } else if (key == "retry-after") {
                    if (hasRetryAfter || field.size > 1024) { return reject("http.exchange_headers_invalid") }
                    for (byte in field.toArray() where byte < 32u8 || byte > 126u8) { return reject("http.exchange_headers_invalid") }
                    hasRetryAfter = true; retryAfter = field
                } else if (key == "content-length") {
                    if (contentLength.isSome() || field == "" || field.size > 16) { return reject("http.exchange_headers_invalid") }
                    for (byte in field.toArray() where byte < 48u8 || byte > 57u8) { return reject("http.exchange_headers_invalid") }
                    let count = Int64.parse(field)
                    // RFC 9110 section 8.6 permits a 304 length describing
                    // the selected representation, not a transferred body.
                    if (status != 304 && count > maxBodyBytes) { return reject("http.exchange_body_limit") }
                    contentLength = Some(count)
                } else if (key == "transfer-encoding") {
                    if (chunked || field.toAsciiLower() != "chunked") { return reject("http.exchange_headers_invalid") }
                    chunked = true
                } else if (key == "content-encoding") {
                    if (hasEncoding || field.toAsciiLower() != "identity") { return reject("http.exchange_headers_invalid") }
                    hasEncoding = true
                }
            }
            if (chunked && contentLength.isSome()) { return reject("http.exchange_headers_invalid") }
            if (status < 200 || status == 204) {
                if (chunked || contentLength.isSome()) {
                    return reject("http.exchange_headers_invalid")
                }
                contentLength = Some(0)
            } else if (status == 304) {
                if (chunked) { return reject("http.exchange_headers_invalid") }
                contentLength = Some(0)
            }
            Result.Ok(HostHttpExchangeHead(status, contentType, contentLength, retryAfter: retryAfter))
        } catch (_: Exception) { reject("http.exchange_headers_invalid") }
    }
}

// RFC 9110 section 5.5 allows opaque obs-text octets in field values. A
// lossless Latin-1 view permits parsing ASCII names/delimiters without making
// unknown private headers depend on UTF-8 validity or exposing their bytes.
public func hostHttpExchangeHeaderText(bytes: Array<Byte>): String {
    let result = ArrayList<Byte>()
    for (byte in bytes) {
        if (byte < 128u8) { result.add(byte) }
        else { result.add(UInt8(192 + Int64(byte) / 64)); result.add(UInt8(128 + Int64(byte) % 64)) }
    }
    String.fromUtf8(result.toArray())
}

public func hostHttpExchangeHeaderName(value: String): Bool {
    if (value == "" || value.size > 128) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= 48u8 && byte <= 57u8) || (byte >= 65u8 && byte <= 90u8) ||
            (byte >= 97u8 && byte <= 122u8) || "!#$%&'*+-.^_`|~".toArray().contains(byte))) { return false }
    }
    true
}
