package json4cj

import std.collection.*

public enum JsonKind <: Equatable<JsonKind> {
    Null | Boolean | Number | Text | List | Object

    public operator func ==(other: JsonKind): Bool {
        match (this) {
            case Null => if (let Null <- other) { true } else { false }
            case Boolean => if (let Boolean <- other) { true } else { false }
            case Number => if (let Number <- other) { true } else { false }
            case Text => if (let Text <- other) { true } else { false }
            case List => if (let List <- other) { true } else { false }
            case Object => if (let Object <- other) { true } else { false }
        }
    }

    public operator func !=(other: JsonKind): Bool { !(this == other) }
}

public enum JsonErrorKind <: Equatable<JsonErrorKind> {
    InvalidSyntax | ResourceLimit | InvalidValue | EncodingLimit

    public operator func ==(other: JsonErrorKind): Bool {
        match (this) {
            case InvalidSyntax => if (let InvalidSyntax <- other) { true } else { false }
            case ResourceLimit => if (let ResourceLimit <- other) { true } else { false }
            case InvalidValue => if (let InvalidValue <- other) { true } else { false }
            case EncodingLimit => if (let EncodingLimit <- other) { true } else { false }
        }
    }

    public operator func !=(other: JsonErrorKind): Bool { !(this == other) }
}

public open class JsonError <: Exception {
    public let kind: JsonErrorKind

    public init(kind: JsonErrorKind, message: String) {
        super(message)
        this.kind = kind
    }
}

public class JsonParseError <: JsonError {
    public let offset: Int64

    public init(message: String, offset: Int64) {
        super(JsonErrorKind.InvalidSyntax, "JSON error at byte ${offset}: ${message}")
        this.offset = offset
    }
}

public class JsonLimitError <: JsonError {
    public let limit: String
    public let maximum: Int64

    public init(limit: String, maximum: Int64, message: String) {
        super(JsonErrorKind.ResourceLimit, message)
        this.limit = limit
        this.maximum = maximum
    }
}

public class JsonEncodeError <: JsonError {
    public init(message: String, limitExceeded!: Bool = false) {
        super(
            if (limitExceeded) { JsonErrorKind.EncodingLimit } else { JsonErrorKind.InvalidValue },
            message
        )
    }
}

public class JsonParseOptions {
    public let maxBytes: Int64
    public let maxDepth: Int64
    public let maxStringBytes: Int64
    public let maxArrayElements: Int64
    public let maxObjectMembers: Int64

    public init(
        maxBytes!: Int64 = 1048576,
        maxDepth!: Int64 = 64,
        maxStringBytes!: Int64 = 1048576,
        maxArrayElements!: Int64 = 1048576,
        maxObjectMembers!: Int64 = 1048576
    ) {
        requirePositiveJsonLimit("maxBytes", maxBytes)
        requireNonNegativeJsonLimit("maxDepth", maxDepth)
        requirePositiveJsonLimit("maxStringBytes", maxStringBytes)
        requireNonNegativeJsonLimit("maxArrayElements", maxArrayElements)
        requireNonNegativeJsonLimit("maxObjectMembers", maxObjectMembers)
        this.maxBytes = maxBytes
        this.maxDepth = maxDepth
        this.maxStringBytes = maxStringBytes
        this.maxArrayElements = maxArrayElements
        this.maxObjectMembers = maxObjectMembers
    }
}

public class JsonEncodeOptions {
    public let maxBytes: Int64
    public let maxDepth: Int64
    public let maxStringBytes: Int64
    public let maxArrayElements: Int64
    public let maxObjectMembers: Int64

    public init(
        maxBytes!: Int64 = 67108864,
        maxDepth!: Int64 = 64,
        maxStringBytes!: Int64 = 16777216,
        maxArrayElements!: Int64 = 1048576,
        maxObjectMembers!: Int64 = 1048576
    ) {
        requirePositiveJsonLimit("maxBytes", maxBytes)
        requireNonNegativeJsonLimit("maxDepth", maxDepth)
        requirePositiveJsonLimit("maxStringBytes", maxStringBytes)
        requireNonNegativeJsonLimit("maxArrayElements", maxArrayElements)
        requireNonNegativeJsonLimit("maxObjectMembers", maxObjectMembers)
        this.maxBytes = maxBytes
        this.maxDepth = maxDepth
        this.maxStringBytes = maxStringBytes
        this.maxArrayElements = maxArrayElements
        this.maxObjectMembers = maxObjectMembers
    }
}

public class JsonField {
    public let name: String
    public let value: JsonValue

    public init(name: String, value: JsonValue) {
        this.name = name
        this.value = value
    }
}

// JSON numbers retain their original lexeme to avoid precision loss.
// Text/List are the Cangjie-facing names for JSON string/array values.
public class JsonValue {
    public let kind: JsonKind
    public let text: String
    public let boolean: Bool
    public var items: Array<JsonValue>
    public var members: Array<JsonField>

    public init(
        kind: JsonKind,
        text!: String = "",
        number!: String = "",
        boolean!: Bool = false,
        items!: Array<JsonValue> = [],
        fields!: Array<JsonField> = []
    ) {
        this.kind = kind
        this.text = if (kind == JsonKind.Number && number != "") { number } else { text }
        this.boolean = boolean
        this.items = items
        this.members = fields
    }

    public prop number: String { get() { text } }
    public prop fields: Array<JsonField> { get() { members } }

    public static func nullValue(): JsonValue { JsonValue(JsonKind.Null) }
    public static func boolValue(value: Bool): JsonValue {
        JsonValue(JsonKind.Boolean, boolean: value)
    }
    public static func numberValue(value: String): JsonValue {
        JsonValue(JsonKind.Number, number: value)
    }
    public static func stringValue(value: String): JsonValue {
        JsonValue(JsonKind.Text, text: value)
    }
    public static func arrayValue(value: Array<JsonValue>): JsonValue {
        JsonValue(JsonKind.List, items: value)
    }
    public static func objectValue(value: Array<JsonField>): JsonValue {
        JsonValue(JsonKind.Object, fields: value)
    }

    public func field(name: String): ?JsonValue {
        for (member in members where member.name == name) { return Some(member.value) }
        None
    }

    public func get(name: String): ?JsonValue { field(name) }

    public func put(name: String, value: JsonValue): Unit {
        if (kind != JsonKind.Object) {
            throw JsonEncodeError("JSON value is not an object")
        }
        let next = ArrayList<JsonField>()
        var replaced = false
        for (member in members) {
            if (member.name == name) {
                next.add(JsonField(name, value))
                replaced = true
            } else {
                next.add(member)
            }
        }
        if (!replaced) { next.add(JsonField(name, value)) }
        members = next.toArray()
    }

    public func add(value: JsonValue): JsonValue {
        if (kind != JsonKind.List) {
            throw JsonEncodeError("JSON value is not an array")
        }
        let next = ArrayList<JsonValue>(items)
        next.add(value)
        items = next.toArray()
        this
    }

    public func stringify(): String { encodeJson(this) }
}

public class JsonParser {
    private let data: Array<Byte>
    private let options: JsonParseOptions
    private var offset: Int64 = 0

    public init(source: String, options!: JsonParseOptions = JsonParseOptions()) {
        this.data = jsonBytes(source)
        this.options = options
        if (data.size > options.maxBytes) {
            throw JsonLimitError(
                "maxBytes", options.maxBytes,
                "JSON document exceeds ${options.maxBytes} bytes"
            )
        }
    }

    public func parse(): JsonValue {
        skipSpace()
        let value = parseValue(0)
        skipSpace()
        if (offset != data.size) { syntax("unexpected trailing input") }
        value
    }

    private func parseValue(depth: Int64): JsonValue {
        if (depth > options.maxDepth) {
            throw JsonLimitError(
                "maxDepth", options.maxDepth,
                "JSON nesting exceeds ${options.maxDepth}"
            )
        }
        skipSpace()
        if (offset >= data.size) { syntax("expected a value") }
        match (data[offset]) {
            case b'n' => consumeLiteral("null"); JsonValue.nullValue()
            case b't' => consumeLiteral("true"); JsonValue.boolValue(true)
            case b'f' => consumeLiteral("false"); JsonValue.boolValue(false)
            case b'"' => JsonValue.stringValue(parseString())
            case b'[' => parseArray(depth + 1)
            case b'{' => parseObject(depth + 1)
            case value =>
                if (value == b'-' || jsonDigit(value)) { parseNumber() } else { syntax("unexpected byte") }
        }
    }

    private func parseArray(depth: Int64): JsonValue {
        enforceDepth(depth)
        offset += 1
        skipSpace()
        let values = ArrayList<JsonValue>()
        if (take(b']')) { return JsonValue.arrayValue(values.toArray()) }
        while (true) {
            if (values.size >= options.maxArrayElements) {
                throw JsonLimitError(
                    "maxArrayElements", options.maxArrayElements,
                    "JSON array exceeds ${options.maxArrayElements} elements"
                )
            }
            values.add(parseValue(depth))
            skipSpace()
            if (take(b']')) { break }
            expect(b',')
        }
        JsonValue.arrayValue(values.toArray())
    }

    private func parseObject(depth: Int64): JsonValue {
        enforceDepth(depth)
        offset += 1
        skipSpace()
        let values = ArrayList<JsonField>()
        if (take(b'}')) { return JsonValue.objectValue(values.toArray()) }
        while (true) {
            if (values.size >= options.maxObjectMembers) {
                throw JsonLimitError(
                    "maxObjectMembers", options.maxObjectMembers,
                    "JSON object exceeds ${options.maxObjectMembers} members"
                )
            }
            skipSpace()
            if (offset >= data.size || data[offset] != b'"') { syntax("expected object key") }
            let name = parseString()
            for (member in values where member.name == name) {
                syntax("duplicate object key ${name}")
            }
            skipSpace()
            expect(b':')
            values.add(JsonField(name, parseValue(depth)))
            skipSpace()
            if (take(b'}')) { break }
            expect(b',')
        }
        JsonValue.objectValue(values.toArray())
    }

    private func parseString(): String {
        expect(b'"')
        let output = ArrayList<Byte>()
        while (offset < data.size) {
            let value = data[offset]
            offset += 1
            if (value == b'"') {
                return try {
                    String.fromUtf8(output.toArray())
                } catch (_: Exception) {
                    syntax("invalid UTF-8 string")
                }
            }
            if (value < 0x20) { syntax("control character in string") }
            if (value != b'\\') {
                appendStringByte(output, value)
                continue
            }
            if (offset >= data.size) { syntax("unfinished escape") }
            let escaped = data[offset]
            offset += 1
            match (escaped) {
                case b'"' => appendStringByte(output, b'"')
                case b'\\' => appendStringByte(output, b'\\')
                case b'/' => appendStringByte(output, b'/')
                case b'b' => appendStringByte(output, 0x08)
                case b'f' => appendStringByte(output, 0x0c)
                case b'n' => appendStringByte(output, b'\n')
                case b'r' => appendStringByte(output, b'\r')
                case b't' => appendStringByte(output, b'\t')
                case b'u' => appendUnicodeEscape(output)
                case _ => syntax("invalid escape")
            }
        }
        syntax("unterminated string")
    }

    private func appendStringByte(output: ArrayList<Byte>, value: Byte): Unit {
        if (output.size >= options.maxStringBytes) {
            throw JsonLimitError(
                "maxStringBytes", options.maxStringBytes,
                "JSON string exceeds ${options.maxStringBytes} bytes"
            )
        }
        output.add(value)
    }

    private func appendUnicodeEscape(output: ArrayList<Byte>): Unit {
        let first = readHex4()
        var codepoint = first
        if (first >= 0xd800 && first <= 0xdbff) {
            if (offset + 2 > data.size || data[offset] != b'\\' || data[offset + 1] != b'u') {
                syntax("high surrogate is missing its low surrogate")
            }
            offset += 2
            let second = readHex4()
            if (second < 0xdc00 || second > 0xdfff) { syntax("invalid low surrogate") }
            codepoint = 0x10000 + (first - 0xd800) * 0x400 + second - 0xdc00
        } else if (first >= 0xdc00 && first <= 0xdfff) {
            syntax("unexpected low surrogate")
        }
        let encoded = ArrayList<Byte>()
        appendJsonUtf8(encoded, codepoint)
        for (value in encoded) { appendStringByte(output, value) }
    }

    private func readHex4(): Int64 {
        if (offset + 4 > data.size) { syntax("unfinished unicode escape") }
        var value: Int64 = 0
        for (_ in 0..4) {
            value = value * 16 + jsonHexValue(data[offset], offset)
            offset += 1
        }
        value
    }

    private func parseNumber(): JsonValue {
        let start = offset
        take(b'-')
        if (take(b'0')) {
            if (offset < data.size && jsonDigit(data[offset])) { syntax("leading zero in number") }
        } else {
            requireDigits()
        }
        if (take(b'.')) { requireDigits() }
        if (take(b'e') || take(b'E')) {
            if (!take(b'+')) { take(b'-') }
            requireDigits()
        }
        JsonValue.numberValue(String.fromUtf8(data[start..offset]))
    }

    private func requireDigits(): Unit {
        let start = offset
        while (offset < data.size && jsonDigit(data[offset])) { offset += 1 }
        if (start == offset) { syntax("expected digit") }
    }

    private func consumeLiteral(literal: String): Unit {
        let expected = jsonBytes(literal)
        if (offset + expected.size > data.size) { syntax("expected ${literal}") }
        for (value in expected) {
            if (data[offset] != value) { syntax("expected ${literal}") }
            offset += 1
        }
    }

    private func skipSpace(): Unit {
        while (offset < data.size) {
            let value = data[offset]
            if (value != b' ' && value != b'\n' && value != b'\r' && value != b'\t') { break }
            offset += 1
        }
    }

    private func expect(value: Byte): Unit {
        skipSpace()
        if (!take(value)) { syntax("expected JSON delimiter") }
    }

    private func take(value: Byte): Bool {
        if (offset < data.size && data[offset] == value) {
            offset += 1
            true
        } else {
            false
        }
    }

    private func syntax(message: String): Nothing { throw JsonParseError(message, offset) }

    private func enforceDepth(depth: Int64): Unit {
        if (depth > options.maxDepth) {
            throw JsonLimitError(
                "maxDepth", options.maxDepth,
                "JSON nesting exceeds ${options.maxDepth}"
            )
        }
    }
}

public class JsonEncoder {
    private let options: JsonEncodeOptions

    public init(options!: JsonEncodeOptions = JsonEncodeOptions()) {
        this.options = options
    }

    public func encode(value: JsonValue): String {
        let encoded = encodeValue(value, 0)
        let size = jsonBytes(encoded).size
        if (size > options.maxBytes) {
            throw JsonEncodeError(
                "encoded JSON exceeds ${options.maxBytes} bytes",
                limitExceeded: true
            )
        }
        encoded
    }

    private func encodeValue(value: JsonValue, depth: Int64): String {
        if (depth > options.maxDepth) {
            throw JsonEncodeError(
                "encoded JSON nesting exceeds ${options.maxDepth}",
                limitExceeded: true
            )
        }
        match (value.kind) {
            case JsonKind.Null => "null"
            case JsonKind.Boolean => if (value.boolean) { "true" } else { "false" }
            case JsonKind.Number =>
                if (!validJsonNumber(value.text)) {
                    throw JsonEncodeError("invalid JSON number")
                }
                value.text
            case JsonKind.Text => jsonQuote(value.text, maxBytes: options.maxStringBytes)
            case JsonKind.List =>
                if (value.items.size > options.maxArrayElements) {
                    throw JsonEncodeError(
                        "JSON array exceeds ${options.maxArrayElements} elements",
                        limitExceeded: true
                    )
                }
                let parts = ArrayList<String>()
                for (item in value.items) { parts.add(encodeValue(item, depth + 1)) }
                "[" + joinJson(parts.toArray()) + "]"
            case JsonKind.Object =>
                if (value.members.size > options.maxObjectMembers) {
                    throw JsonEncodeError(
                        "JSON object exceeds ${options.maxObjectMembers} members",
                        limitExceeded: true
                    )
                }
                let parts = ArrayList<String>()
                let names = ArrayList<String>()
                for (member in value.members) {
                    for (known in names where known == member.name) {
                        throw JsonEncodeError("duplicate JSON object key ${member.name}")
                    }
                    names.add(member.name)
                    parts.add(
                        jsonQuote(member.name, maxBytes: options.maxStringBytes) + ":" +
                            encodeValue(member.value, depth + 1)
                    )
                }
                "{" + joinJson(parts.toArray()) + "}"
        }
    }
}

public func parseJson(
    source: String,
    maxBytes!: Int64 = 1048576,
    maxDepth!: Int64 = 64,
    maxStringBytes!: Int64 = 1048576,
    maxArrayElements!: Int64 = 1048576,
    maxObjectMembers!: Int64 = 1048576
): JsonValue {
      JsonParser(source, options: JsonParseOptions(
        maxBytes: maxBytes,
        maxDepth: maxDepth,
        maxStringBytes: maxStringBytes,
        maxArrayElements: maxArrayElements,
        maxObjectMembers: maxObjectMembers
    )).parse()
}

public func encodeJson(
    value: JsonValue,
    options!: JsonEncodeOptions = JsonEncodeOptions()
): String {
    JsonEncoder(options: options).encode(value)
}

public func jsonQuote(text: String, maxBytes!: Int64 = 16777216): String {
    if (jsonBytes(text).size > maxBytes) {
        throw JsonEncodeError("JSON string exceeds ${maxBytes} bytes", limitExceeded: true)
    }
    let output = ArrayList<Byte>()
    output.add(b'"')
    for (value in jsonBytes(text)) {
        match (value) {
            case b'\\' => output.add(b'\\'); output.add(b'\\')
            case b'"' => output.add(b'\\'); output.add(b'"')
            case b'\b' => output.add(b'\\'); output.add(b'b')
            case b'\f' => output.add(b'\\'); output.add(b'f')
            case b'\n' => output.add(b'\\'); output.add(b'n')
            case b'\r' => output.add(b'\\'); output.add(b'r')
            case b'\t' => output.add(b'\\'); output.add(b't')
            case byte =>
                if (byte < 0x20) {
                    let hex = jsonByteHex(byte)
                    output.add(b'\\'); output.add(b'u'); output.add(b'0'); output.add(b'0')
                    for (digit in jsonBytes(hex)) { output.add(digit) }
                } else {
                    output.add(byte)
                }
        }
    }
    output.add(b'"')
    String.fromUtf8(output.toArray())
}

private func validJsonNumber(value: String): Bool {
    try {
        let parsed = parseJson(value, maxBytes: 1024, maxDepth: 0)
        parsed.kind == JsonKind.Number
    } catch (_: JsonError) {
        false
    }
}

private func joinJson(values: Array<String>): String {
    var result = ""
    for (index in 0..values.size) {
        if (index > 0) { result += "," }
        result += values[index]
    }
    result
}

private func jsonDigit(value: Byte): Bool { value >= b'0' && value <= b'9' }

private func jsonHexValue(value: Byte, offset: Int64): Int64 {
    if (value >= b'0' && value <= b'9') { return Int64(value - b'0') }
    if (value >= b'a' && value <= b'f') { return Int64(value - b'a') + 10 }
    if (value >= b'A' && value <= b'F') { return Int64(value - b'A') + 10 }
    throw JsonParseError("invalid hexadecimal digit", offset)
}

private func appendJsonUtf8(output: ArrayList<Byte>, value: Int64): Unit {
    if (value <= 0x7f) {
        output.add(UInt8(value))
    } else if (value <= 0x7ff) {
        output.add(UInt8(0xc0 | (value >> 6)))
        output.add(UInt8(0x80 | (value & 0x3f)))
    } else if (value <= 0xffff) {
        output.add(UInt8(0xe0 | (value >> 12)))
        output.add(UInt8(0x80 | ((value >> 6) & 0x3f)))
        output.add(UInt8(0x80 | (value & 0x3f)))
    } else {
        output.add(UInt8(0xf0 | (value >> 18)))
        output.add(UInt8(0x80 | ((value >> 12) & 0x3f)))
        output.add(UInt8(0x80 | ((value >> 6) & 0x3f)))
        output.add(UInt8(0x80 | (value & 0x3f)))
    }
}

private func jsonByteHex(value: Byte): String {
    let digits = "0123456789abcdef"
    let raw = jsonBytes(digits)
    String.fromUtf8([raw[Int64(value >> 4)], raw[Int64(value & 0x0f)]])
}

// The parser retains this array after the source expression has returned.
// rawData() is only a borrowed view into String storage and becomes unsafe once
// the source is reclaimed; own the bytes instead.
private func jsonBytes(value: String): Array<Byte> { value.toArray() }

private func requirePositiveJsonLimit(name: String, value: Int64): Unit {
    if (value < 1) { throw IllegalArgumentException("${name} must be positive") }
}

private func requireNonNegativeJsonLimit(name: String, value: Int64): Unit {
    if (value < 0) { throw IllegalArgumentException("${name} must be non-negative") }
}
