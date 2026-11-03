package agent_product

import agent_domain.*
import agent_extension_runtime.reserveNativeObservationBuffer
import std.collection.*
import std.convert.*
import std.io.*
import yjson.*
import yjson_support.*

// Query-local DATA, not an Artifact/operation registry. All strings are host
// captured immutable values. A provider can select already supplied data and
// exact ranges; it cannot introduce a file path, acquire another source or mint
// a reference. This is also used for output recipes, whose repeated ranges are
// charged by expanded size before allocating any output.
class ProductPolicyDataReferences {
    private let canonicalBorrowed113 = HashSet<Int64>()
    private let query: String
    private let strings = ArrayList<String>()
    private let indexes = HashMap<String, Int64>()
    private let reservations = ArrayList<LogicalJsonFixedBufferReservation>()
    private var charged: Int64 = 0
    private var retained: Int64 = 0
    private var closed = false
    init(query: String) {
        if (query == "" || query.size > 256) { throw IllegalArgumentException("invalid policy data query") }
        this.query = query
    }
    private func reserve(bytes: Int64): Unit {
        if (closed || bytes < 0 || bytes > 134217728 - retained) {
            throw IllegalStateException("policy data aggregate capacity exhausted") }
        let target = retained + bytes
        while (charged < target) {
            // Shares the native process-wide pool; this is not a new budget.
            let charge = reserveNativeObservationBuffer()
            reservations.add(charge); charged += 65536
        }
        retained = target
    }
    private func release(bytes: Int64): Unit {
        if (bytes < 0 || bytes > retained) { throw IllegalStateException("invalid policy data release") }
        retained -= bytes
        while (charged >= retained + 65536 && !reservations.isEmpty()) {
            reservations.remove(at: reservations.size - 1).close(); charged -= 65536
        }
    }
    // Scan while the transport still owns its parsed response, claim before
    // cloning, and transfer only the independent copy to the consumer lease.
    func copy(value: AgentValue): ProductPolicyValueLease {
        let bytes = productPolicyCopyCost(value)
        reserve(bytes)
        try { ProductPolicyValueLease(freezeProductPolicyData(value), { => release(bytes) }) }
        catch (error: Exception) { release(bytes); throw error }
    }
    func concatenate(parts: Array<String>): ProductPolicyValueLease {
        var count: Int64 = 0
        for (part in parts) {
            if (part.size > 8388608 - count) { throw IllegalStateException("policy text exceeds checkpoint codec bound") }
            count += part.size
        }
        let charge = productPolicyCopyAdd(512, count * 8)
        reserve(charge)
        try {
            let bytes = Array<Byte>(count, repeat: 0); var offset: Int64 = 0
            for (part in parts) { for (byte in unsafe { part.rawData() }) { bytes[offset] = byte; offset++ } }
            ProductPolicyValueLease(textValue(String.fromUtf8(bytes)), { => release(charge) })
        } catch (error: Exception) { release(charge); throw error }
    }
    func captureProjection(request: ModelRequest): AgentValue {
        // Claim the domain codec's temporary projection containers before it
        // expands the typed message/block arrays. Strings remain immutable.
        // Frozen nodes are charged separately until this temporary is dropped.
        var bytes: Int64 = 32768
        for (message in request.messages) {
            if (bytes > 134217728 - 4096) { throw IllegalStateException("policy projection capacity exhausted") }
            bytes += 4096
            for (_ in message.blocks) {
                if (bytes > 134217728 - 16384) { throw IllegalStateException("policy projection capacity exhausted") }
                bytes += 16384
            }
        }
        reserve(bytes)
        try { freeze(modelRequestSnapshotValue(request)) } finally { release(bytes) }
    }
    func freeze(value: AgentValue, depth!: Int64 = 0): AgentValue {
        if (depth > 128) { throw IllegalStateException("policy source nesting exceeds codec bound") }
        // Claim each newly allocated container/node before copying it. Scalar
        // strings are immutable; intern accounts their retained bytes once.
        reserve(512)
        match (value.unifiedKind) {
            case ValueKind.Null => nullValue()
            case ValueKind.Boolean => boolValue(value.asBool())
            case ValueKind.Number =>
                reserve(value.asNumberText().size); numberValue(value.asNumberText())
            case ValueKind.Text => let _ = intern(value.text); textValue(value.text)
            case ValueKind.List =>
                let values = ArrayList<AgentValue>()
                for (child in value.items) { values.add(freeze(child, depth: depth + 1)) }
                listValue(values.toArray())
            case ValueKind.Object =>
                let fields = ArrayList<ValueField>()
                for (field in value.fields) { let _ = intern(field.name); fields.add(ValueField(field.name, freeze(field.value, depth: depth + 1))) }
                objectValue(fields.toArray())
        }
    }
    // Opt-in canonical row capture. UTF8 bytes are copied while the real row
    // alias is still paid; neither a slice nor a row-backed String escapes.
    // Both transient construction and the independent intern entry coexist.
    func captureDetachedText113(source: String): AgentValue {
        let temporary = productPolicyCopyAdd(8192, productPolicyCopyMultiply113(source.size, 8))
        reserve(temporary)
        try {
            let detached = String.fromUtf8(source.toArray())
            intern(detached)
        } finally { release(temporary) }
    }
    // Actual small containers retained by the complete first-call index are
    // paid before allocation, without a count limit or a second budget.
    // Two bounded reference nodes, their map entry and simultaneous pointer
    // backing growth; no history cell or scalar body is copied into this slot.
    func retainCheckpointIndexEntry113(): Unit { reserve(4096) }
    // Batches are bounded by the ORIGINAL policy page of 64, not by a new
    // history cap. Caller drops the entire batch frame before closing this.
    func checkpointBatchMetadata113(): ProductPolicyValueLease {
        reserve(1048576)
        try { ProductPolicyValueLease(nullValue(), { => release(1048576) }) }
        catch (error: Exception) { release(1048576); throw error }
    }
    func intern(source: String): AgentValue {
        if (closed) { throw IllegalStateException("policy data query is closed") }
        let index = match (indexes.get(source)) {
            case Some(found) => found
            case None =>
                // Strings are immutable and captured by value. This entry
                // never retains a caller-owned JsonNode or mutable array.
                reserve(source.size + 512)
                let next = strings.size
                strings.add(source); indexes[source] = next; next
        }
        objectValue([ValueField("query", textValue(query)), ValueField("ref", integerValue(index)),
            ValueField("bytes", integerValue(source.size)),
            ValueField("inline", if (source.size <= 2048) { textValue(source) } else { nullValue() })])
    }
    // Opt-in event completion only. The query supplies ALL actual retained
    // value leases, not merely Native's claimed newest state. ID slots and
    // their original 512-byte charge remain; only unreachable string bytes
    // retire after the actual String/index-key helper frame has returned.
    func retireUnreferencedText113(roots: Array<AgentValue>): Unit {
        let bytes = productPolicyCopyAdd(8192, productPolicyCopyMultiply113(strings.size, 2))
        reserve(bytes)
        try { retireUnreferencedTextFrame113(roots) } finally { release(bytes) }
    }
    // Only the actual complete canonical-row callback calls this opt-in.
    // Its real row owner remains live through all Native fragments/event RPCs.
    // Finish below drops unreachable captures or separately pays/copies the
    // retained text BEFORE that row callback may ACK.
    func captureCanonicalBorrowedText113(source: String): AgentValue {
        let existed = indexes.get(source).isSome()
        let reference = intern(source)
        if (!existed) { canonicalBorrowed113.add(compactionPageInteger(reference, "ref")) }
        reference
    }
    func finishCanonicalTextLoan113(roots: Array<AgentValue>): Unit {
        try {
            retireUnreferencedText113(roots)
            for (id in canonicalBorrowed113 where strings[id] != "") {
                let peak = productPolicyCopyAdd(8192, productPolicyCopyMultiply113(strings[id].size, 8))
                reserve(peak)
                try { detachCanonicalTextFrame113(id) } finally { release(peak) }
            }
        } finally { canonicalBorrowed113.clear() }
    }
    private func detachCanonicalTextFrame113(id: Int64): Unit {
        let original = strings[id]
        let independent = String.fromUtf8(original.toArray())
        indexes.remove(original); strings[id] = independent; indexes[independent] = id
    }
    private func retireUnreferencedTextFrame113(roots: Array<AgentValue>): Unit {
        let live = Array<Bool>(strings.size, repeat: false)
        for (root in roots) { markLiveText113(root, live, 0) }
        for (id in 0..strings.size where !live[id] && strings[id] != "") {
            let retiredBytes = retireTextFrame113(id)
            // String/local index aliases ended in retireTextFrame113 above.
            release(retiredBytes)
        }
    }
    private func markLiveText113(value: AgentValue, live: Array<Bool>, depth: Int64): Unit {
        if (depth > 128) { throw IllegalStateException("retained reference nesting exceeds original codec") }
        if (value.unifiedKind == ValueKind.Object) {
            if (value.field("ref").isSome()) {
                let _ = this.value(value)
                live[compactionPageInteger(value, "ref")] = true
            } else { for (field in value.fields) { markLiveText113(field.value, live, depth + 1) } }
        } else if (value.unifiedKind == ValueKind.List) {
            for (entry in value.items) { markLiveText113(entry, live, depth + 1) }
        }
    }
    private func retireTextFrame113(id: Int64): Int64 {
        let bytes = strings[id].size
        indexes.remove(strings[id]); strings[id] = ""; bytes
    }
    func value(reference: AgentValue): String {
        if (closed || !httpIntentExactFields(reference, ["query", "ref", "bytes", "inline"]) ||
            httpIntentText(reference, "query") != query) { throw IllegalStateException("foreign policy data reference") }
        let id = compactionPageInteger(reference, "ref")
        let size = compactionPageInteger(reference, "bytes")
        if (id < 0 || id >= strings.size || size != strings[id].size) {
            throw IllegalStateException("policy data reference does not exist") }
        let inline = reference.field("inline").getOrThrow()
        if ((size <= 2048 && (inline.unifiedKind != ValueKind.Text || inline.text != strings[id])) ||
            (size > 2048 && inline.unifiedKind != ValueKind.Null)) {
            throw IllegalStateException("policy data reference projection changed") }
        strings[id]
    }
    func slice(reference: AgentValue, offset: Int64, count: Int64): String {
        let source = value(reference)
        if (offset < 0 || count < 0 || offset > source.size || count > source.size - offset) {
            throw IllegalStateException("policy data range is invalid") }
        // String slicing also rejects a range splitting UTF-8. The host never
        // rounds a provider's recipe to a different set of source bytes.
        source[offset..offset + count]
    }
    func chunk(reference: AgentValue, offset: Int64): String {
        let source = value(reference)
        if (offset < 0 || offset > source.size) { throw IllegalStateException("invalid policy fragment offset") }
        var end = min(source.size, offset + min(262144, source.size - offset))
        let raw = unsafe { source.rawData() }
        while (end < source.size && end > offset && (raw[end] & 0xC0) == 0x80) { end-- }
        source[offset..end]
    }
    // Recipe shape is intentionally nonrecursive. No multiplication, arbitrary
    // selector, expression, path or provider-supplied source is executable.
    func compose(recipe: AgentValue, maximum: Int64): String {
        if (closed || maximum < 0 || maximum > 8388608 || recipe.unifiedKind != ValueKind.List ||
            recipe.items.size > 4096) { throw IllegalStateException("invalid policy output recipe") }
        var bytes: Int64 = 0
        for (part in recipe.items) {
            let length: Int64
            if (httpIntentExactFields(part, ["literal"])) {
                let text = part.field("literal").getOrThrow()
                if (text.unifiedKind != ValueKind.Text || text.text.size > 65536) {
                    throw IllegalStateException("policy recipe literal exceeds its bound") }
                length = text.text.size
            } else {
                if (!httpIntentExactFields(part, ["source", "offset", "bytes"])) {
                    throw IllegalStateException("unknown policy recipe operation") }
                let source = value(part.field("source").getOrThrow())
                let offset = compactionPageInteger(part, "offset")
                length = compactionPageInteger(part, "bytes")
                if (offset < 0 || length < 0 || offset > source.size || length > source.size - offset) {
                    throw IllegalStateException("policy recipe range is invalid") }
            }
            if (length > maximum - bytes) { throw IllegalStateException("policy recipe expanded size exceeds destination") }
            bytes += length
        }
        // Existing native allocation pool accounts all retained intern results
        // and this output's byte/UTF8/JSON copies before allocation. Repeated
        // references are counted each time, even when they share an intern ID.
        reserve(bytes * 8)
        try {
            let output = Array<Byte>(bytes, repeat: 0); var cursor: Int64 = 0
            for (part in recipe.items) {
                let text = if (part.field("literal").isSome()) { part.field("literal").getOrThrow().text } else {
                    slice(part.field("source").getOrThrow(), compactionPageInteger(part, "offset"),
                        compactionPageInteger(part, "bytes")) }
                for (byte in unsafe { text.rawData() }) { output[cursor] = byte; cursor++ }
            }
            let value = String.fromUtf8(output)
            // Transfer to retained immutable data before releasing temporary
            // construction cost. Duplicate recipes reuse the existing entry.
            let _ = intern(value)
            value
        } finally { release(bytes * 8) }
    }
    func internRecipe(recipe: AgentValue): AgentValue { intern(compose(recipe, 8388608)) }
    func close(): Unit {
        if (!closed) {
            canonicalBorrowed113.clear()
            closed = true; strings.clear(); indexes.clear()
            for (entry in reservations) { entry.close() }
            reservations.clear(); charged = 0; retained = 0
        }
    }
}

// Detach all mutable JSON containers before the first provider query. This
// helper neither normalizes nor classifies source values. The caller owns the
// canonical snapshot/selection/token and never exports these nodes directly.
func freezeProductPolicyData(value: AgentValue): AgentValue {
    match (value.unifiedKind) {
        case ValueKind.Null => nullValue()
        case ValueKind.Boolean => boolValue(value.asBool())
        case ValueKind.Number => numberValue(value.asNumberText())
        case ValueKind.Text => textValue(value.text)
        case ValueKind.List => listValue(value.items.toArray().map { child => freezeProductPolicyData(child) })
        case ValueKind.Object => objectValue(value.fields.toArray().map { field =>
            ValueField(field.name, freezeProductPolicyData(field.value)) })
    }
}

func productPolicyCopyMultiply113(value: Int64, factor: Int64): Int64 {
    if (value < 0 || factor < 1 || value > Int64.Max / factor) {
        throw IllegalStateException("policy copy payment overflow") }
    value * factor
}
