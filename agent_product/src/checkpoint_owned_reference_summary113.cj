package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

class CheckpointReferenceState113 {
    var value: AgentValue
    init(value: AgentValue) { this.value = value }
}

// The installed provider keeps every original classification/reduction/fold
// rule. Only complete canonical DATA transport differs. Its row callback is
// after SQL unlock; every borrowed text is retired/copied before row ACK.
func checkpointOwnedReferenceSummary113(query: ProductCompactionReferenceQuery,
    cursor: PaidCanonicalThreadCursor113, thread: ThreadRecord, through: Int64,
    allocate: (Int64) -> LogicalJsonOwnerReservation, localGuard: () -> Result<Unit>): String {
    let current: () -> Result<Unit> = { => query.checkPinnedData113(); Result<Unit>.Ok(()) }
    let layout = query.query("reference_layout", [])
    query.configureLayout(layout)
    let selectors = layout.field("arguments").getOrThrow()
    if (selectors.unifiedKind != ValueKind.List || selectors.items.size > 32) {
        throw IllegalStateException("invalid projection selectors") }
    let state = CheckpointReferenceState113(layout.field("state").getOrThrow())
    compactionDataRequire(visitOwnedCanonicalModelMessages113(cursor, thread.id, thread.revision,
        thread.nextItemOrdinal, through, allocate, localGuard, current, { role =>
            state.value = query.replaceEvent(state.value, objectValue([ValueField("kind", textValue("message")),
                ValueField("role", checkpointProjectionRole113(role))]))
        }, { role, block, custody =>
            compactionDataRequire(custody.ensureAdditionalRetainedPeak(65536))
            let metadata = query.references.checkpointBatchMetadata113()
            try {
                // This helper frame contains all original row String aliases.
                // Native transport has really returned before it ends.
                checkpointOwnedReferenceBlock113(query, state, selectors, role, block)
                // All event/input local Node frames are now gone. Real Native
                // state/result leases determine which actual strings survive.
                query.retireCompletedEventInputs113()
            } finally { metadata.close() }
        }))
    // Checkpoint's original structure call supplies null goal / empty todos.
    // No checkpoint business field is interpreted by this transport.
    let final = query.query("reference_finish", [ValueField("state", state.value)])
    if (!httpIntentExactFields(final, ["snapshot_digest", "recipe"]) ||
        !query.matchesSourceDigest113(httpIntentText(final, "snapshot_digest"))) {
        throw IllegalStateException("invalid final reference recipe") }
    query.check()
    let summary = query.references.compose(final.field("recipe").getOrThrow(), 8388608)
    query.check(); summary
}

func checkpointOwnedReferenceBlock113(query: ProductCompactionReferenceQuery, state: CheckpointReferenceState113,
    selectors: AgentValue, role: ModelRole, block: ModelBlock): Unit {
    let arguments = ArrayList<ValueField>(); let seen = HashSet<String>()
    for (selector in selectors.items) {
        if (!httpIntentExactFields(selector, ["field", "kind"])) { throw IllegalStateException("invalid projection selector") }
        let field = httpIntentText(selector, "field"); let kind = httpIntentText(selector, "kind")
        if (field == "" || field.size > 128 || seen.contains(field) || !["text", "number"].contains(kind)) {
            throw IllegalStateException("invalid scalar projection selector") }
        seen.add(field)
        let node = block.arguments.field(field) ?? nullValue()
        let text = if (kind == "text" && node.unifiedKind == ValueKind.Text) { node.text }
            else if (kind == "number" && node.unifiedKind == ValueKind.Number) { node.asNumberText() } else { "" }
        arguments.add(ValueField(field, query.references.captureCanonicalBorrowedText113(text)))
    }
    let encoded = checkpointOriginalBlockValue113(role, block)
    state.value = query.replaceEvent(state.value, objectValue([ValueField("kind", encoded.field("kind").getOrThrow()),
        ValueField("role", checkpointProjectionRole113(role)), ValueField("name", query.references.captureCanonicalBorrowedText113(block.name)),
        ValueField("text", query.references.captureCanonicalBorrowedText113(block.text)), ValueField("is_error", boolValue(block.isError)),
        ValueField("arguments", objectValue(arguments.toArray()))]))
}
