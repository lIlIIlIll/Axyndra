package agent_runtime

import agent_domain.*
import std.sync.*
import yjson.*
import yjson_support.*

// The caller prepays the fixed buffer, traversal and any redaction copies in
// the actual row's alias before calling this. Complete escaped scalar output
// is emitted in fixed UTF8-aligned chunks, without an escaped-scalar array or
// complete encoded String. The original compact JSON field order is kept.
public func writeOwnedAgentValue(value: AgentValue, write: (String) -> Result<Unit>,
    guard: () -> Result<Unit>): Result<Unit> {
    let stream = OwnedAgentValueStream(write, guard)
    try {
        match (stream.node(value, 0)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => stream.finish() }
    } finally { stream.clear() }
}

private class OwnedAgentValueStream {
    private let buffer = Array<Byte>(16384, repeat: 0)
    private var used: Int64 = 0
    private var write: ?((String) -> Result<Unit>)
    private var guard: ?(() -> Result<Unit>)
    init(write: (String) -> Result<Unit>, guard: () -> Result<Unit>) {
        this.write = Some(write); this.guard = Some(guard)
    }
    private func flush(): Result<Unit> {
        match (guard.getOrThrow()()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => () }
        if (used == 0) { return Result.Ok(()) }
        // Every append keeps a complete UTF8 scalar in the same chunk.
        var frame: ?String = Some(String.fromUtf8(buffer[..used]))
        try {
            match (write.getOrThrow()(frame.getOrThrow())) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => used = 0; Result.Ok(()) }
        } finally { frame = None }
    }
    private func room(bytes: Int64): Result<Unit> {
        if (bytes > buffer.size - used) { return flush() }
        Result.Ok(())
    }
    private func byte(value: Byte): Result<Unit> {
        match (room(1)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        buffer[used] = value; used++; Result.Ok(())
    }
    private func literal(value: String): Result<Unit> {
        let raw = unsafe { value.rawData() }
        var offset: Int64 = 0
        while (offset < raw.size) {
            let first = raw[offset]
            let extent: Int64 = if (first < 128) { 1 } else if (first < 224) { 2 }
                else if (first < 240) { 3 } else { 4 }
            if (extent > raw.size - offset) { return ownedCanonicalDataError("event.json_utf8_invalid") }
            match (room(extent)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            for (index in 0..extent) { buffer[used] = raw[offset + index]; used++ }
            offset += extent
        }
        Result.Ok(())
    }
    private func quoted(value: String): Result<Unit> {
        match (byte(b'"')) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let raw = unsafe { value.rawData() }
        let hex = "0123456789abcdef"
        var offset: Int64 = 0
        while (offset < raw.size) {
            let first = raw[offset]
            let escape = match (first) {
                case 34 => "\\\""
                case 92 => "\\\\"
                case 8 => "\\b"
                case 9 => "\\t"
                case 10 => "\\n"
                case 12 => "\\f"
                case 13 => "\\r"
                case _ => "" }
            if (escape != "") {
                match (literal(escape)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                offset++; continue
            }
            if (first < 32) {
                match (literal("\\u00")) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                match (byte(hex[Int64(first >> 4)])) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                match (byte(hex[Int64(first & 15)])) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                offset++; continue
            }
            let extent: Int64 = if (first < 128) { 1 } else if (first < 224) { 2 }
                else if (first < 240) { 3 } else { 4 }
            if (extent > raw.size - offset) { return ownedCanonicalDataError("event.json_utf8_invalid") }
            match (room(extent)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            for (index in 0..extent) { buffer[used] = raw[offset + index]; used++ }
            offset += extent
        }
        byte(b'"')
    }
    func node(value: AgentValue, depth: Int64): Result<Unit> {
        // Same depth as the pinned compact writer's default. No history,
        // message-count or aggregate encoded-output ceiling is introduced.
        let container = value.unifiedKind == ValueKind.List || value.unifiedKind == ValueKind.Object
        if (depth > 256 || (container && depth >= 256)) {
            return ownedCanonicalDataError("event.json_depth_invalid") }
        match (value.unifiedKind) {
            case ValueKind.Null => literal("null")
            case ValueKind.Boolean => literal(if (value.asBool()) { "true" } else { "false" })
            case ValueKind.Number => literal(value.asNumberText())
            case ValueKind.Text => quoted(value.text)
            case ValueKind.List =>
                match (byte(b'[')) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                var first = true
                for (item in value.items) {
                    if (!first) { match (byte(b',')) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () } }
                    first = false
                    match (node(item, depth + 1)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                }
                byte(b']')
            case ValueKind.Object =>
                match (byte(b'{')) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                var first = true
                for (field in value.fields) {
                    if (!first) { match (byte(b',')) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () } }
                    first = false
                    match (quoted(field.name)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    match (byte(b':')) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    match (node(field.value, depth + 1)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                }
                byte(b'}')
        }
    }
    func finish(): Result<Unit> { flush() }
    func clear(): Unit { used = 0; write = None; guard = None }
}
