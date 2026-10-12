package agent_domain

import yjson.*
import yjson_support.*
import stdx.crypto.digest.SHA256

// Same complete canonicalAgentValue bytes and SHA256, with no complete
// canonical String or scalar-sized byte-array copy. This is only a semantic
// digest: original Store snapshot/continuation/Attempt checks still authorize
// dispatch. Callers retain and pay their complete immutable input separately.
public func canonicalAgentValueSha256(value: AgentValue): String {
    let writer = ModelCanonicalDigestWriter()
    writer.node(value)
    let digest = writer.finish()
    let hex = "0123456789abcdef"
    let result = Array<Byte>(64, repeat: 0)
    for (index in 0..digest.size) {
        result[index * 2] = hex[Int64(digest[index]) / 16]
        result[index * 2 + 1] = hex[Int64(digest[index]) % 16]
    }
    String.fromUtf8(result)
}

private func modelCanonicalExtentAdd(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || right > Int64.Max - left) {
        throw IllegalStateException("canonical model digest extent overflow")
    }
    left + right
}

private func modelCanonicalFramedExtent(bytes: Int64): Int64 {
    modelCanonicalExtentAdd(modelCanonicalExtentAdd(bytes.toString().size, 1), bytes)
}

// All child bytes contribute. Object measurement does not need sorting:
// sorting changes order, never the sum of the original length frames.
private func modelCanonicalExtent(value: AgentValue): Int64 {
    match (value.kind()) {
        case JsonKind.Null => 4
        case JsonKind.Boolean => if (value.asBool()) { 4 } else { 5 }
        case JsonKind.Number => modelCanonicalExtentAdd(1, modelCanonicalFramedExtent(value.asNumberText().size))
        case JsonKind.String => modelCanonicalExtentAdd(1, modelCanonicalFramedExtent(value.asString().size))
        case JsonKind.Array =>
            let array = value.asArray()
            var bytes: Int64 = 2
            for (index in 0..array.size()) {
                bytes = modelCanonicalExtentAdd(bytes,
                    modelCanonicalFramedExtent(modelCanonicalExtent(array.get(index).getOrThrow())))
            }
            bytes
        case JsonKind.Object =>
            let object = value.asObject()
            var bytes: Int64 = 2
            for (index in 0..object.size()) {
                bytes = modelCanonicalExtentAdd(bytes, modelCanonicalFramedExtent(object.nameAt(index).size))
                bytes = modelCanonicalExtentAdd(bytes,
                    modelCanonicalFramedExtent(modelCanonicalExtent(object.valueAt(index))))
            }
            bytes
    }
}

private class ModelCanonicalDigestWriter {
    private let hash = SHA256()
    private let buffer = Array<Byte>(16384, repeat: 0)
    private var used: Int64 = 0
    private func flush(): Unit {
        if (used > 0) { hash.write(buffer[..used]); used = 0 }
    }
    private func text(value: String): Unit {
        let raw = unsafe { value.rawData() }
        var offset: Int64 = 0
        while (offset < raw.size) {
            let extent = min(raw.size - offset, buffer.size - used)
            for (index in 0..extent) { buffer[used + index] = raw[offset + index] }
            used += extent; offset += extent
            if (used == buffer.size) { flush() }
        }
    }
    private func prefix(bytes: Int64): Unit { text(bytes.toString()); text(":") }
    private func frame(value: String): Unit { prefix(value.size); text(value) }
    private func child(value: AgentValue): Unit { prefix(modelCanonicalExtent(value)); node(value) }
    func node(value: AgentValue): Unit {
        match (value.kind()) {
            case JsonKind.Null => text("null")
            case JsonKind.Boolean => text(if (value.asBool()) { "true" } else { "false" })
            case JsonKind.Number => text("n"); frame(value.asNumberText())
            case JsonKind.String => text("s"); frame(value.asString())
            case JsonKind.Array =>
                text("[")
                let array = value.asArray()
                for (index in 0..array.size()) { child(array.get(index).getOrThrow()) }
                text("]")
            case JsonKind.Object =>
                text("{")
                let object = value.asObject()
                // Stable (name,index) order is the original used[] selection
                // order, including equal names, without that per-object array.
                var previous: Int64 = -1
                for (_ in 0..object.size()) {
                    var selected: Int64 = -1
                    for (index in 0..object.size()) {
                        let afterPrevious = previous < 0 || object.nameAt(index) > object.nameAt(previous) ||
                            (object.nameAt(index) == object.nameAt(previous) && index > previous)
                        if (afterPrevious && (selected < 0 || object.nameAt(index) < object.nameAt(selected) ||
                            (object.nameAt(index) == object.nameAt(selected) && index < selected))) { selected = index }
                    }
                    if (selected < 0) { throw IllegalStateException("canonical model object changed during digest") }
                    frame(object.nameAt(selected)); child(object.valueAt(selected)); previous = selected
                }
                text("}")
        }
    }
    func finish(): Array<Byte> { flush(); hash.finish() }
}

// Compare every original canonical byte to an existing frozen witness. This
// does not replace that witness with a hash or an ID, create a dispatch grant,
// or change its lifetime. No additional whole canonical String is allocated.
public func canonicalAgentValueMatches(value: AgentValue, canonical: String): Bool {
    let writer = ModelCanonicalComparisonWriter(canonical)
    writer.node(value)
    writer.finish()
}

private class ModelCanonicalComparisonWriter {
    private let canonical: String
    private var offset: Int64 = 0
    private var matches = true
    init(canonical: String) { this.canonical = canonical }
    private func text(value: String): Unit {
        if (!matches) { return }
        if (value.size > canonical.size - offset) { matches = false; return }
        let actual = unsafe { value.rawData() }
        let expected = unsafe { canonical.rawData() }
        for (index in 0..actual.size) {
            if (actual[index] != expected[offset + index]) { matches = false; return }
        }
        offset += actual.size
    }
    private func prefix(bytes: Int64): Unit { text(bytes.toString()); text(":") }
    private func frame(value: String): Unit { prefix(value.size); text(value) }
    private func child(value: AgentValue): Unit { prefix(modelCanonicalExtent(value)); node(value) }
    func node(value: AgentValue): Unit {
        if (!matches) { return }
        match (value.kind()) {
            case JsonKind.Null => text("null")
            case JsonKind.Boolean => text(if (value.asBool()) { "true" } else { "false" })
            case JsonKind.Number => text("n"); frame(value.asNumberText())
            case JsonKind.String => text("s"); frame(value.asString())
            case JsonKind.Array =>
                text("[")
                let array = value.asArray()
                for (index in 0..array.size()) {
                    if (!matches) { return }
                    child(array.get(index).getOrThrow())
                }
                text("]")
            case JsonKind.Object =>
                text("{")
                let object = value.asObject()
                var previous: Int64 = -1
                for (_ in 0..object.size()) {
                    if (!matches) { return }
                    var selected: Int64 = -1
                    for (index in 0..object.size()) {
                        let afterPrevious = previous < 0 || object.nameAt(index) > object.nameAt(previous) ||
                            (object.nameAt(index) == object.nameAt(previous) && index > previous)
                        if (afterPrevious && (selected < 0 || object.nameAt(index) < object.nameAt(selected) ||
                            (object.nameAt(index) == object.nameAt(selected) && index < selected))) { selected = index }
                    }
                    if (selected < 0) { throw IllegalStateException("canonical model object changed during comparison") }
                    frame(object.nameAt(selected)); child(object.valueAt(selected)); previous = selected
                }
                text("}")
        }
    }
    func finish(): Bool { matches && offset == canonical.size }
}
