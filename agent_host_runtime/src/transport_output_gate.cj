package agent_host_runtime

import agent_domain.*
import std.collection.*

public let HOST_LIFECYCLE_TRANSPORT_OUTPUT_BYTES: Int64 = 134217728

// KMP state plus source offsets. Decoded bytes retain their raw source offset,
// so an incomplete credential prefix is withheld before *any* of its bytes
// cross IPC. A completed harmless SSE frame need not wait for HTTP EOF.
class HostOutputSecretMatcher {
    private let pattern: Array<Byte>
    private let fallback: Array<Int64>
    private let positions: Array<Int64>
    private var cursor: Int64 = 0
    private var matched: Int64 = 0
    init(pattern: Array<Byte>) {
        if (pattern.isEmpty()) { throw IllegalArgumentException("empty output pattern") }
        this.pattern = pattern.clone()
        fallback = Array<Int64>(pattern.size, repeat: 0)
        positions = Array<Int64>(pattern.size, repeat: 0)
        var count: Int64 = 0
        for (index in 1..pattern.size) {
            while (count > 0 && pattern[index] != pattern[count]) { count = fallback[count - 1] }
            if (pattern[index] == pattern[count]) { count += 1 }
            fallback[index] = count
        }
    }
    func push(byte: Byte, source: Int64): Bool {
        positions[cursor % pattern.size] = source; cursor += 1
        while (matched > 0 && pattern[matched] != byte) { matched = fallback[matched - 1] }
        if (pattern[matched] == byte) { matched += 1 }
        if (matched == pattern.size) { matched = fallback[matched - 1]; return true }
        false
    }
    func earliest(limit: Int64): Int64 {
        if (matched == 0) { limit } else { positions[(cursor - matched) % pattern.size] }
    }
}

public class HostOutputByte {
    public let value: Byte
    public let source: Int64
    public init(value: Byte, source: Int64) { this.value = value; this.source = source }
}

// Conservative textual normalization, not a JSON parser or an instruction
// interpreter. Supports mixed literal/escaped JSON and mixed-case %HH forms.
// Arbitrary encodings by the credential recipient are outside this boundary.
public class HostOutputDecoder {
    private let json: Bool
    private let pending = ArrayList<HostOutputByte>()
    public init(json: Bool) { this.json = json }
    public func earliest(limit: Int64): Int64 { if (pending.isEmpty()) { limit } else { pending[0].source } }
    // With no partial escape, an ordinary byte normalizes to itself at its
    // original offset. The gate can feed that byte directly to the same KMP
    // matchers without allocating a byte object, list and returned array.
    // Every escape marker and every byte after a pending marker uses drain.
    public func mayPassLiteral(byte: Byte): Bool {
        let marker: Byte = if (json) { 92u8 } else { 37u8 }
        pending.isEmpty() && byte != marker
    }
    public func push(byte: Byte, source: Int64): Array<HostOutputByte> {
        pending.add(HostOutputByte(byte, source)); drain(false)
    }
    public func finish(): Array<HostOutputByte> { drain(true) }
    private func drain(eof: Bool): Array<HostOutputByte> {
        let result = ArrayList<HostOutputByte>()
        while (!pending.isEmpty()) {
            let start = pending[0].source
            let first = pending[0].value
            var consumed: Int64 = 1
            var scalar: Int64 = -1
            if (!json && first == 37u8) {
                if (pending.size < 3 && !eof) { break }
                if (pending.size >= 3) {
                    let high = hostOutputHex(pending[1].value); let low = hostOutputHex(pending[2].value)
                    if (high >= 0 && low >= 0) { scalar = high * 16 + low; consumed = 3 }
                }
            } else if (json && first == 92u8) {
                if (pending.size < 2 && !eof) { break }
                if (pending.size >= 2) {
                    let escaped = pending[1].value
                    if (escaped == 117u8) {
                        if (pending.size < 6 && !eof) { break }
                        if (pending.size >= 6) {
                            let code = unicodeAt(2)
                            if (code >= 0 && !(code >= 55296 && code <= 57343)) {
                                scalar = code; consumed = 6
                            } else if (code >= 55296 && code <= 56319) {
                                if (pending.size < 12 && !eof) { break }
                                if (pending.size >= 12 && pending[6].value == 92u8 && pending[7].value == 117u8) {
                                    let low = unicodeAt(8)
                                    if (low >= 56320 && low <= 57343) {
                                        scalar = 65536 + (code - 55296) * 1024 + low - 56320; consumed = 12
                                    }
                                }
                            }
                        }
                    } else {
                        scalar = match (escaped) {
                            case 34u8 => 34
                            case 92u8 => 92
                            case 47u8 => 47
                            case 98u8 => 8
                            case 102u8 => 12
                            case 110u8 => 10
                            case 114u8 => 13
                            case 116u8 => 9
                            case _ => -1
                        }
                        if (scalar >= 0) { consumed = 2 }
                    }
                }
            }
            if (scalar < 0) { result.add(pending[0]) }
            else if (!json) { result.add(HostOutputByte(UInt8(scalar), start)) }
            else { for (value in hostOutputUtf8(scalar)) { result.add(HostOutputByte(value, start)) } }
            for (_ in 0..consumed) { pending.remove(at: 0) }
        }
        result.toArray()
    }
    private func unicodeAt(offset: Int64): Int64 {
        var value: Int64 = 0
        for (index in offset..offset + 4) {
            let digit = hostOutputHex(pending[index].value)
            if (digit < 0) { return -1 }
            value = value * 16 + digit
        }
        value
    }
}

public func hostOutputHex(value: Byte): Int64 {
    if (value >= 48u8 && value <= 57u8) { return Int64(value - 48u8) }
    if (value >= 65u8 && value <= 70u8) { return Int64(value - 65u8) + 10 }
    if (value >= 97u8 && value <= 102u8) { return Int64(value - 97u8) + 10 }
    -1
}

public func hostOutputUtf8(value: Int64): Array<Byte> {
    if (value < 128) { return [UInt8(value)] }
    if (value < 2048) { return [UInt8(192 + value / 64), UInt8(128 + value % 64)] }
    if (value < 65536) {
        return [UInt8(224 + value / 4096), UInt8(128 + (value / 64) % 64), UInt8(128 + value % 64)]
    }
    [UInt8(240 + value / 262144), UInt8(128 + (value / 4096) % 64),
        UInt8(128 + (value / 64) % 64), UInt8(128 + value % 64)]
}

// Single-consumer, host-private response filter. Its owner serializes reads,
// charges wire headers/stderr separately, and cancels/closes the exchange on
// failure. This object never grants IO or completes an Operation/Receipt.
public class HostTransportOutputGate {
    private let maxBytes: Int64
    private let raw = ArrayList<HostOutputSecretMatcher>()
    private let json = ArrayList<HostOutputSecretMatcher>()
    private let percent = ArrayList<HostOutputSecretMatcher>()
    private let jsonDecoder = HostOutputDecoder(true)
    private let percentDecoder = HostOutputDecoder(false)
    private var pending: Array<Byte> = []
    private var received: Int64 = 0
    private var released: Int64 = 0
    private var closed = false
    private var failed = false
    public init(secrets: Array<String>, maxBytes!: Int64 = 1048576,
        transportMaximum!: Int64 = 16777216) {
        if (secrets.size > 4 || transportMaximum < 1 || transportMaximum > HOST_LIFECYCLE_TRANSPORT_OUTPUT_BYTES ||
            maxBytes < 1 || maxBytes > transportMaximum) {
            throw IllegalArgumentException("HTTP output requires finite byte and credential limits")
        }
        this.maxBytes = maxBytes
        for (secret in secrets) {
            if (secret == "" || secret.size > 8192) { throw IllegalArgumentException("invalid HTTP output credential") }
            raw.add(HostOutputSecretMatcher(secret.toArray()))
            raw.add(HostOutputSecretMatcher(hostBase64Bytes(secret.toArray()).toArray()))
            json.add(HostOutputSecretMatcher(secret.toArray()))
            percent.add(HostOutputSecretMatcher(secret.toArray()))
        }
        if (!secrets.isEmpty()) { raw.add(HostOutputSecretMatcher("[REDACTED]".toArray())) }
    }

    public func push(bytes: Array<Byte>, eof!: Bool = false): Result<Array<Byte>> {
        if (closed || failed || bytes.size > 8192 || bytes.size > maxBytes - received) {
            return reject()
        }
        let all = ArrayList<Byte>(); all.add(all: pending); all.add(all: bytes)
        pending = all.toArray()
        for (byte in bytes) {
            let source = received; received += 1
            for (matcher in raw where matcher.push(byte, source)) { return reject() }
            if (!json.isEmpty()) {
                if (jsonDecoder.mayPassLiteral(byte)) {
                    for (matcher in json where matcher.push(byte, source)) { return reject() }
                } else {
                    for (value in jsonDecoder.push(byte, source)) {
                        for (matcher in json where matcher.push(value.value, value.source)) { return reject() }
                    }
                }
                if (percentDecoder.mayPassLiteral(byte)) {
                    for (matcher in percent where matcher.push(byte, source)) { return reject() }
                } else {
                    for (value in percentDecoder.push(byte, source)) {
                        for (matcher in percent where matcher.push(value.value, value.source)) { return reject() }
                    }
                }
            }
        }
        if (eof && !json.isEmpty()) {
            for (value in jsonDecoder.finish()) {
                for (matcher in json where matcher.push(value.value, value.source)) { return reject() }
            }
            for (value in percentDecoder.finish()) {
                for (matcher in percent where matcher.push(value.value, value.source)) { return reject() }
            }
        }
        var safe = received
        if (!eof) {
            for (matcher in raw) { safe = min(safe, matcher.earliest(received)) }
            for (matcher in json) { safe = min(safe, matcher.earliest(received)) }
            for (matcher in percent) { safe = min(safe, matcher.earliest(received)) }
            if (!json.isEmpty()) {
                safe = min(safe, jsonDecoder.earliest(received))
                safe = min(safe, percentDecoder.earliest(received))
            }
        }
        let count = safe - released
        if (count < 0 || count > pending.size || pending.size > 57356) { return reject() }
        let output = pending[..count].clone()
        pending = pending[count..].clone(); released = safe
        if (eof) { closed = true }
        Result.Ok(output)
    }

    private func reject(): Result<Array<Byte>> {
        failed = true; pending = []
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "http.exchange_output_withheld",
            "HTTP response was withheld by the host output boundary", retryable: false, fallbackAllowed: false))
    }
}
