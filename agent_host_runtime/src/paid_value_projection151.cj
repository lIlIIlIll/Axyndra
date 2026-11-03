package agent_host_runtime

import agent_domain.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.io.*

// DATA projection only. References are private members of this allocation,
// never an Operation/Source/permission. The caller passes the actual old bank.
public class HostPaidValueProjection151 {
    private let lock = Mutex()
    private let owner: LogicalJsonOwnerReservation
    private var values: ?ArrayList<HostProjectionValue151> = Some(ArrayList<HostProjectionValue151>())
    private var fields: ?ArrayList<HostProjectionField151> = Some(ArrayList<HostProjectionField151>())
    private var output: ?AgentValue = Option<AgentValue>.None
    // Fixed private headers AND the eventual canonical publication carrier
    // are prepaid together; transferring completed DATA needs no new budget.
    private var retained: Int64 = 13312
    private var borrowed: Int64 = 0
    private var published = false
    private var closed = false

    public init(owner: LogicalJsonOwnerReservation) {
        owner.ensureRetainedPeak(retained)
        this.owner = owner
    }
    private func available(): Unit {
        if (closed || published) { throw IllegalStateException("projection data is retired or published") }
    }
    private func fund(bytes: Int64, nodes: Int64): Unit {
        if (bytes < 0 || nodes < 0 || bytes > (Int64.Max - 4096) / 8 ||
            nodes > (Int64.Max - 4096 - bytes * 8) / 512) {
            throw LogicalJsonPayloadError("projection allocation invoice overflow") }
        let additional = bytes * 8 + nodes * 512 + 4096
        if (retained > Int64.Max - additional) { throw LogicalJsonPayloadError("projection retained SUM overflow") }
        owner.ensureRetainedPeak(retained + additional)
        retained += additional
    }
    public func fundAdditional151(bytes: Int64, nodes: Int64): Unit {
        lock.lock()
        try { available(); fund(bytes, nodes) } finally { lock.unlock() }
    }
    public func deriveDataPhase151(invoice: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            available()
            let actual = owner.deriveRetainedLease()
            try { actual.ensureRetainedPeak(invoice); actual }
            catch (error: Exception) { actual.close(); throw error }
        } finally { lock.unlock() }
    }
    private func measureLocked151(value: AgentValue): HostProjectionMeasure151 {
        // The returned fixed counter remains charged to this actual owner.
        // Scalar writer temporaries use a real child of that SAME paid root.
        fund(4096, 8)
        let phase = owner.deriveRetainedLease()
        try {
            phase.ensureRetainedPeak(1048576)
            let measured = hostProjectionMeasure151(value, { bytes => phase.ensureRetainedPeak(bytes) })
            measured.clearScalarPayment151()
            measured
        } finally { phase.close() }
    }
    public func measureBorrowedValue151(value: AgentValue): HostProjectionMeasure151 {
        lock.lock()
        try { available(); measureLocked151(value) } finally { lock.unlock() }
    }
    public func retainValue151(reference: Int64, value: AgentValue): Unit {
        lock.lock()
        try {
            available()
            for (entry in values.getOrThrow() where entry.reference == reference) {
                throw IllegalArgumentException("duplicate projection reference") }
            let measured = measureLocked151(value)
            let bytes = measured.bytes
            let nodes = measured.nodes
            // The caller already pays the source. This structural copy creates
            // decoded UTF8 backing and nodes, not an escaped JSON String. Pay
            // both construction overlap and all nodes BEFORE copying them.
            fund(measured.storageBytes * 2, nodes + 1)
            let copy = hostProjectionCopy151(value)
            values.getOrThrow().add(HostProjectionValue151(reference, copy, bytes, nodes))
        } finally { lock.unlock() }
    }
    public func retainText151(reference: Int64, text: String): Unit {
        // The temporary node aliases the already-paid input String. The actual
        // independent UTF8 copy is paid by retainValue151 before construction.
        fundAdditional151(0, 1)
        retainValue151(reference, textValue(text))
    }
    public func retainParsedJson151(reference: Int64, text: String): Bool {
        // Preserve the original decoder's default 1 MiB byte/depth behavior.
        // No Source fact is obtained from parsing arbitrary data.
        if (text.size > 1048576) { return false }
        // A private temporary phase derives from this EXACT reservation. Its
        // whole reader/DOM frame returns only Bool after the independent copy
        // is paid. No parser reference escapes before phase retirement; the
        // shared physical high-water charge remains until the final owner ACK.
        let phase = deriveDataPhase151(4096)
        try { hostProjectionParseAndRetain151(this, phase, reference, text) }
        finally { phase.close() }
    }
    public func retainField151(collection: Int64, name: String, reference: Int64): Unit {
        lock.lock()
        try {
            available()
            let value = findValue(reference)
            // Every occurrence gets its own field/name storage; its value is
            // the actual private paid member, without a second DOM copy.
            fund(name.size * 2, 2)
            fields.getOrThrow().add(HostProjectionField151(collection, hostProjectionCopyText151(name), reference))
        } finally { lock.unlock() }
    }
    private func findValue(reference: Int64): HostProjectionValue151 {
        for (value in values.getOrThrow() where value.reference == reference) { return value }
        throw IllegalArgumentException("projection reference is not an actual private member")
    }
    public func projectValue151(reference: Int64): Unit {
        lock.lock()
        try { available(); output = Some(findValue(reference).value) } finally { lock.unlock() }
    }
    public func projectFields151(collection: Int64): Unit {
        lock.lock()
        try {
            available()
            var count: Int64 = 0
            for (entry in fields.getOrThrow() where entry.collection == collection) { count += 1 }
            fund(2, count * 2 + 1)
            let selected = ArrayList<ValueField>()
            for (entry in fields.getOrThrow() where entry.collection == collection) {
                selected.add(ValueField(entry.name, findValue(entry.reference).value)) }
            output = Some(objectValue(selected.toArray()))
        } finally { lock.unlock() }
    }
    public func withValue151(consume: (AgentValue) -> Unit): Unit {
        let value: AgentValue
        lock.lock()
        try { available(); value = output.getOrThrow(); borrowed += 1 } finally { lock.unlock() }
        try { consume(value) } finally {
            lock.lock(); try { borrowed -= 1 } finally { lock.unlock() }
        }
    }
    // Alias only the actual selected value already paid in this private owner.
    // The numeric member cannot be supplied by IPC without this real backing.
    public func retainProjectedMember151(reference: Int64): Unit {
        lock.lock()
        try {
            available()
            for (entry in values.getOrThrow() where entry.reference == reference) {
                throw IllegalArgumentException("duplicate projection reference") }
            let actual = output.getOrThrow()
            let measured = measureLocked151(actual)
            let bytes = measured.bytes
            let nodes = measured.nodes
            fund(4096, 2)
            values.getOrThrow().add(HostProjectionValue151(reference, actual, bytes, nodes))
        } finally { lock.unlock() }
    }
    public func projectRecipe151(recipe: AgentValue): Unit {
        lock.lock()
        try {
            available()
            if (borrowed != 0) { throw IllegalStateException("projection loan is active") }
            let measured = measureLocked151(recipe)
            let bytes = measured.bytes
            let nodes = measured.nodes
            fund(measured.storageBytes * 2, nodes * 2 + 1)
            output = Some(evaluate151(recipe, 0))
        } finally { lock.unlock() }
    }
    private func evaluate151(recipe: AgentValue, depth: Int64): AgentValue {
        if (recipe.unifiedKind != ValueKind.Object) {
            throw IllegalArgumentException("invalid projection expression") }
        let kind = httpIntentText(recipe, "kind")
        if (kind == "member" || kind == "encoded_text") {
            if (!httpIntentExactFields(recipe, ["kind", "reference"])) {
                throw IllegalArgumentException("invalid member expression") }
            let reference = recipe.field("reference").getOrThrow()
            if (reference.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("invalid member number") }
            let member = findValue(Int64.parse(reference.asNumberText()))
            if (kind == "member") { return member.value }
            // The complete encoded String and new text-node backing coexist
            // with the actual retained member; invoice BEFORE either exists.
            fund(member.bytes * 2, 2)
            textValue(if (member.value.unifiedKind == ValueKind.Text) { member.value.text }
                else { encodeAgentValue(member.value) })
        } else if (kind == "literal") {
            if (!httpIntentExactFields(recipe, ["kind", "value"])) {
                throw IllegalArgumentException("invalid literal expression") }
            let value = recipe.field("value").getOrThrow()
            let measured = measureLocked151(value)
            let bytes = measured.bytes
            let nodes = measured.nodes
            fund(measured.storageBytes * 2, nodes * 2)
            hostProjectionCopy151(value)
        } else if (kind == "object") {
            if (!httpIntentExactFields(recipe, ["kind", "fields"])) {
                throw IllegalArgumentException("invalid object expression") }
            let source = recipe.field("fields").getOrThrow()
            if (source.unifiedKind != ValueKind.Object) { throw IllegalArgumentException("invalid object fields") }
            let sourceObject = source.asObject()
            fund(0, 2)
            let selected = ArrayList<ValueField>()
            for (index in 0..sourceObject.size()) {
                let name = sourceObject.nameAt(index)
                fund(name.size * 2, 2)
                selected.add(ValueField(hostProjectionCopyText151(name), evaluate151(sourceObject.valueAt(index), depth + 1))) }
            objectValue(selected.toArray())
        } else { throw IllegalArgumentException("unknown projection expression") }
    }
    public func publicationLease151(): ToolResultPayloadLease {
        lock.lock()
        try {
            available()
            if (borrowed != 0 || output.isNone()) { throw IllegalStateException("projection frame is still active") }
            // The publication carrier was paid before any projection DATA.
            // No new loan/allocation invoice is admitted during transfer.
            published = true
            ToolResultPayloadLease({ => retirePublished151() })
        } finally { lock.unlock() }
    }
    private func retirePublished151(): Unit {
        lock.lock()
        try {
            if (closed) { return }
            if (!published || borrowed != 0) { throw IllegalStateException("projection retirement is not quiescent") }
            output = Option<AgentValue>.None
            values = Option<ArrayList<HostProjectionValue151>>.None
            fields = Option<ArrayList<HostProjectionField151>>.None
            closed = true
            owner.close()
        } finally { lock.unlock() }
    }
    public func closeUnpublished151(): Unit {
        lock.lock()
        try {
            if (closed) { return }
            if (published || borrowed != 0) { throw IllegalStateException("projection still has a publication or loan") }
            output = Option<AgentValue>.None
            values = Option<ArrayList<HostProjectionValue151>>.None
            fields = Option<ArrayList<HostProjectionField151>>.None
            closed = true
            owner.close()
        } finally { lock.unlock() }
    }
}

class HostProjectionValue151 {
    let reference: Int64
    let value: AgentValue
    let bytes: Int64
    let nodes: Int64
    init(reference: Int64, value: AgentValue, bytes: Int64, nodes: Int64) {
        this.reference = reference; this.value = value; this.bytes = bytes; this.nodes = nodes
    }
}
class HostProjectionField151 {
    let collection: Int64
    let name: String
    let reference: Int64
    init(collection: Int64, name: String, reference: Int64) {
        this.collection = collection; this.name = name; this.reference = reference
    }
}

public class HostProjectionMeasure151 {
    public var bytes: Int64 = 0
    public var storageBytes: Int64 = 0
    public var nodes: Int64 = 0
    private var lower: Int64 = 0
    private var scalarPayment: ?(Int64) -> Unit
    init() { scalarPayment = Option<(Int64) -> Unit>.None }
    init(fundScalar: (Int64) -> Unit) { scalarPayment = Some(fundScalar) }
    func clearScalarPayment151(): Unit { scalarPayment = Option<(Int64) -> Unit>.None }
    private func fundScalar(bytes: Int64): Unit {
        match (scalarPayment) { case Some(fund) => fund(bytes); case None => () }
    }
    func add(bytes: Int64, nodes: Int64): Unit {
        if (bytes < 0 || nodes < 0 || this.bytes > Int64.Max - bytes || this.nodes > Int64.Max - nodes) {
            throw LogicalJsonPayloadError("projection shape SUM overflow") }
        this.bytes += bytes; this.nodes += nodes
    }
    func scan(value: AgentValue): Unit {
        if (value.unifiedKind == ValueKind.Text) {
            extent(value.text.size + 2); storage(value.text.size); stringBytes(value.text); add(0, 1) }
        else if (value.unifiedKind == ValueKind.Number) {
            // asNumberText is only an allocation upper-bound input. Its
            // Float64 spelling is NEVER used as the original JSON bytes.
            fundScalar(1048576)
            let estimate = max(40, value.asNumberText().size)
            if (estimate > (Int64.Max - 1048576) / 2) {
                throw LogicalJsonPayloadError("projection scalar payment overflow") }
            fundScalar(1048576 + estimate * 2)
            let encoded = HostProjectionScalarCount151()
            value.writeJson(encoded, options: JsonWriteOptions.defaults)
            extent(encoded.bytes); storage(max(estimate, encoded.bytes)); add(encoded.bytes, 1) }
        else if (value.unifiedKind == ValueKind.Null) { extent(4); add(4, 1) }
        else if (value.unifiedKind == ValueKind.Boolean) { extent(4); add(if (value.asBool()) { 4 } else { 5 }, 1) }
        else if (value.unifiedKind == ValueKind.List) {
            extent(2); add(2, 1)
            let array = value.asArray()
            for (index in 0..array.size()) {
                if (index != 0) { add(1, 0) }
                scan(array.get(index).getOrThrow()) }
        } else if (value.unifiedKind == ValueKind.Object) {
            extent(2); add(2, 1)
            let object = value.asObject()
            for (index in 0..object.size()) {
                if (index != 0) { add(1, 0) }
                let name = object.nameAt(index)
                extent(name.size + 3); storage(name.size); stringBytes(name); add(1, 1); scan(object.valueAt(index)) }
        } else { throw IllegalArgumentException("unsupported projection value kind") }
    }
    private func storage(bytes: Int64): Unit {
        if (bytes < 0 || storageBytes > Int64.Max - bytes) {
            throw LogicalJsonPayloadError("projection UTF8 storage SUM overflow") }
        storageBytes += bytes
    }
    private func stringBytes(value: String): Unit {
        // The pinned default writer's exact UTF8 escape extent, as used by the
        // original Store terminal extent visitor. No new String/DOM is built.
        add(2, 0)
        let options = JsonWriteOptions.defaults
        unsafe {
            let raw = value.rawData()
            for (index in 0..raw.size) {
                let byte = Int64(raw[index])
                if (byte == 34 || byte == 92 || byte == 8 || byte == 9 || byte == 10 || byte == 12 || byte == 13) { add(2, 0) }
                else if (byte < 32 || (options.htmlSafe && (byte == 38 || byte == 39 || byte == 60 || byte == 61 || byte == 62))) { add(6, 0) }
                else { add(1, 0) }
            }
        }
    }
    private func extent(bytes: Int64): Unit {
        // Preserve the original 64 MiB write-extent lower-bound check. Count
        // all real occurrences; no new node-count ceiling accompanies it.
        if (bytes < 0 || bytes > LOGICAL_JSON_HARD_BYTES || lower > LOGICAL_JSON_HARD_BYTES - bytes) {
            throw LogicalJsonPayloadError("projection value exceeds original write extent") }
        lower += bytes
    }
}
// Exactly the pinned default writer receives each numeric node. The sink
// keeps only one counter and no scalar bytes; its caller prepays the original
// writer's buffer/raw-slice and Float64 fallback temporary before construction.
class HostProjectionScalarCount151 <: OutputStream {
    var bytes: Int64 = 0
    init() {}
    public func write(value: Array<Byte>): Unit {
        if (value.size > LOGICAL_JSON_HARD_BYTES - bytes) {
            throw LogicalJsonPayloadError("projection scalar exceeds original write extent") }
        bytes += value.size
    }
    public func flush(): Unit { () }
}
// No new flat node/recipe/depth ceiling. The accepted original DATA shape is
// measured completely; its ACTUAL cumulative invoice may exhaust the unchanged
// process-wide bank. That pressure is distinct from the original JSON parser.
public func hostProjectionMeasure151(value: AgentValue): HostProjectionMeasure151 {
    let measured = HostProjectionMeasure151(); measured.scan(value); measured
}
public func hostProjectionMeasure151(value: AgentValue, fundScalar: (Int64) -> Unit): HostProjectionMeasure151 {
    let measured = HostProjectionMeasure151(fundScalar); measured.scan(value); measured
}
func hostProjectionCopyText151(value: String): String { String.fromUtf8(value.toArray()) }
class HostProjectionParserPayment151 {
    let owner: LogicalJsonOwnerReservation
    var retained: Int64 = 4096
    init(owner: LogicalJsonOwnerReservation) { this.owner = owner; owner.ensureRetainedPeak(retained) }
    func fund(bytes: Int64, nodes: Int64): Unit {
        if (bytes < 0 || nodes < 0 || bytes > (Int64.Max - 4096) / 8 ||
            nodes > (Int64.Max - 4096 - bytes * 8) / 512) {
            throw LogicalJsonPayloadError("projection parser invoice overflow") }
        let additional = bytes * 8 + nodes * 512 + 4096
        if (retained > Int64.Max - additional) { throw LogicalJsonPayloadError("projection parser SUM overflow") }
        owner.ensureRetainedPeak(retained + additional); retained += additional
    }
}
func hostProjectionSemanticAccepts151(text: String): Bool {
    try {
        let reader = GeneratedSupportV1.newSemanticReader(text, JsonReadOptions(
            duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject, maxDepth: 64,
            maxStringBytes: 1048576, maxInputBytes: 1048576, maxBufferedValueBytes: 1048576))
        reader.skipValue(); GeneratedSupportV1.finishReader(reader); true
    } catch (_: JsonException) { false }
}
func hostProjectionParseAndRetain151(projection: HostPaidValueProjection151,
    phase: LogicalJsonOwnerReservation, reference: Int64, text: String): Bool {
    let payment = HostProjectionParserPayment151(phase)
    // No lexical-node cutoff: this counter only prepays storage. Validity,
    // duplicate names, depth and EOF use the pinned semantic reader. Its key
    // Strings and doubled name arrays are included before reader construction.
    let lexical = hostProjectionLexicalPaidFrame187(phase, text)
    if (!hostProjectionSemanticPaidFrame187(phase, text, lexical)) { return false }
    // Malformed many-token data remains TEXT without a fictional DOM. The
    // original decoder still decides the actual value/errors after full pay.
    payment.fund(text.size * 2, lexical.nodes + 1)
    match (decodeAgentValue(text)) {
        case Result.Err(_) => false
        case Result.Ok(value) => projection.retainValue151(reference, value); true
    }
}
// The lexical helper exports only three scalar counters. Its source array
// and complete payment/reader frame have returned before the child retires.
// Both children derive from the original parser reservation and never add a
// separate bank, message slot, node ceiling or larger aggregate capacity.
func hostProjectionLexicalPaidFrame187(phase: LogicalJsonOwnerReservation,
    text: String): HostProjectionLexicalInvoice151 {
    let temporary = phase.deriveRetainedLease()
    try { hostProjectionLexicalPaidWork187(temporary, text) }
    finally { temporary.close() }
}
func hostProjectionLexicalPaidWork187(temporary: LogicalJsonOwnerReservation,
    text: String): HostProjectionLexicalInvoice151 {
    let payment = HostProjectionParserPayment151(temporary)
    payment.fund(text.size * 2 + 4096, 8)
    hostProjectionLexicalInvoice151(text)
}
// The semantic reader has no surviving DOM or input callback. Only its Bool
// crosses this entire work frame; all original reader options remain exact.
func hostProjectionSemanticPaidFrame187(phase: LogicalJsonOwnerReservation,
    text: String, lexical: HostProjectionLexicalInvoice151): Bool {
    let temporary = phase.deriveRetainedLease()
    try { hostProjectionSemanticPaidWork187(temporary, text, lexical) }
    finally { temporary.close() }
}
func hostProjectionSemanticPaidWork187(temporary: LogicalJsonOwnerReservation,
    text: String, lexical: HostProjectionLexicalInvoice151): Bool {
    let payment = HostProjectionParserPayment151(temporary)
    payment.fund(text.size * 4 + lexical.nameBytes * 2, lexical.names + 8)
    hostProjectionSemanticAccepts151(text)
}
class HostProjectionLexicalInvoice151 {
    var nodes: Int64 = 0
    var names: Int64 = 0
    var nameBytes: Int64 = 0
    init() {}
}
func hostProjectionLexicalInvoice151(source: String): HostProjectionLexicalInvoice151 {
    let invoice = HostProjectionLexicalInvoice151()
    let bytes = source.toArray()
    var quoted = false
    var escaped = false
    var scalar = false
    var quotedStart: Int64 = 0
    var quotedEnd: Int64 = -1
    for (offset in 0..bytes.size) {
        let byte = bytes[offset]
        if (quoted) {
            if (escaped) { escaped = false }
            else if (byte == b'\\') { escaped = true }
            else if (byte == b'"') { quoted = false; quotedEnd = offset }
        } else if (byte == b'"') {
            quoted = true; scalar = false; quotedStart = offset; quotedEnd = -1; invoice.nodes++
        } else if (byte == b':') {
            if (quotedEnd >= 0) {
                invoice.names++; invoice.nameBytes += quotedEnd - quotedStart + 1 }
            scalar = false; quotedEnd = -1
        } else if (byte == b' ' || byte == b'\t' || byte == b'\r' || byte == b'\n') { () }
        else if (byte == b'{' || byte == b'[') { scalar = false; quotedEnd = -1; invoice.nodes++ }
        else if (byte == b',' || byte == b'}' || byte == b']') { scalar = false; quotedEnd = -1 }
        else if (!scalar) { scalar = true; quotedEnd = -1; invoice.nodes++ }
    }
    invoice
}
func hostProjectionCopy151(value: AgentValue): AgentValue {
    if (value.unifiedKind == ValueKind.Text) { textValue(hostProjectionCopyText151(value.text)) }
    else if (value.unifiedKind == ValueKind.Number) {
        // This is one scalar only. The pinned public materialize(1) creates
        // a new Int/UInt/Float/Literal node of the original concrete subtype.
        // The existing full extent/node invoice also funds its small budget,
        // empty ancestor list and immutable literal backing for this owner.
        // It never traverses a container or applies a new tree node ceiling.
        value.materialize(1) }
    else if (value.unifiedKind == ValueKind.Null) { nullValue() }
    else if (value.unifiedKind == ValueKind.Boolean) { boolValue(value.asBool()) }
    else if (value.unifiedKind == ValueKind.List) {
        let array = value.asArray()
        let copied = JsonArray()
        for (index in 0..array.size()) { copied.insert(copied.size(), hostProjectionCopy151(array.get(index).getOrThrow())) }
        copied }
    else if (value.unifiedKind == ValueKind.Object) {
        let object = value.asObject()
        let copied: AgentValue = JsonObject()
        for (index in 0..object.size()) {
            copied.put(hostProjectionCopyText151(object.nameAt(index)), hostProjectionCopy151(object.valueAt(index))) }
        copied
    } else { throw IllegalArgumentException("unsupported projection value kind") }
}
