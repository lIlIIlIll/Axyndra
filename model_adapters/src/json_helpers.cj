package model_adapters

// Shared teaching support for message JSON and small string scans.
// The lesson chapters import this package so their own source can stay focused on agent behavior.

import json4cj.*
import std.collection.*

public func stripUnsafeControlChars(text: String): String {
    let out = ArrayList<Byte>()
    for (byte in bytes(text) where
        byte == b'\n' || byte == b'\r' || byte == b'\t' || byte >= 32) {
        out.add(byte)
    }
    String.fromUtf8(out.toArray())
}

public func utf8Prefix(text: String, maxBytes: Int64): String {
    if (maxBytes <= 0) { return "" }
    let textBytes = bytes(text)
    if (textBytes.size <= maxBytes) { return text }
    let out = ArrayList<Byte>()
    var index: Int64 = 0
    while (index < textBytes.size) {
        let charBytes = utf8CharByteLength(textBytes[index])
        if (index + charBytes > textBytes.size || out.size + charBytes > maxBytes) { break }
        for (offset in 0..charBytes) {
            out.add(textBytes[index + offset])
        }
        index += charBytes
    }
    String.fromUtf8(out.toArray())
}

func utf8CharByteLength(byte: Byte): Int64 {
    if (byte < 128) {
        1
    } else if (byte >= 194 && byte < 224) {
        2
    } else if (byte >= 224 && byte < 240) {
        3
    } else if (byte >= 240 && byte < 245) {
        4
    } else {
        1
    }
}

public func indexOf(text: String, pattern: String, from: Int64): Int64 {
    let textBytes = bytes(text)
    let patternBytes = bytes(pattern)
    if (from < 0 || patternBytes.size == 0 || textBytes.size < patternBytes.size || from >= textBytes.size) {
        return -1
    }
    for (i in from..(textBytes.size - patternBytes.size + 1)) {
        var matched = true
        for (k in 0..patternBytes.size where textBytes[i + k] != patternBytes[k]) {
            matched = false
            break
        }
        if (matched) { return i }
    }
    -1
}

public func jsonField(text: String, name: String, from: Int64): String {
    let nameIndex = indexOf(text, jsonQuote(name), from)
    if (nameIndex < 0) { return "" }
    let colonIndex = indexOf(text, ":", nameIndex)
    if (colonIndex < 0) { return "" }
    let quoteIndex = indexOf(text, "\"", colonIndex + 1)
    if (quoteIndex < 0) { "" } else { jsonStringAt(text, quoteIndex) }
}

public func jsonInputField(text: String, name: String, toolUseIndex: Int64): String {
    let inputIndex = indexOf(text, "\"input\"", toolUseIndex)
    if (inputIndex < 0) { "" } else { jsonField(text, name, inputIndex) }
}

public func jsonContentArray(response: String): String {
    try {
        match (parseJson(response).field("content")) {
            case Some(content) =>
                if (content.kind == JsonKind.List) { content.stringify() } else { "[]" }
            case None => "[]"
        }
    } catch (_: JsonParseError) {
        "[]"
    }
}

func jsonStringAt(text: String, quoteIndex: Int64): String {
    let textBytes = bytes(text)
    let out = ArrayList<Byte>()
    var i = quoteIndex + 1
    while (i < textBytes.size) {
        if (textBytes[i] == b'"') { return String.fromUtf8(out.toArray()) }
        if (textBytes[i] == b'\\' && i + 1 < textBytes.size) {
            match (textBytes[i + 1]) {
                case b'n' => out.add(b'\n')
                case b'r' => out.add(b'\r')
                case b't' => out.add(b'\t')
                case b'"' => out.add(b'"')
                case b'\\' => out.add(b'\\')
                case value => out.add(value)
            }
            i += 2
            continue
        }
        out.add(textBytes[i])
        i += 1
    }
    ""
}

public func nextToolUseIndex(response: String, from: Int64): Int64 {
    let compact = indexOf(response, "\"type\":\"tool_use\"", from)
    let spaced = indexOf(response, "\"type\": \"tool_use\"", from)
    if (compact < 0) { return spaced }
    if (spaced < 0 || compact < spaced) { compact } else { spaced }
}

public func bytes(text: String): Array<Byte> {
    unsafe { text.rawData() }
}
