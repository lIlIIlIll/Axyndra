package agent_product

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import yjson.*
import yjson_support.*

class CheckpointFirstCallData113 {
    let call: AgentValue
    let name: AgentValue
    init(call: AgentValue, name: AgentValue) { this.call = call; this.name = name }
}

// The original result correlation searches the COMPLETE history, including a
// first matching call located after its result. This independent small index
// preserves that rule. No payload/ThreadItem/String backing is retained.
class CheckpointOwnedHistoryData113 {
    let firstCalls = HashMap<String, CheckpointFirstCallData113>()
    var state: AgentValue = nullValue()
    init() {}
    func clear(): Unit { firstCalls.clear(); state = nullValue() }
}

func checkpointOwnedHistoryCurrent113(query: ProductCompactionReferenceQuery): Result<Unit> {
    query.check(); Result<Unit>.Ok(())
}

func checkpointOwnedHistoryEvent113(query: ProductCompactionReferenceQuery,
    index: CheckpointOwnedHistoryData113, item: ThreadItem): AgentValue {
    match (item.content) {
        case ThreadItemContent.ToolCall(call, name, _) =>
            objectValue([ValueField("kind", textValue("call")), ValueField("ordinal", integerValue(item.ordinal)),
                ValueField("name", query.references.captureDetachedText113(name)),
                ValueField("call_id", query.references.captureDetachedText113(call.value)),
                ValueField("is_error", boolValue(false))])
        case ThreadItemContent.ToolResult(call, _, _, _, failed) =>
            let name = match (index.firstCalls.get(call.value)) {
                case Some(actual) => actual.name
                case None => query.references.intern("") }
            objectValue([ValueField("kind", textValue("result")), ValueField("ordinal", integerValue(item.ordinal)),
                ValueField("name", name), ValueField("call_id", query.references.captureDetachedText113(call.value)),
                ValueField("is_error", boolValue(failed))])
        case _ => objectValue([ValueField("kind", textValue("other")), ValueField("ordinal", integerValue(item.ordinal)),
            ValueField("name", nullValue()), ValueField("call_id", nullValue()), ValueField("is_error", boolValue(false))])
    }
}

// Functional opt-in data path, not yet a replacement for prefix/summary save.
// Every old ordinal is read whole under its original codec; total comes from
// the actual SQLite boundary, not Native metadata or a newest-N projection.
func checkpointSaveActualOwnedHistory113(query: ProductCompactionReferenceQuery,
    cursor: SqlitePaidCanonicalThreadCursor113, thread: ThreadId, revision: Int64,
    nextOrdinal: Int64, target: String, localGuard: () -> Result<Unit>,
    routeRecipe173!: ?AgentValue = None<AgentValue>): AgentValue {
    if (nextOrdinal < 1) { throw IllegalStateException("checkpoint history boundary is invalid") }
    let current: () -> Result<Unit> = { => checkpointOwnedHistoryCurrent113(query) }
    compactionDataRequire(current())
    compactionDataRequire(cursor.requireBoundary(thread, revision, nextOrdinal, localGuard))
    let index = CheckpointOwnedHistoryData113()
    try {
        // No Native call is made inside the Store's original read transaction.
        // The complete prepass builds only detached first-call name/ID data.
        for (ordinal in 1..nextOrdinal) {
            compactionDataRequire(cursor.withOrdinal(thread, revision, nextOrdinal, ordinal, localGuard, current,
                { item, _ =>
                    match (item.content) {
                        case ThreadItemContent.ToolCall(call, name, _) =>
                            if (index.firstCalls.get(call.value).isNone()) {
                                query.references.retainCheckpointIndexEntry113()
                                let id = query.references.captureDetachedText113(call.value)
                                let detachedName = query.references.captureDetachedText113(name)
                                index.firstCalls[query.references.value(id)] = CheckpointFirstCallData113(id, detachedName)
                            }
                        case _ => () }
                    Result<Unit>.Ok(())
                }))
        }
        let total = nextOrdinal - 1
        index.state = query.query(canonicalProjectionPhase173(routeRecipe173, "execution", "begin", "checkpoint_begin"),
            [ValueField("total", integerValue(total))])
        let actualTarget = query.references.intern(target)
        for (after in [false, true]) {
            if (after) {
                let next = query.query(canonicalProjectionPhase173(routeRecipe173, "execution", "second_begin", "checkpoint_after_begin"),
                    [ValueField("state", index.state)])
                query.release(index.state); index.state = next }
            var offset: Int64 = 0
            while (offset < total) {
                let end = min(total, offset + 64)
                let metadata = query.references.checkpointBatchMetadata113()
                try {
                    // All row borrows have returned/ACKed before the batch RPC.
                    // Values contain only detached references and scalar data.
                    checkpointOwnedHistoryBatch113(query, cursor, index, thread, revision, nextOrdinal,
                        offset, end, after, actualTarget, localGuard, current, routeRecipe173)
                } finally { metadata.close() }
                offset = end
            }
        }
        compactionDataRequire(current())
        compactionDataRequire(cursor.requireBoundary(thread, revision, nextOrdinal, localGuard))
        let result = index.state; index.state = nullValue()
        result
    } finally { index.clear() }
}

func checkpointOwnedHistoryBatch113(query: ProductCompactionReferenceQuery,
    cursor: SqlitePaidCanonicalThreadCursor113, index: CheckpointOwnedHistoryData113,
    thread: ThreadId, revision: Int64, nextOrdinal: Int64, offset: Int64, end: Int64,
    after: Bool, target: AgentValue, localGuard: () -> Result<Unit>, current: () -> Result<Unit>, routeRecipe173: ?AgentValue): Unit {
    let events = ArrayList<AgentValue>()
    try {
        for (at in offset..end) {
            compactionDataRequire(cursor.withOrdinal(thread, revision, nextOrdinal, at + 1, localGuard, current,
                { item, _ => events.add(checkpointOwnedHistoryEvent113(query, index, item)); Result<Unit>.Ok(()) }))
        }
        let batch = query.copy(listValue(events.toArray()))
        try {
            let fields = ArrayList<ValueField>([ValueField("state", index.state), ValueField("events", batch)])
            if (!after) { fields.add(ValueField("target_call", target)) }
            let next = query.query(canonicalProjectionPhase173(routeRecipe173, "execution",
                if (after) { "second_batch" } else { "first_batch" },
                if (after) { "checkpoint_after_batch" } else { "checkpoint_latest_batch" }), fields.toArray())
            if (compactionPageInteger(next, "offset") != end || compactionPageInteger(next, "total") != nextOrdinal - 1) {
                throw IllegalStateException("checkpoint save did not consume the complete actual event batch") }
            query.release(index.state); index.state = next
        } finally { query.release(batch) }
    } finally { events.clear() }
}

// Opt-in bridge captures the original dynamic error WHILE query/source data
// are still paid. It never exports error.error after query.close(). The caller
// routes this typed consumer to actual error consumers; no canonical execution
// result is reclassified and no public AgentError receives a fake payload lease.
func checkpointSaveOwnedHistoryProgress113(query: ProductCompactionReferenceQuery,
    cursor: SqlitePaidCanonicalThreadCursor113, thread: ThreadId, revision: Int64,
    nextOrdinal: Int64, target: String, localGuard: () -> Result<Unit>,
    allocate: (Int64) -> LogicalJsonOwnerReservation): OwnedFailureDataOutcome113<AgentValue> {
    try { OwnedFailureDataOutcome113<AgentValue>.Value(checkpointSaveActualOwnedHistory113(
        query, cursor, thread, revision, nextOrdinal, target, localGuard)) }
    catch (failure: ProductCompactionDataError) {
        let actual = OwnedFailureData113(failure.error, allocate)
        try {
            match (actual.retainConsumer()) {
                case Result.Err(error) => throw ProductCompactionDataError(error)
                case Result.Ok(consumer) => OwnedFailureDataOutcome113<AgentValue>.Failure(consumer) }
        } finally {
            match (actual.closeAfterProducerRetirement()) { case Result.Ok(_) => ()
                case Result.Err(_) => throw IllegalStateException("paid error producer still has an active borrow") }
        }
    }
}
