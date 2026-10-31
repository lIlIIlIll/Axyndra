package agent_store

import agent_domain.*
import yjson.*
import yjson_support.*

// Compare the current mutable value with every byte of the existing frozen
// Store encoding. No JSON tree, encoded copy, hash, prefix, or authority is
// retained. Only a previously successful bounded full validator can provide
// a reusable memo. A mismatch still runs that exact original full validator.
func currentStoredValueMatches(value: AgentValue, encoded: String): Bool {
    if (encoded.size > 8388608) { return false }
    let comparison = CurrentStoredValueComparison(encoded)
    comparison.matchesValue(value, 0) && comparison.complete()
}

private class CurrentStoredValueComparison {
    private let data: Array<Byte>
    private var offset: Int64 = 0

    init(encoded: String) { data = unsafe { encoded.rawData() } }

    func complete(): Bool { offset == data.size }

    private func matchesByte(value: Byte): Bool {
        if (offset >= data.size || data[offset] != value) { return false }
        offset++
        true
    }

    private func matchesText(value: String): Bool {
        let current = unsafe { value.rawData() }
        let size = current.size
        if (offset > data.size || size > data.size - offset) { return false }
        if (size > 0) {
            // All arrays, offsets and the native length exist before pinning.
            // The pointers are used only by this exact synchronous comparison.
            let nativeSize = UIntNative(size)
            let start = offset
            let same = unsafe {
                let frozenLease = acquireArrayRawData(data)
                try {
                    let currentLease = acquireArrayRawData(current)
                    try { memcmp(frozenLease.pointer + start, currentLease.pointer, nativeSize) == 0 }
                    finally { releaseArrayRawData(currentLease) }
                } finally { releaseArrayRawData(frozenLease) }
            }
            if (!same) { return false }
        }
        offset += size
        true
    }

    private func matchesFrame(value: String): Bool {
        matchesText(value.size.toString() + ":") && matchesText(value)
    }

    func matchesValue(value: AgentValue, depth: Int64): Bool {
        // Successful memo inputs already passed StoredValueParser's original
        // 64-level limit. A deeper mutation cannot reuse that successful proof.
        if (depth > 64 || offset >= data.size) { return false }
        match (value.unifiedKind) {
            case ValueKind.Null => matchesByte(b'n')
            case ValueKind.Boolean => matchesByte(if (value.asBool()) { b't' } else { b'f' })
            case ValueKind.Number => matchesByte(b'd') && matchesFrame(value.asNumberText())
            case ValueKind.Text => matchesByte(b's') && matchesFrame(value.text)
            case ValueKind.List =>
                let items = value.items
                if (!matchesByte(b'l') || !matchesFrame(items.size.toString())) { return false }
                for (item in items) {
                    if (!matchesValue(item, depth + 1)) { return false }
                }
                true
            case ValueKind.Object =>
                let fields = value.fields
                if (!matchesByte(b'o') || !matchesFrame(fields.size.toString())) { return false }
                for (field in fields) {
                    if (!matchesFrame(field.name) || !matchesValue(field.value, depth + 1)) { return false }
                }
                true
        }
    }
}
