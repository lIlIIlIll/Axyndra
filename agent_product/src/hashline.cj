package agent_product

import agent_domain.*
import std.collection.*
import std.convert.*
import std.math.*
import std.overflow.*

class HashlineOperation {
    let start: Int64
    let end: Int64
    let replacement: Array<String>

    init(start: Int64, end: Int64, replacement: Array<String>) {
        this.start = start
        this.end = end
        this.replacement = replacement
    }
}

class ParsedOperation {
    let start: Int64
    let end: Int64
    let bodyRequired: Bool

    init(start: Int64, end: Int64, bodyRequired: Bool) {
        this.start = start
        this.end = end
        this.bodyRequired = bodyRequired
    }
}

class LineRange {
    let start: Int64
    let end: Int64

    init(start: Int64, end: Int64) {
        this.start = start
        this.end = end
    }
}

class HashlineEdit {
    let path: String
    let tag: String
    let operations: Array<HashlineOperation>

    init(
        path: String,
        tag: String,
        operations: Array<HashlineOperation>
    ) {
        this.path = path
        this.tag = tag
        this.operations = operations
    }
}

public func formatHashlineRead(path: String, content: String): String {
    let lines = content.split("\n")
    var result = "[" + path + "#" + hashlineTag(content) + "]"
    for (index in 0..lines.size) {
        result += "\n" + (index + 1).toString() + ":" + lines[index]
    }
    result
}

public func formatHashlineRange(
    path: String,
    fullContent: String,
    selectedContent: String,
    firstLine: Int64
): String {
    let lines = selectedContent.split("\n")
    var result = "[" + path + "#" + hashlineTag(fullContent) + "]"
    for (index in 0..lines.size) {
        result += "\n" + (firstLine + index).toString() +
            ":" + lines[index]
    }
    result
}

public func hashlineTag(content: String): String {
    let value = xxHash32(normalizeHashText(content)) & UInt32(0xffff)
    var encoded = value.toString(radix: 16).toAsciiUpper()
    while (encoded.size < 4) { encoded = "0" + encoded }
    encoded
}

public func applyHashlineEdit(
    input: String,
    currentPath: (String) -> Result<String>
): Result<WorkspaceMutation> {
    let mutations = match (applyHashlineEdits(input, currentPath)) {
        case Result.Ok(values) => values
        case Result.Err(error) => return Result.Err(error)
    }
    if (mutations.size != 1) {
        return hashlineSyntax(
            "single-file edit API received a multi-file patch"
        )
    }
    Result.Ok(mutations[0])
}

public func applyHashlineEdits(
    input: String,
    currentPath: (String) -> Result<String>
): Result<Array<WorkspaceMutation>> {
    let sections = match (splitHashlineSections(input)) {
        case Result.Ok(values) => values
        case Result.Err(error) => return Result.Err(error)
    }
    let mutations = ArrayList<WorkspaceMutation>()
    for (section in sections) {
        let parsed = match (parseHashline(section)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (existing in mutations where existing.path == parsed.path) {
            return hashlineSyntax(
                "multi-file patch repeats path: " + parsed.path
            )
        }
        let mutation = match (prepareHashlineMutation(
            parsed,
            currentPath
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        mutations.add(mutation)
    }
    Result.Ok(mutations.toArray())
}

func prepareHashlineMutation(
    parsed: HashlineEdit,
    currentPath: (String) -> Result<String>
): Result<WorkspaceMutation> {
    let current = match (currentPath(parsed.path)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (hashlineTag(current) != parsed.tag) {
        return Result.Err(AgentError(
            AgentErrorKind.Conflict,
            "edit.stale_anchor",
            "hashline snapshot tag does not match the current file",
            fields: [
                ErrorField("path", parsed.path),
                ErrorField("expected_tag", parsed.tag),
                ErrorField("actual_tag", hashlineTag(current))
            ]
        ))
    }
    let replacement = match (applyOperations(
        current,
        parsed.operations
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    Result.Ok(WorkspaceMutation(
        OperationId("hashline-preflight"),
        parsed.path,
        current,
        replacement
    ))
}

func splitHashlineSections(input: String): Result<Array<String>> {
    let sections = ArrayList<String>()
    var current = ""
    for (line in input.split("\n")) {
        if (line.startsWith("[") && line.endsWith("]")) {
            if (current.trimAscii() != "") {
                sections.add(current)
            }
            current = line
        } else {
            if (current == "") {
                if (line.trimAscii() == "") { continue }
                return hashlineSyntax(
                    "patch content appears before the first [path#TAG]"
                )
            }
            current += "\n" + line
        }
    }
    if (current.trimAscii() != "") { sections.add(current) }
    if (sections.isEmpty()) {
        return hashlineSyntax("patch has no file sections")
    }
    Result.Ok(sections.toArray())
}

func parseHashline(input: String): Result<HashlineEdit> {
    let lines = input.split("\n")
    if (lines.size < 2) { return hashlineSyntax("patch has no operations") }
    let header = lines[0]
    if (!header.startsWith("[") || !header.endsWith("]")) {
        return hashlineSyntax("patch must start with [path#TAG]")
    }
    let bytes = unsafe { header.rawData() }
    let inner = String.fromUtf8(bytes[1..bytes.size - 1])
    let parts = inner.split("#")
    if (parts.size != 2 || parts[0] == "" || parts[1].size != 4) {
        return hashlineSyntax("hashline header is malformed")
    }
    let operations = ArrayList<HashlineOperation>()
    var index: Int64 = 1
    while (index < lines.size) {
        if (lines[index] == "") {
            index += 1
            continue
        }
        let parsed = match (parseOperation(lines[index])) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        index += 1
        let body = ArrayList<String>()
        if (parsed.bodyRequired) {
            while (index < lines.size && lines[index].startsWith("+")) {
                let lineBytes = unsafe { lines[index].rawData() }
                body.add(if (lineBytes.size == 1) {
                    ""
                } else {
                    String.fromUtf8(lineBytes[1..lineBytes.size])
                })
                index += 1
            }
            if (body.size == 0) {
                return hashlineSyntax(
                    "replacement and insertion operations require + body rows"
                )
            }
        }
        operations.add(HashlineOperation(
            parsed.start,
            parsed.end,
            body.toArray()
        ))
    }
    if (operations.size == 0) {
        return hashlineSyntax("patch has no operations")
    }
    Result.Ok(HashlineEdit(
        parts[0],
        parts[1].toAsciiUpper(),
        sortOperations(operations.toArray())
    ))
}

func parseOperation(
    line: String
): Result<ParsedOperation> {
    if (line.startsWith("SWAP ") && line.endsWith(":")) {
        let value = between(line, 5, 1)
        let range = match (parseRange(value)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        return Result.Ok(ParsedOperation(
            range.start,
            range.end,
            true
        ))
    }
    if (line.startsWith("DEL ")) {
        let range = match (parseRange(between(line, 4, 0))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        return Result.Ok(ParsedOperation(
            range.start,
            range.end,
            false
        ))
    }
    if (line == "INS.HEAD:") {
        return Result.Ok(ParsedOperation(1, 0, true))
    }
    if (line == "INS.TAIL:") {
        return Result.Ok(ParsedOperation(
            tailSentinel(),
            tailSentinel() - 1,
            true
        ))
    }
    if (line.startsWith("INS.PRE ") && line.endsWith(":")) {
        let anchor = match (parseLine(between(line, 8, 1))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        return Result.Ok(ParsedOperation(anchor, anchor - 1, true))
    }
    if (line.startsWith("INS.POST ") && line.endsWith(":")) {
        let anchor = match (parseLine(between(line, 9, 1))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        return Result.Ok(ParsedOperation(anchor + 1, anchor, true))
    }
    hashlineSyntax("unsupported hashline operation: " + line)
}

func between(value: String, prefix: Int64, suffix: Int64): String {
    let bytes = unsafe { value.rawData() }
    String.fromUtf8(bytes[prefix..bytes.size - suffix])
}

func parseRange(value: String): Result<LineRange> {
    let parts = value.split("..=")
    if (parts.size == 1) {
        match (parseLine(parts[0])) {
            case Result.Ok(line) => Result.Ok(LineRange(line, line))
            case Result.Err(error) => Result.Err(error)
        }
    } else if (parts.size == 2) {
        let first = match (parseLine(parts[0])) {
            case Result.Ok(line) => line
            case Result.Err(error) => return Result.Err(error)
        }
        let last = match (parseLine(parts[1])) {
            case Result.Ok(line) => line
            case Result.Err(error) => return Result.Err(error)
        }
        if (last < first) {
            hashlineSyntax("hashline range is reversed")
        } else {
            Result.Ok(LineRange(first, last))
        }
    } else {
        hashlineSyntax("hashline range is malformed")
    }
}

func parseLine(value: String): Result<Int64> {
    try {
        let line = Int64.parse(value)
        if (line < 1) {
            hashlineSyntax("hashline line numbers must be positive")
        } else {
            Result.Ok(line)
        }
    } catch (_: Exception) {
        hashlineSyntax("hashline line number is malformed")
    }
}

func applyOperations(
    content: String,
    operations: Array<HashlineOperation>
): Result<String> {
    let lines = content.split("\n")
    let output = ArrayList<String>()
    var cursor: Int64 = 1
    for (operation in operations) {
        let start = if (operation.start == tailSentinel()) {
            lines.size + 1
        } else {
            operation.start
        }
        let end = if (
            operation.end == tailSentinel() - 1
        ) {
            lines.size
        } else {
            operation.end
        }
        if (start < cursor || start > lines.size + 1 ||
            end > lines.size) {
            return hashlineSyntax(
                "hashline operations overlap or address missing lines"
            )
        }
        for (line in cursor..start) {
            output.add(lines[line - 1])
        }
        output.add(all: operation.replacement)
        cursor = if (end >= start) { end + 1 } else { start }
    }
    for (line in cursor..lines.size + 1) {
        output.add(lines[line - 1])
    }
    Result.Ok(joinLines(output.toArray()))
}

func sortOperations(
    values: Array<HashlineOperation>
): Array<HashlineOperation> {
    let result = ArrayList<HashlineOperation>()
    result.add(all: values)
    if (result.size > 1) {
        for (outer in 0..result.size - 1) {
            let _ = outer
            for (index in 0..result.size - 1) {
                if (result[index].start > result[index + 1].start) {
                    let previous = result[index]
                    result[index] = result[index + 1]
                    result[index + 1] = previous
                }
            }
        }
    }
    result.toArray()
}

func joinLines(lines: Array<String>): String {
    var result = ""
    for (index in 0..lines.size) {
        if (index > 0) { result += "\n" }
        result += lines[index]
    }
    result
}

func normalizeHashText(content: String): Array<Byte> {
    let result = ArrayList<Byte>()
    let bytes = unsafe { content.rawData() }
    var pending = ArrayList<Byte>()
    for (byte in bytes) {
        if (byte == b' ' || byte == b'\t' || byte == b'\r') {
            pending.add(byte)
        } else {
            if (byte != b'\n') { result.add(all: pending) }
            pending = ArrayList<Byte>()
            result.add(byte)
        }
    }
    result.toArray()
}

func xxHash32(bytes: Array<Byte>): UInt32 {
    let prime1 = UInt32(2654435761)
    let prime2 = UInt32(2246822519)
    let prime3 = UInt32(3266489917)
    let prime4 = UInt32(668265263)
    let prime5 = UInt32(374761393)
    var index: Int64 = 0
    var hash: UInt32
    if (bytes.size >= 16) {
        var v1 = prime1.wrappingAdd(prime2)
        var v2 = prime2
        var v3 = UInt32(0)
        var v4 = UInt32(0).wrappingSub(prime1)
        while (index <= bytes.size - 16) {
            v1 = xxRound(v1, readUInt32(bytes, index))
            v2 = xxRound(v2, readUInt32(bytes, index + 4))
            v3 = xxRound(v3, readUInt32(bytes, index + 8))
            v4 = xxRound(v4, readUInt32(bytes, index + 12))
            index += 16
        }
        hash = rotate(v1, Int8(1))
        hash = hash.wrappingAdd(rotate(v2, Int8(7)))
        hash = hash.wrappingAdd(rotate(v3, Int8(12)))
        hash = hash.wrappingAdd(rotate(v4, Int8(18)))
    } else {
        hash = prime5
    }
    hash = hash.wrappingAdd(UInt32(bytes.size))
    while (index <= bytes.size - 4) {
        let word = readUInt32(bytes, index)
        hash = hash.wrappingAdd(word.wrappingMul(prime3))
        hash = rotate(hash, Int8(17)).wrappingMul(prime4)
        index += 4
    }
    while (index < bytes.size) {
        let byte = UInt32(bytes[index])
        hash = hash.wrappingAdd(byte.wrappingMul(prime5))
        hash = rotate(hash, Int8(11)).wrappingMul(prime1)
        index += 1
    }
    hash = hash ^ (hash >> 15)
    hash = hash.wrappingMul(prime2)
    hash = hash ^ (hash >> 13)
    hash = hash.wrappingMul(prime3)
    hash ^ (hash >> 16)
}

func xxRound(accumulator: UInt32, input: UInt32): UInt32 {
    let multiplied = input.wrappingMul(UInt32(2246822519))
    let added = accumulator.wrappingAdd(multiplied)
    rotate(added, Int8(13)).wrappingMul(UInt32(2654435761))
}

func readUInt32(bytes: Array<Byte>, index: Int64): UInt32 {
    let first = UInt32(bytes[index])
    let second = UInt32(bytes[index + 1]) << 8
    let third = UInt32(bytes[index + 2]) << 16
    let fourth = UInt32(bytes[index + 3]) << 24
    first | second | third | fourth
}

func hashlineSyntax<T>(message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "edit.invalid_hashline",
        message + "; expected [path#TAG] followed by SWAP N or SWAP N..=M plus + rows, " +
            "DEL N or DEL N..=M, or INS.HEAD/INS.TAIL/INS.PRE N/INS.POST N plus + rows"
    ))
}

func tailSentinel(): Int64 { 9000000000000000000 }
