package agent_embed

import agent_domain.*
import yjson.*

// Complete compact JSON with the same ordered default redaction passes as
// defaultJsonTextRedaction. Readers hold fixed lookahead, never a complete
// transformed scalar, an edit list, or a copied object-field array.
// The caller pays the fixed reader graph and 256 traversal frames in the
// actual original owner's ledger BEFORE entry and keeps it through IO ACK.
public func writeOwnedRedactedAgentValue(value: JsonValueView,
    write: (String) -> Result<Unit>, guard: () -> Result<Unit>): Result<Unit> {
    let output = OwnedRedactedValueOutput(write, guard, true)
    try {
        output.node(value, 0)
        output.finish()
        Result.Ok(())
    } catch (error: OwnedRedactionIoFailure) { Result.Err(error.error) }
    finally { output.clear() }
}

// The RPC protocol deliberately preserves raw event details. It uses the
// same fixed complete writer, without importing the display redaction policy.
public func writeOwnedUnredactedAgentValue(value: JsonValueView,
    write: (String) -> Result<Unit>, guard: () -> Result<Unit>): Result<Unit> {
    let output = OwnedRedactedValueOutput(write, guard, false)
    try {
        output.node(value, 0); output.finish(); Result.Ok(())
    } catch (error: OwnedRedactionIoFailure) { Result.Err(error.error) }
    finally { output.clear() }
}

private class OwnedRedactionIoFailure <: Exception {
    let error: AgentError
    init(error: AgentError) { super(error.message); this.error = error }
}

private interface OwnedRedactionBytes {
    func next(): ?Byte
    func reset(): Unit
    func clear(): Unit
}

private class OwnedRedactionSource <: OwnedRedactionBytes {
    private var value: ?String
    private var guard: ?(() -> Result<Unit>)
    private var position: Int64 = 0
    init(value: String, guard: () -> Result<Unit>) {
        this.value = Some(value); this.guard = Some(guard)
    }
    public func next(): ?Byte {
        if (position % 4096 == 0) {
            match (guard.getOrThrow()()) {
                case Result.Err(error) => throw OwnedRedactionIoFailure(error)
                case Result.Ok(_) => () }
        }
        if (position == value.getOrThrow().size) { return None }
        let byte = value.getOrThrow()[position]; position++
        Some(byte)
    }
    public func reset(): Unit { position = 0 }
    public func clear(): Unit { value = None; guard = None; position = 0 }
}

// kind: 0 JSON field, 1 line header, 2 assignment, 3 prefixed secret,
// 4 PEM. Replacements enter the next pass, exactly as in the old pipeline.
private class OwnedRedactionRule <: OwnedRedactionBytes {
    private var source: ?OwnedRedactionBytes
    private let kind: Int64
    private let marker: String
    private let buffer = Array<Byte>(64, repeat: 0)
    private var used: Int64 = 0
    private var eof = false
    private var state: Int64 = 0
    private var quoted = false
    private var pending = ""
    private var pendingIndex: Int64 = 0
    init(source: OwnedRedactionBytes, kind: Int64, marker: String) {
        this.source = Some(source); this.kind = kind; this.marker = marker
    }
    private func peek(index: Int64): ?Byte {
        if (index < 0 || index >= buffer.size) { throw IllegalStateException("fixed redactor lookahead") }
        while (used <= index && !eof) {
            match (source.getOrThrow().next()) {
                case Some(value) => buffer[used] = value; used++
                case None => eof = true }
        }
        if (index < used) { Some(buffer[index]) } else { None }
    }
    private func take(): ?Byte {
        let result = peek(0)
        if (result.isSome()) {
            for (index in 1..used) { buffer[index - 1] = buffer[index] }
            used--
        }
        result
    }
    private func matches(value: String): Bool {
        for (index in 0..value.size) {
            match (peek(index)) { case Some(byte) => if (byte != value[index]) { return false }
                case None => return false }
        }
        true
    }
    private func skip(count: Int64): Unit { for (_ in 0..count) { let _ = take() } }
    private func replacement(value: String): Unit { pending = value; pendingIndex = 0 }
    public func next(): ?Byte {
        while (true) {
            if (pendingIndex < pending.size) {
                let result = pending[pendingIndex]; pendingIndex++
                return Some(result)
            }
            pending = ""; pendingIndex = 0
            if (state == 0) {
                if (!matches(marker)) { return take() }
                if (kind == 3) {
                    // At most three bytes after the prefix must be held to
                    // preserve a short token. A fourth non-delimiter byte is
                    // sufficient to discard the COMPLETE remaining token.
                    var count = marker.size
                    while (count < marker.size + 4) {
                        match (peek(count)) {
                            case Some(value) => if (ownedRedactionDelimiter(value)) { break }
                                else { count++ }
                            case None => break }
                    }
                    if (count < marker.size + 4) {
                        let short = Array<Byte>(count, repeat: 0)
                        for (index in 0..count) { short[index] = take().getOrThrow() }
                        replacement(String.fromUtf8(short)); continue
                    }
                    skip(marker.size); state = 4
                    replacement("[REDACTED]"); continue
                }
                skip(marker.size)
                if (kind == 4) {
                    state = 5; replacement("[REDACTED PRIVATE KEY]")
                } else {
                    state = if (kind == 0) { 1 } else { 4 }
                    replacement(marker)
                }
                continue
            }
            if (state == 1) {
                let result = take()
                if (result.isSome() && result.getOrThrow() == b':') { state = 2 }
                return result
            }
            if (state == 2) {
                match (peek(0)) {
                    case None => return None
                    case Some(value) => if (value == b' ' || value == b'\t') { return take() }
                        else if (value == b'"') { quoted = true; state = 3; return take() }
                        else { quoted = false; state = 3 }
                }
                continue
            }
            if (state == 3) {
                if (matches("[REDACTED]")) {
                    skip(10); state = 0; replacement("[REDACTED]"); continue
                }
                while (true) {
                    match (peek(0)) {
                        case None => break
                        case Some(value) =>
                            if (quoted && value == b'"') { break }
                            if (!quoted && (value == b',' || value == b'}')) { break }
                            let _ = take()
                            if (quoted && value == b'\\' && take().isNone()) {
                                // The old quoted scan advances two bytes and
                                // then slices beyond EOF on a trailing slash.
                                // Do not silently turn that error into output.
                                throw IllegalStateException("quoted redaction escape past EOF") }
                    }
                }
                state = 0; replacement("[REDACTED]"); continue
            }
            if (state == 4) {
                while (true) {
                    match (peek(0)) {
                        case None => break
                        case Some(value) =>
                            if ((kind == 1 && (value == b'\n' || value == b'\r')) ||
                                (kind != 1 && ownedRedactionDelimiter(value))) { break }
                            let _ = take()
                    }
                }
                state = 0
                if (kind == 1) { replacement(" [REDACTED]") }
                else if (kind == 2) { replacement("[REDACTED]") }
                continue
            }
            if (state == 5) {
                while (!matches("-----END ")) {
                    if (take().isNone()) { state = 0; return None }
                }
                skip(9); state = 6; continue
            }
            if (state == 6) {
                while (!matches("-----")) {
                    if (take().isNone()) { state = 0; return None }
                }
                skip(5); state = 0
            }
        }
        None
    }
    public func reset(): Unit {
        source.getOrThrow().reset(); used = 0; eof = false; state = 0
        pending = ""; pendingIndex = 0; quoted = false
    }
    public func clear(): Unit {
        match (source) { case Some(value) => value.clear(); case None => () }
        source = None; used = 0; pending = ""; pendingIndex = 0
    }
}

private func ownedRedactionDelimiter(value: Byte): Bool {
    value == b' ' || value == b'\t' || value == b'\n' || value == b'\r' ||
        value == b'"' || value == b'\'' || value == b',' || value == b'}' ||
        value == b']' || value == b'&'
}

// The legacy URL rule considers only the FIRST scheme and FIRST subsequent
// @. A full scan followed by reset preserves its no-colon/no-@ behavior
// without retaining an arbitrarily long candidate authority String.
private class OwnedRedactionUrl <: OwnedRedactionBytes {
    private var source: ?OwnedRedactionBytes
    private var start: Int64 = -1
    private var end: Int64 = -1
    private var position: Int64 = 0
    private var replacementIndex: Int64 = -1
    init(source: OwnedRedactionBytes) {
        this.source = Some(source)
    }
    func initialize(): Unit {
        let source = this.source.getOrThrow()
        var offset: Int64 = 0
        var matched: Int64 = 0
        var colon = false
        while (true) {
            let value = match (source.next()) { case Some(value) => value; case None => break }
            if (start < 0) {
                let pattern = "://"
                if (value == pattern[matched]) { matched++ }
                else { matched = if (value == b':') { 1 } else { 0 } }
                if (matched == 3) { start = offset + 1 }
            } else {
                if (value == b'@') {
                    if (colon) { end = offset } else { start = -1 }
                    break
                }
                if (value == b':') { colon = true }
            }
            if (offset == Int64.Max) { throw IllegalStateException("redacted scalar extent overflow") }
            offset++
        }
        if (end < 0) { start = -1 }
        source.reset()
    }
    public func next(): ?Byte {
        if (start >= 0 && position == start && replacementIndex < 0) {
            while (position < end) { let _ = source.getOrThrow().next(); position++ }
            replacementIndex = 0
        }
        let replacement = "[REDACTED]"
        if (replacementIndex >= 0 && replacementIndex < replacement.size) {
            let result = replacement[replacementIndex]; replacementIndex++
            return Some(result)
        }
        let result = source.getOrThrow().next()
        if (result.isSome()) { position++ }
        result
    }
    public func reset(): Unit { source.getOrThrow().reset(); position = 0; replacementIndex = -1 }
    public func clear(): Unit {
        match (source) { case Some(value) => value.clear(); case None => () }
        source = None; position = 0
    }
}

private func ownedRedactionPipeline(value: String, guard: () -> Result<Unit>): OwnedRedactionBytes {
    var result: OwnedRedactionBytes = OwnedRedactionSource(value, guard)
    try {
    for (key in ["api_key", "apiKey", "x-api-key", "token", "access_token", "refresh_token",
        "authorization", "cookie", "set-cookie", "password", "secret", "private_key",
        "credential", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]) {
        result = OwnedRedactionRule(result, 0, "\"" + key + "\"") }
    for (marker in ["Authorization:", "authorization:", "X-Api-Key:", "x-api-key:",
        "Cookie:", "cookie:", "Set-Cookie:", "set-cookie:"]) {
        result = OwnedRedactionRule(result, 1, marker) }
    for (prefix in ["Authorization: Bearer ", "authorization: bearer ", "api_key=", "API_KEY=",
        "apiKey=", "access_token=", "refresh_token=", "password=", "secret=", "token=", "cookie=",
        "X-Api-Key: ", "x-api-key: ", "AWS_ACCESS_KEY_ID=", "AWS_SECRET_ACCESS_KEY="]) {
        result = OwnedRedactionRule(result, 2, prefix) }
    for (prefix in ["sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-"]) {
        result = OwnedRedactionRule(result, 3, prefix) }
    result = OwnedRedactionRule(result, 4, "-----BEGIN ")
    let url = OwnedRedactionUrl(result)
    result = url
    url.initialize()
    result
    } catch (error: Exception) {
        result.clear()
        throw error
    }
}

private func ownedMayNeedRedaction(value: String): Bool {
    // String.indexOf returns only a scalar offset; it does not create an
    // escaped String or a tail slice. The no-marker path is exactly identity.
    for (marker in ["\"api_key\"", "\"apiKey\"", "\"x-api-key\"", "\"token\"", "\"access_token\"",
        "\"refresh_token\"", "\"authorization\"", "\"cookie\"", "\"set-cookie\"", "\"password\"",
        "\"secret\"", "\"private_key\"", "\"credential\"", "\"AWS_ACCESS_KEY_ID\"", "\"AWS_SECRET_ACCESS_KEY\"",
        "Authorization:", "authorization:", "X-Api-Key:", "x-api-key:", "Cookie:", "cookie:",
        "Set-Cookie:", "set-cookie:", "api_key=", "API_KEY=", "apiKey=", "access_token=", "refresh_token=",
        "password=", "secret=", "token=", "cookie=", "AWS_ACCESS_KEY_ID=", "AWS_SECRET_ACCESS_KEY=",
        "sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-", "-----BEGIN ", "://"]) {
        if (value.indexOf(marker).isSome()) { return true }
    }
    false
}

// Equivalent to jsonSensitiveFieldName's lowercase/hyphen/underscore passes,
// including the compact-name token suffix, without allocating full name copies.
private func ownedSensitiveFieldName(value: String): Bool {
    for (needle in ["api_key", "authorization", "cookie", "password", "secret",
        "private_key", "credential", "passwd"]) {
        if (ownedNameContains(value, needle, false)) { return true } }
    if (ownedNameContains(value, "apikey", true) || ownedNameContains(value, "privatekey", true)) { return true }
    let suffix = "token"
    var matched: Int64 = 0
    for (index in 0..value.size) {
        var byte = value[index]
        if (byte >= b'A' && byte <= b'Z') { byte += 32 }
        if (byte == b'_' || byte == b'-') { continue }
        if (byte == suffix[matched]) { matched++ }
        else { matched = if (byte == suffix[0]) { 1 } else { 0 } }
        if (matched == suffix.size && index + 1 < value.size) {
            var remainder = index + 1
            while (remainder < value.size && (value[remainder] == b'_' || value[remainder] == b'-')) { remainder++ }
            if (remainder == value.size) { return true }
            matched = 0
        }
    }
    matched == suffix.size
}

private func ownedNameContains(value: String, needle: String, compact: Bool): Bool {
    // Each candidate advances through original bytes. At most needle.size
    // comparisons per byte; the name itself remains in the original row.
    for (start in 0..value.size) {
        if (compact && (value[start] == b'_' || value[start] == b'-')) { continue }
        var offset = start
        var matched: Int64 = 0
        while (offset < value.size && matched < needle.size) {
            var byte = value[offset]; offset++
            if (byte >= b'A' && byte <= b'Z') { byte += 32 }
            if (byte == b'-') { byte = b'_' }
            if (compact && byte == b'_') { continue }
            if (byte != needle[matched]) { break }
            matched++
        }
        if (matched == needle.size) { return true }
    }
    false
}

private class OwnedRedactedValueOutput {
    private let buffer = Array<Byte>(16384, repeat: 0)
    private var used: Int64 = 0
    private var write: ?((String) -> Result<Unit>)
    private var guard: ?(() -> Result<Unit>)
    private let redact: Bool
    init(write: (String) -> Result<Unit>, guard: () -> Result<Unit>, redact: Bool) {
        this.write = Some(write); this.guard = Some(guard)
        this.redact = redact
    }
    private func check(): Unit {
        match (guard.getOrThrow()()) { case Result.Err(error) => throw OwnedRedactionIoFailure(error)
            case Result.Ok(_) => () }
    }
    private func flush(): Unit {
        check()
        if (used == 0) { return }
        var frame: ?String = Some(String.fromUtf8(buffer[..used]))
        try {
            match (write.getOrThrow()(frame.getOrThrow())) {
                case Result.Err(error) => throw OwnedRedactionIoFailure(error)
                case Result.Ok(_) => used = 0 }
        } finally { frame = None }
    }
    private func append(value: Byte): Unit {
        if (used == buffer.size) { flush() }
        buffer[used] = value; used++
    }
    private func literal(value: String): Unit {
        let raw = unsafe { value.rawData() }
        var offset: Int64 = 0
        while (offset < raw.size) {
            let extent: Int64 = if (raw[offset] < 128) { 1 } else if (raw[offset] < 224) { 2 }
                else if (raw[offset] < 240) { 3 } else { 4 }
            if (extent > raw.size - offset) { throw IllegalStateException("invalid JSON UTF8") }
            if (extent > buffer.size - used) { flush() }
            for (index in 0..extent) { append(raw[offset + index]) }
            offset += extent
        }
    }
    private func quoted(source: OwnedRedactionBytes): Unit {
        append(b'"')
        while (true) {
            let first = match (source.next()) { case Some(value) => value; case None => break }
            let escaped = match (first) { case 34 => "\\\""; case 92 => "\\\\"; case 8 => "\\b";
                case 9 => "\\t"; case 10 => "\\n"; case 12 => "\\f"; case 13 => "\\r"; case _ => "" }
            if (escaped != "") { literal(escaped); continue }
            if (first < 32) {
                literal("\\u00"); let hex = "0123456789abcdef"
                append(hex[Int64(first >> 4)]); append(hex[Int64(first & 15)]); continue
            }
            let extent: Int64 = if (first < 128) { 1 } else if (first < 224) { 2 }
                else if (first < 240) { 3 } else { 4 }
            if (extent > buffer.size - used) { flush() }
            append(first)
            for (_ in 1..extent) {
                match (source.next()) { case Some(value) => append(value)
                    case None => throw IllegalStateException("invalid redacted UTF8") }
            }
        }
        append(b'"')
    }
    private func plainQuoted(value: String): Unit {
        let source = OwnedRedactionSource(value, guard.getOrThrow())
        try { quoted(source) } finally { source.clear() }
    }
    func node(value: JsonValueView, depth: Int64): Unit {
        let kind = value.kind()
        let container = kind == JsonKind.Array || kind == JsonKind.Object
        if (depth > 256 || (container && depth >= 256)) { throw IllegalStateException("JSON depth limit") }
        check()
        match (kind) {
            case JsonKind.Null => literal("null")
            case JsonKind.Boolean => literal(if (value.asBool()) { "true" } else { "false" })
            case JsonKind.Number => literal(value.asNumberText())
            case JsonKind.String =>
                if (!redact || !ownedMayNeedRedaction(value.asString())) { plainQuoted(value.asString()); return }
                var source: ?OwnedRedactionBytes = None
                try {
                    source = Some(ownedRedactionPipeline(value.asString(), guard.getOrThrow()))
                    quoted(source.getOrThrow())
                } finally {
                    match (source) { case Some(selected) => selected.clear(); case None => () }
                    source = None
                }
            case JsonKind.Array =>
                append(b'[')
                for (index in 0..value.size()) {
                    if (index > 0) { append(b',') }
                    node(value.element(index).getOrThrow(), depth + 1)
                }
                append(b']')
            case JsonKind.Object =>
                append(b'{')
                for (index in 0..value.size()) {
                    if (index > 0) { append(b',') }
                    let name = value.memberName(index)
                    plainQuoted(name); append(b':')
                    if (redact && ownedSensitiveFieldName(name)) { plainQuoted("[REDACTED]") }
                    else { node(value.memberValue(index), depth + 1) }
                }
                append(b'}')
        }
    }
    func finish(): Unit { flush() }
    func clear(): Unit { used = 0; write = None; guard = None }
}
