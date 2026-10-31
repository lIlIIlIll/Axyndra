package workspace_plugin

import std.convert.*

class ReadTarget {
    let path: String
    let offset: Int64
    let limit: Int64
    let hasRange: Bool
    let raw: Bool

    init(
        path: String,
        offset!: Int64 = 1,
        limit!: Int64 = 2000,
        hasRange!: Bool = false,
        raw!: Bool = false
    ) {
        this.path = path
        this.offset = offset
        this.limit = limit
        this.hasRange = hasRange
        this.raw = raw
    }
}

func parseReadTarget(authored: String): ReadTarget {
    var source = authored
    var raw = false
    if (source.endsWith(":raw")) {
        source = source[..source.size - 4]
        raw = true
    }
    let separator = source.lastIndexOf(":")
    if (separator.isNone()) {
        return ReadTarget(source, raw: raw)
    }
    let index = separator.getOrThrow()
    let selector = source[index + 1..]
    let path = source[..index]
    let plus = selector.indexOf("+")
    if (plus.isSome()) {
        let split = plus.getOrThrow()
        let start = parsePositiveLine(selector[..split])
        let count = parsePositiveLine(selector[split + 1..])
        if (start > 0 && count > 0 && path != "") {
            return ReadTarget(
                path,
                offset: start,
                limit: count,
                hasRange: true,
                raw: raw
            )
        }
    }
    let dash = selector.indexOf("-")
    if (dash.isSome()) {
        let split = dash.getOrThrow()
        let start = parsePositiveLine(selector[..split])
        let end = parsePositiveLine(selector[split + 1..])
        if (start > 0 && end >= start && path != "") {
            return ReadTarget(
                path,
                offset: start,
                limit: end - start + 1,
                hasRange: true,
                raw: raw
            )
        }
    }
    let line = parsePositiveLine(selector)
    if (line > 0 && path != "") {
        return ReadTarget(
            path,
            offset: line,
            limit: 1,
            hasRange: true,
            raw: raw
        )
    }
    ReadTarget(source, raw: raw)
}

func parsePositiveLine(source: String): Int64 {
    let normalized = if (source.startsWith("L")) {
        source[1..]
    } else {
        source
    }
    try {
        let value = Int64.parse(normalized)
        if (value > 0) {
            value
        } else {
            -1
        }
    } catch (_: Exception) {
        -1
    }
}
